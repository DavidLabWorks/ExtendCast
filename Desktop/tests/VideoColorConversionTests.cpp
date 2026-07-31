#include "../VideoColorConversion.h"

#include <array>
#include <cassert>
#include <cmath>
#include <iostream>

namespace {

using RGB8 = std::array<int, 3>;
using YUV8 = std::array<int, 3>;

YUV8 encodeLimitedBT601(const RGB8& rgb) {
    const auto [red, green, blue] = rgb;
    return {
        ((66 * red + 129 * green + 25 * blue + 128) >> 8) + 16,
        ((-38 * red - 74 * green + 112 * blue + 128) >> 8) + 128,
        ((112 * red - 94 * green - 18 * blue + 128) >> 8) + 128,
    };
}

YUV8 encodeLimitedBT709(const RGB8& rgb) {
    const auto [red, green, blue] = rgb;
    const double normalizedRed = red / 255.0;
    const double normalizedGreen = green / 255.0;
    const double normalizedBlue = blue / 255.0;
    return {
        static_cast<int>(std::lround(
            16.0 + 219.0 * (
                0.2126 * normalizedRed
                + 0.7152 * normalizedGreen
                + 0.0722 * normalizedBlue
            )
        )),
        static_cast<int>(std::lround(
            128.0 + 224.0 * (
                -0.114572 * normalizedRed
                - 0.385428 * normalizedGreen
                + 0.5 * normalizedBlue
            )
        )),
        static_cast<int>(std::lround(
            128.0 + 224.0 * (
                0.5 * normalizedRed
                - 0.454153 * normalizedGreen
                - 0.045847 * normalizedBlue
            )
        )),
    };
}

void expectVividPrimary(
    video_color::Range range,
    video_color::Matrix matrix,
    const YUV8& encoded,
    const RGB8& primary
) {
    const auto parameters = video_color::parametersFor(
        range,
        matrix
    );
    const auto decoded = video_color::convert(
        parameters,
        encoded[0] / 255.0f,
        encoded[1] / 255.0f,
        encoded[2] / 255.0f
    );

    assert(video_color::saturation(decoded) > 0.98f);
    for (int index = 0; index < 3; ++index) {
        const float expected = primary[index] / 255.0f;
        assert(std::abs(decoded[index] - expected) < 0.025f);
    }
}

} // namespace

int main() {
    assert(video_color::matrixForSignal(
        video_color::MatrixSignal::unspecified
    ) == video_color::Matrix::bt709);
    assert(video_color::matrixForSignal(
        video_color::MatrixSignal::bt601
    ) == video_color::Matrix::bt601);
    assert(video_color::matrixForSignal(
        video_color::MatrixSignal::bt709
    ) == video_color::Matrix::bt709);

    for (const auto& primary : {
             RGB8{255, 0, 0},
             RGB8{0, 255, 0},
             RGB8{0, 0, 255},
         }) {
        const auto bt601 = encodeLimitedBT601(primary);
        expectVividPrimary(
            video_color::Range::limited,
            video_color::Matrix::bt601,
            bt601,
            primary
        );
        expectVividPrimary(
            video_color::Range::unspecified,
            video_color::Matrix::bt601,
            bt601,
            primary
        );

        expectVividPrimary(
            video_color::Range::limited,
            video_color::Matrix::bt709,
            encodeLimitedBT709(primary),
            primary
        );
    }

    std::cout << "Video color conversion tests passed\n";
    return 0;
}
