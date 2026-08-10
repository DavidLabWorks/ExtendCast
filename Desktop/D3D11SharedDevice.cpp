#ifdef _WIN32

#include "D3D11SharedDevice.h"
#include "MainWindow.h"

#include <d3d11.h>
#include <d3d10.h>
#include <dxgi.h>

extern "C" {
#include <libavutil/hwcontext.h>
#include <libavutil/hwcontext_d3d11va.h>
}

D3D11SharedDevice& D3D11SharedDevice::instance() {
    static D3D11SharedDevice device;
    return device;
}

D3D11SharedDevice::~D3D11SharedDevice() {
    if (m_ffmpegHwDeviceCtx) {
        av_buffer_unref(&m_ffmpegHwDeviceCtx);
        m_ffmpegHwDeviceCtx = nullptr;
    }
    if (m_context) {
        m_context->Release();
        m_context = nullptr;
    }
    if (m_device) {
        m_device->Release();
        m_device = nullptr;
    }
}

bool D3D11SharedDevice::ensureCreated() {
    if (m_hardwareDecodeDisabled.load()) {
        return false;
    }
    if (m_device) {
        return !m_hardwareDecodeDisabled.load();
    }
    if (!createDevice()) {
        return false;
    }
    if (!createFfmpegCtx()) {
        if (m_context) {
            m_context->Release();
            m_context = nullptr;
        }
        if (m_device) {
            m_device->Release();
            m_device = nullptr;
        }
        return false;
    }
    LogManager::instance().log("D3D11: Shared device ready for decode + present");
    return !m_hardwareDecodeDisabled.load();
}

bool D3D11SharedDevice::createDevice() {
    UINT flags = D3D11_CREATE_DEVICE_VIDEO_SUPPORT;
    // Avoid the debug layer in normal builds — missing D3D11SDKLayers.dll
    // can make CreateDevice fail or crash on some Surface images.
    D3D_FEATURE_LEVEL level = D3D_FEATURE_LEVEL_11_0;
    const HRESULT hr = D3D11CreateDevice(
        nullptr,
        D3D_DRIVER_TYPE_HARDWARE,
        nullptr,
        flags,
        nullptr,
        0,
        D3D11_SDK_VERSION,
        &m_device,
        &level,
        &m_context
    );
    if (FAILED(hr) || !m_device || !m_context) {
        LogManager::instance().log(
            QString("D3D11: CreateDevice failed hr=0x%1").arg(quint32(hr), 8, 16, QChar('0'))
        );
        m_device = nullptr;
        m_context = nullptr;
        return false;
    }

    // Multithread protection — decode and present share this device.
    ID3D10Multithread* multithread = nullptr;
    if (SUCCEEDED(m_device->QueryInterface(
            __uuidof(ID3D10Multithread),
            reinterpret_cast<void**>(&multithread)
        ))
        && multithread) {
        multithread->SetMultithreadProtected(TRUE);
        multithread->Release();
    }
    return true;
}

bool D3D11SharedDevice::createFfmpegCtx() {
    m_ffmpegHwDeviceCtx = av_hwdevice_ctx_alloc(AV_HWDEVICE_TYPE_D3D11VA);
    if (!m_ffmpegHwDeviceCtx) {
        return false;
    }

    auto* deviceCtx = reinterpret_cast<AVHWDeviceContext*>(m_ffmpegHwDeviceCtx->data);
    auto* d3d11 = static_cast<AVD3D11VADeviceContext*>(deviceCtx->hwctx);
    d3d11->device = m_device;
    m_device->AddRef();
    d3d11->device_context = m_context;
    m_context->AddRef();
    // FFmpeg and the presenter share one immediate context. Use one recursive
    // lock for both instead of FFmpeg's otherwise-private default mutex.
    d3d11->lock = &D3D11SharedDevice::lockFfmpegContext;
    d3d11->unlock = &D3D11SharedDevice::unlockFfmpegContext;
    d3d11->lock_ctx = this;

    if (av_hwdevice_ctx_init(m_ffmpegHwDeviceCtx) < 0) {
        LogManager::instance().log("D3D11: FFmpeg hwdevice_ctx_init failed");
        av_buffer_unref(&m_ffmpegHwDeviceCtx);
        return false;
    }
    return true;
}

AVBufferRef* D3D11SharedDevice::ffmpegHwDeviceCtx() {
    if (!ensureCreated()) {
        return nullptr;
    }
    return m_ffmpegHwDeviceCtx;
}

void D3D11SharedDevice::markDeviceLost() {
    if (!m_hardwareDecodeDisabled.exchange(true)) {
        LogManager::instance().log(
            "D3D11: Device lost — hardware decode disabled until restart"
        );
    }
}

bool D3D11SharedDevice::deviceIsLost() {
    if (m_hardwareDecodeDisabled.load()) {
        return true;
    }
    if (!m_device) {
        return false;
    }
    const HRESULT reason = m_device->GetDeviceRemovedReason();
    if (SUCCEEDED(reason)) {
        return false;
    }
    LogManager::instance().log(
        QString("D3D11: GetDeviceRemovedReason hr=0x%1")
            .arg(quint32(reason), 8, 16, QChar('0'))
    );
    markDeviceLost();
    return true;
}

std::unique_lock<std::recursive_mutex> D3D11SharedDevice::acquireContextLock() {
    return std::unique_lock<std::recursive_mutex>(m_contextMutex);
}

void D3D11SharedDevice::lockFfmpegContext(void* opaque) {
    static_cast<D3D11SharedDevice*>(opaque)->m_contextMutex.lock();
}

void D3D11SharedDevice::unlockFfmpegContext(void* opaque) {
    static_cast<D3D11SharedDevice*>(opaque)->m_contextMutex.unlock();
}

#endif  // _WIN32
