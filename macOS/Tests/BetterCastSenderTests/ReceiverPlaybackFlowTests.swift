import XCTest
@testable import BetterCastSender

final class ReceiverPlaybackFlowTests: XCTestCase {
    func testSlowDisplayKeepsOnlyTheLatestDecodedFrame() {
        let mailbox = LatestFrameMailbox<Int>()

        for frame in 1...600 {
            mailbox.replace(with: frame)
            XCTAssertEqual(mailbox.pendingCount, 1)

            if frame % 4 != 0 {
                XCTAssertEqual(mailbox.take(), frame)
            }
        }

        XCTAssertEqual(mailbox.take(), 600)
        XCTAssertEqual(mailbox.pendingCount, 0)
    }

    func testPlaybackAcknowledgementIsNeverRepeated() {
        let acknowledgement = InputEvent(type: .command, keyCode: 666)
        let keyframeRequest = InputEvent(type: .command, keyCode: 999)

        XCTAssertEqual(
            ReceiverNetworkListener.transmissionRepeatCount(
                for: acknowledgement
            ),
            1
        )
        XCTAssertEqual(
            ReceiverNetworkListener.transmissionRepeatCount(
                for: keyframeRequest
            ),
            3
        )
    }
}
