import XCTest
@testable import BetterCastSender

@MainActor
final class SessionResumeRecoveryTests: XCTestCase {
    func testLongLockDoesNotTimeOutReceiverConnection() {
        let now = Date()

        XCTAssertFalse(
            NetworkClient.receiverConnectionHasTimedOut(
                lastHeartbeat: now.addingTimeInterval(-600),
                now: now,
                pathIsViable: true,
                sessionIsSuspended: true
            )
        )
    }

    func testUnlockRestartsCaptureWithoutRecreatingVirtualDisplay() {
        XCTAssertEqual(
            NetworkClient.sessionResumeRecoveryAction(usesVirtualDisplay: true),
            .restartCapture
        )
        XCTAssertEqual(
            NetworkClient.sessionResumeRecoveryAction(usesVirtualDisplay: false),
            .restartCapture
        )
    }

    func testLaterWakeSignalCannotDelayImmediateUnlockRecovery() {
        let now = Date()

        XCTAssertTrue(
            NetworkClient.shouldScheduleSessionRecovery(
                scheduledDeadline: now.addingTimeInterval(3),
                proposedDeadline: now
            )
        )
        XCTAssertFalse(
            NetworkClient.shouldScheduleSessionRecovery(
                scheduledDeadline: now,
                proposedDeadline: now.addingTimeInterval(3)
            )
        )
    }
}
