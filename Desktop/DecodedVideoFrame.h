#pragma once

#include "VideoColorConversion.h"

#include <QByteArray>
#include <QMetaType>

#include <cstdint>

struct DecodedVideoFrame {
    QByteArray yPlane;
    QByteArray uvPlane;
    int width = 0;
    int height = 0;
    std::uint64_t streamId = 0;
    std::uint64_t sequence = 0;
    std::uint64_t presentationTimestampNanoseconds = 0;
    video_color::Parameters colorParameters = video_color::parametersFor(
        video_color::Range::unspecified,
        video_color::Matrix::bt709
    );
};

Q_DECLARE_METATYPE(DecodedVideoFrame)
