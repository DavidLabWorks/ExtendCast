#include "../WindowsToMacKeyCode.h"

#include <cassert>
#include <iostream>

int main() {
    // The crash case: Windows D (VK 0x44) must become Mac D (0x02),
    // not the undefined gap that was previously injected as-is.
    assert(windowsVirtualKeyToMacKeyCode(0x44).value() == 0x02);

    // Spot-check letters that previously mapped to volume / keypad keys.
    assert(windowsVirtualKeyToMacKeyCode(0x41).value() == 0x00); // A
    assert(windowsVirtualKeyToMacKeyCode(0x48).value() == 0x04); // H (was VolumeUp)
    assert(windowsVirtualKeyToMacKeyCode(0x49).value() == 0x22); // I (was VolumeDown)
    assert(windowsVirtualKeyToMacKeyCode(0x4A).value() == 0x26); // J (was Mute)
    assert(windowsVirtualKeyToMacKeyCode(0x5A).value() == 0x06); // Z

    // Digits that previously mapped to Command / Shift / Escape.
    assert(windowsVirtualKeyToMacKeyCode(0x37).value() == 0x1A); // 7 (was Command)
    assert(windowsVirtualKeyToMacKeyCode(0x38).value() == 0x1C); // 8 (was Shift)
    assert(windowsVirtualKeyToMacKeyCode(0x35).value() == 0x17); // 5 (was Escape)

    // Controls
    assert(windowsVirtualKeyToMacKeyCode(0x0D).value() == 0x24); // Enter
    assert(windowsVirtualKeyToMacKeyCode(0x08).value() == 0x33); // Backspace
    assert(windowsVirtualKeyToMacKeyCode(0x20).value() == 0x31); // Space
    assert(windowsVirtualKeyToMacKeyCode(0x1B).value() == 0x35); // Escape

    // Modifiers
    assert(windowsVirtualKeyToMacKeyCode(0x10).value() == 0x38); // Shift
    assert(windowsVirtualKeyToMacKeyCode(0x11).value() == 0x3B); // Ctrl
    assert(windowsVirtualKeyToMacKeyCode(0x12).value() == 0x3A); // Alt → Option
    assert(windowsVirtualKeyToMacKeyCode(0x5B).value() == 0x37); // LWin → Command

    // Arrows
    assert(windowsVirtualKeyToMacKeyCode(0x25).value() == 0x7B); // Left
    assert(windowsVirtualKeyToMacKeyCode(0x26).value() == 0x7E); // Up
    assert(windowsVirtualKeyToMacKeyCode(0x27).value() == 0x7C); // Right
    assert(windowsVirtualKeyToMacKeyCode(0x28).value() == 0x7D); // Down

    // Every letter VK must map (no holes that would drop typing).
    for (uint32_t vk = 0x41; vk <= 0x5A; ++vk) {
        assert(windowsVirtualKeyToMacKeyCode(vk).has_value());
    }
    for (uint32_t vk = 0x30; vk <= 0x39; ++vk) {
        assert(windowsVirtualKeyToMacKeyCode(vk).has_value());
    }

    // Unmapped / garbage must not pretend to be a Mac key.
    assert(!windowsVirtualKeyToMacKeyCode(0).has_value());
    assert(!windowsVirtualKeyToMacKeyCode(0xFF).has_value());
    assert(!windowsVirtualKeyToMacKeyCode(0x1234).has_value());

    // Pre-fix bug: raw VK must not equal Mac keycode for letters.
    assert(windowsVirtualKeyToMacKeyCode(0x44).value() != 0x44);

    std::cout << "WindowsToMacKeyCode tests passed\n";
    return 0;
}
