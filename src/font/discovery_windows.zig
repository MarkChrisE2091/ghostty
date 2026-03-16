/// Windows font discovery helper.
///
/// Provides basic font discovery for Windows by searching the system fonts
/// directory. This is a simpler alternative to DirectWrite that maps font
/// family names to .ttf/.otf files in %WINDIR%\Fonts.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.font_discovery_windows);

/// The standard Windows fonts directory.
pub fn fontsDir(buf: []u8) !?[]const u8 {
    if (comptime builtin.os.tag != .windows) return null;

    // Try %WINDIR%\Fonts first
    const windir = std.process.getEnvVarOwned(
        std.heap.page_allocator,
        "WINDIR",
    ) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return null,
        else => return null,
    };
    defer std.heap.page_allocator.free(windir);

    const path = std.fmt.bufPrint(buf, "{s}\\Fonts", .{windir}) catch
        return null;
    return path;
}

/// Well-known font family name to file mappings on Windows.
/// This covers the most common monospace fonts that terminal users expect.
pub const known_fonts = [_]struct {
    family: []const u8,
    file: []const u8,
}{
    .{ .family = "Consolas", .file = "consola.ttf" },
    .{ .family = "Courier New", .file = "cour.ttf" },
    .{ .family = "Lucida Console", .file = "lucon.ttf" },
    .{ .family = "Cascadia Code", .file = "CascadiaCode.ttf" },
    .{ .family = "Cascadia Mono", .file = "CascadiaMono.ttf" },
    .{ .family = "Segoe UI", .file = "segoeui.ttf" },
    .{ .family = "Arial", .file = "arial.ttf" },
};

/// Try to resolve a font family name to a file path in the Windows fonts dir.
/// Returns null if the family is not recognized or the file doesn't exist.
pub fn resolveFamily(alloc: Allocator, family: []const u8) ?[:0]const u8 {
    var fonts_buf: [std.fs.max_path_bytes]u8 = undefined;
    const fonts_path = fontsDir(&fonts_buf) orelse return null;

    for (known_fonts) |entry| {
        if (std.ascii.eqlIgnoreCase(family, entry.family)) {
            const full_path = std.fmt.allocPrintZ(
                alloc,
                "{s}\\{s}",
                .{ fonts_path, entry.file },
            ) catch return null;

            // Verify the file exists
            std.fs.cwd().access(full_path, .{}) catch {
                alloc.free(full_path);
                return null;
            };

            return full_path;
        }
    }

    return null;
}
