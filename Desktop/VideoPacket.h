#pragma once

#include <cstddef>
#include <cstdint>
#include <optional>

namespace video_packet {

constexpr std::size_t headerSize = 25;
constexpr std::uint8_t keyframeFlag = 0x01;

struct Header {
    std::uint64_t streamId = 0;
    std::uint64_t sequence = 0;
    std::uint64_t presentationTimestampNanoseconds = 0;
    bool isKeyframe = false;
};

struct LivePosition {
    std::uint64_t streamId;
    std::uint64_t expectedPresentationTimestampNanoseconds;
};

struct CatchUpDecision {
    std::size_t discardBytes = 0;
    std::uint64_t bufferedDurationNanoseconds = 0;
    bool resetDecoder = false;
    bool requestKeyframe = false;
    /// When set, receiver should re-anchor its live clock to this PTS so a
    /// kept in-band IDR is not immediately treated as stale again.
    std::optional<LivePosition> resumeLivePosition;
};

inline std::uint32_t readBigEndianUInt32(const std::uint8_t* data) {
    return
        (static_cast<std::uint32_t>(data[0]) << 24)
        | (static_cast<std::uint32_t>(data[1]) << 16)
        | (static_cast<std::uint32_t>(data[2]) << 8)
        | static_cast<std::uint32_t>(data[3]);
}

inline std::uint64_t readBigEndianUInt64(const std::uint8_t* data) {
    std::uint64_t value = 0;
    for (int index = 0; index < 8; ++index) {
        value = (value << 8) | data[index];
    }
    return value;
}

inline void writeBigEndianUInt64(
    std::uint8_t* destination,
    std::uint64_t value
) {
    for (int index = 7; index >= 0; --index) {
        destination[index] = static_cast<std::uint8_t>(value);
        value >>= 8;
    }
}

inline bool parseHeader(
    const std::uint8_t* payload,
    std::size_t payloadSize,
    Header& header
) {
    if (payloadSize < headerSize) {
        return false;
    }
    header.streamId = readBigEndianUInt64(payload);
    header.sequence = readBigEndianUInt64(payload + 8);
    header.presentationTimestampNanoseconds =
        readBigEndianUInt64(payload + 16);
    header.isKeyframe = (payload[24] & keyframeFlag) != 0;
    return true;
}

inline CatchUpDecision planTcpVideoCatchUp(
    const std::uint8_t* tcpBuffer,
    std::size_t tcpBufferSize,
    std::uint64_t preferredBufferedDurationNanoseconds,
    std::uint64_t maximumBufferedDurationNanoseconds,
    std::uint32_t maximumPacketSize,
    std::optional<LivePosition> livePosition = std::nullopt
) {
    std::optional<Header> firstVideoHeader;
    std::optional<Header> newestVideoHeader;
    std::optional<std::size_t> firstVideoPacketOffset;
    std::optional<std::size_t> newestStreamKeyframeOffset;
    std::optional<Header> newestStreamKeyframeHeader;

    std::size_t packetOffset = 0;
    while (packetOffset + 4 <= tcpBufferSize) {
        const std::uint32_t bodySize =
            readBigEndianUInt32(tcpBuffer + packetOffset);
        if (bodySize > maximumPacketSize) {
            break;
        }

        const std::size_t packetSize = 4 + bodySize;
        if (packetSize > tcpBufferSize - packetOffset) {
            break;
        }

        const std::uint8_t* body = tcpBuffer + packetOffset + 4;
        constexpr std::size_t typeSize = 1;
        Header header;
        if (bodySize >= typeSize + headerSize
            && body[0] == 0x01
            && parseHeader(body + typeSize, bodySize - typeSize, header)) {
            if (!firstVideoHeader.has_value()) {
                firstVideoHeader = header;
                firstVideoPacketOffset = packetOffset;
            }
            if (newestVideoHeader.has_value()
                && newestVideoHeader->streamId != header.streamId) {
                newestStreamKeyframeOffset.reset();
                newestStreamKeyframeHeader.reset();
            }
            newestVideoHeader = header;
            if (header.isKeyframe) {
                newestStreamKeyframeOffset = packetOffset;
                newestStreamKeyframeHeader = header;
            }
        }

        packetOffset += packetSize;
    }

    CatchUpDecision decision;
    if (!firstVideoHeader.has_value() || !newestVideoHeader.has_value()) {
        return decision;
    }

    const bool bufferedStreamChanged =
        firstVideoHeader->streamId != newestVideoHeader->streamId;
    const bool currentStreamChanged =
        livePosition.has_value()
        && livePosition->streamId != firstVideoHeader->streamId;
    const bool timestampReset =
        !bufferedStreamChanged
        && newestVideoHeader->presentationTimestampNanoseconds
            < firstVideoHeader->presentationTimestampNanoseconds;

    const bool streamIsContinuous =
        !bufferedStreamChanged && !currentStreamChanged && !timestampReset;
    if (streamIsContinuous) {
        decision.bufferedDurationNanoseconds =
            newestVideoHeader->presentationTimestampNanoseconds
            - firstVideoHeader->presentationTimestampNanoseconds;
        if (livePosition.has_value()
            && livePosition->expectedPresentationTimestampNanoseconds
                > firstVideoHeader->presentationTimestampNanoseconds) {
            const std::uint64_t liveDelay =
                livePosition->expectedPresentationTimestampNanoseconds
                - firstVideoHeader->presentationTimestampNanoseconds;
            if (liveDelay > decision.bufferedDurationNanoseconds) {
                decision.bufferedDurationNanoseconds = liveDelay;
            }
        }
        if (decision.bufferedDurationNanoseconds
            <= preferredBufferedDurationNanoseconds) {
            return decision;
        }
    }

    const bool hardLimitExceeded =
        !streamIsContinuous
        || decision.bufferedDurationNanoseconds
            > maximumBufferedDurationNanoseconds;
    const bool keyframeAdvancesPlayback =
        newestStreamKeyframeOffset.has_value()
        && (*newestStreamKeyframeOffset > *firstVideoPacketOffset
            || bufferedStreamChanged
            || currentStreamChanged
            || timestampReset);
    // When live delay alone trips the hard limit, an already-buffered IDR is
    // still a usable resume point — even if it is the oldest packet. Dropping
    // it and requesting another IDR is what creates the evening catch-up spiral.
    if (keyframeAdvancesPlayback
        || (hardLimitExceeded && newestStreamKeyframeOffset.has_value())) {
        decision.discardBytes = *newestStreamKeyframeOffset;
        // Skip to an in-band IDR without tearing the decoder down. Stream-ID
        // changes are handled when the kept keyframe is decoded.
        decision.resetDecoder = false;
        if (newestStreamKeyframeHeader.has_value()) {
            decision.resumeLivePosition = LivePosition{
                newestStreamKeyframeHeader->streamId,
                newestStreamKeyframeHeader->presentationTimestampNanoseconds,
            };
        }
        return decision;
    }

    // A normal network burst may exceed the preferred latency budget before
    // it contains a newer keyframe. Keep decoding until the hard limit rather
    // than resetting a healthy stream during startup or routine batching.
    if (!hardLimitExceeded) {
        return decision;
    }

    // No safe resume point exists in the buffered data. Drop every complete
    // packet already inspected and wait for a freshly requested keyframe.
    decision.discardBytes = packetOffset;
    decision.resetDecoder = true;
    decision.requestKeyframe = true;
    return decision;
}

} // namespace video_packet
