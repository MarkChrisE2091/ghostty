/// Resource directory detection for Windows.
///
/// On Windows, resources (terminfo, shell integration scripts, themes) are
/// located relative to the executable.
const std = @import("std");
const internal_os = @import("../../os/main.zig");

pub const resourcesDir = internal_os.resourcesDir;
