#pragma once

#include "VideoColorConversion.h"

#include <QMetaType>

#include <cstdint>
#include <memory>

struct AVFrame;
struct ID3D11Texture2D;

/// GPU-resident NV12 frame. `anchor` keeps the FFmpeg surface alive until present.
struct HardwareVideoFrame {
    std::shared_ptr<AVFrame> anchor;
    ID3D11Texture2D* texture = nullptr;
    int textureIndex = 0;
    int width = 0;
    int height = 0;
    std::uint64_t streamId = 0;
    std::uint64_t sequence = 0;
    std::uint64_t presentationTimestampNanoseconds = 0;
    video_color::Parameters colorParameters = video_color::parametersFor(
        video_color::Range::unspecified,
        video_color::Matrix::bt709
    );

    bool isValid() const {
        return anchor != nullptr && texture != nullptr && width > 0 && height > 0;
    }
};

Q_DECLARE_METATYPE(HardwareVideoFrame)
