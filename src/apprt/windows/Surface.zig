/// Win32 Surface — one terminal tab (child window).
///
/// Each Surface owns:
///   - A Win32 child HWND (WS_CHILD, parented to Window)
///   - A WGL OpenGL context (hdc + hglrc)
///   - An initialized CoreSurface (the terminal state + renderer)
///
/// The Surface is always heap-allocated so that its address (and the address
/// of its embedded CoreSurface) is stable for the lifetime of the tab.
const Self = @This();

const std = @import("std");
const builtin = @import("builtin");
const apprt = @import("../../apprt.zig");
const configpkg = @import("../../config.zig");
const CoreSurface = @import("../../Surface.zig");
const internal_os = @import("../../os/main.zig");
const input = @import("../../input.zig");
const renderer = @import("../../renderer.zig");
const terminal = @import("../../terminal/main.zig");
const ApprtApp = @import("App.zig");
const Window = @import("Window.zig");
const win32 = @import("win32.zig");
const wgl = @import("wgl.zig");
const vkey = @import("key.zig");

const w = std.os.windows;

const log = std.log.scoped(.win32_surface);

// ---------------------------------------------------------------------------
// State fields
// ---------------------------------------------------------------------------

/// Win32 child window handle.
hwnd: win32.HWND,

/// WGL rendering context.
hdc: win32.HDC,
hglrc: wgl.HGLRC,

/// The core terminal surface (owns the PTY, renderer, terminal state).
core_surface: CoreSurface,
core_surface_initialized: bool,

/// Back-reference to the parent Window.
window: *Window,

/// Current dimensions (physical pixels of the child area).
width: u32,
height: u32,

/// DPI scaling factor relative to 96 DPI.
scale_x: f32,
scale_y: f32,

/// Mouse-related state.
cursor_visible: bool,
cursor_handle: ?win32.HCURSOR,
tracking_mouse_leave: bool,

/// Cell dimensions (set by the core via cell_size action).
cell_width: u32,
cell_height: u32,

/// Current window title (set by setTitle, used by getTitle/copy_title_to_clipboard).
current_title: ?[:0]const u8,

/// Back-reference to the split tree node containing this surface (if any).
split_node: ?*@import("SplitNode.zig"),

/// Pending size from main thread, read by renderer thread.
/// Packed as (width << 32 | height), 0 means no pending resize.
pending_size: std.atomic.Value(u64),

/// Search overlay state.
search_active: bool,
search_edit_hwnd: ?win32.HWND,
search_total: ?usize,
search_selected: ?usize,

// ---------------------------------------------------------------------------
// Public init / deinit
// ---------------------------------------------------------------------------

pub fn init(self: *Self, window: *Window, x: u32, y: u32, width: u32, height: u32) !void {
    // Create a child window inside the Window's client area.
    const hwnd = try win32.createChildWindow(
        window.app.hinstance,
        window.hwnd,
        @intCast(x),
        @intCast(y),
        @intCast(width),
        @intCast(height),
        @intFromPtr(self),
    );
    errdefer win32.destroyWindow(hwnd);

    // Create WGL OpenGL context on the child's DC
    const hdc = win32.getDC(hwnd) orelse return error.GetDCFailed;
    const hglrc = try wgl.createContext(hdc);
    errdefer wgl.deleteContext(hglrc) catch {};
    try wgl.makeCurrent(hdc, hglrc);

    // Get DPI scaling from the parent window
    const dpi = win32.getDpiForWindow(window.hwnd);
    const scale: f32 = @as(f32, @floatFromInt(dpi)) / 96.0;

    self.* = .{
        .hwnd = hwnd,
        .hdc = hdc,
        .hglrc = hglrc,
        .core_surface = undefined,
        .core_surface_initialized = false,
        .window = window,
        .width = width,
        .height = height,
        .scale_x = scale,
        .scale_y = scale,
        .cursor_visible = true,
        .cursor_handle = null,
        .tracking_mouse_leave = false,
        .cell_width = 0,
        .cell_height = 0,
        .current_title = null,
        .split_node = null,
        .pending_size = std.atomic.Value(u64).init(0),
        .search_active = false,
        .search_edit_hwnd = null,
        .search_total = null,
        .search_selected = null,
    };

    // Initialize the core surface. This starts the renderer thread,
    // PTY thread, and everything else.
    try self.initCoreSurface();

    log.info("Win32 surface initialized hwnd={*} size={}x{} dpi={} scale={d:.2}", .{
        hwnd, width, height, dpi, scale,
    });
}

fn initCoreSurface(self: *Self) !void {
    const alloc = self.window.app.alloc;
    const config = &self.window.app.config;
    const core_app = self.window.app.core_app;

    try self.core_surface.init(
        alloc,
        config,
        core_app,
        self.window.app,
        self,
    );
    self.core_surface_initialized = true;
}

pub fn deinit(self: *Self) void {
    // Clean up search overlay
    if (self.search_edit_hwnd) |edit| {
        win32.destroyWindow(edit);
        self.search_edit_hwnd = null;
    }

    if (self.core_surface_initialized) {
        self.core_surface.deinit();
        self.core_surface_initialized = false;
    }

    wgl.makeCurrent(null, null) catch {};
    wgl.deleteContext(self.hglrc) catch {};
    win32.releaseDC(self.hwnd, self.hdc);
    win32.destroyWindow(self.hwnd);
}

// ---------------------------------------------------------------------------
// Apprt Surface interface (called by CoreSurface / libghostty)
// ---------------------------------------------------------------------------

pub fn core(self: *Self) *CoreSurface {
    return &self.core_surface;
}

pub fn rtApp(self: *Self) *ApprtApp {
    return self.window.app;
}

pub fn close(self: *Self, process_active: bool) void {
    if (process_active) {
        // Ask the user for confirmation before closing with active process
        const msg = "A process is still running in this terminal. Close anyway?";
        const title = "Ghostty";
        var wide_msg: [256]u16 = undefined;
        var wide_title: [64]u16 = undefined;
        const msg_len = std.unicode.utf8ToUtf16Le(&wide_msg, msg) catch 0;
        const title_len = std.unicode.utf8ToUtf16Le(&wide_title, title) catch 0;
        wide_msg[msg_len] = 0;
        wide_title[title_len] = 0;
        const result = win32.messageBoxW(
            self.window.hwnd,
            @as([*:0]const u16, @ptrCast(&wide_msg)),
            @as([*:0]const u16, @ptrCast(&wide_title)),
            win32.MB_OKCANCEL | win32.MB_ICONWARNING,
        );
        if (result != 1) return; // IDOK = 1
    }
    self.window.removeTab(self);
}

pub fn getTitle(self: *Self) ?[:0]const u8 {
    return self.current_title;
}

pub fn getContentScale(self: *const Self) !apprt.ContentScale {
    return .{ .x = self.scale_x, .y = self.scale_y };
}

pub fn getSize(self: *const Self) !apprt.SurfaceSize {
    return .{ .width = self.width, .height = self.height };
}

pub fn getCursorPos(self: *const Self) !apprt.CursorPos {
    var point: win32.POINT = .{};
    if (win32.getCursorPos(&point)) {
        _ = win32.screenToClient(self.hwnd, &point);
    }
    return .{
        .x = @floatFromInt(point.x),
        .y = @floatFromInt(point.y),
    };
}

pub fn supportsClipboard(_: *const Self, clipboard_type: apprt.Clipboard) bool {
    return switch (clipboard_type) {
        .standard => true,
        .selection, .primary => false, // X11-only concepts
    };
}

pub fn clipboardRequest(
    self: *Self,
    clipboard_type: apprt.Clipboard,
    state: apprt.ClipboardRequest,
) !bool {
    if (clipboard_type != .standard) return false;
    if (!self.core_surface_initialized) return false;

    const alloc = self.window.app.alloc;
    const text = win32.clipboardReadText(self.hwnd, alloc) orelse return false;
    defer alloc.free(text);

    const textZ = try alloc.dupeZ(u8, text);
    defer alloc.free(textZ);

    self.core_surface.completeClipboardRequest(state, textZ, false) catch |err| switch (err) {
        error.UnsafePaste => {
            // Auto-confirm multiline paste (TODO: confirmation dialog)
            self.core_surface.completeClipboardRequest(state, textZ, true) catch |err2| {
                log.warn("clipboard paste failed after confirm: {}", .{err2});
                return false;
            };
        },
        else => {
            log.warn("clipboard request completion failed: {}", .{err});
            return false;
        },
    };
    return true;
}

pub fn setClipboard(
    self: *Self,
    clipboard_type: apprt.Clipboard,
    contents: []const apprt.ClipboardContent,
    confirm: bool,
) !void {
    _ = confirm;
    if (clipboard_type != .standard) return;

    for (contents) |item| {
        if (std.mem.eql(u8, item.mime, "text/plain") or
            std.mem.eql(u8, item.mime, "text/plain;charset=utf-8"))
        {
            _ = win32.clipboardWriteText(self.hwnd, item.data);
            return;
        }
    }
    if (contents.len > 0) {
        _ = win32.clipboardWriteText(self.hwnd, contents[0].data);
    }
}

pub fn defaultTermioEnv(self: *Self) !std.process.EnvMap {
    var env = try std.process.getEnvMap(self.window.app.alloc);
    try env.put("TERM", "xterm-256color");
    try env.put("COLORTERM", "truecolor");
    try env.put("TERM_PROGRAM", "ghostty");
    return env;
}

pub fn redrawInspector(_: *Self) void {}

// ---------------------------------------------------------------------------
// Win32 event callbacks (called by win32.zig surfaceWndProc)
// ---------------------------------------------------------------------------

pub fn onClose(self: *Self) void {
    self.window.removeTab(self);
}

pub fn onPaint(self: *Self) void {
    _ = self;
    // SwapBuffers is called from the renderer thread in drawFrameEnd.
    // We just validate the region here so Windows stops sending WM_PAINT.
}

pub fn onResize(self: *Self, width: u32, height: u32) void {
    if (width == 0 or height == 0) return;
    if (width == self.width and height == self.height) return;

    self.width = width;
    self.height = height;

    // Notify the renderer thread of the new size
    const val: u64 = (@as(u64, width) << 32) | @as(u64, height);
    self.pending_size.store(val, .release);

    if (self.core_surface_initialized) {
        self.core_surface.contentScaleCallback(.{
            .x = self.scale_x,
            .y = self.scale_y,
        }) catch |err| {
            log.warn("contentScaleCallback failed: {}", .{err});
        };
        self.core_surface.sizeCallback(.{
            .width = width,
            .height = height,
        }) catch |err| {
            log.warn("sizeCallback failed: {}", .{err});
        };
    }
}

pub fn onDpiChange(self: *Self, dpi: u32) void {
    self.scale_x = @as(f32, @floatFromInt(dpi)) / 96.0;
    self.scale_y = self.scale_x;
    if (self.core_surface_initialized) {
        self.core_surface.contentScaleCallback(.{
            .x = self.scale_x,
            .y = self.scale_y,
        }) catch |err| {
            log.warn("contentScaleCallback failed on DPI change: {}", .{err});
        };
    }
}

pub fn onFocusChange(self: *Self, focused: bool) void {
    if (focused) {
        // Track this as the active surface in the parent window's tab
        self.window.setActiveSurface(self);
    }
    if (self.core_surface_initialized) {
        self.core_surface.focusCallback(focused) catch |err| {
            log.warn("focusCallback failed: {}", .{err});
        };
    }
}

// ---------------------------------------------------------------------------
// Keyboard
// ---------------------------------------------------------------------------

pub fn onKey(self: *Self, vk: u16, scan_code: u32, action: input.Action) void {
    if (!self.core_surface_initialized) return;

    const phy_key = vkey.keyFromVK(vk);
    const mods = vkey.getModifiers();

    var utf8_buf: [32]u8 = undefined;
    var utf8_len: usize = if (action != .release)
        vkey.keyEventToUtf8(@intCast(vk), scan_code, &utf8_buf)
    else
        0;

    if (utf8_len > 0 and mods.ctrl and mods.shift and utf8_buf[0] < 0x20) {
        utf8_len = 0;
    }

    const utf8 = utf8_buf[0..utf8_len];
    const consumed_mods: input.Mods = if (utf8_len > 0 and mods.shift)
        .{ .shift = true }
    else
        .{};

    const unshifted: u21 = vkey.unshiftedCodepoint(vk);

    const event: input.KeyEvent = .{
        .action = action,
        .key = phy_key,
        .mods = mods,
        .consumed_mods = consumed_mods,
        .composing = false,
        .utf8 = utf8,
        .unshifted_codepoint = unshifted,
    };

    const effect = self.core_surface.keyCallback(event) catch |err| effect: {
        log.warn("keyCallback failed: {}", .{err});
        break :effect CoreSurface.InputEffect.ignored;
    };
    if (effect == .closed) return;
}

pub fn onChar(self: *Self, wchar: u16) void {
    if (!self.core_surface_initialized) return;

    var buf: [4]u8 = undefined;
    const wide = [1]u16{wchar};
    const n = std.unicode.utf16LeToUtf8(&buf, &wide) catch return;
    if (n == 0) return;

    const mods = vkey.getModifiers();
    const event: input.KeyEvent = .{
        .action = .press,
        .key = .unidentified,
        .mods = mods,
        .consumed_mods = .{},
        .composing = false,
        .utf8 = buf[0..n],
        .unshifted_codepoint = 0,
    };
    const effect = self.core_surface.keyCallback(event) catch CoreSurface.InputEffect.ignored;
    if (effect == .closed) return;
}

pub fn onUnichar(self: *Self, cp: u21) void {
    if (!self.core_surface_initialized) return;

    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &buf) catch return;

    const mods = vkey.getModifiers();
    const event: input.KeyEvent = .{
        .action = .press,
        .key = .unidentified,
        .mods = mods,
        .consumed_mods = .{},
        .composing = false,
        .utf8 = buf[0..n],
        .unshifted_codepoint = cp,
    };
    const effect = self.core_surface.keyCallback(event) catch CoreSurface.InputEffect.ignored;
    if (effect == .closed) return;
}

// ---------------------------------------------------------------------------
// Mouse
// ---------------------------------------------------------------------------

pub fn onMouseMove(self: *Self, x: f32, y: f32) void {
    if (!self.core_surface_initialized) return;
    const pos: apprt.CursorPos = .{ .x = x, .y = y };
    const mods = vkey.getModifiers();
    self.core_surface.cursorPosCallback(pos, mods) catch |err| {
        log.warn("cursorPosCallback failed: {}", .{err});
    };
}

pub fn onMouseButton(self: *Self, action: input.MouseButtonState, button: input.MouseButton) void {
    if (!self.core_surface_initialized) return;
    const mods = vkey.getModifiers();
    _ = self.core_surface.mouseButtonCallback(action, button, mods) catch |err| res: {
        log.warn("mouseButtonCallback failed: {}", .{err});
        break :res false;
    };
}

pub fn onScroll(self: *Self, xoff: f64, yoff: f64) void {
    if (!self.core_surface_initialized) return;
    const scroll_mods: input.ScrollMods = .{};
    self.core_surface.scrollCallback(xoff, yoff, scroll_mods) catch |err| {
        log.warn("scrollCallback failed: {}", .{err});
    };
}

// ---------------------------------------------------------------------------
// Action handlers (called by App.performAction via Window)
// ---------------------------------------------------------------------------

pub fn setTitle(self: *Self, title: [:0]const u8) void {
    self.current_title = title;
    // If this is the active tab, update the window title bar too
    if (self.window.activeSurface() == self) {
        win32.setWindowTitleZ(self.window.hwnd, title);
    }
    // Repaint tab bar to show new title
    self.window.invalidateTabBar();
}

pub fn requestRender(self: *Self) void {
    win32.invalidateRect(self.hwnd, null, false);
}

pub fn setMouseShape(self: *Self, shape: terminal.MouseShape) void {
    const idc: usize = switch (shape) {
        .default, .context_menu, .help, .alias, .copy, .no_drop,
        .grab, .grabbing, .zoom_in, .zoom_out, .cell, .vertical_text => 32512,
        .text => 32513,
        .wait => 32514,
        .crosshair => 32515,
        .pointer => 32649,
        .progress => 32650,
        .not_allowed => 32648,
        .move, .all_scroll => 32646,
        .col_resize, .ew_resize, .e_resize, .w_resize => 32644,
        .row_resize, .ns_resize, .n_resize, .s_resize => 32645,
        .nwse_resize, .nw_resize, .se_resize => 32642,
        .nesw_resize, .ne_resize, .sw_resize => 32643,
    };
    const cursor = win32.loadCursor(null, idc);
    self.cursor_handle = cursor;
    _ = win32.setCursor(cursor);
}

pub fn setMouseVisibility(self: *Self, visibility: anytype) void {
    const visible = visibility == .visible;
    if (self.cursor_visible != visible) {
        self.cursor_visible = visible;
        _ = win32.showCursor(visible);
    }
}

// ---------------------------------------------------------------------------
// Search overlay
// ---------------------------------------------------------------------------

const SEARCH_BAR_HEIGHT: u32 = 28;
const SEARCH_EDIT_ID: u16 = 100;

pub fn startSearch(self: *Self, needle: [:0]const u8) void {
    if (self.search_active) {
        // Already active — just update the needle
        if (self.search_edit_hwnd) |edit| {
            win32.setEditText(edit, needle.ptr);
        }
        return;
    }

    self.search_active = true;
    self.search_total = null;
    self.search_selected = null;

    // Create an EDIT control overlaying the top-right of the surface
    const edit_width: i32 = 260;
    const edit_height: i32 = @intCast(SEARCH_BAR_HEIGHT);
    const edit_x: i32 = @as(i32, @intCast(self.width)) - edit_width - 8;
    const edit_y: i32 = 4;

    const edit_hwnd = win32.createControl(
        "EDIT",
        needle.ptr,
        win32.WS_CHILD | win32.WS_VISIBLE | win32.WS_BORDER | win32.ES_AUTOHSCROLL | win32.WS_TABSTOP,
        0,
        edit_x,
        edit_y,
        edit_width,
        edit_height,
        self.hwnd,
        self.window.app.hinstance,
    );
    self.search_edit_hwnd = edit_hwnd;

    if (edit_hwnd) |h| {
        win32.setFocus(h);
        // If there's a pre-filled needle, trigger search
        if (needle.len > 0) {
            self.onSearchTextChanged();
        }
    }
}

pub fn endSearch(self: *Self) void {
    if (!self.search_active) return;
    self.search_active = false;
    self.search_total = null;
    self.search_selected = null;

    if (self.search_edit_hwnd) |edit| {
        win32.destroyWindow(edit);
        self.search_edit_hwnd = null;
    }

    // Return focus to the surface
    win32.setFocus(self.hwnd);
}

pub fn setSearchTotal(self: *Self, total: ?usize) void {
    self.search_total = total;
    // Trigger repaint to update the search overlay (match count drawn on paint)
    win32.invalidateRect(self.hwnd, null, false);
}

pub fn setSearchSelected(self: *Self, selected: ?usize) void {
    self.search_selected = selected;
    win32.invalidateRect(self.hwnd, null, false);
}

pub fn onSearchTextChanged(self: *Self) void {
    if (!self.core_surface_initialized) return;
    const edit = self.search_edit_hwnd orelse return;

    var buf: [1024]u8 = undefined;
    const text = win32.getEditText(edit, &buf);

    // Send search text to core via performBindingAction
    if (text.len < buf.len) {
        buf[text.len] = 0;
        const sentinel: [:0]const u8 = buf[0..text.len :0];
        _ = self.core_surface.performBindingAction(.{ .search = sentinel }) catch |err| blk: {
            log.warn("search binding action failed: {}", .{err});
            break :blk false;
        };
    }
}

pub fn onSearchKeyDown(self: *Self, vk: u16) bool {
    if (!self.search_active) return false;

    const VK_RETURN: u16 = 0x0D;
    const VK_ESCAPE: u16 = 0x1B;

    if (vk == VK_ESCAPE) {
        // End search and send end_search binding
        if (self.core_surface_initialized) {
            _ = self.core_surface.performBindingAction(.end_search) catch false;
        }
        self.endSearch();
        return true;
    }

    if (vk == VK_RETURN) {
        if (!self.core_surface_initialized) return true;
        const mods = vkey.getModifiers();
        if (mods.shift) {
            _ = self.core_surface.performBindingAction(.{ .navigate_search = .previous }) catch false;
        } else {
            _ = self.core_surface.performBindingAction(.{ .navigate_search = .next }) catch false;
        }
        return true;
    }

    return false;
}
