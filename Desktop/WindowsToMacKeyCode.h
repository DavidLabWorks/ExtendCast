#pragma once

#include <cstdint>
#include <optional>

// Maps Windows virtual-key codes (WinUser.h VK_*) to macOS CGKeyCode /
// Carbon kVK_* values used by the Mac sender's CGEvent injection.
//
// The wire protocol carries Mac keycodes (Mac receivers already send
// NSEvent.keyCode). Windows must translate before sending.
inline std::optional<uint16_t> windowsVirtualKeyToMacKeyCode(uint32_t vk) {
    switch (vk) {
    // Letters A–Z (VK_A=0x41 … VK_Z=0x5A) → kVK_ANSI_*
    case 0x41: return 0x00; // A
    case 0x42: return 0x0B; // B
    case 0x43: return 0x08; // C
    case 0x44: return 0x02; // D
    case 0x45: return 0x0E; // E
    case 0x46: return 0x03; // F
    case 0x47: return 0x05; // G
    case 0x48: return 0x04; // H
    case 0x49: return 0x22; // I
    case 0x4A: return 0x26; // J
    case 0x4B: return 0x28; // K
    case 0x4C: return 0x25; // L
    case 0x4D: return 0x2E; // M
    case 0x4E: return 0x2D; // N
    case 0x4F: return 0x1F; // O
    case 0x50: return 0x23; // P
    case 0x51: return 0x0C; // Q
    case 0x52: return 0x0F; // R
    case 0x53: return 0x01; // S
    case 0x54: return 0x11; // T
    case 0x55: return 0x20; // U
    case 0x56: return 0x09; // V
    case 0x57: return 0x0D; // W
    case 0x58: return 0x07; // X
    case 0x59: return 0x10; // Y
    case 0x5A: return 0x06; // Z

    // Digits 0–9
    case 0x30: return 0x1D; // 0
    case 0x31: return 0x12; // 1
    case 0x32: return 0x13; // 2
    case 0x33: return 0x14; // 3
    case 0x34: return 0x15; // 4
    case 0x35: return 0x17; // 5
    case 0x36: return 0x16; // 6
    case 0x37: return 0x1A; // 7
    case 0x38: return 0x1C; // 8
    case 0x39: return 0x19; // 9

    // Controls
    case 0x08: return 0x33; // VK_BACK → Delete (backspace)
    case 0x09: return 0x30; // VK_TAB
    case 0x0D: return 0x24; // VK_RETURN
    case 0x1B: return 0x35; // VK_ESCAPE
    case 0x20: return 0x31; // VK_SPACE

    // Modifiers — Win/Cmd swap matches typical Mac remote-desktop feel
    case 0x10: // VK_SHIFT
    case 0xA0: return 0x38; // VK_LSHIFT → Shift
    case 0xA1: return 0x3C; // VK_RSHIFT → RightShift
    case 0x11: // VK_CONTROL
    case 0xA2: return 0x3B; // VK_LCONTROL → Control
    case 0xA3: return 0x3E; // VK_RCONTROL → RightControl
    case 0x12: // VK_MENU (Alt)
    case 0xA4: return 0x3A; // VK_LMENU → Option
    case 0xA5: return 0x3D; // VK_RMENU → RightOption
    case 0x5B: return 0x37; // VK_LWIN → Command
    case 0x5C: return 0x36; // VK_RWIN → RightCommand
    case 0x14: return 0x39; // VK_CAPITAL → CapsLock

    // Arrows / navigation
    case 0x25: return 0x7B; // VK_LEFT
    case 0x26: return 0x7E; // VK_UP
    case 0x27: return 0x7C; // VK_RIGHT
    case 0x28: return 0x7D; // VK_DOWN
    case 0x21: return 0x74; // VK_PRIOR (Page Up)
    case 0x22: return 0x79; // VK_NEXT (Page Down)
    case 0x23: return 0x77; // VK_END
    case 0x24: return 0x73; // VK_HOME
    case 0x2D: return 0x72; // VK_INSERT → Help/Insert
    case 0x2E: return 0x75; // VK_DELETE → ForwardDelete

    // Function keys F1–F12
    case 0x70: return 0x7A; // F1
    case 0x71: return 0x78; // F2
    case 0x72: return 0x63; // F3
    case 0x73: return 0x76; // F4
    case 0x74: return 0x60; // F5
    case 0x75: return 0x61; // F6
    case 0x76: return 0x62; // F7
    case 0x77: return 0x64; // F8
    case 0x78: return 0x65; // F9
    case 0x79: return 0x6D; // F10
    case 0x7A: return 0x67; // F11
    case 0x7B: return 0x6F; // F12

    // Numpad
    case 0x60: return 0x52; // VK_NUMPAD0
    case 0x61: return 0x53; // VK_NUMPAD1
    case 0x62: return 0x54; // VK_NUMPAD2
    case 0x63: return 0x55; // VK_NUMPAD3
    case 0x64: return 0x56; // VK_NUMPAD4
    case 0x65: return 0x57; // VK_NUMPAD5
    case 0x66: return 0x58; // VK_NUMPAD6
    case 0x67: return 0x59; // VK_NUMPAD7
    case 0x68: return 0x5B; // VK_NUMPAD8
    case 0x69: return 0x5C; // VK_NUMPAD9
    case 0x6A: return 0x43; // VK_MULTIPLY
    case 0x6B: return 0x45; // VK_ADD
    case 0x6D: return 0x4E; // VK_SUBTRACT
    case 0x6E: return 0x41; // VK_DECIMAL
    case 0x6F: return 0x4B; // VK_DIVIDE
    case 0x90: return 0x47; // VK_NUMLOCK → KeypadClear

    // OEM punctuation (US ANSI)
    case 0xBA: return 0x29; // VK_OEM_1 ;:
    case 0xBB: return 0x18; // VK_OEM_PLUS =+
    case 0xBC: return 0x2B; // VK_OEM_COMMA ,<
    case 0xBD: return 0x1B; // VK_OEM_MINUS -_
    case 0xBE: return 0x2F; // VK_OEM_PERIOD .>
    case 0xBF: return 0x2C; // VK_OEM_2 /?
    case 0xC0: return 0x32; // VK_OEM_3 `~
    case 0xDB: return 0x21; // VK_OEM_4 [{
    case 0xDC: return 0x2A; // VK_OEM_5 \|
    case 0xDD: return 0x1E; // VK_OEM_6 ]}
    case 0xDE: return 0x27; // VK_OEM_7 '"

    default:
        return std::nullopt;
    }
}
