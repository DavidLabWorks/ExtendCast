#include "HardwareDecodeSupport.h"

#ifdef _WIN32
#include "D3D11SharedDevice.h"
#endif

extern "C" {
#include <libavutil/hwcontext.h>
}

bool hardwareH264DecodeAvailable() {
#ifdef _WIN32
    auto& shared = D3D11SharedDevice::instance();
    if (shared.hardwareDecodeDisabled()) {
        return false;
    }
    static const bool available = []() {
        if (D3D11SharedDevice::instance().ensureCreated()) {
            return true;
        }
        AVBufferRef* device = nullptr;
        const int ret = av_hwdevice_ctx_create(
            &device,
            AV_HWDEVICE_TYPE_D3D11VA,
            nullptr,
            nullptr,
            0
        );
        if (ret < 0 || !device) {
            return false;
        }
        av_buffer_unref(&device);
        return true;
    }();
    return available && !shared.hardwareDecodeDisabled();
#else
    return false;
#endif
}
