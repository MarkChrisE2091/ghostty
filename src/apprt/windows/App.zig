/// Win32 application runtime for Ghostty.
///
/// This implements the apprt interface using native Win32 APIs.
/// One App drives one Win32 message loop. Each terminal window is
/// a Surface (see Surface.zig).
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
const internal_os = @import("../../os/main.zig");
const renderer = @import("../../renderer.zig");
const terminal = @import("../../terminal/main.zig");

const win32 = @import("win32.zig");
const w = std.os.windows;

const log = std.log.scoped(.win32);

// ---------------------------------------------------------------------------
// Apprt constants queried by CoreApp
// ---------------------------------------------------------------------------

/// The renderer thread can draw from any thread via WGL.
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

/// All live surfaces.
surfaces: std.ArrayListUnmanaged(*Surface),

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

    // Load the configuration. On failure, log the error and continue with
    // a default config so the window can still open.
    var config = configpkg.Config.load(alloc) catch |err| blk: {
        log.warn("failed to load config: {}; using defaults", .{err});
        break :blk try configpkg.Config.default(alloc);
    };
    defer config.deinit();

    var config_clone = try config.clone(alloc);
    errdefer config_clone.deinit();

    // GetModuleHandleW returns HMODULE; Win32 treats HMODULE == HINSTANCE
    // at the ABI level but Zig models them as distinct opaques, so cast.
    const hinstance: w.HINSTANCE = @ptrCast(
        w.kernel32.GetModuleHandleW(null) orelse return error.GetModuleHandleFailed,
    );

    try win32.registerWindowClass(hinstance);

    self.* = .{
        .hinstance = hinstance,
        .core_app = core_app,
        .config = config_clone,
        .surfaces = .{},
        .alloc = alloc,
        .quit_requested = false,
        .quit_timer_id = null,
    };

    // Create the first terminal window
    _ = try self.newSurface();
}

pub fn run(self: *App) !void {
    // Classic Win32 message loop with WaitMessage so we don't spin.
    var msg: win32.MSG = undefined;
    while (!self.quit_requested) {
        // Process all pending messages
        while (win32.peekMessage(&msg, null, 0, 0, win32.PM_REMOVE)) {
            if (msg.message == win32.WM_QUIT) {
                self.quit_requested = true;
                break;
            }
            win32.translateMessage(&msg);
            win32.dispatchMessage(&msg);
        }

        if (self.quit_requested) break;

        // Tick the core app mailbox
        self.core_app.tick(self) catch |err| {
            log.err("error ticking core app: {}", .{err});
        };

        if (self.surfaces.items.len == 0 and self.quit_timer_id == null) {
            self.quit_requested = true;
            break;
        }

        // Wait for the next message instead of busy-spinning.
        // The wakeup() method posts WM_USER to interrupt this wait.
        win32.waitMessage();
    }
}

pub fn terminate(self: *App) void {
    for (self.surfaces.items) |surface| {
        surface.deinit();
        self.alloc.destroy(surface);
    }
    self.surfaces.deinit(self.alloc);
    self.config.deinit();
}

/// Called by CoreApp to interrupt the WaitMessage() in run().
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
            // Close all surfaces; the message loop will then exit.
            var i = self.surfaces.items.len;
            while (i > 0) {
                i -= 1;
                const s = self.surfaces.items[i];
                _ = self.surfaces.swapRemove(i);
                s.deinit();
                self.alloc.destroy(s);
            }
            self.quit_requested = true;
            return true;
        },

        .quit_timer => {
            switch (value) {
                .start => {
                    // Set a 100ms WM_TIMER to poll the "no more surfaces" condition.
                    // In a real implementation, honor the config quit-after-close-delay.
                    // For now just quit immediately if no surfaces.
                    if (self.surfaces.items.len == 0) {
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
            _ = try self.newSurface();
            return true;
        },

        .close_window => {
            if (target == .surface) {
                if (self.surfaceForCore(target.surface)) |s| {
                    self.removeSurface(s);
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

        // set_tab_title: we don't have tabs, treat same as set_title
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
                for (self.surfaces.items) |s| s.requestRender();
            }
            return true;
        },

        // ------------------------------------------------------------------
        // Window state
        // ------------------------------------------------------------------
        .toggle_fullscreen => {
            if (target == .surface) {
                if (self.surfaceForCore(target.surface)) |s| s.toggleFullscreen();
            }
            return true;
        },

        .toggle_maximize => {
            if (target == .surface) {
                if (self.surfaceForCore(target.surface)) |s| s.toggleMaximize();
            }
            return true;
        },

        .toggle_window_decorations => {
            if (target == .surface) {
                if (self.surfaceForCore(target.surface)) |s| s.toggleDecorations();
            }
            return true;
        },

        .float_window => {
            if (target == .surface) {
                if (self.surfaceForCore(target.surface)) |s| {
                    switch (value) {
                        .on => s.setFloating(true),
                        .off => s.setFloating(false),
                        .toggle => s.setFloating(true), // simplified
                    }
                }
            }
            return true;
        },

        .toggle_visibility => {
            // Toggle all windows visible/hidden
            for (self.surfaces.items) |s| {
                win32.showWindow(s.hwnd, win32.SW_SHOW);
            }
            return true;
        },

        // ------------------------------------------------------------------
        // Size constraints
        // ------------------------------------------------------------------
        .size_limit => {
            if (target == .surface) {
                if (self.surfaceForCore(target.surface)) |s| s.setSizeLimit(value);
            }
            return true;
        },

        .initial_size => {
            if (target == .surface) {
                if (self.surfaceForCore(target.surface)) |s| s.setInitialSize(value);
            }
            return true;
        },

        .reset_window_size => {
            if (target == .surface) {
                if (self.surfaceForCore(target.surface)) |s| {
                    s.setInitialSize(.{ .width = 800, .height = 600 });
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
                if (self.surfaceForCore(target.surface)) |s| {
                    s.showDesktopNotification(value.title, value.body);
                }
            } else if (self.surfaces.items.len > 0) {
                self.surfaces.items[0].showDesktopNotification(value.title, value.body);
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
            // Resolve the config path and open it in the default editor
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
                if (self.surfaceForCore(target.surface)) |s| s.present();
            }
            return true;
        },

        // ------------------------------------------------------------------
        // Config reload
        // ------------------------------------------------------------------
        .reload_config => {
            if (!value.soft) {
                // Hard reload: re-read config from disk
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
            // Push config to core (updates all surfaces)
            self.core_app.updateConfig(self, &self.config) catch |err| {
                log.warn("failed to push config update: {}", .{err});
            };
            return true;
        },

        .config_change => {
            // The core has applied a new config. Update our stored copy
            // so future surfaces pick it up.
            // The value.config pointer is only valid for this call; clone it.
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
                if (self.surfaceForCore(target.surface)) |s| {
                    s.toggleBackgroundOpacity();
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

        .color_change => return true, // renderer handles internally

        .scrollbar => return true, // no native scrollbar yet

        .pwd => return true, // tracked internally by core

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
                if (self.surfaceForCore(target.surface)) |s| {
                    // Flash the taskbar to indicate the child has exited
                    win32.flashWindow(s.hwnd);
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
            log.info("search not yet implemented on Windows", .{});
            return false;
        },
        .end_search => return true,
        .search_total => return true,
        .search_selected => return true,

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
        // Features requiring complex UI (tabs, splits, command palette, etc.)
        // Not yet implemented in Win32 runtime.
        // ------------------------------------------------------------------
        .toggle_quick_terminal,
        .toggle_command_palette,
        .toggle_tab_overview,
        .toggle_split_zoom,
        .equalize_splits,
        .resize_split,
        .goto_split,
        .goto_tab,
        .goto_window,
        .move_tab,
        .close_tab,
        .new_tab,
        .new_split,
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

/// Create a new terminal window surface.
pub fn newSurface(self: *App) !*Surface {
    const surface = try self.alloc.create(Surface);
    errdefer self.alloc.destroy(surface);

    try surface.init(self);
    errdefer surface.deinit();

    try self.surfaces.append(self.alloc, surface);
    return surface;
}

/// Remove and destroy a surface. Called when a window is closed.
pub fn removeSurface(self: *App, surface: *Surface) void {
    for (self.surfaces.items, 0..) |s, i| {
        if (s == surface) {
            _ = self.surfaces.swapRemove(i);
            break;
        }
    }
    surface.deinit();
    self.alloc.destroy(surface);

    // If no surfaces remain, start the quit process
    if (self.surfaces.items.len == 0) {
        self.quit_requested = true;
    }
}

/// Find the Win32 Surface that wraps the given CoreSurface.
fn surfaceForCore(self: *App, core_surface: *CoreSurface) ?*Surface {
    for (self.surfaces.items) |surface| {
        if (&surface.core_surface == core_surface) return surface;
    }
    return null;
}
