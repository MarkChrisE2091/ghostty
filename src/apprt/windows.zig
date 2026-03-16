// The required comptime API for any apprt.
pub const App = @import("windows/App.zig");
pub const Surface = @import("windows/Surface.zig");
pub const resourcesDir = @import("windows/resourcesdir.zig").resourcesDir;

test {
    @import("std").testing.refAllDecls(@This());
}
