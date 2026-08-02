import XCTest
@testable import BetterCastSender

final class StreamFeedbackControllerTests: XCTestCase {
    func testSustainedPlaybackLagReducesCaptureRateBeforeEncoding() {
        let controller = StreamFeedbackController(maximumFPS: 60)
        controller.noteEncodedFrame(streamID: 7, timestampNanoseconds: 600_000_000)
        controller.notePresentedFrame(streamID: 7, timestampNanoseconds: 100_000_000)

        XCTAssertEqual(controller.targetFPS, 30)
    }

    func testAcknowledgementFromOldStreamCannotThrottleNewStream() {
        let controller = StreamFeedbackController(maximumFPS: 60)
        controller.noteEncodedFrame(streamID: 8, timestampNanoseconds: 600_000_000)
        controller.notePresentedFrame(streamID: 7, timestampNanoseconds: 100_000_000)

        XCTAssertEqual(controller.targetFPS, 60)
    }

    func testAdmissionDropsRawFramesToConfiguredTargetRate() {
        let controller = StreamFeedbackController(maximumFPS: 60)
        controller.noteEncodedFrame(streamID: 7, timestampNanoseconds: 600_000_000)
        controller.notePresentedFrame(streamID: 7, timestampNanoseconds: 100_000_000)

        var admitted = 0
        for frame in 0..<60 {
            if controller.shouldEncodeFrame(
                nowNanoseconds: UInt64(frame) * 16_666_667
            ) {
                admitted += 1
            }
        }

        XCTAssertEqual(admitted, 30)
    }
}
