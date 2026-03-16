/// Win32 Virtual Key (VK_*) to Ghostty input.Key translation.
///
/// This module provides the mapping from Windows virtual key codes to
/// the platform-independent key codes used throughout Ghostty.
const std = @import("std");
const input = @import("../../input.zig");

// Win32 Virtual Key constants
pub const VK_BACK: u8 = 0x08;
pub const VK_TAB: u8 = 0x09;
pub const VK_RETURN: u8 = 0x0D;
pub const VK_SHIFT: u8 = 0x10;
pub const VK_CONTROL: u8 = 0x11;
pub const VK_MENU: u8 = 0x12; // Alt
pub const VK_PAUSE: u8 = 0x13;
pub const VK_CAPITAL: u8 = 0x14;
pub const VK_ESCAPE: u8 = 0x1B;
pub const VK_SPACE: u8 = 0x20;
pub const VK_PRIOR: u8 = 0x21; // Page Up
pub const VK_NEXT: u8 = 0x22;  // Page Down
pub const VK_END: u8 = 0x23;
pub const VK_HOME: u8 = 0x24;
pub const VK_LEFT: u8 = 0x25;
pub const VK_UP: u8 = 0x26;
pub const VK_RIGHT: u8 = 0x27;
pub const VK_DOWN: u8 = 0x28;
pub const VK_SNAPSHOT: u8 = 0x2C; // Print Screen
pub const VK_INSERT: u8 = 0x2D;
pub const VK_DELETE: u8 = 0x2E;
// 0x30-0x39: '0'-'9'
// 0x41-0x5A: 'A'-'Z'
pub const VK_LWIN: u8 = 0x5B;
pub const VK_RWIN: u8 = 0x5C;
pub const VK_APPS: u8 = 0x5D; // Context Menu
pub const VK_NUMPAD0: u8 = 0x60;
pub const VK_NUMPAD1: u8 = 0x61;
pub const VK_NUMPAD2: u8 = 0x62;
pub const VK_NUMPAD3: u8 = 0x63;
pub const VK_NUMPAD4: u8 = 0x64;
pub const VK_NUMPAD5: u8 = 0x65;
pub const VK_NUMPAD6: u8 = 0x66;
pub const VK_NUMPAD7: u8 = 0x67;
pub const VK_NUMPAD8: u8 = 0x68;
pub const VK_NUMPAD9: u8 = 0x69;
pub const VK_MULTIPLY: u8 = 0x6A;
pub const VK_ADD: u8 = 0x6B;
pub const VK_SEPARATOR: u8 = 0x6C;
pub const VK_SUBTRACT: u8 = 0x6D;
pub const VK_DECIMAL: u8 = 0x6E;
pub const VK_DIVIDE: u8 = 0x6F;
pub const VK_F1: u8 = 0x70;
pub const VK_F2: u8 = 0x71;
pub const VK_F3: u8 = 0x72;
pub const VK_F4: u8 = 0x73;
pub const VK_F5: u8 = 0x74;
pub const VK_F6: u8 = 0x75;
pub const VK_F7: u8 = 0x76;
pub const VK_F8: u8 = 0x77;
pub const VK_F9: u8 = 0x78;
pub const VK_F10: u8 = 0x79;
pub const VK_F11: u8 = 0x7A;
pub const VK_F12: u8 = 0x7B;
pub const VK_F13: u8 = 0x7C;
pub const VK_F14: u8 = 0x7D;
pub const VK_F15: u8 = 0x7E;
pub const VK_F16: u8 = 0x7F;
pub const VK_F17: u8 = 0x80;
pub const VK_F18: u8 = 0x81;
pub const VK_F19: u8 = 0x82;
pub const VK_F20: u8 = 0x83;
pub const VK_F21: u8 = 0x84;
pub const VK_F22: u8 = 0x85;
pub const VK_F23: u8 = 0x86;
pub const VK_F24: u8 = 0x87;
pub const VK_NUMLOCK: u8 = 0x90;
pub const VK_SCROLL: u8 = 0x91;
pub const VK_LSHIFT: u8 = 0xA0;
pub const VK_RSHIFT: u8 = 0xA1;
pub const VK_LCONTROL: u8 = 0xA2;
pub const VK_RCONTROL: u8 = 0xA3;
pub const VK_LMENU: u8 = 0xA4; // Left Alt
pub const VK_RMENU: u8 = 0xA5; // Right Alt
pub const VK_OEM_1: u8 = 0xBA;       // ;:
pub const VK_OEM_PLUS: u8 = 0xBB;    // =+
pub const VK_OEM_COMMA: u8 = 0xBC;   // ,<
pub const VK_OEM_MINUS: u8 = 0xBD;   // -_
pub const VK_OEM_PERIOD: u8 = 0xBE;  // .>
pub const VK_OEM_2: u8 = 0xBF;       // /?
pub const VK_OEM_3: u8 = 0xC0;       // `~
pub const VK_OEM_4: u8 = 0xDB;       // [{
pub const VK_OEM_5: u8 = 0xDC;       // \|
pub const VK_OEM_6: u8 = 0xDD;       // ]}
pub const VK_OEM_7: u8 = 0xDE;       // '"

/// Map a Win32 virtual key code to a Ghostty input.Key.
/// Returns .unidentified if no mapping exists.
pub fn keyFromVK(vk: u16) input.Key {
    return switch (vk) {
        VK_BACK => .backspace,
        VK_TAB => .tab,
        VK_RETURN => .enter,
        VK_PAUSE => .pause,
        VK_CAPITAL => .caps_lock,
        VK_ESCAPE => .escape,
        VK_SPACE => .space,
        VK_PRIOR => .page_up,
        VK_NEXT => .page_down,
        VK_END => .end,
        VK_HOME => .home,
        VK_LEFT => .arrow_left,
        VK_UP => .arrow_up,
        VK_RIGHT => .arrow_right,
        VK_DOWN => .arrow_down,
        VK_SNAPSHOT => .print_screen,
        VK_INSERT => .insert,
        VK_DELETE => .delete,

        // Digits row
        '0' => .digit_0,
        '1' => .digit_1,
        '2' => .digit_2,
        '3' => .digit_3,
        '4' => .digit_4,
        '5' => .digit_5,
        '6' => .digit_6,
        '7' => .digit_7,
        '8' => .digit_8,
        '9' => .digit_9,

        // Alpha keys (VK codes for A-Z are the ASCII uppercase values)
        'A' => .key_a,
        'B' => .key_b,
        'C' => .key_c,
        'D' => .key_d,
        'E' => .key_e,
        'F' => .key_f,
        'G' => .key_g,
        'H' => .key_h,
        'I' => .key_i,
        'J' => .key_j,
        'K' => .key_k,
        'L' => .key_l,
        'M' => .key_m,
        'N' => .key_n,
        'O' => .key_o,
        'P' => .key_p,
        'Q' => .key_q,
        'R' => .key_r,
        'S' => .key_s,
        'T' => .key_t,
        'U' => .key_u,
        'V' => .key_v,
        'W' => .key_w,
        'X' => .key_x,
        'Y' => .key_y,
        'Z' => .key_z,

        VK_LWIN => .meta_left,
        VK_RWIN => .meta_right,
        VK_APPS => .context_menu,

        // Numpad
        VK_NUMPAD0 => .numpad_0,
        VK_NUMPAD1 => .numpad_1,
        VK_NUMPAD2 => .numpad_2,
        VK_NUMPAD3 => .numpad_3,
        VK_NUMPAD4 => .numpad_4,
        VK_NUMPAD5 => .numpad_5,
        VK_NUMPAD6 => .numpad_6,
        VK_NUMPAD7 => .numpad_7,
        VK_NUMPAD8 => .numpad_8,
        VK_NUMPAD9 => .numpad_9,
        VK_MULTIPLY => .numpad_multiply,
        VK_ADD => .numpad_add,
        VK_SEPARATOR => .numpad_separator,
        VK_SUBTRACT => .numpad_subtract,
        VK_DECIMAL => .numpad_decimal,
        VK_DIVIDE => .numpad_divide,

        // Function keys
        VK_F1 => .f1,
        VK_F2 => .f2,
        VK_F3 => .f3,
        VK_F4 => .f4,
        VK_F5 => .f5,
        VK_F6 => .f6,
        VK_F7 => .f7,
        VK_F8 => .f8,
        VK_F9 => .f9,
        VK_F10 => .f10,
        VK_F11 => .f11,
        VK_F12 => .f12,
        VK_F13 => .f13,
        VK_F14 => .f14,
        VK_F15 => .f15,
        VK_F16 => .f16,
        VK_F17 => .f17,
        VK_F18 => .f18,
        VK_F19 => .f19,
        VK_F20 => .f20,
        VK_F21 => .f21,
        VK_F22 => .f22,
        VK_F23 => .f23,
        VK_F24 => .f24,

        VK_NUMLOCK => .num_lock,
        VK_SCROLL => .scroll_lock,

        // Modifier keys (sided)
        VK_LSHIFT => .shift_left,
        VK_RSHIFT => .shift_right,
        VK_LCONTROL => .control_left,
        VK_RCONTROL => .control_right,
        VK_LMENU => .alt_left,
        VK_RMENU => .alt_right,

        // OEM keys (US layout)
        VK_OEM_1 => .semicolon,
        VK_OEM_PLUS => .equal,
        VK_OEM_COMMA => .comma,
        VK_OEM_MINUS => .minus,
        VK_OEM_PERIOD => .period,
        VK_OEM_2 => .slash,
        VK_OEM_3 => .backquote,
        VK_OEM_4 => .bracket_left,
        VK_OEM_5 => .backslash,
        VK_OEM_6 => .bracket_right,
        VK_OEM_7 => .quote,

        else => .unidentified,
    };
}

/// Get the unshifted codepoint for a VK + layout.
/// This is the character the key would produce with no modifiers applied.
/// We get it by calling MapVirtualKeyW(vk, MAPVK_VK_TO_CHAR) and masking
/// off the dead-key flag.
pub fn unshiftedCodepoint(vk: u16) u21 {
    const char = mapVirtualKey(@intCast(vk), 2); // MAPVK_VK_TO_CHAR = 2
    if (char == 0) return 0;
    // Bit 31 is the dead key flag; mask it off
    const cp = char & 0x7FFFFFFF;
    const result = std.math.cast(u21, cp) orelse return 0;
    // MapVirtualKeyW returns uppercase letters (e.g. 'V' for VK_V).
    // Ghostty keybindings use lowercase codepoints, so we must lowercase.
    if (result >= 'A' and result <= 'Z') return result + 32;
    return result;
}

// Win32 APIs needed for key translation
extern "user32" fn MapVirtualKeyW(uCode: u32, uMapType: u32) callconv(.winapi) u32;
extern "user32" fn GetKeyState(nVirtKey: i32) callconv(.winapi) i16;
extern "user32" fn ToUnicode(
    wVirtKey: u32,
    wScanCode: u32,
    lpKeyState: *const [256]u8,
    pwszBuff: [*]u16,
    cchBuff: i32,
    wFlags: u32,
) callconv(.winapi) i32;
extern "user32" fn GetKeyboardState(lpKeyState: *[256]u8) callconv(.winapi) std.os.windows.BOOL;

/// Get the keyboard state as a 256-byte array suitable for ToUnicode.
pub fn getKeyboardState(state: *[256]u8) bool {
    return GetKeyboardState(state) != 0;
}

pub fn mapVirtualKey(code: u32, map_type: u32) u32 {
    return MapVirtualKeyW(code, map_type);
}

/// Get the current modifier state from Win32 keyboard.
pub fn getModifiers() input.Mods {
    // Note: Mods.Side only has .left and .right (no .none).
    // The side is meaningful only when the corresponding modifier bool is true,
    // so we just indicate which physical side is pressed (defaulting to .left).
    // GetKeyState returns i16; the high bit (0x8000) indicates the key is down.
    // 0x8000 doesn't fit in i16, so bitcast to u16 before masking.
    const ks = struct {
        fn down(vk: i32) bool {
            return (@as(u16, @bitCast(GetKeyState(vk))) & 0x8000) != 0;
        }
        fn toggled(vk: i32) bool {
            return (@as(u16, @bitCast(GetKeyState(vk))) & 0x0001) != 0;
        }
    };
    return .{
        .shift = ks.down(0x10),      // VK_SHIFT
        .ctrl = ks.down(0x11),       // VK_CONTROL
        .alt = ks.down(0x12),        // VK_MENU
        .super = ks.down(0x5B) or ks.down(0x5C), // VK_LWIN / VK_RWIN
        .caps_lock = ks.toggled(0x14),  // VK_CAPITAL
        .num_lock = ks.toggled(0x90),   // VK_NUMLOCK
        .sides = .{
            // Right side takes priority; otherwise left (default)
            .shift = if (ks.down(0xA1)) .right else .left,
            .ctrl  = if (ks.down(0xA3)) .right else .left,
            .alt   = if (ks.down(0xA5)) .right else .left,
            .super = if (ks.down(0x5C)) .right else .left,
        },
    };
}

/// Convert a Win32 key event into a UTF-8 string.
/// `buf` must be at least 32 bytes. Returns the number of bytes written,
/// or 0 if the key generates no text (e.g. modifier keys, dead keys with
/// no base character).
pub fn keyEventToUtf8(
    vk: u32,
    scan_code: u32,
    buf: []u8,
) usize {
    var key_state: [256]u8 = undefined;
    if (!getKeyboardState(&key_state)) return 0;

    // Buffer for up to 4 UTF-16 code units
    var wide: [8]u16 = undefined;
    const n = ToUnicode(vk, scan_code, &key_state, &wide, wide.len, 0);

    if (n <= 0) {
        // n == 0: no translation, n < 0: dead key stored
        return 0;
    }

    const src = wide[0..@intCast(n)];
    const result = std.unicode.utf16LeToUtf8(buf, src) catch return 0;
    return result;
}
