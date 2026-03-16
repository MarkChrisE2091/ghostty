/// Win32 Surface — one terminal window.
///
/// Each Surface owns:
///   - A Win32 HWND
///   - A WGL OpenGL context (hdc + hglrc)
///   - An initialized CoreSurface (the terminal state + renderer)
///
/// The Surface is always heap-allocated so that its address (and the address
/// of its embedded CoreSurface) is stable for the lifetime of the window.
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
const win32 = @import("win32.zig");
const wgl = @import("wgl.zig");
const vkey = @import("key.zig");

const w = std.os.windows;

const log = std.log.scoped(.win32_surface);

// ---------------------------------------------------------------------------
// State fields
// ---------------------------------------------------------------------------

/// Win32 window handle.
hwnd: win32.HWND,

/// WGL rendering context.
hdc: win32.HDC,
hglrc: wgl.HGLRC,

/// The core terminal surface (owns the PTY, renderer, terminal state).
/// Initialized during init(); valid for the entire lifetime of the surface.
core_surface: CoreSurface,
core_surface_initialized: bool,

/// Back-reference to the app runtime.
app: *ApprtApp,

/// Current window dimensions (in physical pixels).
width: u32,
height: u32,

/// DPI scaling factor relative to 96 DPI.
scale_x: f32,
scale_y: f32,

/// Fullscreen state + saved placement for restore.
fullscreen: bool,
saved_placement: ?win32.WINDOWPLACEMENT,
/// Style saved before entering fullscreen.
saved_style: u32,

/// Mouse-related state.
cursor_visible: bool,
cursor_handle: ?win32.HCURSOR,
tracking_mouse_leave: bool,

/// Pending size-limit constraints (set by the `size_limit` action).
min_width: u32,
min_height: u32,

/// Cell dimensions (set by the core via cell_size action).
cell_width: u32,
cell_height: u32,

/// Background opacity state for toggle.
background_opacity: f64,
background_opaque: bool,

/// Current window title (set by setTitle, used by getTitle/copy_title_to_clipboard).
current_title: ?[:0]const u8,

// ---------------------------------------------------------------------------
// Public init / deinit
// ---------------------------------------------------------------------------

pub fn init(self: *Self, app: *ApprtApp) !void {
    const default_width: u32 = 800;
    const default_height: u32 = 600;

    // Create the Win32 window. The userdata pointer points to *this* Surface
    // so the WndProc can find us.
    const hwnd = try win32.createWindow(
        app.hinstance,
        "Ghostty",
        default_width,
        default_height,
        @intFromPtr(self),
    );
    errdefer win32.destroyWindow(hwnd);

    // Create WGL OpenGL context
    const hdc = win32.getDC(hwnd) orelse return error.GetDCFailed;
    const hglrc = try wgl.createContext(hdc);
    errdefer wgl.deleteContext(hglrc) catch {};
    try wgl.makeCurrent(hdc, hglrc);

    // Get DPI scaling
    const dpi = win32.getDpiForWindow(hwnd);
    const scale: f32 = @as(f32, @floatFromInt(dpi)) / 96.0;

    // Zero-initialize the core surface (it is initialized below)
    self.* = .{
        .hwnd = hwnd,
        .hdc = hdc,
        .hglrc = hglrc,
        .core_surface = undefined,
        .core_surface_initialized = false,
        .app = app,
        .width = default_width,
        .height = default_height,
        .scale_x = scale,
        .scale_y = scale,
        .fullscreen = false,
        .saved_placement = null,
        .saved_style = win32.WS_OVERLAPPEDWINDOW,
        .cursor_visible = true,
        .cursor_handle = null,
        .tracking_mouse_leave = false,
        .min_width = 0,
        .min_height = 0,
        .cell_width = 0,
        .cell_height = 0,
        .background_opacity = app.config.@"background-opacity",
        .background_opaque = true,
        .current_title = null,
    };

    // Show the window before initializing the core surface so that the
    // renderer can read back the actual window dimensions.
    win32.showWindow(hwnd, win32.SW_SHOWNORMAL);
    win32.updateWindow(hwnd);

    // Get actual client area after showing
    var client_rect: win32.RECT = .{};
    if (win32.getClientRect(hwnd, &client_rect)) {
        self.width = @intCast(client_rect.right - client_rect.left);
        self.height = @intCast(client_rect.bottom - client_rect.top);
    }

    // Initialize the core surface. This starts the renderer thread,
    // PTY thread, and everything else.
    try self.initCoreSurface();

    log.info("Win32 surface initialized hwnd={*} size={}x{} dpi={} scale={d:.2}", .{
        hwnd, self.width, self.height, dpi, scale,
    });
}

fn initCoreSurface(self: *Self) !void {
    const alloc = self.app.alloc;
    const config = &self.app.config;
    const core_app = self.app.core_app;

    try self.core_surface.init(
        alloc,
        config,
        core_app,
        self.app,
        self,
    );
    self.core_surface_initialized = true;
}

pub fn deinit(self: *Self) void {
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
    return self.app;
}

pub fn close(self: *Self, process_active: bool) void {
    _ = process_active;
    self.app.removeSurface(self);
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

    const alloc = self.app.alloc;
    const text = win32.clipboardReadText(self.hwnd, alloc) orelse return false;
    defer alloc.free(text);

    // completeClipboardRequest expects a null-terminated slice
    const textZ = try alloc.dupeZ(u8, text);
    defer alloc.free(textZ);

    self.core_surface.completeClipboardRequest(state, textZ, false) catch |err| switch (err) {
        error.UnsafePaste => {
            // Multiline paste detected — auto-confirm since we don't have
            // a confirmation dialog yet. TODO: implement a proper dialog.
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

    // Find the text/plain content item
    for (contents) |item| {
        if (std.mem.eql(u8, item.mime, "text/plain") or
            std.mem.eql(u8, item.mime, "text/plain;charset=utf-8"))
        {
            _ = win32.clipboardWriteText(self.hwnd, item.data);
            return;
        }
    }
    // Fallback: use first item's data as text
    if (contents.len > 0) {
        _ = win32.clipboardWriteText(self.hwnd, contents[0].data);
    }
}

pub fn defaultTermioEnv(self: *Self) !std.process.EnvMap {
    var env = try std.process.getEnvMap(self.app.alloc);
    try env.put("TERM", "xterm-256color");
    try env.put("COLORTERM", "truecolor");
    try env.put("TERM_PROGRAM", "ghostty");
    return env;
}

pub fn redrawInspector(_: *Self) void {}

// ---------------------------------------------------------------------------
// Win32 event callbacks (called by win32.zig WndProc)
// ---------------------------------------------------------------------------

pub fn onClose(self: *Self) void {
    self.app.removeSurface(self);
}

pub fn onPaint(self: *Self) void {
    // SwapBuffers is called from the renderer thread in drawFrameEnd,
    // since the WGL context is owned by that thread. We just validate
    // the window region here so Windows stops sending WM_PAINT.
    _ = self;
}

pub fn onResize(self: *Self, width: u32, height: u32) void {
    if (width == 0 or height == 0) return;
    if (width == self.width and height == self.height) return;

    self.width = width;
    self.height = height;

    // Notify the renderer thread to update glViewport.
    // On Win32, GTK's GLArea isn't managing the viewport for us.
    const OpenGL = @import("../../renderer/OpenGL.zig");
    OpenGL.win32SetPendingSize(width, height);

    if (self.core_surface_initialized) {
        // Update content scale first (like GTK does), then notify of new size.
        // This ensures font metrics are correct before the grid is recalculated.
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

pub fn onMinMaxInfo(self: *Self, mmi: *win32.MINMAXINFO) void {
    if (self.min_width > 0) mmi.ptMinTrackSize.x = @intCast(self.min_width);
    if (self.min_height > 0) mmi.ptMinTrackSize.y = @intCast(self.min_height);
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
    if (self.core_surface_initialized) {
        self.core_surface.focusCallback(focused) catch |err| {
            log.warn("focusCallback failed: {}", .{err});
        };
    }
}

// ---------------------------------------------------------------------------
// Keyboard
// ---------------------------------------------------------------------------

/// Called for WM_KEYDOWN / WM_SYSKEYDOWN / WM_KEYUP / WM_SYSKEYUP.
pub fn onKey(self: *Self, vk: u16, scan_code: u32, action: input.Action) void {
    if (!self.core_surface_initialized) return;

    const phy_key = vkey.keyFromVK(vk);
    const mods = vkey.getModifiers();

    // Get the UTF-8 text for press/repeat events
    var utf8_buf: [32]u8 = undefined;
    var utf8_len: usize = if (action != .release)
        vkey.keyEventToUtf8(@intCast(vk), scan_code, &utf8_buf)
    else
        0;

    // When Ctrl+Shift is held, ToUnicode produces control characters (0x00-0x1F)
    // which aren't real text. Clear them so the keybind system sees the
    // full modifier set (e.g. Ctrl+Shift+C for copy, Ctrl+Shift+V for paste).
    // When only Ctrl is held (no Shift), keep the control character — the
    // terminal needs it (e.g. Ctrl+C = 0x03 for interrupt, Ctrl+D = 0x04 for EOF).
    if (utf8_len > 0 and mods.ctrl and mods.shift and utf8_buf[0] < 0x20) {
        utf8_len = 0;
    }

    const utf8 = utf8_buf[0..utf8_len];

    // Determine consumed mods: if we got real text, shift was consumed
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

/// Called for WM_CHAR when we have a composed character from the input method.
/// We synthesize a key-press event for the character.
pub fn onChar(self: *Self, wchar: u16) void {
    if (!self.core_surface_initialized) return;

    // Convert the single UTF-16 code unit to UTF-8
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

/// Called for WM_UNICHAR with a full Unicode codepoint (non-BMP characters).
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
// Action handlers (called by App.performAction)
// ---------------------------------------------------------------------------

pub fn setTitle(self: *Self, title: [:0]const u8) void {
    win32.setWindowTitleZ(self.hwnd, title);
    self.current_title = title;
}

pub fn requestRender(self: *Self) void {
    win32.invalidateRect(self.hwnd, null, false);
}

pub fn setSizeLimit(self: *Self, limit: anytype) void {
    self.min_width = limit.min_width;
    self.min_height = limit.min_height;
}

pub fn setInitialSize(self: *Self, size: anytype) void {
    win32.setWindowPos(
        self.hwnd,
        null,
        0,
        0,
        @intCast(size.width),
        @intCast(size.height),
        win32.SWP_NOMOVE | win32.SWP_NOZORDER,
    );
    self.width = size.width;
    self.height = size.height;
}

pub fn setMouseShape(self: *Self, shape: terminal.MouseShape) void {
    // Map W3C cursor shapes (as used by Ghostty) to Win32 cursor resource IDs.
    // IDC_* constants: ARROW=32512, IBEAM=32513, WAIT=32514, CROSS=32515,
    //   APPSTARTING=32650, NO=32648, HAND=32649, SIZEALL=32646,
    //   SIZENS=32645, SIZEWE=32644, SIZENWSE=32642, SIZENESW=32643
    const idc: usize = switch (shape) {
        .default, .context_menu, .help, .alias, .copy, .no_drop,
        .grab, .grabbing, .zoom_in, .zoom_out, .cell, .vertical_text => 32512, // IDC_ARROW

        .text => 32513,               // IDC_IBEAM
        .wait => 32514,               // IDC_WAIT
        .crosshair => 32515,          // IDC_CROSS
        .pointer => 32649,            // IDC_HAND
        .progress => 32650,           // IDC_APPSTARTING
        .not_allowed => 32648,        // IDC_NO
        .move, .all_scroll => 32646,  // IDC_SIZEALL
        .col_resize, .ew_resize, .e_resize, .w_resize => 32644,   // IDC_SIZEWE
        .row_resize, .ns_resize, .n_resize, .s_resize => 32645,   // IDC_SIZENS
        .nwse_resize, .nw_resize, .se_resize => 32642,            // IDC_SIZENWSE
        .nesw_resize, .ne_resize, .sw_resize => 32643,            // IDC_SIZENESW
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

pub fn toggleFullscreen(self: *Self) void {
    const hwnd = self.hwnd;

    if (self.fullscreen) {
        // Restore window style
        win32.setWindowLong(hwnd, win32.GWL_STYLE, @as(i32, @bitCast(self.saved_style)));
        if (self.saved_placement) |placement| {
            win32.setWindowPlacement(hwnd, &placement);
        }
        win32.setWindowPos(hwnd, null, 0, 0, 0, 0,
            win32.SWP_NOMOVE | win32.SWP_NOSIZE | win32.SWP_NOZORDER | win32.SWP_FRAMECHANGED);
        self.fullscreen = false;
    } else {
        // Save current state (getWindowLong returns i32; store as u32 for bit manipulation)
        self.saved_style = @bitCast(win32.getWindowLong(hwnd, win32.GWL_STYLE));
        var placement: win32.WINDOWPLACEMENT = .{};
        _ = win32.getWindowPlacement(hwnd, &placement);
        self.saved_placement = placement;

        // Get monitor rect
        const monitor = win32.monitorFromWindow(hwnd, win32.MONITOR_DEFAULTTONEAREST);
        var mi: win32.MONITORINFO = .{};
        if (win32.getMonitorInfo(monitor, &mi)) {
            // Remove title bar and borders (WS_POPUP | WS_VISIBLE)
            win32.setWindowLong(hwnd, win32.GWL_STYLE,
                @bitCast(win32.WS_POPUP | win32.WS_VISIBLE));
            win32.setWindowPos(
                hwnd,
                win32.HWND_TOP,
                mi.rcMonitor.left,
                mi.rcMonitor.top,
                mi.rcMonitor.right - mi.rcMonitor.left,
                mi.rcMonitor.bottom - mi.rcMonitor.top,
                win32.SWP_FRAMECHANGED,
            );
        }
        self.fullscreen = true;
    }
}

pub fn toggleMaximize(self: *Self) void {
    const style: u32 = @bitCast(win32.getWindowLong(self.hwnd, win32.GWL_STYLE));
    if (style & win32.WS_MAXIMIZE != 0) {
        win32.showWindow(self.hwnd, win32.SW_RESTORE);
    } else {
        win32.showWindow(self.hwnd, win32.SW_MAXIMIZE);
    }
}

pub fn toggleDecorations(self: *Self) void {
    var style: u32 = @bitCast(win32.getWindowLong(self.hwnd, win32.GWL_STYLE));
    if (style & win32.WS_CAPTION != 0) {
        style &= ~(win32.WS_CAPTION | win32.WS_THICKFRAME);
    } else {
        style |= win32.WS_CAPTION | win32.WS_THICKFRAME;
    }
    win32.setWindowLong(self.hwnd, win32.GWL_STYLE, @bitCast(style));
    win32.setWindowPos(self.hwnd, null, 0, 0, 0, 0,
        win32.SWP_FRAMECHANGED | win32.SWP_NOMOVE | win32.SWP_NOSIZE | win32.SWP_NOZORDER);
}

pub fn toggleBackgroundOpacity(self: *Self) void {
    if (self.background_opacity >= 1.0) return; // nothing to toggle

    self.background_opaque = !self.background_opaque;
    if (self.background_opaque) {
        // Make fully opaque: remove layered style
        var style: u32 = @bitCast(win32.getWindowLong(self.hwnd, win32.GWL_EXSTYLE));
        style &= ~win32.WS_EX_LAYERED;
        win32.setWindowLong(self.hwnd, win32.GWL_EXSTYLE, @bitCast(style));
    } else {
        // Apply configured background opacity
        var style: u32 = @bitCast(win32.getWindowLong(self.hwnd, win32.GWL_EXSTYLE));
        style |= win32.WS_EX_LAYERED;
        win32.setWindowLong(self.hwnd, win32.GWL_EXSTYLE, @bitCast(style));
        const alpha: u8 = @intFromFloat(self.background_opacity * 255.0);
        win32.setLayeredWindowAttributes(self.hwnd, 0, alpha, win32.LWA_ALPHA);
    }
}

pub fn setFloating(self: *Self, floating: bool) void {
    const insert_after: ?win32.HWND = null;
    _ = insert_after;
    const z: isize = if (floating) win32.HWND_TOPMOST else win32.HWND_NOTOPMOST;
    _ = win32.setWindowPosZ(self.hwnd, z, 0, 0, 0, 0,
        win32.SWP_NOMOVE | win32.SWP_NOSIZE);
}

pub fn present(self: *Self) void {
    win32.setForegroundWindow(self.hwnd);
    win32.bringWindowToTop(self.hwnd);
}

pub fn showDesktopNotification(self: *Self, title: [:0]const u8, body: [:0]const u8) void {
    // Simple Win32 message box notification fallback.
    // A proper implementation would use Windows Toast notifications via COM.
    // Combine title + body into a wide string message
    var msg_buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, "{s}\n\n{s}", .{ title, body }) catch return;

    var wide_msg: [1024]u16 = undefined;
    var wide_title: [256]u16 = undefined;

    const msg_len = std.unicode.utf8ToUtf16Le(&wide_msg, msg) catch return;
    const title_len = std.unicode.utf8ToUtf16Le(&wide_title, title) catch return;
    wide_msg[msg_len] = 0;
    wide_title[title_len] = 0;

    _ = win32.messageBoxW(
        self.hwnd,
        @as([*:0]const u16, @ptrCast(&wide_msg)),
        @as([*:0]const u16, @ptrCast(&wide_title)),
        win32.MB_ICONINFORMATION,
    );
}
