/// Win32 Window — top-level frame that hosts tabs of terminal Surfaces.
///
/// Each Window owns:
///   - A top-level Win32 HWND (with a custom tab bar when multiple tabs)
///   - A list of tabs, each with a SplitNode tree of Surfaces
///   - Window-level state (fullscreen, decorations, etc.)
const Window = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const apprt = @import("../../apprt.zig");
const configpkg = @import("../../config.zig");
const input = @import("../../input.zig");
const terminal = @import("../../terminal/main.zig");
const App = @import("App.zig");
const Surface = @import("Surface.zig");
const SplitNode = @import("SplitNode.zig");
const win32 = @import("win32.zig");
const w = std.os.windows;

const log = std.log.scoped(.win32_window);

/// Tab bar height when visible (2+ tabs).
const TAB_BAR_HEIGHT: u32 = 30;

// Tab colors (COLORREF = 0x00BBGGRR)
const CLR_TAB_BG: u32 = 0x001E1E1E;
const CLR_TAB_ACTIVE: u32 = 0x00403030;
const CLR_TAB_INACTIVE: u32 = 0x00262626;
const CLR_TAB_TEXT: u32 = 0x00CCCCCC;
const CLR_TAB_ACTIVE_TEXT: u32 = 0x00FFFFFF;
const CLR_TAB_CLOSE: u32 = 0x00808080;
const CLR_TAB_SEPARATOR: u32 = 0x003C3C3C;

// Tab dimensions
const TAB_MAX_WIDTH: u32 = 200;
const TAB_MIN_WIDTH: u32 = 80;
const TAB_PADDING: u32 = 10;
const TAB_CLOSE_SIZE: u32 = 16;
const TAB_NEW_BTN_WIDTH: u32 = 30;

/// A tab — one split tree of surfaces.
pub const Tab = struct {
    root: *SplitNode,
    /// The surface that last had focus within this tab.
    active_surface: *Surface,
    /// Zoomed surface (if any) — only this one is shown, full-size.
    zoomed: ?*Surface,
};

// ---------------------------------------------------------------------------
// Fields
// ---------------------------------------------------------------------------

/// Top-level window handle.
hwnd: win32.HWND,

/// All tabs.
tabs: std.ArrayListUnmanaged(Tab),

/// Index of the currently active (visible) tab.
active_tab: usize,

/// Back-reference to the App.
app: *App,

/// Window dimensions (physical pixels of client area).
width: u32,
height: u32,

/// DPI scaling.
scale_x: f32,
scale_y: f32,

/// Fullscreen state + saved placement for restore.
fullscreen: bool,
saved_placement: ?win32.WINDOWPLACEMENT,
saved_style: u32,

/// Size constraints.
min_width: u32,
min_height: u32,

/// Background opacity.
background_opacity: f64,
background_opaque: bool,

/// Whether the window is currently floating (always-on-top).
floating: bool,

// ---------------------------------------------------------------------------
// Init / Deinit
// ---------------------------------------------------------------------------

pub fn init(self: *Window, app: *App) !void {
    const default_width: u32 = 800;
    const default_height: u32 = 600;

    const hwnd = try win32.createMainWindow(
        app.hinstance,
        "Ghostty",
        default_width,
        default_height,
        @intFromPtr(self),
    );
    errdefer win32.destroyWindow(hwnd);

    const dpi = win32.getDpiForWindow(hwnd);
    const scale: f32 = @as(f32, @floatFromInt(dpi)) / 96.0;

    self.* = .{
        .hwnd = hwnd,
        .tabs = .{},
        .active_tab = 0,
        .app = app,
        .width = default_width,
        .height = default_height,
        .scale_x = scale,
        .scale_y = scale,
        .fullscreen = false,
        .saved_placement = null,
        .saved_style = win32.WS_OVERLAPPEDWINDOW,
        .min_width = 0,
        .min_height = 0,
        .background_opacity = app.config.@"background-opacity",
        .background_opaque = true,
        .floating = false,
    };

    win32.showWindow(hwnd, win32.SW_SHOWNORMAL);
    win32.updateWindow(hwnd);

    // Get actual client area after showing
    var client_rect: win32.RECT = .{};
    if (win32.getClientRect(hwnd, &client_rect)) {
        self.width = @intCast(client_rect.right - client_rect.left);
        self.height = @intCast(client_rect.bottom - client_rect.top);
    }

    // Create the first tab
    _ = try self.addTab();
}

pub fn deinit(self: *Window) void {
    const alloc = self.app.alloc;
    for (self.tabs.items) |tab| {
        tab.root.destroyAll(alloc);
    }
    self.tabs.deinit(alloc);
    win32.destroyWindow(self.hwnd);
}

// ---------------------------------------------------------------------------
// Tab management
// ---------------------------------------------------------------------------

pub fn addTab(self: *Window) !*Surface {
    const alloc = self.app.alloc;
    const surface = try alloc.create(Surface);
    errdefer alloc.destroy(surface);

    // Calculate the surface area (below tab bar).
    const will_have_tabs = self.tabs.items.len + 1;
    const bar_h: u32 = if (will_have_tabs <= 1) 0 else TAB_BAR_HEIGHT;
    const surface_height = if (self.height > bar_h) self.height - bar_h else 1;

    try surface.init(self, 0, @intCast(bar_h), self.width, surface_height);
    errdefer surface.deinit();

    const node = try SplitNode.initLeaf(alloc, surface);
    errdefer alloc.destroy(node);
    surface.split_node = node;

    // Hide all surfaces in the currently active tab
    if (self.tabs.items.len > 0 and self.active_tab < self.tabs.items.len) {
        self.hideTabSurfaces(self.active_tab);
    }

    try self.tabs.append(alloc, .{
        .root = node,
        .active_surface = surface,
        .zoomed = null,
    });
    self.active_tab = self.tabs.items.len - 1;

    // Show the new surface
    win32.showWindow(surface.hwnd, win32.SW_SHOW);
    win32.setFocus(surface.hwnd);

    // Tab bar visibility may have changed (1->2 tabs)
    self.relayoutTabs();
    self.invalidateTabBar();

    return surface;
}

pub fn removeTab(self: *Window, surface: *Surface) void {
    const alloc = self.app.alloc;

    // Find which tab contains this surface
    var tab_idx: ?usize = null;
    for (self.tabs.items, 0..) |tab, i| {
        if (tab.root.findLeaf(surface) != null) {
            tab_idx = i;
            break;
        }
    }
    const i = tab_idx orelse return;

    // If this tab has splits, just remove this one surface from the split tree
    if (self.tabs.items[i].root.leafCount() > 1) {
        self.removeSurfaceFromSplit(i, surface);
        return;
    }

    // Single surface tab — remove the entire tab
    self.hideTabSurfaces(i);
    self.tabs.items[i].root.destroyAll(alloc);
    _ = self.tabs.orderedRemove(i);

    if (self.tabs.items.len == 0) {
        self.app.removeWindow(self);
        return;
    }

    // Adjust active tab index
    if (self.active_tab >= self.tabs.items.len) {
        self.active_tab = self.tabs.items.len - 1;
    } else if (self.active_tab > i) {
        self.active_tab -= 1;
    }

    self.showActiveTab();
    self.relayoutTabs();
    self.invalidateTabBar();
}

fn removeSurfaceFromSplit(self: *Window, tab_idx: usize, surface: *Surface) void {
    const alloc = self.app.alloc;
    var tab = &self.tabs.items[tab_idx];
    const leaf = surface.split_node orelse return;

    // If zoomed, unzoom first
    if (tab.zoomed != null) tab.zoomed = null;

    // Remove the surface from the tree
    surface.deinit();
    alloc.destroy(surface);
    const remaining = leaf.remove(alloc);

    // Update active surface if needed
    if (tab.active_surface == surface) {
        if (remaining) |r| {
            tab.active_surface = r.firstLeaf() orelse return;
        } else {
            // Tree is now empty — shouldn't happen since we checked leafCount > 1
            return;
        }
    }

    // Re-layout and focus
    self.layoutActiveTab();
    win32.setFocus(tab.active_surface.hwnd);
}

pub fn switchTab(self: *Window, index: usize) void {
    if (index >= self.tabs.items.len) return;
    if (index == self.active_tab) return;

    // Hide current tab's surfaces
    self.hideTabSurfaces(self.active_tab);

    self.active_tab = index;
    self.showActiveTab();
    self.invalidateTabBar();
}

pub fn gotoTab(self: *Window, value: anytype) void {
    const tab_count = self.tabs.items.len;
    if (tab_count == 0) return;

    const int_val: c_int = @intFromEnum(value);
    if (int_val == -1) {
        // previous
        if (tab_count <= 1) return;
        const prev = if (self.active_tab == 0) tab_count - 1 else self.active_tab - 1;
        self.switchTab(prev);
    } else if (int_val == -2) {
        // next
        if (tab_count <= 1) return;
        const next = (self.active_tab + 1) % tab_count;
        self.switchTab(next);
    } else if (int_val == -3) {
        // last
        self.switchTab(tab_count - 1);
    } else if (int_val >= 0) {
        const idx: usize = @intCast(int_val);
        if (idx < tab_count) self.switchTab(idx);
    }
}

pub fn closeTab(self: *Window, mode: anytype) void {
    const int_val: c_int = @intFromEnum(mode);
    if (int_val == 0) {
        // this: close current tab
        if (self.active_tab < self.tabs.items.len) {
            const tab = self.tabs.items[self.active_tab];
            // Close the active surface (which will remove from split or close tab)
            self.removeTab(tab.active_surface);
        }
    } else if (int_val == 1) {
        // other: close all other tabs
        const alloc = self.app.alloc;
        var i: usize = self.tabs.items.len;
        while (i > 0) {
            i -= 1;
            if (i != self.active_tab) {
                self.hideTabSurfaces(i);
                self.tabs.items[i].root.destroyAll(alloc);
                _ = self.tabs.orderedRemove(i);
                if (self.active_tab > i) self.active_tab -= 1;
            }
        }
        self.relayoutTabs();
        self.invalidateTabBar();
    } else if (int_val == 2) {
        // right: close tabs to the right
        const alloc = self.app.alloc;
        while (self.tabs.items.len > self.active_tab + 1) {
            const last = self.tabs.items.len - 1;
            self.hideTabSurfaces(last);
            self.tabs.items[last].root.destroyAll(alloc);
            _ = self.tabs.orderedRemove(last);
        }
        self.relayoutTabs();
        self.invalidateTabBar();
    }
}

pub fn moveTab(self: *Window, amount: isize) void {
    if (self.tabs.items.len <= 1) return;
    const len: isize = @intCast(self.tabs.items.len);
    const cur: isize = @intCast(self.active_tab);
    var new_pos = @mod(cur + amount, len);
    if (new_pos < 0) new_pos += len;
    const new_idx: usize = @intCast(new_pos);
    if (new_idx == self.active_tab) return;

    const tab = self.tabs.orderedRemove(self.active_tab);
    self.tabs.insert(self.app.alloc, new_idx, tab) catch return;
    self.active_tab = new_idx;
    self.invalidateTabBar();
}

fn showActiveTab(self: *Window) void {
    if (self.active_tab >= self.tabs.items.len) return;
    const tab = self.tabs.items[self.active_tab];

    // Show all surfaces in this tab
    self.showTabSurfaces(self.active_tab);
    self.layoutActiveTab();

    // Focus the active surface
    win32.setFocus(tab.active_surface.hwnd);

    // Update window title
    if (tab.active_surface.getTitle()) |title| {
        win32.setWindowTitleZ(self.hwnd, title);
    } else {
        win32.setWindowTitle(self.hwnd, "Ghostty");
    }
}

fn hideTabSurfaces(self: *Window, tab_idx: usize) void {
    if (tab_idx >= self.tabs.items.len) return;
    const tab = self.tabs.items[tab_idx];
    var leaves: std.ArrayListUnmanaged(*Surface) = .{};
    defer leaves.deinit(self.app.alloc);
    tab.root.collectLeaves(self.app.alloc, &leaves);
    for (leaves.items) |s| {
        win32.showWindow(s.hwnd, win32.SW_HIDE);
    }
}

fn showTabSurfaces(self: *Window, tab_idx: usize) void {
    if (tab_idx >= self.tabs.items.len) return;
    const tab = self.tabs.items[tab_idx];
    var leaves: std.ArrayListUnmanaged(*Surface) = .{};
    defer leaves.deinit(self.app.alloc);
    tab.root.collectLeaves(self.app.alloc, &leaves);
    for (leaves.items) |s| {
        win32.showWindow(s.hwnd, win32.SW_SHOW);
    }
}

// ---------------------------------------------------------------------------
// Split operations
// ---------------------------------------------------------------------------

pub fn newSplit(self: *Window, direction: apprt.action.SplitDirection) !void {
    if (self.active_tab >= self.tabs.items.len) return;
    var tab = &self.tabs.items[self.active_tab];

    // Unzoom if zoomed
    if (tab.zoomed != null) tab.zoomed = null;

    const alloc = self.app.alloc;
    const active = tab.active_surface;
    const leaf = active.split_node orelse return;

    // Create a new surface
    const new_surface = try alloc.create(Surface);
    errdefer alloc.destroy(new_surface);

    // Initialize it in a temporary position; layout will fix it
    try new_surface.init(self, 0, 0, 100, 100);
    errdefer new_surface.deinit();

    const split_dir: SplitNode.Direction = switch (direction) {
        .right, .left => .horizontal,
        .down, .up => .vertical,
    };

    // Split the leaf node
    const new_node = try leaf.split(alloc, split_dir, new_surface);
    _ = new_node;

    // If direction is left or up, swap first/second so new surface appears before
    if (direction == .left or direction == .up) {
        if (leaf.tag == .split) {
            const tmp = leaf.data.split.first;
            leaf.data.split.first = leaf.data.split.second;
            leaf.data.split.second = tmp;
        }
    }

    // Update active surface and layout
    tab.active_surface = new_surface;
    self.layoutActiveTab();
    win32.showWindow(new_surface.hwnd, win32.SW_SHOW);
    win32.setFocus(new_surface.hwnd);
}

pub fn gotoSplit(self: *Window, goto_value: apprt.action.GotoSplit) void {
    if (self.active_tab >= self.tabs.items.len) return;
    var tab = &self.tabs.items[self.active_tab];
    const active = tab.active_surface;

    const target: ?*Surface = switch (goto_value) {
        .previous => tab.root.gotoPrevNext(active, false, self.app.alloc),
        .next => tab.root.gotoPrevNext(active, true, self.app.alloc),
        .up => tab.root.gotoSpatial(active, .up),
        .down => tab.root.gotoSpatial(active, .down),
        .left => tab.root.gotoSpatial(active, .left),
        .right => tab.root.gotoSpatial(active, .right),
    };

    if (target) |t| {
        tab.active_surface = t;
        win32.setFocus(t.hwnd);
    }
}

pub fn resizeSplit(self: *Window, value: apprt.action.ResizeSplit) void {
    if (self.active_tab >= self.tabs.items.len) return;
    const tab = self.tabs.items[self.active_tab];
    const active = tab.active_surface;

    tab.root.resizeSplit(active, switch (value.direction) {
        .up => .up,
        .down => .down,
        .left => .left,
        .right => .right,
    }, value.amount);
    self.layoutActiveTab();
}

pub fn equalizeSplits(self: *Window) void {
    if (self.active_tab >= self.tabs.items.len) return;
    self.tabs.items[self.active_tab].root.equalize();
    self.layoutActiveTab();
}

pub fn toggleSplitZoom(self: *Window) void {
    if (self.active_tab >= self.tabs.items.len) return;
    var tab = &self.tabs.items[self.active_tab];

    // Only makes sense if there are splits
    if (tab.root.leafCount() <= 1) return;

    if (tab.zoomed != null) {
        // Unzoom — show all surfaces
        tab.zoomed = null;
        self.showTabSurfaces(self.active_tab);
        self.layoutActiveTab();
    } else {
        // Zoom — hide all except active, make it full size
        tab.zoomed = tab.active_surface;
        var leaves: std.ArrayListUnmanaged(*Surface) = .{};
        defer leaves.deinit(self.app.alloc);
        tab.root.collectLeaves(self.app.alloc, &leaves);
        for (leaves.items) |s| {
            if (s != tab.active_surface) {
                win32.showWindow(s.hwnd, win32.SW_HIDE);
            }
        }
        // Position the zoomed surface to fill the entire content area
        const bar_h = self.getTabBarHeight();
        const surface_h = if (self.height > bar_h) self.height - bar_h else 1;
        win32.moveWindow(tab.active_surface.hwnd, 0, @intCast(bar_h), @intCast(self.width), @intCast(surface_h), true);
        tab.active_surface.onResize(self.width, surface_h);
    }
}

// ---------------------------------------------------------------------------
// Layout
// ---------------------------------------------------------------------------

pub fn getTabBarHeight(self: *const Window) u32 {
    if (self.tabs.items.len <= 1) return 0;
    return TAB_BAR_HEIGHT;
}

fn relayoutTabs(self: *Window) void {
    // Only need to layout the active tab
    self.layoutActiveTab();
}

fn layoutActiveTab(self: *Window) void {
    if (self.active_tab >= self.tabs.items.len) return;
    const tab = self.tabs.items[self.active_tab];

    // If zoomed, just position the zoomed surface
    if (tab.zoomed) |zoomed| {
        const bar_h = self.getTabBarHeight();
        const surface_h = if (self.height > bar_h) self.height - bar_h else 1;
        win32.moveWindow(zoomed.hwnd, 0, @intCast(bar_h), @intCast(self.width), @intCast(surface_h), true);
        zoomed.onResize(self.width, surface_h);
        return;
    }

    const bar_h = self.getTabBarHeight();
    const surface_h = if (self.height > bar_h) self.height - bar_h else 1;
    tab.root.layout(.{
        .x = 0,
        .y = @intCast(bar_h),
        .w = self.width,
        .h = surface_h,
    });
}

pub fn invalidateTabBar(self: *Window) void {
    if (self.getTabBarHeight() == 0) return;
    var rc: win32.RECT = .{
        .left = 0,
        .top = 0,
        .right = @intCast(self.width),
        .bottom = @intCast(self.getTabBarHeight()),
    };
    win32.invalidateRect(self.hwnd, &rc, false);
}

// ---------------------------------------------------------------------------
// Tab bar painting
// ---------------------------------------------------------------------------

pub fn paintTabBar(self: *Window, hdc: win32.HDC) void {
    const bar_h = self.getTabBarHeight();
    if (bar_h == 0) return;

    const tab_count = self.tabs.items.len;
    if (tab_count == 0) return;

    // Fill background
    var bg_rect: win32.RECT = .{
        .left = 0,
        .top = 0,
        .right = @intCast(self.width),
        .bottom = @intCast(bar_h),
    };
    win32.gdi.fillRect(hdc, &bg_rect, CLR_TAB_BG);

    // Calculate tab width
    const available_width = self.width -| TAB_NEW_BTN_WIDTH;
    var tab_width: u32 = if (tab_count > 0)
        available_width / @as(u32, @intCast(tab_count))
    else
        TAB_MAX_WIDTH;
    tab_width = @min(tab_width, TAB_MAX_WIDTH);
    tab_width = @max(tab_width, TAB_MIN_WIDTH);

    // Select font
    const font = win32.gdi.getStockObject(win32.gdi.DEFAULT_GUI_FONT);
    const old_font = win32.gdi.selectObject(hdc, font);
    defer _ = win32.gdi.selectObject(hdc, old_font);
    _ = win32.gdi.setBkMode(hdc, win32.gdi.TRANSPARENT);

    // Draw each tab
    for (self.tabs.items, 0..) |tab, idx| {
        const x: i32 = @intCast(idx * tab_width);
        const is_active = (idx == self.active_tab);

        var tab_rect: win32.RECT = .{
            .left = x,
            .top = 0,
            .right = x + @as(i32, @intCast(tab_width)),
            .bottom = @intCast(bar_h),
        };

        // Fill tab background
        const bg_color: u32 = if (is_active) CLR_TAB_ACTIVE else CLR_TAB_INACTIVE;
        win32.gdi.fillRect(hdc, &tab_rect, bg_color);

        // Draw tab text — use the active surface's title
        const text_color: u32 = if (is_active) CLR_TAB_ACTIVE_TEXT else CLR_TAB_TEXT;
        _ = win32.gdi.setTextColor(hdc, text_color);

        const title: []const u8 = if (tab.active_surface.getTitle()) |t| t[0..t.len] else "Terminal";

        var text_rect = tab_rect;
        text_rect.left += @intCast(TAB_PADDING);
        text_rect.right -= @intCast(TAB_CLOSE_SIZE + TAB_PADDING);
        win32.gdi.drawText(hdc, title, &text_rect, win32.gdi.DT_SINGLELINE | win32.gdi.DT_VCENTER | win32.gdi.DT_END_ELLIPSIS | win32.gdi.DT_NOPREFIX);

        // Draw close button "x"
        _ = win32.gdi.setTextColor(hdc, CLR_TAB_CLOSE);
        var close_rect: win32.RECT = .{
            .left = tab_rect.right - @as(i32, @intCast(TAB_CLOSE_SIZE + 4)),
            .top = tab_rect.top + 4,
            .right = tab_rect.right - 4,
            .bottom = tab_rect.bottom - 4,
        };
        win32.gdi.drawText(hdc, "x", &close_rect, win32.gdi.DT_SINGLELINE | win32.gdi.DT_CENTER | win32.gdi.DT_VCENTER);

        // Right separator between tabs
        if (idx < tab_count - 1) {
            var sep_rect: win32.RECT = .{
                .left = tab_rect.right - 1,
                .top = 4,
                .right = tab_rect.right,
                .bottom = @intCast(bar_h - 4),
            };
            win32.gdi.fillRect(hdc, &sep_rect, CLR_TAB_SEPARATOR);
        }
    }

    // Draw "+" button
    const plus_x: i32 = @intCast(@min(tab_count * tab_width, self.width -| TAB_NEW_BTN_WIDTH));
    _ = win32.gdi.setTextColor(hdc, CLR_TAB_TEXT);
    var plus_rect: win32.RECT = .{
        .left = plus_x,
        .top = 0,
        .right = plus_x + @as(i32, @intCast(TAB_NEW_BTN_WIDTH)),
        .bottom = @intCast(bar_h),
    };
    win32.gdi.drawText(hdc, "+", &plus_rect, win32.gdi.DT_SINGLELINE | win32.gdi.DT_CENTER | win32.gdi.DT_VCENTER);

    // Bottom separator line
    var bottom_rect: win32.RECT = .{
        .left = 0,
        .top = @intCast(bar_h - 1),
        .right = @intCast(self.width),
        .bottom = @intCast(bar_h),
    };
    win32.gdi.fillRect(hdc, &bottom_rect, CLR_TAB_SEPARATOR);
}

// ---------------------------------------------------------------------------
// Tab bar click handling
// ---------------------------------------------------------------------------

pub fn onTabBarClick(self: *Window, x: i32, y: i32) void {
    _ = y;
    const tab_count = self.tabs.items.len;
    if (tab_count == 0) return;

    const available_width = self.width -| TAB_NEW_BTN_WIDTH;
    var tab_width: u32 = if (tab_count > 0)
        available_width / @as(u32, @intCast(tab_count))
    else
        TAB_MAX_WIDTH;
    tab_width = @min(tab_width, TAB_MAX_WIDTH);
    tab_width = @max(tab_width, TAB_MIN_WIDTH);

    const total_tabs_width: i32 = @intCast(tab_count * tab_width);

    // Check if clicked on "+" button
    if (x >= total_tabs_width and x < total_tabs_width + @as(i32, @intCast(TAB_NEW_BTN_WIDTH))) {
        _ = self.addTab() catch |err| {
            log.warn("failed to create new tab: {}", .{err});
            return;
        };
        return;
    }

    // Check which tab was clicked
    if (x < 0 or x >= total_tabs_width) return;
    const tab_idx: usize = @intCast(@divFloor(@as(u32, @intCast(x)), tab_width));
    if (tab_idx >= tab_count) return;

    // Check if close button was clicked
    const tab_right: i32 = @intCast((tab_idx + 1) * tab_width);
    if (x > tab_right - @as(i32, @intCast(TAB_CLOSE_SIZE + 4))) {
        // Close the entire tab
        const alloc = self.app.alloc;
        self.hideTabSurfaces(tab_idx);
        self.tabs.items[tab_idx].root.destroyAll(alloc);
        _ = self.tabs.orderedRemove(tab_idx);
        if (self.tabs.items.len == 0) {
            self.app.removeWindow(self);
            return;
        }
        if (self.active_tab >= self.tabs.items.len) {
            self.active_tab = self.tabs.items.len - 1;
        } else if (self.active_tab > tab_idx) {
            self.active_tab -= 1;
        }
        self.showActiveTab();
        self.relayoutTabs();
        self.invalidateTabBar();
        return;
    }

    // Switch to this tab
    self.switchTab(tab_idx);
}

// ---------------------------------------------------------------------------
// Window state operations
// ---------------------------------------------------------------------------

pub fn toggleFullscreen(self: *Window) void {
    if (self.fullscreen) {
        win32.setWindowLong(self.hwnd, win32.GWL_STYLE, @bitCast(self.saved_style));
        if (self.saved_placement) |placement| {
            win32.setWindowPlacement(self.hwnd, &placement);
        }
        win32.setWindowPos(self.hwnd, null, 0, 0, 0, 0,
            win32.SWP_NOMOVE | win32.SWP_NOSIZE | win32.SWP_NOZORDER | win32.SWP_FRAMECHANGED);
        self.fullscreen = false;
    } else {
        self.saved_style = @bitCast(win32.getWindowLong(self.hwnd, win32.GWL_STYLE));
        var placement: win32.WINDOWPLACEMENT = .{};
        _ = win32.getWindowPlacement(self.hwnd, &placement);
        self.saved_placement = placement;

        const monitor = win32.monitorFromWindow(self.hwnd, win32.MONITOR_DEFAULTTONEAREST);
        var mi: win32.MONITORINFO = .{};
        if (win32.getMonitorInfo(monitor, &mi)) {
            win32.setWindowLong(self.hwnd, win32.GWL_STYLE,
                @bitCast(win32.WS_POPUP | win32.WS_VISIBLE));
            win32.setWindowPos(self.hwnd, win32.HWND_TOP,
                mi.rcMonitor.left, mi.rcMonitor.top,
                mi.rcMonitor.right - mi.rcMonitor.left,
                mi.rcMonitor.bottom - mi.rcMonitor.top,
                win32.SWP_FRAMECHANGED);
        }
        self.fullscreen = true;
    }
}

pub fn toggleMaximize(self: *Window) void {
    const style: u32 = @bitCast(win32.getWindowLong(self.hwnd, win32.GWL_STYLE));
    if (style & win32.WS_MAXIMIZE != 0) {
        win32.showWindow(self.hwnd, win32.SW_RESTORE);
    } else {
        win32.showWindow(self.hwnd, win32.SW_MAXIMIZE);
    }
}

pub fn toggleDecorations(self: *Window) void {
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

pub fn toggleBackgroundOpacity(self: *Window) void {
    if (self.background_opacity >= 1.0) return;
    self.background_opaque = !self.background_opaque;
    if (self.background_opaque) {
        var style: u32 = @bitCast(win32.getWindowLong(self.hwnd, win32.GWL_EXSTYLE));
        style &= ~win32.WS_EX_LAYERED;
        win32.setWindowLong(self.hwnd, win32.GWL_EXSTYLE, @bitCast(style));
    } else {
        var style: u32 = @bitCast(win32.getWindowLong(self.hwnd, win32.GWL_EXSTYLE));
        style |= win32.WS_EX_LAYERED;
        win32.setWindowLong(self.hwnd, win32.GWL_EXSTYLE, @bitCast(style));
        const alpha: u8 = @intFromFloat(self.background_opacity * 255.0);
        win32.setLayeredWindowAttributes(self.hwnd, 0, alpha, win32.LWA_ALPHA);
    }
}

pub fn setFloating(self: *Window, float: bool) void {
    self.floating = float;
    const z: isize = if (float) win32.HWND_TOPMOST else win32.HWND_NOTOPMOST;
    _ = win32.setWindowPosZ(self.hwnd, z, 0, 0, 0, 0, win32.SWP_NOMOVE | win32.SWP_NOSIZE);
}

pub fn present(self: *Window) void {
    win32.setForegroundWindow(self.hwnd);
    win32.bringWindowToTop(self.hwnd);
}

pub fn setSizeLimit(self: *Window, limit: anytype) void {
    self.min_width = limit.min_width;
    self.min_height = limit.min_height;
}

pub fn setInitialSize(self: *Window, size: anytype) void {
    win32.setWindowPos(self.hwnd, null, 0, 0,
        @intCast(size.width), @intCast(size.height),
        win32.SWP_NOMOVE | win32.SWP_NOZORDER);
}

pub fn setTitle(self: *Window, title: [:0]const u8) void {
    win32.setWindowTitleZ(self.hwnd, title);
}

pub fn showDesktopNotification(self: *Window, title: [:0]const u8, body: [:0]const u8) void {
    var msg_buf: [1024]u8 = undefined;
    const msg_text = std.fmt.bufPrint(&msg_buf, "{s}\n\n{s}", .{ title, body }) catch return;

    var wide_msg: [1024]u16 = undefined;
    var wide_title: [256]u16 = undefined;

    const msg_len = std.unicode.utf8ToUtf16Le(&wide_msg, msg_text) catch return;
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

// ---------------------------------------------------------------------------
// WndProc event handlers (called from win32.zig windowWndProc)
// ---------------------------------------------------------------------------

pub fn onClose(self: *Window) void {
    self.app.removeWindow(self);
}

pub fn onSize(self: *Window, width: u32, height: u32) void {
    if (width == 0 or height == 0) return;
    self.width = width;
    self.height = height;
    self.relayoutTabs();
}

pub fn onMinMaxInfo(self: *Window, mmi: *win32.MINMAXINFO) void {
    if (self.min_width > 0) mmi.ptMinTrackSize.x = @intCast(self.min_width);
    if (self.min_height > 0) mmi.ptMinTrackSize.y = @intCast(self.min_height + self.getTabBarHeight());
}

pub fn onDpiChange(self: *Window, dpi: u32) void {
    self.scale_x = @as(f32, @floatFromInt(dpi)) / 96.0;
    self.scale_y = self.scale_x;
    // Forward to all surfaces in all tabs
    for (self.tabs.items) |tab| {
        var leaves: std.ArrayListUnmanaged(*Surface) = .{};
        defer leaves.deinit(self.app.alloc);
        tab.root.collectLeaves(self.app.alloc, &leaves);
        for (leaves.items) |surface| {
            surface.onDpiChange(dpi);
        }
    }
}

pub fn onFocusIn(self: *Window) void {
    if (self.active_tab < self.tabs.items.len) {
        win32.setFocus(self.tabs.items[self.active_tab].active_surface.hwnd);
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Get the active Surface (if any).
pub fn activeSurface(self: *Window) ?*Surface {
    if (self.active_tab < self.tabs.items.len) return self.tabs.items[self.active_tab].active_surface;
    return null;
}

/// Find a Surface within this window by its CoreSurface pointer.
pub fn findSurface(self: *Window, core_surface: anytype) ?*Surface {
    for (self.tabs.items) |tab| {
        var leaves: std.ArrayListUnmanaged(*Surface) = .{};
        defer leaves.deinit(self.app.alloc);
        tab.root.collectLeaves(self.app.alloc, &leaves);
        for (leaves.items) |surface| {
            if (&surface.core_surface == core_surface) return surface;
        }
    }
    return null;
}

/// Update the active_surface for the tab containing the given surface.
pub fn setActiveSurface(self: *Window, surface: *Surface) void {
    for (self.tabs.items) |*tab| {
        if (tab.root.findLeaf(surface) != null) {
            tab.active_surface = surface;
            return;
        }
    }
}
