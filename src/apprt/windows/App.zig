/// Win32 application runtime for Ghostty.
///
/// This implements the apprt interface using native Win32 APIs.
/// One App drives one Win32 message loop. Each top-level window is a
/// Window (see Window.zig) which hosts one or more terminal Surfaces
/// as tabs (see Surface.zig).
const App = @This();

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const apprt = @import("../../apprt.zig");
const configpkg = @import("../../config.zig");
const Config = configpkg.Config;
const input = @import("../../input.zig");
const CoreApp = @import("../../App.zig");
const CoreSurface = @import("../../Surface.zig");
const Surface = @import("Surface.zig");
const Window = @import("Window.zig");
const internal_os = @import("../../os/main.zig");
const renderer = @import("../../renderer.zig");
const terminal = @import("../../terminal/main.zig");

const win32 = @import("win32.zig");
const w = std.os.windows;

const log = std.log.scoped(.win32);

// ---------------------------------------------------------------------------
// Apprt constants queried by CoreApp
// ---------------------------------------------------------------------------

pub const must_draw_from_app_thread = false;

// ---------------------------------------------------------------------------
// Fields
// ---------------------------------------------------------------------------

/// Win32 module handle for this process.
hinstance: w.HINSTANCE,

/// The core application (owns the font set, config, mailbox, etc.).
core_app: *CoreApp,

/// A copy of the application configuration (owned by us).
config: Config,

/// All live windows.
windows: std.ArrayListUnmanaged(*Window),

/// Allocator for all win32 runtime objects.
alloc: Allocator,

/// Set to true when the app should stop its message loop.
quit_requested: bool,

/// Timer ID used to implement the quit_timer action.
quit_timer_id: ?usize,

// ---------------------------------------------------------------------------
// Public interface
// ---------------------------------------------------------------------------

pub fn init(
    self: *App,
    core_app: *CoreApp,
    opts: struct {},
) !void {
    _ = opts;

    const alloc = core_app.alloc;

    var config = configpkg.Config.load(alloc) catch |err| blk: {
        log.warn("failed to load config: {}; using defaults", .{err});
        break :blk try configpkg.Config.default(alloc);
    };
    defer config.deinit();

    var config_clone = try config.clone(alloc);
    errdefer config_clone.deinit();

    const hinstance: w.HINSTANCE = @ptrCast(
        w.kernel32.GetModuleHandleW(null) orelse return error.GetModuleHandleFailed,
    );

    try win32.registerWindowClass(hinstance);
    try win32.registerSurfaceClass(hinstance);

    self.* = .{
        .hinstance = hinstance,
        .core_app = core_app,
        .config = config_clone,
        .windows = .{},
        .alloc = alloc,
        .quit_requested = false,
        .quit_timer_id = null,
    };

    // Create the first terminal window
    _ = try self.newWindow();
}

pub fn run(self: *App) !void {
    var msg: win32.MSG = undefined;
    while (!self.quit_requested) {
        while (win32.peekMessage(&msg, null, 0, 0, win32.PM_REMOVE)) {
            if (msg.message == win32.WM_QUIT) {
                self.quit_requested = true;
                break;
            }

            // Intercept key messages for search edits before dispatch
            if (msg.message == win32.WM_KEYDOWN) {
                if (self.handleSearchKeyIntercept(&msg)) continue;
            }

            win32.translateMessage(&msg);
            win32.dispatchMessage(&msg);
        }

        if (self.quit_requested) break;

        // Tick the core app mailbox
        self.core_app.tick(self) catch |err| {
            log.err("error ticking core app: {}", .{err});
        };

        if (self.windows.items.len == 0 and self.quit_timer_id == null) {
            self.quit_requested = true;
            break;
        }

        win32.waitMessage();
    }
}

pub fn terminate(self: *App) void {
    for (self.windows.items) |window| {
        window.deinit();
        self.alloc.destroy(window);
    }
    self.windows.deinit(self.alloc);
    self.config.deinit();
}

pub fn wakeup(self: *App) void {
    _ = self;
    win32.postThreadMessage(
        w.kernel32.GetCurrentThreadId(),
        win32.WM_USER,
        0,
        0,
    );
}

pub fn performAction(
    self: *App,
    target: apprt.Target,
    comptime action: apprt.Action.Key,
    value: apprt.Action.Value(action),
) !bool {
    switch (action) {
        // ------------------------------------------------------------------
        // Application lifecycle
        // ------------------------------------------------------------------
        .quit => {
            self.quit_requested = true;
            return true;
        },

        .close_all_windows => {
            var i = self.windows.items.len;
            while (i > 0) {
                i -= 1;
                const window = self.windows.items[i];
                _ = self.windows.swapRemove(i);
                window.deinit();
                self.alloc.destroy(window);
            }
            self.quit_requested = true;
            return true;
        },

        .quit_timer => {
            switch (value) {
                .start => {
                    if (self.windows.items.len == 0) {
                        self.quit_requested = true;
                    }
                },
                .stop => {
                    self.quit_timer_id = null;
                },
            }
            return true;
        },

        // ------------------------------------------------------------------
        // Window creation
        // ------------------------------------------------------------------
        .new_window => {
            _ = try self.newWindow();
            return true;
        },

        .close_window => {
            if (target == .surface) {
                if (self.windowForCore(target.surface)) |window| {
                    self.removeWindow(window);
                }
            }
            return true;
        },

        // ------------------------------------------------------------------
        // Tabs
        // ------------------------------------------------------------------
        .new_tab => {
            if (target == .surface) {
                if (self.windowForCore(target.surface)) |window| {
                    _ = window.addTab() catch |err| {
                        log.warn("failed to create new tab: {}", .{err});
                    };
                }
            } else {
                // App target: add tab to first window or create new window
                if (self.windows.items.len > 0) {
                    _ = self.windows.items[0].addTab() catch |err| {
                        log.warn("failed to create new tab: {}", .{err});
                    };
                } else {
                    _ = try self.newWindow();
                }
            }
            return true;
        },

        .close_tab => {
            if (target == .surface) {
                if (self.windowForCore(target.surface)) |window| {
                    window.closeTab(value);
                }
            }
            return true;
        },

        .goto_tab => {
            if (target == .surface) {
                if (self.windowForCore(target.surface)) |window| {
                    window.gotoTab(value);
                }
            }
            return true;
        },

        .move_tab => {
            if (target == .surface) {
                if (self.windowForCore(target.surface)) |window| {
                    window.moveTab(value.amount);
                }
            }
            return true;
        },

        // ------------------------------------------------------------------
        // Title
        // ------------------------------------------------------------------
        .set_title => {
            if (target == .surface) {
                if (self.surfaceForCore(target.surface)) |s| {
                    s.setTitle(value.title);
                }
            }
            return true;
        },

        .set_tab_title => {
            if (target == .surface) {
                if (self.surfaceForCore(target.surface)) |s| {
                    s.setTitle(value.title);
                }
            }
            return true;
        },

        // ------------------------------------------------------------------
        // Rendering
        // ------------------------------------------------------------------
        .render => {
            if (target == .surface) {
                if (self.surfaceForCore(target.surface)) |s| s.requestRender();
            } else {
                for (self.windows.items) |window| {
                    for (window.tabs.items) |tab| {
                        var leaves: std.ArrayListUnmanaged(*Surface) = .{};
                        defer leaves.deinit(self.alloc);
                        tab.root.collectLeaves(self.alloc, &leaves);
                        for (leaves.items) |s| s.requestRender();
                    }
                }
            }
            return true;
        },

        // ------------------------------------------------------------------
        // Window state
        // ------------------------------------------------------------------
        .toggle_fullscreen => {
            if (target == .surface) {
                if (self.windowForCore(target.surface)) |window| window.toggleFullscreen();
            }
            return true;
        },

        .toggle_maximize => {
            if (target == .surface) {
                if (self.windowForCore(target.surface)) |window| window.toggleMaximize();
            }
            return true;
        },

        .toggle_window_decorations => {
            if (target == .surface) {
                if (self.windowForCore(target.surface)) |window| window.toggleDecorations();
            }
            return true;
        },

        .float_window => {
            if (target == .surface) {
                if (self.windowForCore(target.surface)) |window| {
                    switch (value) {
                        .on => window.setFloating(true),
                        .off => window.setFloating(false),
                        .toggle => window.setFloating(!window.floating),
                    }
                }
            }
            return true;
        },

        .toggle_visibility => {
            for (self.windows.items) |window| {
                win32.showWindow(window.hwnd, win32.SW_SHOW);
            }
            return true;
        },

        // ------------------------------------------------------------------
        // Size constraints
        // ------------------------------------------------------------------
        .size_limit => {
            if (target == .surface) {
                if (self.windowForCore(target.surface)) |window| window.setSizeLimit(value);
            }
            return true;
        },

        .initial_size => {
            if (target == .surface) {
                if (self.windowForCore(target.surface)) |window| window.setInitialSize(value);
            }
            return true;
        },

        .reset_window_size => {
            if (target == .surface) {
                if (self.windowForCore(target.surface)) |window| {
                    window.setInitialSize(.{ .width = 800, .height = 600 });
                }
            }
            return true;
        },

        // ------------------------------------------------------------------
        // Mouse
        // ------------------------------------------------------------------
        .mouse_shape => {
            if (target == .surface) {
                if (self.surfaceForCore(target.surface)) |s| s.setMouseShape(value);
            }
            return true;
        },

        .mouse_visibility => {
            if (target == .surface) {
                if (self.surfaceForCore(target.surface)) |s| s.setMouseVisibility(value);
            }
            return true;
        },

        .mouse_over_link => return true,

        // ------------------------------------------------------------------
        // Notifications / alerts
        // ------------------------------------------------------------------
        .desktop_notification => {
            if (target == .surface) {
                if (self.windowForCore(target.surface)) |window| {
                    window.showDesktopNotification(value.title, value.body);
                }
            } else if (self.windows.items.len > 0) {
                self.windows.items[0].showDesktopNotification(value.title, value.body);
            }
            return true;
        },

        .ring_bell => {
            _ = win32.messageBeep(win32.MB_OK);
            return true;
        },

        // ------------------------------------------------------------------
        // Config / URLs
        // ------------------------------------------------------------------
        .open_config => {
            if (configpkg.preferredDefaultFilePath(self.alloc)) |path| {
                defer self.alloc.free(path);
                win32.shellOpen(null, path);
            } else |_| {
                log.warn("could not resolve config path", .{});
            }
            return true;
        },

        .open_url => {
            win32.shellOpen(null, value.url);
            return true;
        },

        // ------------------------------------------------------------------
        // Focus / present
        // ------------------------------------------------------------------
        .present_terminal => {
            if (target == .surface) {
                if (self.windowForCore(target.surface)) |window| window.present();
            }
            return true;
        },

        // ------------------------------------------------------------------
        // Config reload
        // ------------------------------------------------------------------
        .reload_config => {
            if (!value.soft) {
                var config = configpkg.Config.load(self.alloc) catch |err| blk: {
                    log.warn("failed to reload config: {}; keeping current", .{err});
                    break :blk null;
                };
                if (config) |*cfg| {
                    defer cfg.deinit();
                    const new_clone = cfg.clone(self.alloc) catch |err| {
                        log.warn("failed to clone reloaded config: {}", .{err});
                        return true;
                    };
                    self.config.deinit();
                    self.config = new_clone;
                }
            }
            self.core_app.updateConfig(self, &self.config) catch |err| {
                log.warn("failed to push config update: {}", .{err});
            };
            return true;
        },

        .config_change => {
            const new_clone = value.config.clone(self.alloc) catch |err| {
                log.warn("failed to clone config change: {}", .{err});
                return true;
            };
            self.config.deinit();
            self.config = new_clone;
            log.info("config updated", .{});
            return true;
        },

        // ------------------------------------------------------------------
        // Background opacity
        // ------------------------------------------------------------------
        .toggle_background_opacity => {
            if (target == .surface) {
                if (self.windowForCore(target.surface)) |window| {
                    window.toggleBackgroundOpacity();
                }
            }
            return true;
        },

        // ------------------------------------------------------------------
        // Copy title to clipboard
        // ------------------------------------------------------------------
        .copy_title_to_clipboard => {
            if (target == .surface) {
                if (self.surfaceForCore(target.surface)) |s| {
                    if (s.getTitle()) |title| {
                        _ = win32.clipboardWriteText(s.hwnd, title);
                    }
                }
            }
            return true;
        },

        // ------------------------------------------------------------------
        // Cell size, color change, scrollbar, pwd — acknowledge
        // ------------------------------------------------------------------
        .cell_size => {
            if (target == .surface) {
                if (self.surfaceForCore(target.surface)) |s| {
                    s.cell_width = value.width;
                    s.cell_height = value.height;
                }
            }
            return true;
        },

        .color_change => return true,
        .scrollbar => return true,
        .pwd => return true,

        .renderer_health => {
            switch (value) {
                .healthy => {},
                .unhealthy => log.warn("renderer is unhealthy", .{}),
            }
            return true;
        },

        // ------------------------------------------------------------------
        // Secure input / key sequence / key table / readonly
        // ------------------------------------------------------------------
        .secure_input => return true,
        .key_sequence => return true,
        .key_table => return true,
        .readonly => return true,

        // ------------------------------------------------------------------
        // Child exited / command finished
        // ------------------------------------------------------------------
        .show_child_exited => {
            if (target == .surface) {
                if (self.windowForCore(target.surface)) |window| {
                    win32.flashWindow(window.hwnd);
                }
            }
            return true;
        },

        .command_finished => return true,
        .progress_report => return true,

        // ------------------------------------------------------------------
        // Search (not yet implemented — needs overlay UI)
        // ------------------------------------------------------------------
        .start_search => {
            if (target == .surface) {
                if (self.surfaceForCore(target.surface)) |s| {
                    s.startSearch(value.needle);
                }
            }
            return true;
        },

        .end_search => {
            if (target == .surface) {
                if (self.surfaceForCore(target.surface)) |s| {
                    s.endSearch();
                }
            }
            return true;
        },

        .search_total => {
            if (target == .surface) {
                if (self.surfaceForCore(target.surface)) |s| {
                    s.setSearchTotal(value.total);
                }
            }
            return true;
        },

        .search_selected => {
            if (target == .surface) {
                if (self.surfaceForCore(target.surface)) |s| {
                    s.setSearchSelected(value.selected);
                }
            }
            return true;
        },

        // ------------------------------------------------------------------
        // Show on-screen keyboard (not applicable on desktop Windows)
        // ------------------------------------------------------------------
        .show_on_screen_keyboard => return true,

        // ------------------------------------------------------------------
        // Prompt title (would need a dialog)
        // ------------------------------------------------------------------
        .prompt_title => {
            log.info("prompt_title not yet implemented on Windows", .{});
            return false;
        },

        // ------------------------------------------------------------------
        // Undo/Redo (macOS-centric, not applicable)
        // ------------------------------------------------------------------
        .undo, .redo => return false,

        // ------------------------------------------------------------------
        // Check for updates (not yet implemented)
        // ------------------------------------------------------------------
        .check_for_updates => return false,

        // ------------------------------------------------------------------
        // GTK-specific
        // ------------------------------------------------------------------
        .show_gtk_inspector => return false,
        .render_inspector => return true,
        .inspector => return false,

        // ------------------------------------------------------------------
        // Splits
        // ------------------------------------------------------------------
        .new_split => {
            if (target == .surface) {
                if (self.windowForCore(target.surface)) |window| {
                    window.newSplit(value) catch |err| {
                        log.warn("failed to create split: {}", .{err});
                    };
                }
            }
            return true;
        },

        .goto_split => {
            if (target == .surface) {
                if (self.windowForCore(target.surface)) |window| {
                    window.gotoSplit(value);
                }
            }
            return true;
        },

        .resize_split => {
            if (target == .surface) {
                if (self.windowForCore(target.surface)) |window| {
                    window.resizeSplit(value);
                }
            }
            return true;
        },

        .equalize_splits => {
            if (target == .surface) {
                if (self.windowForCore(target.surface)) |window| {
                    window.equalizeSplits();
                }
            }
            return true;
        },

        .toggle_split_zoom => {
            if (target == .surface) {
                if (self.windowForCore(target.surface)) |window| {
                    window.toggleSplitZoom();
                }
            }
            return true;
        },

        // ------------------------------------------------------------------
        // Features not yet implemented
        // ------------------------------------------------------------------
        .goto_window => {
            if (self.windows.items.len <= 1) return true;
            if (target == .surface) {
                // Find the current window index
                const current_win = self.windowForCore(target.surface);
                var cur_idx: usize = 0;
                for (self.windows.items, 0..) |w_item, idx| {
                    if (current_win != null and w_item == current_win.?) {
                        cur_idx = idx;
                        break;
                    }
                }
                const int_val: c_int = @intFromEnum(value);
                const next_idx: usize = if (int_val == 0)
                    // previous
                    if (cur_idx == 0) self.windows.items.len - 1 else cur_idx - 1
                else
                    // next
                    (cur_idx + 1) % self.windows.items.len;
                self.windows.items[next_idx].present();
            }
            return true;
        },

        .toggle_quick_terminal,
        .toggle_command_palette,
        .toggle_tab_overview,
        => return false,
    }
}

/// Static IPC handler. Not currently implemented for Windows.
pub fn performIpc(
    _: Allocator,
    _: apprt.ipc.Target,
    comptime action: apprt.ipc.Action.Key,
    _: apprt.ipc.Action.Value(action),
) !bool {
    return false;
}

/// Redraw the inspector for a surface (no-op; inspector not implemented).
pub fn redrawInspector(_: *App, _: *Surface) void {}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/// Create a new top-level terminal window with one tab.
pub fn newWindow(self: *App) !*Window {
    const window = try self.alloc.create(Window);
    errdefer self.alloc.destroy(window);

    try window.init(self);
    errdefer window.deinit();

    try self.windows.append(self.alloc, window);
    return window;
}

/// Remove and destroy a window. Called when a window is closed.
pub fn removeWindow(self: *App, window: *Window) void {
    for (self.windows.items, 0..) |w_item, i| {
        if (w_item == window) {
            _ = self.windows.swapRemove(i);
            break;
        }
    }
    window.deinit();
    self.alloc.destroy(window);

    if (self.windows.items.len == 0) {
        self.quit_requested = true;
    }
}

/// Check if a WM_KEYDOWN message targets a search edit control and intercept
/// Escape/Enter keys before they are dispatched normally.
fn handleSearchKeyIntercept(self: *App, msg: *win32.MSG) bool {
    const vk: u16 = @intCast(msg.wParam & 0xFFFF);
    // Only intercept Escape and Enter
    if (vk != 0x1B and vk != 0x0D) return false;

    // Check if the message's target HWND belongs to a search edit
    const target_hwnd = msg.hwnd orelse return false;
    for (self.windows.items) |window| {
        for (window.tabs.items) |tab| {
            var leaves: std.ArrayListUnmanaged(*Surface) = .{};
            defer leaves.deinit(self.alloc);
            tab.root.collectLeaves(self.alloc, &leaves);
            for (leaves.items) |surface| {
                if (surface.search_edit_hwnd) |edit_hwnd| {
                    if (edit_hwnd == target_hwnd) {
                        return surface.onSearchKeyDown(vk);
                    }
                }
            }
        }
    }
    return false;
}

/// Find the Win32 Surface that wraps the given CoreSurface.
fn surfaceForCore(self: *App, core_surface: *CoreSurface) ?*Surface {
    for (self.windows.items) |window| {
        if (window.findSurface(core_surface)) |surface| return surface;
    }
    return null;
}

/// Find the Window that contains the given CoreSurface.
fn windowForCore(self: *App, core_surface: *CoreSurface) ?*Window {
    for (self.windows.items) |window| {
        if (window.findSurface(core_surface) != null) return window;
    }
    return null;
}
