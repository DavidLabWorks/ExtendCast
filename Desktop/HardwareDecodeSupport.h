#pragma once

/// Returns whether this platform can open an H.264 hardware decode device.
/// Result is cached for the process lifetime.
bool hardwareH264DecodeAvailable();
