#pragma once

#ifdef _WIN32

struct ID3D11Device;
struct ID3D11DeviceContext;
struct AVBufferRef;

/// Process-wide D3D11 device shared by hardware decode and zero-copy present.
class D3D11SharedDevice {
public:
    static D3D11SharedDevice& instance();

    bool ensureCreated();
    bool isAvailable() const { return m_device != nullptr; }

    ID3D11Device* device() const { return m_device; }
    ID3D11DeviceContext* context() const { return m_context; }

    /// FFmpeg hwdevice ctx wrapping this device. Owned here; callers may av_buffer_ref.
    AVBufferRef* ffmpegHwDeviceCtx();

private:
    D3D11SharedDevice() = default;
    ~D3D11SharedDevice();
    D3D11SharedDevice(const D3D11SharedDevice&) = delete;
    D3D11SharedDevice& operator=(const D3D11SharedDevice&) = delete;

    bool createDevice();
    bool createFfmpegCtx();

    ID3D11Device* m_device = nullptr;
    ID3D11DeviceContext* m_context = nullptr;
    AVBufferRef* m_ffmpegHwDeviceCtx = nullptr;
};

#endif  // _WIN32
