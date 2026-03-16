/// WGL (Windows GL) wrapper for OpenGL context creation and management.
///
/// Creates a modern OpenGL 4.3+ core profile context using the classic
/// "dummy window" technique: create a legacy context first to load the
/// wglCreateContextAttribsARB extension, then create the real context.
const std = @import("std");
const w = std.os.windows;
const win32 = @import("win32.zig");

pub const HGLRC = *anyopaque;

const log = std.log.scoped(.wgl);

// WGL constants for wglCreateContextAttribsARB
const WGL_CONTEXT_MAJOR_VERSION_ARB = 0x2091;
const WGL_CONTEXT_MINOR_VERSION_ARB = 0x2092;
const WGL_CONTEXT_FLAGS_ARB = 0x2094;
const WGL_CONTEXT_PROFILE_MASK_ARB = 0x9126;
const WGL_CONTEXT_CORE_PROFILE_BIT_ARB = 0x00000001;
const WGL_CONTEXT_DEBUG_BIT_ARB = 0x00000001;

// WGL function types
const wglCreateContextAttribsARBFn = *const fn (
    win32.HDC,
    ?HGLRC,
    ?[*]const i32,
) callconv(.winapi) ?HGLRC;

// OpenGL32 extern functions
extern "opengl32" fn wglCreateContext(win32.HDC) callconv(.winapi) ?HGLRC;
extern "opengl32" fn wglDeleteContext(HGLRC) callconv(.winapi) w.BOOL;
extern "opengl32" fn wglMakeCurrent(?win32.HDC, ?HGLRC) callconv(.winapi) w.BOOL;
extern "opengl32" fn wglGetProcAddress([*:0]const u8) callconv(.winapi) ?*anyopaque;

/// Create an OpenGL context for the given device context.
///
/// This creates a legacy context first if needed to load extensions,
/// then attempts to create a modern 4.3 core profile context.
pub fn createContext(hdc: win32.HDC) !HGLRC {
    // Set up a basic pixel format
    var pfd: win32.PIXELFORMATDESCRIPTOR = .{
        .dwFlags = win32.PFD_DRAW_TO_WINDOW | win32.PFD_SUPPORT_OPENGL | win32.PFD_DOUBLEBUFFER,
        .iPixelType = win32.PFD_TYPE_RGBA,
        .cColorBits = 32,
        .cDepthBits = 24,
        .cStencilBits = 8,
        .iLayerType = win32.PFD_MAIN_PLANE,
    };

    const pixel_format = win32.choosePixelFormat(hdc, &pfd);
    if (pixel_format == 0) return error.ChoosePixelFormatFailed;

    if (!win32.setPixelFormat(hdc, pixel_format, &pfd))
        return error.SetPixelFormatFailed;

    // Create a legacy context first
    const legacy_ctx = wglCreateContext(hdc) orelse
        return error.WglCreateContextFailed;

    // Make it current so we can query for extensions
    if (wglMakeCurrent(hdc, legacy_ctx) == 0)
        return error.WglMakeCurrentFailed;

    // Try to get the modern context creation function
    const create_attribs_fn: ?wglCreateContextAttribsARBFn =
        if (wglGetProcAddress("wglCreateContextAttribsARB")) |ptr|
        @ptrCast(ptr)
    else
        null;

    if (create_attribs_fn) |createAttribs| {
        // Create a modern 4.3 core profile context
        const attribs = [_]i32{
            WGL_CONTEXT_MAJOR_VERSION_ARB, 4,
            WGL_CONTEXT_MINOR_VERSION_ARB, 3,
            WGL_CONTEXT_PROFILE_MASK_ARB,  WGL_CONTEXT_CORE_PROFILE_BIT_ARB,
            0, // terminator
        };

        if (createAttribs(hdc, null, &attribs)) |modern_ctx| {
            // Delete the legacy context and use the modern one
            _ = wglMakeCurrent(null, null);
            _ = wglDeleteContext(legacy_ctx);
            if (wglMakeCurrent(hdc, modern_ctx) == 0)
                return error.WglMakeCurrentFailed;
            log.info("created modern OpenGL 4.3 core profile context", .{});
            return modern_ctx;
        }

        log.warn("wglCreateContextAttribsARB failed, falling back to legacy context", .{});
    } else {
        log.warn("wglCreateContextAttribsARB not available, using legacy context", .{});
    }

    // Fall back to legacy context
    return legacy_ctx;
}

/// Delete an OpenGL context.
pub fn deleteContext(hglrc: HGLRC) !void {
    if (wglDeleteContext(hglrc) == 0)
        return error.WglDeleteContextFailed;
}

/// Make an OpenGL context current on the calling thread.
pub fn makeCurrent(hdc: ?win32.HDC, hglrc: ?HGLRC) !void {
    if (wglMakeCurrent(hdc, hglrc) == 0)
        return error.WglMakeCurrentFailed;
}

/// Swap the front and back buffers.
pub fn swapBuffers(hdc: win32.HDC) void {
    _ = win32.swapBuffers(hdc);
}
