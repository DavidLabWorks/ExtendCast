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

    func testSeverePlaybackLagCanReduceCaptureBelowThirtyFPS() {
        let controller = StreamFeedbackController(maximumFPS: 60)
        controller.noteEncodedFrame(
            streamID: 7,
            timestampNanoseconds: 1_000_000_000
        )
        controller.notePresentedFrame(
            streamID: 7,
            timestampNanoseconds: 100_000_000
        )

        XCTAssertEqual(controller.targetFPS, 15)
    }

    func testExtremePlaybackLagUsesRecoveryFrameRate() {
        let controller = StreamFeedbackController(maximumFPS: 60)
        controller.noteEncodedFrame(
            streamID: 7,
            timestampNanoseconds: 2_100_000_000
        )
        controller.notePresentedFrame(
            streamID: 7,
            timestampNanoseconds: 100_000_000
        )

        XCTAssertEqual(controller.targetFPS, 10)
    }

    func testLagFloorCannotRaiseTargetFPSWithoutRecoveryWindow() {
        let controller = StreamFeedbackController(maximumFPS: 60)
        controller.noteEncodedFrame(streamID: 7, timestampNanoseconds: 2_100_000_000)
        controller.notePresentedFrame(streamID: 7, timestampNanoseconds: 100_000_000)
        XCTAssertEqual(controller.targetFPS, 10)

        // Momentary improvement still above the recovery threshold must not
        // jump back toward the maximum — that was the 15↔45 oscillation.
        controller.noteEncodedFrame(streamID: 7, timestampNanoseconds: 2_300_000_000)
        controller.notePresentedFrame(
            streamID: 7,
            timestampNanoseconds: 2_100_000_000,
            nowNanoseconds: 1_000_000_000
        )
        XCTAssertEqual(controller.targetFPS, 10)
    }

    func testRecoveryRaisesFPSOnlyAfterSustainedLowLag() {
        let controller = StreamFeedbackController(maximumFPS: 60)
        controller.noteEncodedFrame(streamID: 7, timestampNanoseconds: 1_000_000_000)
        controller.notePresentedFrame(streamID: 7, timestampNanoseconds: 100_000_000)
        XCTAssertEqual(controller.targetFPS, 15)

        controller.noteEncodedFrame(streamID: 7, timestampNanoseconds: 1_050_000_000)
        controller.notePresentedFrame(
            streamID: 7,
            timestampNanoseconds: 1_000_000_000,
            nowNanoseconds: 5_000_000_000
        )
        XCTAssertEqual(controller.targetFPS, 15)

        controller.notePresentedFrame(
            streamID: 7,
            timestampNanoseconds: 1_020_000_000,
            nowNanoseconds: 7_000_000_000
        )
        XCTAssertEqual(controller.targetFPS, 30)
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
