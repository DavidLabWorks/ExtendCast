# ExtendCast

ExtendCast is an independent GPLv3 project based on
[StephenLovino/BetterCast](https://github.com/StephenLovino/BetterCast).
It focuses on a more configurable, responsive, and reliable macOS
extended-display experience.

ExtendCast is not affiliated with or endorsed by the original BetterCast
project. See [NOTICE.md](NOTICE.md) for attribution and modification details.

## Repository Structure

Each platform is kept as a top-level project:

| Directory | Platform | Build system |
|-----------|----------|--------------|
| [`macOS/`](macOS/) | macOS sender + receiver | Swift Package Manager |
| [`iOS/`](iOS/) | iOS/iPadOS receiver | Swift Package Manager + Xcode |
| [`Android/`](Android/) | Android sender + receiver | Gradle |
| [`Desktop/`](Desktop/) | Windows/Linux sender + receiver | CMake + Qt |
| [`Shared/`](Shared/) | Branding and protocol documentation | Shared assets |

The applications share a network protocol, not source-code dependencies, so
each platform can be opened and built independently.

## Implementation Documentation

- [Sender / Receiver implementation baseline](docs/sender-receiver-implementation-baseline.md) defines the current macOS Sender + Windows Receiver lifecycle and the cross-platform behavior contract.
- [Wire protocol](Shared/Protocol/PROTOCOL.md) defines discovery names, media framing, stable Sender identity, and Receiver control commands.
- [Shared terminology](CONTEXT.md) defines role, route, advertisement, stream, and session names used across platform implementations.

## Improvements over BetterCast

ExtendCast substantially changes the macOS sender experience. The work focuses
on per-device control, virtual-display correctness, lower background overhead,
and fixes for display identity, ColorSync, HiDPI, and session recovery.

### At a Glance

| Area | Original BetterCast | ExtendCast |
|------|---------------------|------------|
| Device settings | Shared global settings | Persisted settings for each receiver |
| Apply behavior | Restarts every active pipeline | Applies only to the selected device |
| Auto-connect | One global switch | Independent setting for each receiver |
| Frame rate | Chosen automatically by link type | Per-device 30 or 60 FPS control |
| Resolutions | Fixed built-in presets | Add, edit, validate, and remove custom presets |
| Display identity | Runtime serial based on connection order | Stable identity for each receiver and density mode |
| HiDPI handling | Relies on the mode macOS restores | Verifies and selects the exact logical and backing-pixel mode |
| Display previews | Full-resolution capture every two seconds | No automatic preview capture; optional previews are downscaled |
| Capture buffering | Queue depth of 4 or 8 at foreground QoS | Queue depth of 3 using a lower-priority capture queue |
| Receiver service | Starts automatically with the app | Starts only when requested or explicitly enabled at launch |
| Background controls | Main window required | Menu-bar connect, disconnect, open, and quit controls |
| Recovery | Capture can remain stale after wake or unlock | Restarts capture while preserving virtual displays |

### Device Management and macOS UI

- A menu-bar controller shows connected and available devices without
  requiring the main window.

- Devices can be connected or disconnected from compact icon actions aligned
  to the right side of each menu-bar row.

- The sidebar now uses stable destinations for Devices, Recent, Connect,
  Receive Screen, Settings, and Logs instead of mixing navigation with a
  changing list of discovered devices.

- The Devices page separates connected and available receivers into consistent
  macOS-style cards with device-specific Settings and Disconnect actions.

- Duplicate Bonjour P2P entries, synthetic ADB entries, active devices, and
  saved manual addresses are filtered from the Available list.

- Available receivers can be configured before connecting. The same settings
  sections remain available after connection.

- Connected-device pages include a compact status bar with the active
  resolution, Apply or Apply & Reconnect, and Disconnect.

- Apply is enabled only when the selected device has pending changes. Transport
  changes reconnect that device; display and stream changes keep the network
  connection when possible.

- Manual IP connections have a dedicated page. Successful connections are
  stored in a Recent page instead of being lost when the app closes.

- Recent devices show Checking, Available, Unavailable, Connected, and Local
  Network Off states, with direct access to the relevant privacy setting.

- Settings use grouped native forms, aligned content widths, compact secondary
  actions, and consistent destructive-button styling.

- Launch at Login is managed through `SMAppService`, including the macOS
  approval-required state and a shortcut to Login Items.

### Per-Device Profiles and Custom Resolutions

- Each receiver stores its own display mode, resolution, pixel density, Retina
  state, bitrate, frame rate, audio setting, protocol, interface preference,
  and auto-connect state.

- Receiver profiles are restored before reconnecting, so one device no longer
  overwrites the settings intended for another.

- Auto-connect is tracked per receiver. Multiple saved receivers can reconnect
  independently when they become available.

- Custom resolutions can be added, edited, and removed. Validation covers pixel
  bounds, even dimensions, duplicate sizes, labels, and a 72–500 PPI range.

- Resolution choices combine built-in and custom presets, sort them by
  dimensions, and preserve a selected custom value across launches.

- PPI is translated into an equivalent diagonal display size. A setting such
  as `2880 × 1920 at 267 PPI` is shown as approximately `13.0″`.

- The custom editor explains that full PPI is used for Retina displays, while
  standard-density mode advertises no more than 110 PPI.

- Editing or deleting a custom resolution updates saved receiver profiles and
  active settings that referenced it.

### Virtual Display Stability and HiDPI Correctness

- Virtual-display serial numbers are stable across launches instead of being
  assigned from an in-memory counter that changes with connection order.

- Identities are stored in a dedicated preferences domain and migrated from
  earlier application domains, so application identifier changes do not create
  a new monitor identity.

- Receiver keys normalize discovery prefixes, letter case, whitespace, and
  macOS duplicate-name suffixes such as ` (2)`.

- Standard and Retina modes use separate stable identities. This prevents
  macOS from restoring a cached 1× mode for a requested 2× display, or the
  reverse.

- The descriptor sets both serial fields, a nonzero vendor ID, and a stable
  product ID before registering the display.

- After registration, ExtendCast matches both logical dimensions and backing
  pixels, then explicitly selects the requested 1× or 2× display mode.

- Active mode diagnostics report logical size, backing-pixel size, refresh
  rate, scale factor, and whether the result matches the requested density.

- Standard mode caps the descriptor at 110 PPI to stop macOS from retaining an
  unintended HiDPI scale. Retina mode uses the configured full density.

- Virtual-display refresh rate follows the selected 30 or 60 FPS setting
  instead of being fixed at 60 Hz.

- Resolution and refresh-rate changes can update an existing display in place.
  A display is recreated only when density changes or the in-place update fails.

- Capture or encoder restarts reuse the existing virtual display. This preserves
  display arrangement and avoids unnecessary monitor registration events.

- Stable identities prevent the duplicate ICC-profile growth that previously
  drove `colorsync.useragent` CPU usage and stalled the macOS Displays pane.

- Seven regression tests cover identity migration, deterministic serials,
  discovery aliases, duplicate suffixes, and separate Standard/Retina identity.

### Performance and Responsiveness

- ScreenCaptureKit requests the bi-planar `420v` pixel format directly, reducing
  conversion work before VideoToolbox encoding.

- The capture queue depth is fixed at three frames instead of four or eight,
  reducing buffered surfaces, memory pressure, and capture latency.

- Screen and audio sample handling runs at utility QoS instead of
  user-initiated QoS, allowing keyboard, pointer, and foreground UI work to win
  scheduling contention.

- Automatic full-resolution display screenshots every two seconds were removed
  from the main device workflow.

- Optional display previews are captured only on demand and resized to at most
  480 pixels before reaching SwiftUI, reducing WindowServer and UI overhead.

- Applying settings restarts only the selected capture and encoder instead of
  destroying every connected device pipeline.

- In-place virtual-display updates avoid repeated display creation, ColorSync
  scans, ICC generation, and System Settings refreshes.

- The log view renders one selectable monospaced text block instead of hundreds
  of independent SwiftUI text views.

- Logs remain capped at 200 entries, and excess entries are removed in one
  operation.

- The receiver listener no longer starts by default, avoiding an unused network
  listener and related background activity.

### Networking and Connection Reliability

- TCP and UDP Bonjour services are browsed simultaneously. A receiver's saved
  protocol selects the matching endpoint when connecting.

- Discovery is independent from the chosen route, while each receiver can use
  Auto, P2P, Router, or Cable mode.

- If AWDL negotiation times out, fallback now keeps the receiver's selected
  TCP or UDP protocol instead of always switching the retry to TCP.

- Route and protocol choices are stored per receiver, so changing one device
  no longer changes discovery or connection behavior for every device.

- Manual IP connections use TCP and can retain a saved interface preference.
  Localhost remains unrestricted for ADB forwarding.

- Recent manual devices are probed with a bounded timeout and one retry, which
  handles routes that briefly remain unavailable while USB4, ARP, or link-local
  networking settles.

- Local-network privacy denial is detected separately from an offline device,
  so the UI can present the correct recovery action.

- Release metadata declares Bonjour use, local-network access, and client/server
  network entitlements.

- Frame rate is selectable per receiver. Bitrate, keyframe interval, and rate
  limiting remain link-aware for AWDL, USB ADB, WiFi ADB, and router paths.

### Recovery and Operational Fixes

- Wake, login-session activation, and screen unlock events are coalesced into a
  single capture recovery operation.

- Recovery rebuilds ScreenCaptureKit and encoder state without destroying the
  virtual monitor or losing its arrangement.

- Input bounds are now refreshed after exact 1× or 2× mode selection, avoiding
  coordinates based on the temporary mode macOS exposes during registration.

- App services are started only once even if SwiftUI reconstructs or reveals the
  main view multiple times.

- Receiver listening is opt-in and includes a separate Start Listening at
  Launch preference.

- The release checker uses ExtendCast GitHub Releases and compares the complete
  semantic version instead of presenting unrelated upstream updates.

- The built-in-display brightness control was removed from streaming settings,
  keeping device pages focused on receiver and virtual-display behavior.

## How It Works

**ExtendCast** is a unified Mac app that can **send** your screen to other
devices and **receive** screens from other Macs in a separate window. Each
extended connection creates a dedicated virtual display.

Each receiver has independent display, connection, quality, frame-rate, input,
audio, and auto-connect settings.

## Supported Platforms

| Platform | Role | Connection | Download |
|----------|------|------------|----------|
| **macOS** | Sender + Receiver | P2P Direct / WiFi / Cable | Build from source |
| **iOS / iPadOS** | Receiver | P2P Direct (AWDL) / WiFi | [bettercast.online](https://bettercast.online/#install) |
| **Windows** | Sender + Receiver | WiFi / Cable | [GitHub Actions build](https://github.com/Ruobin521/ExtendCast/actions/workflows/build-windows-receiver.yml) |
| **Linux** | Receiver | WiFi | [bettercast.online](https://bettercast.online/#install) |
| **Android** | Receiver | WiFi / ADB USB / ADB WiFi | [bettercast.online](https://bettercast.online/#install) |

## Features

- **Multi-device** — Connect multiple receivers simultaneously, each with its own virtual display
- **Per-device profiles** — Save display, network, quality, frame-rate, audio, and auto-connect settings independently
- **Custom resolutions** — Create validated presets with pixel density and equivalent physical display size
- **Menu-bar control** — Connect or disconnect devices, open the app, or quit without keeping the main window visible
- **Cross-platform input** — Mouse and keyboard pass-through from any receiver back to the Mac
- **Audio streaming** — Optional per-device AAC-LC audio forwarding (128 kbps stereo)
- **Selectable frame rate** — Choose 30 or 60 FPS per receiver while bitrate, keyframe interval, and rate limiting adapt to the link
- **Stable virtual displays** — Preserve display identity, arrangement, density mode, and ColorSync state across capture restarts
- **Session recovery** — Resume capture after wake or unlock without replacing the virtual monitor
- **Zero-config for Apple devices** — iOS/Mac receivers are discovered automatically via AWDL (no WiFi network needed)
- **mDNS discovery** — Windows/Linux/Android receivers are discovered automatically when on the same network

## Installation

### macOS (Sender + Receiver)

1. Run `./macOS/build.sh`.
2. Copy `macOS/ExtendCast.app` to `/Applications`.
3. Launch **ExtendCast** and grant the required permissions:
   - **Screen Recording** — to capture your display
   - **Accessibility** — to relay mouse and keyboard input from receivers
   - **Local Network** — to discover and connect to receivers

The receiver is stopped by default. Open **Receive Screen** and click
**Start Listening** when this Mac should accept incoming streams. Enable
**Start Listening at Launch** if receiver mode should start automatically.

### iOS / iPadOS

The receiver source and unsigned IPA packaging instructions are in
[`iOS/`](iOS/). Installation requires Apple signing and provisioning.

### Windows

Download the latest ExtendCast Windows installer and run `ExtendCast.exe`.
The Windows build includes sender and receiver modes, with optional virtual
display support provided by the bundled VDD driver.

### Linux

Download the AppImage from [bettercast.online](https://bettercast.online/#install). Make it executable (`chmod +x`) and run. Both devices must be on the same WiFi network.

### Android

Open [`Android/`](Android/) in Android Studio or run
`cd Android && ./gradlew :app:assembleDebug`. It supports receiver and sender
modes over WiFi or ADB.

## Networking

ExtendCast uses **TCP (port 41820)** for the primary video/audio stream and
**UDP (port 51821)** for chunked frame delivery. Discovery browses both
`_bettercast._tcp` and `_bettercast._udp`.

- **Apple-to-Apple**: Uses AWDL (Apple Wireless Direct Link) for a direct P2P connection — no WiFi router needed
- **All other platforms**: Requires both devices to be on the same WiFi/LAN network
- **Hotspot**: If no shared network is available, create a hotspot on any device and connect the Mac to it

### Wire Protocol

See [Shared/Protocol/PROTOCOL.md](Shared/Protocol/PROTOCOL.md) for the shared
protocol reference. Frames are sent as length-prefixed TCP messages with a
1-byte type tag:

```
[4-byte big-endian length] [1-byte type] [payload]
  type 0x01 = H.264 video (AVCC NALUs, no Annex B start codes)
  type 0x02 = AAC-LC audio (raw frames, no ADTS header)
```

## Release Notes

See the [ExtendCast v1.0.0 release notes](docs/release-notes/v1.0.0.md).
Historical upstream notes (v5–v8) remain available in
[docs/release-notes/](docs/release-notes/).

## Support the Project

ExtendCast is free and open source.

The original BetterCast project accepts donations through
**[Whop](https://whop.com/bettercast/bettercast-donate/)**.

## Disclaimer

**USE AT YOUR OWN RISK.**

This software is provided "as is", without warranty of any kind, express or implied. We are not responsible for any damages to your devices, data loss, or other issues that may occur while using this application.

ExtendCast is fully open source. Users are encouraged to audit the code for
safety and security, report issues, and contribute fixes.

## License & Contribution

ExtendCast is licensed under the **GNU General Public License v3.0 (GPLv3)**.

### Why GPLv3?
We believe in the freedom of software and the collective benefit of open collaboration. We choose GPLv3 to specifically:
- **Prevent restrictive forks**: Anyone who modifies and distributes this code must also share their changes under the same license. You cannot take this open source project, modify it, and sell it as a closed-source product.
- **Encourage contribution**: We welcome contributions! By keeping the source open, we ensure that improvements benefit everyone.

We strongly encourage safety and transparency. If you are contributing, please ensure your code adheres to safety standards and respects user privacy.
