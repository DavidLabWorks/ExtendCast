#include "../VideoPacket.h"
#include "../ReceiverRouteClassifier.h"

#include <cassert>
#include <cstdint>
#include <iostream>
#include <vector>

using video_packet::LivePosition;
using video_packet::planTcpVideoCatchUp;

namespace {

void appendBigEndianUInt32(
    std::vector<std::uint8_t>& bytes,
    std::uint32_t value
) {
    bytes.push_back(static_cast<std::uint8_t>(value >> 24));
    bytes.push_back(static_cast<std::uint8_t>(value >> 16));
    bytes.push_back(static_cast<std::uint8_t>(value >> 8));
    bytes.push_back(static_cast<std::uint8_t>(value));
}

std::size_t appendVideoPacket(
    std::vector<std::uint8_t>& bytes,
    std::uint64_t streamId,
    std::uint64_t sequence,
    std::uint64_t pts,
    bool isKeyframe
) {
    const std::size_t packetOffset = bytes.size();
    constexpr std::uint32_t avccSize = 2;
    constexpr std::uint32_t bodySize =
        1 + video_packet::headerSize + avccSize;

    appendBigEndianUInt32(bytes, bodySize);
    bytes.push_back(0x01);
    const std::size_t headerOffset = bytes.size();
    bytes.resize(headerOffset + video_packet::headerSize);
    video_packet::writeBigEndianUInt64(
        bytes.data() + headerOffset,
        streamId
    );
    video_packet::writeBigEndianUInt64(
        bytes.data() + headerOffset + 8,
        sequence
    );
    video_packet::writeBigEndianUInt64(
        bytes.data() + headerOffset + 16,
        pts
    );
    bytes[headerOffset + 24] =
        isKeyframe ? video_packet::keyframeFlag : 0;
    bytes.push_back(0x00);
    bytes.push_back(0x01);
    return packetOffset;
}

constexpr std::uint64_t milliseconds(std::uint64_t value) {
    return value * 1'000'000;
}

constexpr std::uint64_t maximumDelay = milliseconds(500);
constexpr std::uint64_t preferredDelay = milliseconds(150);
constexpr std::uint32_t maximumPacketSize = 8 * 1024 * 1024;

} // namespace

int main() {
    {
        std::vector<std::uint8_t> buffer;
        appendVideoPacket(buffer, 7, 0, milliseconds(0), true);
        appendVideoPacket(buffer, 7, 1, milliseconds(200), false);

        const auto decision = planTcpVideoCatchUp(
            buffer.data(),
            buffer.size(),
            preferredDelay,
            maximumDelay,
            maximumPacketSize
        );

        assert(decision.discardBytes == 0);
        assert(!decision.resetDecoder);
        assert(!decision.requestKeyframe);
    }

    {
        std::vector<std::uint8_t> buffer;
        appendVideoPacket(buffer, 7, 0, milliseconds(0), true);
        appendVideoPacket(buffer, 7, 1, milliseconds(100), false);
        const std::size_t completePacketBytes = buffer.size();
        appendBigEndianUInt32(buffer, 100);
        buffer.push_back(0x01);

        const auto decision = planTcpVideoCatchUp(
            buffer.data(),
            buffer.size(),
            preferredDelay,
            maximumDelay,
            maximumPacketSize,
            LivePosition{7, milliseconds(800)}
        );

        assert(decision.discardBytes == completePacketBytes);
        assert(decision.resetDecoder);
        assert(decision.requestKeyframe);
        assert(decision.bufferedDurationNanoseconds == milliseconds(800));
    }

    {
        std::vector<std::uint8_t> buffer;
        appendVideoPacket(buffer, 7, 0, milliseconds(0), true);
        appendVideoPacket(buffer, 7, 1, milliseconds(60), false);

        const auto decision = planTcpVideoCatchUp(
            buffer.data(),
            buffer.size(),
            preferredBufferedVideoNanosecondsFor(
                ReceiverAdvertisedRoute::thunderbolt
            ),
            maximumDelay,
            maximumPacketSize,
            LivePosition{7, milliseconds(60)}
        );

        assert(decision.discardBytes == 0);
        assert(!decision.resetDecoder);
        assert(!decision.requestKeyframe);
    }

    {
        std::vector<std::uint8_t> buffer;
        appendVideoPacket(buffer, 7, 0, milliseconds(0), true);
        appendVideoPacket(buffer, 7, 1, milliseconds(480), false);

        const auto decision = planTcpVideoCatchUp(
            buffer.data(),
            buffer.size(),
            preferredBufferedVideoNanosecondsFor(
                ReceiverAdvertisedRoute::thunderbolt
            ),
            maximumDelay,
            maximumPacketSize,
            LivePosition{7, milliseconds(480)}
        );

        assert(decision.discardBytes == 0);
        assert(!decision.resetDecoder);
        assert(!decision.requestKeyframe);
    }

    {
        std::vector<std::uint8_t> buffer;
        appendVideoPacket(buffer, 7, 0, milliseconds(0), true);
        for (std::uint64_t sequence = 1; sequence <= 10; ++sequence) {
            appendVideoPacket(
                buffer,
                7,
                sequence,
                milliseconds(sequence * 20),
                false
            );
        }

        const auto decision = planTcpVideoCatchUp(
            buffer.data(),
            buffer.size(),
            preferredBufferedVideoNanosecondsFor(
                ReceiverAdvertisedRoute::thunderbolt
            ),
            maximumDelay,
            maximumPacketSize
        );

        assert(decision.discardBytes == 0);
        assert(!decision.resetDecoder);
        assert(!decision.requestKeyframe);
    }

    {
        std::vector<std::uint8_t> buffer;
        appendVideoPacket(buffer, 7, 0, milliseconds(0), true);
        appendVideoPacket(buffer, 7, 1, milliseconds(600), false);

        const auto decision = planTcpVideoCatchUp(
            buffer.data(),
            buffer.size(),
            preferredDelay,
            maximumDelay,
            maximumPacketSize,
            LivePosition{7, milliseconds(600)}
        );

        assert(decision.discardBytes == buffer.size());
        assert(decision.resetDecoder);
        assert(decision.requestKeyframe);
    }

    {
        std::vector<std::uint8_t> buffer;
        appendVideoPacket(buffer, 7, 0, milliseconds(0), true);
        appendVideoPacket(buffer, 7, 1, milliseconds(100), false);
        const std::size_t preferredKeyframeOffset =
            appendVideoPacket(buffer, 7, 2, milliseconds(180), true);
        appendVideoPacket(buffer, 7, 3, milliseconds(200), false);

        const auto decision = planTcpVideoCatchUp(
            buffer.data(),
            buffer.size(),
            preferredDelay,
            maximumDelay,
            maximumPacketSize
        );

        assert(decision.discardBytes == preferredKeyframeOffset);
        assert(decision.resetDecoder);
        assert(!decision.requestKeyframe);
    }

    {
        std::vector<std::uint8_t> buffer;
        appendVideoPacket(buffer, 7, 0, milliseconds(0), true);
        appendVideoPacket(buffer, 7, 1, milliseconds(300), false);
        const std::size_t liveKeyframeOffset =
            appendVideoPacket(buffer, 7, 2, milliseconds(700), true);
        appendVideoPacket(buffer, 7, 3, milliseconds(800), false);

        const auto decision = planTcpVideoCatchUp(
            buffer.data(),
            buffer.size(),
            preferredDelay,
            maximumDelay,
            maximumPacketSize
        );

        assert(decision.discardBytes == liveKeyframeOffset);
        assert(decision.resetDecoder);
        assert(!decision.requestKeyframe);
    }

    {
        std::vector<std::uint8_t> buffer;
        appendVideoPacket(buffer, 7, 20, milliseconds(5'000), false);
        const std::size_t restartedStreamOffset =
            appendVideoPacket(buffer, 8, 0, milliseconds(5'010), true);
        appendVideoPacket(buffer, 8, 1, milliseconds(5'026), false);

        const auto decision = planTcpVideoCatchUp(
            buffer.data(),
            buffer.size(),
            preferredDelay,
            maximumDelay,
            maximumPacketSize,
            LivePosition{7, milliseconds(5'030)}
        );

        assert(decision.discardBytes == restartedStreamOffset);
        assert(!decision.resetDecoder);
        assert(!decision.requestKeyframe);
    }

    {
        std::vector<std::uint8_t> buffer;
        appendVideoPacket(buffer, 8, 0, milliseconds(0), true);

        const auto decision = planTcpVideoCatchUp(
            buffer.data(),
            buffer.size(),
            preferredDelay,
            maximumDelay,
            maximumPacketSize,
            LivePosition{7, milliseconds(10'000)}
        );

        assert(decision.discardBytes == 0);
        assert(!decision.resetDecoder);
        assert(!decision.requestKeyframe);
    }

    {
        std::vector<std::uint8_t> buffer;
        appendVideoPacket(buffer, 7, 40, milliseconds(5'000), false);
        const std::size_t resetKeyframeOffset =
            appendVideoPacket(buffer, 7, 41, milliseconds(0), true);

        const auto decision = planTcpVideoCatchUp(
            buffer.data(),
            buffer.size(),
            preferredDelay,
            maximumDelay,
            maximumPacketSize,
            LivePosition{7, milliseconds(5'020)}
        );

        assert(decision.discardBytes == resetKeyframeOffset);
        assert(decision.resetDecoder);
        assert(!decision.requestKeyframe);
    }

    {
        std::vector<std::uint8_t> buffer;
        appendVideoPacket(buffer, 8, 1, milliseconds(16), false);
        appendVideoPacket(buffer, 8, 2, milliseconds(32), false);

        const auto decision = planTcpVideoCatchUp(
            buffer.data(),
            buffer.size(),
            preferredDelay,
            maximumDelay,
            maximumPacketSize,
            LivePosition{7, milliseconds(10'000)}
        );

        assert(decision.discardBytes == buffer.size());
        assert(decision.resetDecoder);
        assert(decision.requestKeyframe);
    }

    std::cout << "Video packet tests passed\n";
}
