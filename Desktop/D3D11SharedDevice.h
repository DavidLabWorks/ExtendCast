#pragma once

#ifdef _WIN32

#include <atomic>
#include <mutex>

struct ID3D11Device;
struct ID3D11DeviceContext;
struct AVBufferRef;

/// Process-wide D3D11 device shared by hardware decode and zero-copy present.
class D3D11SharedDevice {
public:
    static D3D11SharedDevice& instance();

    bool ensureCreated();
    bool isAvailable() const {
        return m_device != nullptr && !m_hardwareDecodeDisabled.load();
    }
    bool hardwareDecodeDisabled() const {
        return m_hardwareDecodeDisabled.load();
    }
    /// Permanently disables D3D decode/present until process restart.
    void markDeviceLost();
    /// Checks the device health and marks it lost when removal is reported.
    bool deviceIsLost();

    ID3D11Device* device() const { return m_device; }
    ID3D11DeviceContext* context() const { return m_context; }

    /// Serializes presenter work with FFmpeg's use of the immediate context.
    std::unique_lock<std::recursive_mutex> acquireContextLock();

    /// FFmpeg hwdevice ctx wrapping this device. Owned here; callers may av_buffer_ref.
    AVBufferRef* ffmpegHwDeviceCtx();

private:
    D3D11SharedDevice() = default;
    ~D3D11SharedDevice();
    D3D11SharedDevice(const D3D11SharedDevice&) = delete;
    D3D11SharedDevice& operator=(const D3D11SharedDevice&) = delete;

    bool createDevice();
    bool createFfmpegCtx();
    static void lockFfmpegContext(void* opaque);
    static void unlockFfmpegContext(void* opaque);

    ID3D11Device* m_device = nullptr;
    ID3D11DeviceContext* m_context = nullptr;
    AVBufferRef* m_ffmpegHwDeviceCtx = nullptr;
    std::atomic_bool m_hardwareDecodeDisabled{false};
    std::recursive_mutex m_contextMutex;
};

#endif  // _WIN32
