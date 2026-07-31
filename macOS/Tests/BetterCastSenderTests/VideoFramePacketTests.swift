import XCTest
@testable import BetterCastSender

final class VideoFramePacketTests: XCTestCase {
    func testTimestampNormalizerUsesAStreamRelativeMonotonicTimeline() {
        var normalizer = VideoTimestampNormalizer(expectedFPS: 60)

        XCTAssertEqual(normalizer.normalize(rawNanoseconds: 10_000_000_000), 0)
        XCTAssertEqual(
            normalizer.normalize(rawNanoseconds: 10_016_666_667),
            16_666_667
        )
    }

    func testTimestampNormalizerReanchorsWhenCaptureTimeMovesBackward() {
        var normalizer = VideoTimestampNormalizer(expectedFPS: 60)

        _ = normalizer.normalize(rawNanoseconds: 10_000_000_000)
        let beforeReset = normalizer.normalize(rawNanoseconds: 10_016_666_667)
        let resetFrame = normalizer.normalize(rawNanoseconds: 5_000_000_000)
        let nextFrame = normalizer.normalize(rawNanoseconds: 5_010_000_000)

        XCTAssertEqual(resetFrame, beforeReset + 16_666_667)
        XCTAssertEqual(nextFrame, resetFrame + 10_000_000)
    }

    func testTimestampNormalizerAdvancesInvalidTimestampsByOneFrame() {
        var normalizer = VideoTimestampNormalizer(expectedFPS: 30)

        XCTAssertEqual(normalizer.normalize(rawNanoseconds: nil), 0)
        let syntheticFrame = normalizer.normalize(rawNanoseconds: nil)
        let firstValidFrame = normalizer.normalize(
            rawNanoseconds: 10_000_000_000
        )
        let nextValidFrame = normalizer.normalize(
            rawNanoseconds: 10_010_000_000
        )

        XCTAssertEqual(syntheticFrame, 33_333_333)
        XCTAssertEqual(firstValidFrame, 66_666_666)
        XCTAssertEqual(nextValidFrame, 76_666_666)
    }

    func testVideoFrameUsesExplicitBigEndianHeader() {
        let frame = EncodedVideoFrame(
            streamID: 0x0102_0304_0506_0708,
            sequence: 0x1112_1314_1516_1718,
            presentationTimestampNanoseconds: 0x2122_2324_2526_2728,
            isKeyframe: true,
            avccData: Data([0xaa, 0xbb])
        )

        XCTAssertEqual(
            Array(frame.wirePayload),
            [
                0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
                0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18,
                0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28,
                EncodedVideoFrame.keyframeFlag,
                0xaa, 0xbb,
            ]
        )

        let header = VideoFramePacketHeader.decode(from: frame.wirePayload)
        XCTAssertEqual(header?.streamID, frame.streamID)
        XCTAssertEqual(header?.sequence, frame.sequence)
        XCTAssertEqual(
            header?.presentationTimestampNanoseconds,
            frame.presentationTimestampNanoseconds
        )
        XCTAssertEqual(header?.isKeyframe, true)
    }
}
