/// Win32 API bindings and window management for the Windows app runtime.
///
/// This module wraps all Win32 API calls used by Ghostty's Windows backend.
/// The WndProc here is the central event dispatcher; it translates Win32
/// messages into Ghostty's platform-independent callbacks.
const std = @import("std");
const w = std.os.windows;
const input = @import("../../input.zig");
const apprt = @import("../../apprt.zig");
const key = @import("key.zig");

// Re-export commonly used types
pub const HWND = w.HANDLE;
pub const HDC = *anyopaque;
pub const HINSTANCE = w.HINSTANCE;
pub const HMONITOR = *anyopaque;
pub const HCURSOR = *anyopaque;
pub const HICON = *anyopaque;
pub const HBRUSH = *anyopaque;
pub const HMENU = *anyopaque;
pub const HGLOBAL = *anyopaque;
pub const LRESULT = isize;
pub const WPARAM = usize;
pub const LPARAM = isize;
pub const ATOM = u16;
pub const BOOL = w.BOOL;
pub const DWORD = w.DWORD;
pub const UINT = u32;
pub const WORD = u16;

// ---------------------------------------------------------------------------
// Window Messages
// ---------------------------------------------------------------------------
pub const WM_NULL = 0x0000;
pub const WM_CREATE = 0x0001;
pub const WM_DESTROY = 0x0002;
pub const WM_MOVE = 0x0003;
pub const WM_SIZE = 0x0005;
pub const WM_ACTIVATE = 0x0006;
pub const WM_SETFOCUS = 0x0007;
pub const WM_KILLFOCUS = 0x0008;
pub const WM_CLOSE = 0x0010;
pub const WM_PAINT = 0x000F;
pub const WM_QUIT = 0x0012;
pub const WM_GETMINMAXINFO = 0x0024;
pub const WM_SETCURSOR = 0x0020;
pub const WM_NCACTIVATE = 0x0086;
pub const WM_SYSCOMMAND = 0x0112;
pub const WM_TIMER = 0x0113;
pub const WM_KEYDOWN = 0x0100;
pub const WM_KEYUP = 0x0101;
pub const WM_CHAR = 0x0102;
pub const WM_DEADCHAR = 0x0103;
pub const WM_SYSKEYDOWN = 0x0104;
pub const WM_SYSKEYUP = 0x0105;
pub const WM_SYSCHAR = 0x0106;
pub const WM_UNICHAR = 0x0109;
pub const WM_IME_STARTCOMPOSITION = 0x010D;
pub const WM_IME_ENDCOMPOSITION = 0x010E;
pub const WM_IME_COMPOSITION = 0x010F;
pub const WM_MOUSEMOVE = 0x0200;
pub const WM_LBUTTONDOWN = 0x0201;
pub const WM_LBUTTONUP = 0x0202;
pub const WM_LBUTTONDBLCLK = 0x0203;
pub const WM_RBUTTONDOWN = 0x0204;
pub const WM_RBUTTONUP = 0x0205;
pub const WM_RBUTTONDBLCLK = 0x0206;
pub const WM_MBUTTONDOWN = 0x0207;
pub const WM_MBUTTONUP = 0x0208;
pub const WM_MBUTTONDBLCLK = 0x0209;
pub const WM_MOUSEWHEEL = 0x020A;
pub const WM_XBUTTONDOWN = 0x020B;
pub const WM_XBUTTONUP = 0x020C;
pub const WM_MOUSEHWHEEL = 0x020E;
pub const WM_MOUSELEAVE = 0x02A3;
pub const WM_DPICHANGED = 0x02E0;
pub const WM_USER = 0x0400;

// SC_CLOSE for WM_SYSCOMMAND
pub const SC_CLOSE = 0xF060;

// XBUTTON identifiers
pub const XBUTTON1: u16 = 0x0001;
pub const XBUTTON2: u16 = 0x0002;

// Mouse tracking
pub const TME_LEAVE: DWORD = 0x00000002;

// WHEEL_DELTA
pub const WHEEL_DELTA: i16 = 120;

// ---------------------------------------------------------------------------
// Window Styles
// ---------------------------------------------------------------------------
pub const WS_OVERLAPPEDWINDOW: u32 = 0x00CF0000;
pub const WS_POPUP: u32 = 0x80000000;
pub const WS_VISIBLE: u32 = 0x10000000;
pub const WS_CAPTION: u32 = 0x00C00000;
pub const WS_THICKFRAME: u32 = 0x00040000;
pub const WS_MAXIMIZE: u32 = 0x01000000;
pub const WS_MINIMIZE: u32 = 0x20000000;
pub const WS_CLIPCHILDREN: u32 = 0x02000000;
pub const WS_CLIPSIBLINGS: u32 = 0x04000000;
pub const WS_SYSMENU: u32 = 0x00080000;
pub const CS_OWNDC: u32 = 0x0020;
pub const CS_HREDRAW: u32 = 0x0002;
pub const CS_VREDRAW: u32 = 0x0001;
pub const CS_DBLCLKS: u32 = 0x0008;

// Extended styles
pub const WS_EX_LAYERED: u32 = 0x00080000;
pub const WS_EX_TOPMOST: u32 = 0x00000008;

// ---------------------------------------------------------------------------
// SetWindowPos / ShowWindow flags
// ---------------------------------------------------------------------------
pub const SWP_NOMOVE: UINT = 0x0002;
pub const SWP_NOSIZE: UINT = 0x0001;
pub const SWP_NOZORDER: UINT = 0x0004;
pub const SWP_FRAMECHANGED: UINT = 0x0020;
pub const SWP_NOACTIVATE: UINT = 0x0010;
pub const SWP_SHOWWINDOW: UINT = 0x0040;
pub const HWND_TOP: ?HWND = null;
pub const HWND_TOPMOST: isize = -1;
pub const HWND_NOTOPMOST: isize = -2;

pub const SW_SHOW: i32 = 5;
pub const SW_HIDE: i32 = 0;
pub const SW_MAXIMIZE: i32 = 3;
pub const SW_RESTORE: i32 = 9;
pub const SW_SHOWNORMAL: i32 = 1;

// ---------------------------------------------------------------------------
// PeekMessage
// ---------------------------------------------------------------------------
pub const PM_REMOVE: UINT = 0x0001;
pub const PM_NOREMOVE: UINT = 0x0000;

// ---------------------------------------------------------------------------
// MessageBeep
// ---------------------------------------------------------------------------
pub const MB_OK: UINT = 0x00000000;
pub const MB_ICONINFORMATION: UINT = 0x00000040;

// ---------------------------------------------------------------------------
// GetWindowLong indices
// ---------------------------------------------------------------------------
pub const GWL_STYLE: i32 = -16;
pub const GWL_EXSTYLE: i32 = -20;
pub const GWL_USERDATA: i32 = -21;
pub const GWLP_USERDATA: i32 = -21;

// ---------------------------------------------------------------------------
// Pixel format
// ---------------------------------------------------------------------------
pub const PFD_DRAW_TO_WINDOW: u32 = 0x00000004;
pub const PFD_SUPPORT_OPENGL: u32 = 0x00000020;
pub const PFD_DOUBLEBUFFER: u32 = 0x00000001;
pub const PFD_TYPE_RGBA: u8 = 0;
pub const PFD_MAIN_PLANE: u8 = 0;

// ---------------------------------------------------------------------------
// Monitor
// ---------------------------------------------------------------------------
pub const MONITOR_DEFAULTTONEAREST: DWORD = 2;
pub const MONITOR_DEFAULTTOPRIMARY: DWORD = 1;

// ---------------------------------------------------------------------------
// Clipboard formats
// ---------------------------------------------------------------------------
pub const CF_UNICODETEXT: UINT = 13;
pub const CF_TEXT: UINT = 1;
pub const GMEM_MOVEABLE: UINT = 0x0002;

// ---------------------------------------------------------------------------
// Structs
// ---------------------------------------------------------------------------

pub const POINT = extern struct {
    x: i32 = 0,
    y: i32 = 0,
};

pub const RECT = extern struct {
    left: i32 = 0,
    top: i32 = 0,
    right: i32 = 0,
    bottom: i32 = 0,
};

pub const MSG = extern struct {
    hwnd: ?HWND = null,
    message: UINT = 0,
    wParam: WPARAM = 0,
    lParam: LPARAM = 0,
    time: DWORD = 0,
    pt: POINT = .{},
};

pub const WNDCLASSEXA = extern struct {
    cbSize: UINT = @sizeOf(WNDCLASSEXA),
    style: UINT = 0,
    lpfnWndProc: ?WNDPROC = null,
    cbClsExtra: i32 = 0,
    cbWndExtra: i32 = 0,
    hInstance: ?w.HINSTANCE = null,
    hIcon: ?HICON = null,
    hCursor: ?HCURSOR = null,
    hbrBackground: ?HBRUSH = null,
    lpszMenuName: ?[*:0]const u8 = null,
    lpszClassName: ?[*:0]const u8 = null,
    hIconSm: ?HICON = null,
};

pub const PIXELFORMATDESCRIPTOR = extern struct {
    nSize: u16 = @sizeOf(PIXELFORMATDESCRIPTOR),
    nVersion: u16 = 1,
    dwFlags: DWORD = 0,
    iPixelType: u8 = 0,
    cColorBits: u8 = 0,
    cRedBits: u8 = 0,
    cRedShift: u8 = 0,
    cGreenBits: u8 = 0,
    cGreenShift: u8 = 0,
    cBlueBits: u8 = 0,
    cBlueShift: u8 = 0,
    cAlphaBits: u8 = 0,
    cAlphaShift: u8 = 0,
    cAccumBits: u8 = 0,
    cAccumRedBits: u8 = 0,
    cAccumGreenBits: u8 = 0,
    cAccumBlueBits: u8 = 0,
    cAccumAlphaBits: u8 = 0,
    cDepthBits: u8 = 0,
    cStencilBits: u8 = 0,
    cAuxBuffers: u8 = 0,
    iLayerType: u8 = 0,
    bReserved: u8 = 0,
    dwLayerMask: DWORD = 0,
    dwVisibleMask: DWORD = 0,
    dwDamageMask: DWORD = 0,
};

pub const WINDOWPLACEMENT = extern struct {
    length: UINT = @sizeOf(WINDOWPLACEMENT),
    flags: UINT = 0,
    showCmd: UINT = 0,
    ptMinPosition: POINT = .{},
    ptMaxPosition: POINT = .{},
    rcNormalPosition: RECT = .{},
};

pub const MONITORINFO = extern struct {
    cbSize: DWORD = @sizeOf(MONITORINFO),
    rcMonitor: RECT = .{},
    rcWork: RECT = .{},
    dwFlags: DWORD = 0,
};

pub const MINMAXINFO = extern struct {
    ptReserved: POINT = .{},
    ptMaxSize: POINT = .{},
    ptMaxPosition: POINT = .{},
    ptMinTrackSize: POINT = .{},
    ptMaxTrackSize: POINT = .{},
};

pub const TRACKMOUSEEVENT = extern struct {
    cbSize: DWORD = @sizeOf(TRACKMOUSEEVENT),
    dwFlags: DWORD = 0,
    hwndTrack: ?HWND = null,
    dwHoverTime: DWORD = 0,
};

pub const PAINTSTRUCT = extern struct {
    hdc: ?HDC = null,
    fErase: BOOL = 0,
    rcPaint: RECT = .{},
    fRestore: BOOL = 0,
    fIncUpdate: BOOL = 0,
    rgbReserved: [32]u8 = [_]u8{0} ** 32,
};

pub const WNDPROC = *const fn (HWND, UINT, WPARAM, LPARAM) callconv(.winapi) LRESULT;

const CLASS_NAME = "GhosttyWindowClass";

// ---------------------------------------------------------------------------
// Raw Win32 extern declarations
// ---------------------------------------------------------------------------
extern "user32" fn RegisterClassExA(*const WNDCLASSEXA) callconv(.winapi) ATOM;
extern "user32" fn CreateWindowExA(DWORD, [*:0]const u8, [*:0]const u8, DWORD, i32, i32, i32, i32, ?HWND, ?HMENU, ?w.HINSTANCE, ?*anyopaque) callconv(.winapi) ?HWND;
extern "user32" fn DestroyWindow(HWND) callconv(.winapi) BOOL;
extern "user32" fn ShowWindow(HWND, i32) callconv(.winapi) BOOL;
extern "user32" fn UpdateWindow(HWND) callconv(.winapi) BOOL;
extern "user32" fn PeekMessageA(*MSG, ?HWND, UINT, UINT, UINT) callconv(.winapi) BOOL;
extern "user32" fn GetMessageA(*MSG, ?HWND, UINT, UINT) callconv(.winapi) BOOL;
extern "user32" fn WaitMessage() callconv(.winapi) BOOL;
extern "user32" fn TranslateMessage(*const MSG) callconv(.winapi) BOOL;
extern "user32" fn DispatchMessageA(*const MSG) callconv(.winapi) LRESULT;
extern "user32" fn PostQuitMessage(i32) callconv(.winapi) void;
extern "user32" fn PostMessageA(?HWND, UINT, WPARAM, LPARAM) callconv(.winapi) BOOL;
extern "user32" fn DefWindowProcA(HWND, UINT, WPARAM, LPARAM) callconv(.winapi) LRESULT;
extern "user32" fn GetDC(HWND) callconv(.winapi) ?HDC;
extern "user32" fn ReleaseDC(HWND, HDC) callconv(.winapi) i32;
extern "user32" fn BeginPaint(HWND, *PAINTSTRUCT) callconv(.winapi) ?HDC;
extern "user32" fn EndPaint(HWND, *const PAINTSTRUCT) callconv(.winapi) BOOL;
extern "user32" fn SetWindowTextW(HWND, [*:0]const u16) callconv(.winapi) BOOL;
extern "user32" fn SetWindowTextA(HWND, [*:0]const u8) callconv(.winapi) BOOL;
extern "user32" fn InvalidateRect(?HWND, ?*const RECT, BOOL) callconv(.winapi) BOOL;
extern "user32" fn SetWindowPos(HWND, ?HWND, i32, i32, i32, i32, UINT) callconv(.winapi) BOOL;
extern "user32" fn GetWindowLongA(HWND, i32) callconv(.winapi) i32;
extern "user32" fn SetWindowLongA(HWND, i32, i32) callconv(.winapi) i32;
extern "user32" fn GetWindowLongPtrA(HWND, i32) callconv(.winapi) isize;
extern "user32" fn SetWindowLongPtrA(HWND, i32, isize) callconv(.winapi) isize;
extern "user32" fn GetWindowPlacement(HWND, *WINDOWPLACEMENT) callconv(.winapi) BOOL;
extern "user32" fn SetWindowPlacement(HWND, *const WINDOWPLACEMENT) callconv(.winapi) BOOL;
extern "user32" fn GetClientRect(HWND, *RECT) callconv(.winapi) BOOL;
extern "user32" fn MonitorFromWindow(HWND, DWORD) callconv(.winapi) ?HMONITOR;
extern "user32" fn GetMonitorInfoA(?HMONITOR, *MONITORINFO) callconv(.winapi) BOOL;
extern "user32" fn SetForegroundWindow(HWND) callconv(.winapi) BOOL;
extern "user32" fn BringWindowToTop(HWND) callconv(.winapi) BOOL;
extern "user32" fn GetCursorPos(*POINT) callconv(.winapi) BOOL;
extern "user32" fn ScreenToClient(HWND, *POINT) callconv(.winapi) BOOL;
extern "user32" fn ShowCursor(BOOL) callconv(.winapi) i32;
extern "user32" fn LoadCursorA(?w.HINSTANCE, ?[*:0]const u8) callconv(.winapi) ?HCURSOR;
extern "user32" fn SetCursor(?HCURSOR) callconv(.winapi) ?HCURSOR;
extern "user32" fn MessageBeep(UINT) callconv(.winapi) BOOL;
extern "user32" fn PostThreadMessageA(DWORD, UINT, WPARAM, LPARAM) callconv(.winapi) BOOL;
extern "user32" fn GetDpiForWindow(HWND) callconv(.winapi) UINT;
extern "user32" fn TrackMouseEvent(*TRACKMOUSEEVENT) callconv(.winapi) BOOL;
extern "user32" fn MessageBoxW(?HWND, [*:0]const u16, [*:0]const u16, UINT) callconv(.winapi) i32;

// Layered window
pub const LWA_COLORKEY: DWORD = 0x00000001;
pub const LWA_ALPHA: DWORD = 0x00000002;
extern "user32" fn SetLayeredWindowAttributes(HWND, DWORD, u8, DWORD) callconv(.winapi) BOOL;
extern "user32" fn FlashWindow(HWND, BOOL) callconv(.winapi) BOOL;
extern "user32" fn GetWindowTextA(HWND, [*]u8, i32) callconv(.winapi) i32;

// Clipboard
extern "user32" fn OpenClipboard(?HWND) callconv(.winapi) BOOL;
extern "user32" fn CloseClipboard() callconv(.winapi) BOOL;
extern "user32" fn EmptyClipboard() callconv(.winapi) BOOL;
extern "user32" fn GetClipboardData(UINT) callconv(.winapi) ?HGLOBAL;
extern "user32" fn SetClipboardData(UINT, ?HGLOBAL) callconv(.winapi) ?HGLOBAL;
extern "kernel32" fn GlobalAlloc(UINT, usize) callconv(.winapi) ?HGLOBAL;
extern "kernel32" fn GlobalLock(?HGLOBAL) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GlobalUnlock(?HGLOBAL) callconv(.winapi) BOOL;
extern "kernel32" fn GlobalFree(?HGLOBAL) callconv(.winapi) ?HGLOBAL;
extern "kernel32" fn GlobalSize(?HGLOBAL) callconv(.winapi) usize;

// GDI
extern "gdi32" fn ChoosePixelFormat(HDC, *const PIXELFORMATDESCRIPTOR) callconv(.winapi) i32;
extern "gdi32" fn SetPixelFormat(HDC, i32, *const PIXELFORMATDESCRIPTOR) callconv(.winapi) BOOL;
extern "gdi32" fn SwapBuffers(HDC) callconv(.winapi) BOOL;

// Shell
extern "shell32" fn ShellExecuteW(?HWND, ?[*:0]const u16, [*:0]const u16, ?[*:0]const u16, ?[*:0]const u16, i32) callconv(.winapi) isize;

// ---------------------------------------------------------------------------
// Zig wrappers
// ---------------------------------------------------------------------------

pub fn registerWindowClass(hinstance: w.HINSTANCE) !void {
    const wc: WNDCLASSEXA = .{
        .style = CS_OWNDC | CS_HREDRAW | CS_VREDRAW | CS_DBLCLKS,
        .lpfnWndProc = wndProc,
        .hInstance = hinstance,
        .hCursor = LoadCursorA(null, @ptrFromInt(32512)), // IDC_ARROW
        .hbrBackground = null,
        .lpszClassName = CLASS_NAME,
    };

    if (RegisterClassExA(&wc) == 0) {
        return error.RegisterClassFailed;
    }
}

pub fn createWindow(
    hinstance: w.HINSTANCE,
    title: [*:0]const u8,
    width: u32,
    height: u32,
    userdata: usize,
) !HWND {
    const style: DWORD = WS_OVERLAPPEDWINDOW | WS_CLIPCHILDREN | WS_CLIPSIBLINGS;
    const cw_usedefault: i32 = @bitCast(@as(u32, 0x80000000));
    const hwnd = CreateWindowExA(
        0,
        CLASS_NAME,
        title,
        style,
        cw_usedefault,
        cw_usedefault,
        @intCast(width),
        @intCast(height),
        null,
        null,
        hinstance,
        null,
    ) orelse return error.CreateWindowFailed;

    _ = SetWindowLongPtrA(hwnd, GWLP_USERDATA, @intCast(userdata));
    return hwnd;
}

pub fn destroyWindow(hwnd: HWND) void {
    _ = DestroyWindow(hwnd);
}

pub fn showWindow(hwnd: HWND, cmd: i32) void {
    _ = ShowWindow(hwnd, cmd);
}

pub fn updateWindow(hwnd: HWND) void {
    _ = UpdateWindow(hwnd);
}

pub fn peekMessage(msg: *MSG, hwnd: ?HWND, min: UINT, max: UINT, remove: UINT) bool {
    return PeekMessageA(msg, hwnd, min, max, remove) != 0;
}

pub fn waitMessage() void {
    _ = WaitMessage();
}

pub fn translateMessage(msg: *const MSG) void {
    _ = TranslateMessage(msg);
}

pub fn dispatchMessage(msg: *const MSG) void {
    _ = DispatchMessageA(msg);
}

pub fn getDC(hwnd: HWND) ?HDC {
    return GetDC(hwnd);
}

pub fn releaseDC(hwnd: HWND, hdc: HDC) void {
    _ = ReleaseDC(hwnd, hdc);
}

pub fn setWindowTitle(hwnd: HWND, title: []const u8) void {
    // Convert UTF-8 title to UTF-16 for SetWindowTextW
    var buf: [512]u16 = undefined;
    const len = std.unicode.utf8ToUtf16Le(&buf, title) catch {
        // Fallback to ANSI if conversion fails
        var abuf: [256:0]u8 = undefined;
        const alen = @min(title.len, abuf.len - 1);
        @memcpy(abuf[0..alen], title[0..alen]);
        abuf[alen] = 0;
        _ = SetWindowTextA(hwnd, &abuf);
        return;
    };
    buf[len] = 0;
    _ = SetWindowTextW(hwnd, buf[0..len :0]);
}

pub fn setWindowTitleZ(hwnd: HWND, title: [:0]const u8) void {
    setWindowTitle(hwnd, title);
}

pub fn invalidateRect(hwnd: HWND, rect: ?*const RECT, erase: bool) void {
    _ = InvalidateRect(hwnd, rect, if (erase) 1 else 0);
}

pub fn setWindowPos(hwnd: HWND, insert_after: ?HWND, x: i32, y: i32, cx: i32, cy: i32, flags: UINT) void {
    _ = SetWindowPos(hwnd, insert_after, x, y, cx, cy, flags);
}

pub fn getWindowLong(hwnd: HWND, index: i32) i32 {
    return GetWindowLongA(hwnd, index);
}

pub fn setWindowLong(hwnd: HWND, index: i32, value: i32) void {
    _ = SetWindowLongA(hwnd, index, value);
}

pub fn getWindowPlacement(hwnd: HWND, placement: *WINDOWPLACEMENT) bool {
    return GetWindowPlacement(hwnd, placement) != 0;
}

pub fn setWindowPlacement(hwnd: HWND, placement: *const WINDOWPLACEMENT) void {
    _ = SetWindowPlacement(hwnd, placement);
}

pub fn monitorFromWindow(hwnd: HWND, flags: DWORD) ?HMONITOR {
    return MonitorFromWindow(hwnd, flags);
}

pub fn getMonitorInfo(monitor: ?HMONITOR, info: *MONITORINFO) bool {
    return GetMonitorInfoA(monitor, info) != 0;
}

pub fn setForegroundWindow(hwnd: HWND) void {
    _ = SetForegroundWindow(hwnd);
}

pub fn bringWindowToTop(hwnd: HWND) void {
    _ = BringWindowToTop(hwnd);
}

pub fn getCursorPos(point: *POINT) bool {
    return GetCursorPos(point) != 0;
}

pub fn screenToClient(hwnd: HWND, point: *POINT) bool {
    return ScreenToClient(hwnd, point) != 0;
}

pub fn showCursor(show: bool) i32 {
    return ShowCursor(if (show) 1 else 0);
}

pub fn messageBeep(typ: UINT) bool {
    return MessageBeep(typ) != 0;
}

pub fn postThreadMessage(thread_id: DWORD, msg: UINT, wparam: WPARAM, lparam: LPARAM) void {
    _ = PostThreadMessageA(thread_id, msg, wparam, lparam);
}

pub fn postMessage(hwnd: ?HWND, msg: UINT, wparam: WPARAM, lparam: LPARAM) void {
    _ = PostMessageA(hwnd, msg, wparam, lparam);
}

pub fn getDpiForWindow(hwnd: HWND) UINT {
    return GetDpiForWindow(hwnd);
}

pub fn choosePixelFormat(hdc: HDC, pfd: *const PIXELFORMATDESCRIPTOR) i32 {
    return ChoosePixelFormat(hdc, pfd);
}

pub fn setPixelFormat(hdc: HDC, format: i32, pfd: *const PIXELFORMATDESCRIPTOR) bool {
    return SetPixelFormat(hdc, format, pfd) != 0;
}

pub fn swapBuffers(hdc: HDC) bool {
    return SwapBuffers(hdc) != 0;
}

pub fn getClientRect(hwnd: HWND, rect: *RECT) bool {
    return GetClientRect(hwnd, rect) != 0;
}

pub fn loadCursor(hinstance: ?w.HINSTANCE, idc: usize) ?HCURSOR {
    return LoadCursorA(hinstance, @ptrFromInt(idc));
}

pub fn setCursor(cursor: ?HCURSOR) ?HCURSOR {
    return SetCursor(cursor);
}

pub fn messageBoxW(hwnd: ?HWND, text: [*:0]const u16, caption: [*:0]const u16, typ: UINT) i32 {
    return MessageBoxW(hwnd, text, caption, typ);
}

/// SetWindowPos variant that accepts an isize insert_after (for HWND_TOPMOST etc.)
pub fn setWindowPosZ(hwnd: HWND, insert_after: isize, x: i32, y: i32, cx: i32, cy: i32, flags: UINT) void {
    // Cast isize to ?HWND — works because Win32 HWND_TOPMOST = -1 etc. are sentinel values
    _ = SetWindowPos(hwnd, @ptrFromInt(@as(usize, @bitCast(insert_after))), x, y, cx, cy, flags);
}

pub fn setLayeredWindowAttributes(hwnd: HWND, crKey: DWORD, alpha: u8, flags: DWORD) void {
    _ = SetLayeredWindowAttributes(hwnd, crKey, alpha, flags);
}

pub fn flashWindow(hwnd: HWND) void {
    _ = FlashWindow(hwnd, 1);
}

pub fn getWindowTextA(hwnd: HWND, buf: [*]u8, max_count: i32) i32 {
    return GetWindowTextA(hwnd, buf, max_count);
}

/// Open a URL or file with the default application (equivalent to xdg-open / macOS open).
pub fn shellOpen(hwnd: ?HWND, url: []const u8) void {
    // Convert UTF-8 URL to wide string
    var buf: [2048]u16 = undefined;
    const len = std.unicode.utf8ToUtf16Le(&buf, url) catch return;
    if (len >= buf.len) return;
    buf[len] = 0;
    _ = ShellExecuteW(hwnd, null, @as([*:0]const u16, @ptrCast(&buf)), null, null, SW_SHOWNORMAL);
}

/// Read the clipboard as UTF-8. Caller owns the returned slice (allocated with alloc).
/// Returns null if the clipboard is empty or doesn't contain text.
pub fn clipboardReadText(hwnd: ?HWND, alloc: std.mem.Allocator) ?[]u8 {
    if (OpenClipboard(hwnd) == 0) return null;
    defer _ = CloseClipboard();

    const hdata = GetClipboardData(CF_UNICODETEXT) orelse return null;
    const ptr = GlobalLock(hdata) orelse return null;
    defer _ = GlobalUnlock(hdata);

    const size_bytes = GlobalSize(hdata);
    if (size_bytes < 2) return null;

    // Treat as null-terminated UTF-16LE
    const wide_ptr: [*]const u16 = @alignCast(@ptrCast(ptr));
    const max_chars = size_bytes / 2;

    // Find the null terminator
    var len: usize = 0;
    while (len < max_chars and wide_ptr[len] != 0) len += 1;

    const wide = wide_ptr[0..len];
    const utf8 = std.unicode.utf16LeToUtf8Alloc(alloc, wide) catch return null;
    return utf8;
}

/// Write text to the clipboard as UTF-16 (standard Windows clipboard format).
pub fn clipboardWriteText(hwnd: ?HWND, text: []const u8) bool {
    // Convert to UTF-16
    const alloc = std.heap.page_allocator;
    const wide = std.unicode.utf8ToUtf16LeAllocZ(alloc, text) catch return false;
    defer alloc.free(wide);

    const size = (wide.len + 1) * 2; // include null terminator
    const hmem = GlobalAlloc(GMEM_MOVEABLE, size) orelse return false;

    const ptr = GlobalLock(hmem) orelse {
        _ = GlobalFree(hmem);
        return false;
    };

    const dst: [*]u16 = @alignCast(@ptrCast(ptr));
    @memcpy(dst[0..wide.len], wide);
    dst[wide.len] = 0;
    _ = GlobalUnlock(hmem);

    if (OpenClipboard(hwnd) == 0) {
        _ = GlobalFree(hmem);
        return false;
    }
    _ = EmptyClipboard();
    const result = SetClipboardData(CF_UNICODETEXT, hmem);
    _ = CloseClipboard();

    // If SetClipboardData failed, free the memory ourselves
    if (result == null) {
        _ = GlobalFree(hmem);
        return false;
    }

    return true;
}

// ---------------------------------------------------------------------------
// Window procedure (central event dispatcher)
// ---------------------------------------------------------------------------

fn wndProc(hwnd: HWND, msg: UINT, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) LRESULT {
    const Surface = @import("Surface.zig");

    // Retrieve the Surface pointer stored in GWLP_USERDATA
    const surface_ptr = GetWindowLongPtrA(hwnd, GWLP_USERDATA);
    const surface: ?*Surface = if (surface_ptr != 0)
        @ptrFromInt(@as(usize, @intCast(surface_ptr)))
    else
        null;

    switch (msg) {
        // ------------------------------------------------------------------
        // Window lifecycle
        // ------------------------------------------------------------------
        WM_CLOSE => {
            if (surface) |s| s.onClose();
            return 0;
        },

        WM_DESTROY => {
            // Only post WM_QUIT if this was the last window. The App tracks
            // surface count; if we're down to zero it posts WM_QUIT itself.
            return 0;
        },

        // ------------------------------------------------------------------
        // Painting / rendering
        // ------------------------------------------------------------------
        WM_PAINT => {
            var ps: PAINTSTRUCT = .{};
            const paint_hdc = BeginPaint(hwnd, &ps);
            _ = paint_hdc;
            if (surface) |s| s.onPaint();
            _ = EndPaint(hwnd, &ps);
            return 0;
        },

        // ------------------------------------------------------------------
        // Resize
        // ------------------------------------------------------------------
        WM_SIZE => {
            const width: u32 = @intCast(lparam & 0xFFFF);
            const height: u32 = @intCast((lparam >> 16) & 0xFFFF);
            if (surface) |s| s.onResize(width, height);
            return 0;
        },

        // ------------------------------------------------------------------
        // Size constraints
        // ------------------------------------------------------------------
        WM_GETMINMAXINFO => {
            if (surface) |s| {
                const mmi: *MINMAXINFO = @ptrFromInt(@as(usize, @bitCast(lparam)));
                s.onMinMaxInfo(mmi);
            }
            return 0;
        },

        // ------------------------------------------------------------------
        // DPI change
        // ------------------------------------------------------------------
        WM_DPICHANGED => {
            const new_dpi: u32 = @intCast(wparam & 0xFFFF);
            if (surface) |s| {
                s.onDpiChange(new_dpi);
                // Auto-resize window to the suggested rect
                const suggested: *const RECT = @ptrFromInt(@as(usize, @bitCast(lparam)));
                _ = SetWindowPos(
                    hwnd,
                    null,
                    suggested.left,
                    suggested.top,
                    suggested.right - suggested.left,
                    suggested.bottom - suggested.top,
                    SWP_NOZORDER | SWP_NOACTIVATE,
                );
            }
            return 0;
        },

        // ------------------------------------------------------------------
        // Focus
        // ------------------------------------------------------------------
        WM_SETFOCUS => {
            if (surface) |s| s.onFocusChange(true);
            return DefWindowProcA(hwnd, msg, wparam, lparam);
        },

        WM_KILLFOCUS => {
            if (surface) |s| s.onFocusChange(false);
            return DefWindowProcA(hwnd, msg, wparam, lparam);
        },

        // ------------------------------------------------------------------
        // Keyboard
        // ------------------------------------------------------------------
        WM_KEYDOWN, WM_SYSKEYDOWN => {
            if (surface) |s| {
                const vk: u16 = @intCast(wparam & 0xFFFF);
                const scan: u32 = @intCast((lparam >> 16) & 0xFF);
                // Bit 30 of lParam: key was already down (auto-repeat)
                const is_repeat = (lparam >> 30) & 1 != 0;
                s.onKey(vk, scan, if (is_repeat) .repeat else .press);
            }
            // Let DefWindowProc handle Alt+F4 (WM_SYSCOMMAND) and other system shortcuts
            if (msg == WM_SYSKEYDOWN) return DefWindowProcA(hwnd, msg, wparam, lparam);
            return 0;
        },

        WM_KEYUP, WM_SYSKEYUP => {
            if (surface) |s| {
                const vk: u16 = @intCast(wparam & 0xFFFF);
                const scan: u32 = @intCast((lparam >> 16) & 0xFF);
                s.onKey(vk, scan, .release);
            }
            if (msg == WM_SYSKEYUP) return DefWindowProcA(hwnd, msg, wparam, lparam);
            return 0;
        },

        // WM_CHAR carries the UTF-16 character for the key event.
        // Text is already captured via ToUnicode in WM_KEYDOWN, so we
        // suppress WM_CHAR to avoid duplicate character input.
        // TODO: For proper IME support, handle WM_IME_COMPOSITION instead.
        WM_CHAR, WM_SYSCHAR => return 0,

        WM_UNICHAR => {
            if (wparam == 0xFFFF) return 1; // UNICODE_NOCHAR: tell Windows we support WM_UNICHAR
            if (surface) |s| {
                const cp: u21 = @intCast(wparam);
                s.onUnichar(cp);
            }
            return 0;
        },

        // ------------------------------------------------------------------
        // Mouse movement
        // ------------------------------------------------------------------
        WM_MOUSEMOVE => {
            const x: i16 = @bitCast(@as(u16, @intCast(lparam & 0xFFFF)));
            const y: i16 = @bitCast(@as(u16, @intCast((lparam >> 16) & 0xFFFF)));
            if (surface) |s| {
                // Request WM_MOUSELEAVE tracking
                if (!s.tracking_mouse_leave) {
                    var tme = TRACKMOUSEEVENT{
                        .dwFlags = TME_LEAVE,
                        .hwndTrack = hwnd,
                    };
                    _ = TrackMouseEvent(&tme);
                    s.tracking_mouse_leave = true;
                }
                s.onMouseMove(@floatFromInt(x), @floatFromInt(y));
            }
            return 0;
        },

        WM_MOUSELEAVE => {
            if (surface) |s| {
                s.tracking_mouse_leave = false;
                // Send a negative position to indicate "mouse left"
                s.onMouseMove(-1.0, -1.0);
            }
            return 0;
        },

        // ------------------------------------------------------------------
        // Mouse buttons
        // ------------------------------------------------------------------
        WM_LBUTTONDOWN, WM_LBUTTONDBLCLK => {
            if (surface) |s| {
                setCapture(hwnd);
                s.onMouseButton(.press, .left);
            }
            return 0;
        },
        WM_LBUTTONUP => {
            if (surface) |s| {
                releaseCapture();
                s.onMouseButton(.release, .left);
            }
            return 0;
        },
        WM_RBUTTONDOWN, WM_RBUTTONDBLCLK => {
            if (surface) |s| s.onMouseButton(.press, .right);
            return 0;
        },
        WM_RBUTTONUP => {
            if (surface) |s| s.onMouseButton(.release, .right);
            return 0;
        },
        WM_MBUTTONDOWN, WM_MBUTTONDBLCLK => {
            if (surface) |s| s.onMouseButton(.press, .middle);
            return 0;
        },
        WM_MBUTTONUP => {
            if (surface) |s| s.onMouseButton(.release, .middle);
            return 0;
        },
        WM_XBUTTONDOWN => {
            const xbutton: u16 = @intCast((wparam >> 16) & 0xFFFF);
            if (surface) |s| {
                const btn: input.MouseButton = if (xbutton == XBUTTON1) .four else .five;
                s.onMouseButton(.press, btn);
            }
            return 1; // XBUTTON handlers should return TRUE
        },
        WM_XBUTTONUP => {
            const xbutton: u16 = @intCast((wparam >> 16) & 0xFFFF);
            if (surface) |s| {
                const btn: input.MouseButton = if (xbutton == XBUTTON1) .four else .five;
                s.onMouseButton(.release, btn);
            }
            return 1;
        },

        // ------------------------------------------------------------------
        // Mouse scroll
        // ------------------------------------------------------------------
        WM_MOUSEWHEEL => {
            const delta: i16 = @bitCast(@as(u16, @intCast((wparam >> 16) & 0xFFFF)));
            if (surface) |s| {
                const yoff: f64 = @as(f64, @floatFromInt(delta)) / @as(f64, WHEEL_DELTA);
                s.onScroll(0.0, yoff);
            }
            return 0;
        },

        WM_MOUSEHWHEEL => {
            const delta: i16 = @bitCast(@as(u16, @intCast((wparam >> 16) & 0xFFFF)));
            if (surface) |s| {
                // Horizontal scroll: positive = right, so negate for xoff convention
                const xoff: f64 = @as(f64, @floatFromInt(delta)) / @as(f64, WHEEL_DELTA);
                s.onScroll(xoff, 0.0);
            }
            return 0;
        },

        // ------------------------------------------------------------------
        // Cursor shape (set by default handler initially)
        // ------------------------------------------------------------------
        WM_SETCURSOR => {
            if (surface) |s| {
                if (s.cursor_handle) |h| {
                    _ = SetCursor(h);
                    return 1; // handled
                }
            }
            return DefWindowProcA(hwnd, msg, wparam, lparam);
        },

        // ------------------------------------------------------------------
        // User-defined wakeup
        // ------------------------------------------------------------------
        WM_USER => return 0,

        else => return DefWindowProcA(hwnd, msg, wparam, lparam),
    }
}

// SetCapture / ReleaseCapture for mouse button tracking
extern "user32" fn SetCapture(hwnd: HWND) callconv(.winapi) ?HWND;
extern "user32" fn ReleaseCapture() callconv(.winapi) BOOL;

fn setCapture(hwnd: HWND) void {
    _ = SetCapture(hwnd);
}

fn releaseCapture() void {
    _ = ReleaseCapture();
}
