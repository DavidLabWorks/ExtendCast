# ExtendCast Desktop — Build Instructions

Cross-platform C++ receiver for Windows and Linux.

## Prerequisites

### Windows
1. **Qt 6.5+** — Install via [Qt Online Installer](https://www.qt.io/download-qt-installer)
   - Select: Qt 6.x → MSVC 2019/2022 64-bit, Qt OpenGL Widgets
2. **FFmpeg** — Install via [vcpkg](https://vcpkg.io/) or pre-built binaries
   ```powershell
   vcpkg install ffmpeg:x64-windows
   ```
3. **CMake 3.20+** — Included with Visual Studio or install separately
4. **Visual Studio 2022** (Community edition is fine) — C++ Desktop workload
5. **(Optional) Bonjour SDK** — For mDNS auto-discovery
   - Install [Bonjour SDK for Windows](https://developer.apple.com/bonjour/)

### Linux
1. **Qt 6.5+**
   ```bash
   sudo apt install qt6-base-dev qt6-opengl-dev  # Debian/Ubuntu
   ```
2. **FFmpeg**
   ```bash
   sudo apt install libavcodec-dev libavutil-dev libswscale-dev
   ```
3. **Avahi** (for mDNS)
   ```bash
   sudo apt install libavahi-compat-libdnssd-dev
   ```
4. **CMake 3.20+**
   ```bash
   sudo apt install cmake
   ```

## Build

### Windows (Visual Studio)
```powershell
$buildDir = "D:/Temp/ExtendCast/windows-build"
New-Item -ItemType Directory -Force $buildDir | Out-Null

# If using vcpkg for FFmpeg:
cmake -S . -B $buildDir `
      -DCMAKE_PREFIX_PATH="C:/Qt/6.7.0/msvc2019_64" `
      -DCMAKE_TOOLCHAIN_FILE="C:/vcpkg/scripts/buildsystems/vcpkg.cmake" `
      -DBONJOUR_SDK_HOME="C:/Program Files/Bonjour SDK"

cmake --build $buildDir --config Release
```

### Windows package (portable + installer)

Always use `package-windows.ps1` after a Release build. It **requires** bundling the
MSVC CRT (`VCRUNTIME140.dll`, etc.) and `vc_redist.x64.exe` — packaging fails if
they cannot be found.

```powershell
# Portable folder only
.\package-windows.ps1 `
  -BuildDir "D:/Temp/ExtendCast/windows-build" `
  -OutDir "D:/ExtendCast/Windows-x64" `
  -QtBin "C:/Qt/6.7.0/msvc2019_64/bin"

# Portable + NSIS installer
.\package-windows.ps1 `
  -BuildDir "D:/Temp/ExtendCast/windows-build" `
  -OutDir "D:/ExtendCast/Windows-x64" `
  -QtBin "C:/Qt/6.7.0/msvc2019_64/bin" `
  -Installer `
  -InstallerOut "D:/ExtendCast/ExtendCast-Setup-1.0.0.exe"
```

Needs NSIS (`makensis`) on PATH when using `-Installer`.

### Linux
```bash
mkdir build && cd build
cmake ..
cmake --build . -j$(nproc)
```

### macOS (for development/testing only)
```bash
brew install qt@6 ffmpeg
mkdir build && cd build
cmake .. -DCMAKE_PREFIX_PATH=$(brew --prefix qt@6)
cmake --build .
```

## Usage

1. Run `ExtendCast.exe` on Windows or `BetterCastReceiver` on Linux
2. On the Mac sender, the receiver should appear via Bonjour auto-discovery
3. If auto-discovery doesn't work, use manual connect:
   - Enter the Mac sender's IP and port (default: 51820) in the receiver UI
   - Click "Connect"

## Architecture

```
main.cpp            → App entry point, OpenGL setup
MainWindow          → Qt window with connect UI + video display
NetworkListener     → TCP/UDP networking (same protocol as Swift receiver)
VideoDecoder       → FFmpeg H.264 decode (D3D11VA when available)
D3D11VideoPresenter → Zero-copy NV12 present on Windows (GPU blit, no CPU round-trip)
VideoRenderer       → OpenGL YUV→RGB rendering fallback with aspect-ratio letterboxing
InputHandler        → Mouse/keyboard capture → normalized coordinates → JSON
ServiceDiscovery    → mDNS advertising (Bonjour on Windows, Avahi on Linux)
InputEvent          → Data model matching Swift InputEvent exactly
```

## Windows D3D11 presentation and recovery

On supported Windows systems, FFmpeg D3D11VA decode and the zero-copy
presenter share one D3D11 device. Access to the immediate context is serialized
between FFmpeg and the presenter; decoded NV12 textures remain on the GPU for
the normal presentation path.

The receiver uses a stability-first fallback policy:

- A presenter or swap-chain failure that does not remove the D3D device falls
  back to the OpenGL presenter. Hardware decode may continue, with frames
  transferred to system memory for OpenGL rendering.
- A removed, reset, hung, or internally failed D3D device disables D3D decode
  and presentation for the rest of the process lifetime. Active sessions clear
  queued frames, reopen the H.264 decoder in software, wait for a fresh IDR,
  and then resume through OpenGL.
- Playback acknowledgement is emitted only after `Present` succeeds and the
  frame is not reported as occluded. A dropped or failed presentation is never
  acknowledged as displayed.
- Restart ExtendCast to attempt hardware decode again after a device-loss
  fallback. The process does not hot-recreate the shared device because old
  FFmpeg frame references may still be alive.

Set `EXTENDCAST_DISABLE_ZERO_COPY=1` before starting the receiver to exercise
the OpenGL presentation path without disabling D3D11VA hardware decode.

After changing this path, validate a Windows Release build with normal playback,
window resizing, fullscreen enter/exit, the environment-variable fallback, and
at least one device-loss or forced software-decode recovery scenario.
