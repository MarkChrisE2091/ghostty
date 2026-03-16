/// Binary tree node for split pane layout within a tab.
///
/// Each tab in a Window has a root SplitNode. A leaf node holds a single
/// Surface. A split node divides its rectangle between two children
/// (first/second) along a horizontal or vertical axis.
const SplitNode = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Surface = @import("Surface.zig");
const win32 = @import("win32.zig");

const log = std.log.scoped(.win32_split);

/// Split orientation.
pub const Direction = enum {
    horizontal, // left | right
    vertical, // top | bottom
};

/// A rectangle in physical pixels.
pub const Rect = struct {
    x: i32,
    y: i32,
    w: u32,
    h: u32,
};

/// Node payload — either a single surface or a pair of children.
tag: Tag,
data: Data,
parent: ?*SplitNode,

const Tag = enum { leaf, split };

const Data = union {
    leaf: *Surface,
    split: struct {
        direction: Direction,
        ratio: f32, // proportion of first child (0.0 – 1.0)
        first: *SplitNode,
        second: *SplitNode,
    },
};

/// Divider size in pixels between split panes.
const DIVIDER_SIZE: u32 = 4;

// ---------------------------------------------------------------------------
// Construction
// ---------------------------------------------------------------------------

/// Create a leaf node wrapping a single surface.
pub fn initLeaf(alloc: Allocator, surface: *Surface) !*SplitNode {
    const node = try alloc.create(SplitNode);
    node.* = .{
        .tag = .leaf,
        .data = .{ .leaf = surface },
        .parent = null,
    };
    return node;
}

/// Split a leaf node into two children. The existing surface becomes the
/// first child; a NEW surface is created for the second child.
/// Returns the newly created Surface.
pub fn split(
    self: *SplitNode,
    alloc: Allocator,
    direction: Direction,
    new_surface: *Surface,
) !*SplitNode {
    // self must be a leaf
    if (self.tag != .leaf) return error.NotALeaf;

    const existing_surface = self.data.leaf;

    // Create two leaf children
    const first = try alloc.create(SplitNode);
    first.* = .{
        .tag = .leaf,
        .data = .{ .leaf = existing_surface },
        .parent = self,
    };

    const second = try alloc.create(SplitNode);
    second.* = .{
        .tag = .leaf,
        .data = .{ .leaf = new_surface },
        .parent = self,
    };

    // Tell surfaces about their new nodes
    existing_surface.split_node = first;
    new_surface.split_node = second;

    // Convert self from leaf to split
    self.tag = .split;
    self.data = .{
        .split = .{
            .direction = direction,
            .ratio = 0.5,
            .first = first,
            .second = second,
        },
    };

    return second;
}

/// Remove a leaf node from the tree. Returns the sibling that replaces
/// the parent split node, or null if this was the root (last surface).
pub fn remove(self: *SplitNode, alloc: Allocator) ?*SplitNode {
    if (self.tag != .leaf) return null;

    const par = self.parent orelse {
        // This is the root leaf — removing it means the tab is empty
        alloc.destroy(self);
        return null;
    };

    // par must be a split node
    const s = par.data.split;
    const sibling = if (s.first == self) s.second else s.first;

    // Copy sibling's content into parent's slot
    par.tag = sibling.tag;
    par.data = sibling.data;

    // Re-parent any children of sibling to point to par
    if (sibling.tag == .split) {
        sibling.data.split.first.parent = par;
        sibling.data.split.second.parent = par;
    } else {
        // Leaf — update surface's split_node reference
        sibling.data.leaf.split_node = par;
    }

    // Free the removed leaf and the now-unused sibling node shell
    alloc.destroy(self);
    alloc.destroy(sibling);

    return par;
}

// ---------------------------------------------------------------------------
// Layout
// ---------------------------------------------------------------------------

/// Recursively position all surface HWNDs within the given rectangle.
pub fn layout(self: *SplitNode, rect: Rect) void {
    switch (self.tag) {
        .leaf => {
            const surface = self.data.leaf;
            win32.moveWindow(
                surface.hwnd,
                rect.x,
                rect.y,
                @intCast(rect.w),
                @intCast(rect.h),
                true,
            );
            surface.onResize(rect.w, rect.h);
        },
        .split => {
            const s = self.data.split;
            var first_rect: Rect = undefined;
            var second_rect: Rect = undefined;

            switch (s.direction) {
                .horizontal => {
                    const total_w = rect.w;
                    const first_w = @as(u32, @intFromFloat(@as(f32, @floatFromInt(total_w -| DIVIDER_SIZE)) * s.ratio));
                    const second_w = total_w -| first_w -| DIVIDER_SIZE;
                    first_rect = .{
                        .x = rect.x,
                        .y = rect.y,
                        .w = first_w,
                        .h = rect.h,
                    };
                    second_rect = .{
                        .x = rect.x + @as(i32, @intCast(first_w + DIVIDER_SIZE)),
                        .y = rect.y,
                        .w = second_w,
                        .h = rect.h,
                    };
                },
                .vertical => {
                    const total_h = rect.h;
                    const first_h = @as(u32, @intFromFloat(@as(f32, @floatFromInt(total_h -| DIVIDER_SIZE)) * s.ratio));
                    const second_h = total_h -| first_h -| DIVIDER_SIZE;
                    first_rect = .{
                        .x = rect.x,
                        .y = rect.y,
                        .w = rect.w,
                        .h = first_h,
                    };
                    second_rect = .{
                        .x = rect.x,
                        .y = rect.y + @as(i32, @intCast(first_h + DIVIDER_SIZE)),
                        .w = rect.w,
                        .h = second_h,
                    };
                },
            }

            s.first.layout(first_rect);
            s.second.layout(second_rect);
        },
    }
}

// ---------------------------------------------------------------------------
// Navigation
// ---------------------------------------------------------------------------

/// Find the active (focused) surface by checking Win32 focus.
pub fn findFocused(self: *SplitNode) ?*Surface {
    switch (self.tag) {
        .leaf => return self.data.leaf,
        .split => {
            const s = self.data.split;
            return s.first.findFocused() orelse s.second.findFocused();
        },
    }
}

/// Collect all leaves in order (left-to-right / top-to-bottom).
pub fn collectLeaves(self: *SplitNode, alloc: Allocator, buf: *std.ArrayListUnmanaged(*Surface)) void {
    switch (self.tag) {
        .leaf => buf.append(alloc, self.data.leaf) catch {},
        .split => {
            const s = self.data.split;
            s.first.collectLeaves(alloc, buf);
            s.second.collectLeaves(alloc, buf);
        },
    }
}

/// Find the leaf node containing the given surface.
pub fn findLeaf(self: *SplitNode, surface: *Surface) ?*SplitNode {
    switch (self.tag) {
        .leaf => {
            if (self.data.leaf == surface) return self;
            return null;
        },
        .split => {
            const s = self.data.split;
            return s.first.findLeaf(surface) orelse s.second.findLeaf(surface);
        },
    }
}

/// Navigate to previous/next surface in tree order.
pub fn gotoPrevNext(self: *SplitNode, surface: *Surface, comptime forward: bool, alloc: Allocator) ?*Surface {
    var leaves: std.ArrayListUnmanaged(*Surface) = .{};
    defer leaves.deinit(alloc);
    self.collectLeaves(alloc, &leaves);
    if (leaves.items.len <= 1) return null;

    for (leaves.items, 0..) |s, i| {
        if (s == surface) {
            if (forward) {
                return leaves.items[(i + 1) % leaves.items.len];
            } else {
                return leaves.items[if (i == 0) leaves.items.len - 1 else i - 1];
            }
        }
    }
    return null;
}

/// Navigate spatially (up/down/left/right) from a surface.
/// Finds the nearest split boundary in the given direction.
pub fn gotoSpatial(_: *SplitNode, surface: *Surface, direction: enum { up, down, left, right }) ?*Surface {
    // Find the leaf node for this surface
    const leaf = surface.split_node orelse return null;

    // Walk up the tree to find a split that can satisfy the direction
    var current = leaf;
    while (current.parent) |par| {
        if (par.tag != .split) break;
        const s = par.data.split;

        switch (direction) {
            .left => {
                if (s.direction == .horizontal and s.second == current) {
                    return s.first.lastLeaf();
                }
            },
            .right => {
                if (s.direction == .horizontal and s.first == current) {
                    return s.second.firstLeaf();
                }
            },
            .up => {
                if (s.direction == .vertical and s.second == current) {
                    return s.first.lastLeaf();
                }
            },
            .down => {
                if (s.direction == .vertical and s.first == current) {
                    return s.second.firstLeaf();
                }
            },
        }
        current = par;
    }
    return null;
}

/// Get the first (leftmost/topmost) leaf surface.
pub fn firstLeaf(self: *SplitNode) ?*Surface {
    switch (self.tag) {
        .leaf => return self.data.leaf,
        .split => return self.data.split.first.firstLeaf(),
    }
}

/// Get the last (rightmost/bottommost) leaf surface.
pub fn lastLeaf(self: *SplitNode) ?*Surface {
    switch (self.tag) {
        .leaf => return self.data.leaf,
        .split => return self.data.split.second.lastLeaf(),
    }
}

// ---------------------------------------------------------------------------
// Resize
// ---------------------------------------------------------------------------

/// Adjust the ratio of the nearest ancestor split matching the given
/// direction. Amount is in pixels; we convert to a ratio delta.
pub const ResizeDir = enum { up, down, left, right };

pub fn resizeSplit(
    _: *SplitNode,
    surface: *Surface,
    resize_dir: ResizeDir,
    amount: u16,
) void {
    const leaf = surface.split_node orelse return;

    // Find the nearest split that matches the resize direction
    var current = leaf;
    while (current.parent) |par| {
        if (par.tag != .split) break;
        const s = &par.data.split;

        const matches = switch (resize_dir) {
            .left, .right => s.direction == .horizontal,
            .up, .down => s.direction == .vertical,
        };

        if (matches) {
            const delta: f32 = @as(f32, @floatFromInt(amount)) / 1000.0;
            const sign: f32 = switch (resize_dir) {
                .left, .up => -1.0,
                .right, .down => 1.0,
            };
            // If we're in the second child, flip the sign
            const flip: f32 = if (s.second == current) -1.0 else 1.0;
            s.ratio = std.math.clamp(s.ratio + delta * sign * flip, 0.1, 0.9);
            return;
        }
        current = par;
    }
}

/// Set all split ratios to equal.
pub fn equalize(self: *SplitNode) void {
    if (self.tag != .split) return;
    self.data.split.ratio = 0.5;
    self.data.split.first.equalize();
    self.data.split.second.equalize();
}

// ---------------------------------------------------------------------------
// Cleanup
// ---------------------------------------------------------------------------

/// Recursively destroy all nodes and their surfaces.
pub fn destroyAll(self: *SplitNode, alloc: Allocator) void {
    switch (self.tag) {
        .leaf => {
            self.data.leaf.deinit();
            alloc.destroy(self.data.leaf);
        },
        .split => {
            self.data.split.first.destroyAll(alloc);
            self.data.split.second.destroyAll(alloc);
        },
    }
    alloc.destroy(self);
}

/// Count total number of surfaces (leaves).
pub fn leafCount(self: *const SplitNode) usize {
    switch (self.tag) {
        .leaf => return 1,
        .split => {
            return self.data.split.first.leafCount() + self.data.split.second.leafCount();
        },
    }
}
