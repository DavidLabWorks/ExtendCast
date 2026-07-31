#pragma once

#include <algorithm>
#include <array>

namespace video_color {

enum class Range {
    unspecified,
    limited,
    full,
};

enum class Matrix {
    bt601,
    bt709,
};

enum class MatrixSignal {
    unspecified,
    bt601,
    bt709,
};

inline Matrix matrixForSignal(MatrixSignal signal) {
    return signal == MatrixSignal::bt601 ? Matrix::bt601 : Matrix::bt709;
}

struct Parameters {
    float yOffset;
    float yScale;
    float uvOffset;
    float uvScale;
    float redFromV;
    float greenFromU;
    float greenFromV;
    float blueFromU;
};

inline Parameters parametersFor(Range range, Matrix matrix) {
    const bool isFullRange = range == Range::full;
    const float yOffset = isFullRange ? 0.0f : 16.0f / 255.0f;
    const float yScale = isFullRange ? 1.0f : 255.0f / 219.0f;
    const float uvOffset = 128.0f / 255.0f;
    const float uvScale = isFullRange ? 1.0f : 255.0f / 224.0f;

    if (matrix == Matrix::bt709) {
        return {
            yOffset,
            yScale,
            uvOffset,
            uvScale,
            1.5748f,
            -0.187324f,
            -0.468124f,
            1.8556f,
        };
    }

    return {
        yOffset,
        yScale,
        uvOffset,
        uvScale,
        1.402f,
        -0.344136f,
        -0.714136f,
        1.772f,
    };
}

inline std::array<float, 3> convert(
    const Parameters& parameters,
    float y,
    float u,
    float v
) {
    const float normalizedY = (y - parameters.yOffset) * parameters.yScale;
    const float normalizedU = (u - parameters.uvOffset) * parameters.uvScale;
    const float normalizedV = (v - parameters.uvOffset) * parameters.uvScale;
    return {
        normalizedY + parameters.redFromV * normalizedV,
        normalizedY
            + parameters.greenFromU * normalizedU
            + parameters.greenFromV * normalizedV,
        normalizedY + parameters.blueFromU * normalizedU,
    };
}

inline float saturation(const std::array<float, 3>& rgb) {
    const auto [minimum, maximum] = std::minmax_element(rgb.begin(), rgb.end());
    return *maximum - *minimum;
}

} // namespace video_color
