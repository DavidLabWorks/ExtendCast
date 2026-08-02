import XCTest
@testable import BetterCastSender

@MainActor
final class SessionResumeRecoveryTests: XCTestCase {
    func testLockAllowsTheLoginTransitionToReachTheRemoteDisplay() {
        let inactivePlan = NetworkClient.sessionSuspensionPlan(for: .inactive)
        let lockedPlan = NetworkClient.sessionSuspensionPlan(for: .locked)

        XCTAssertGreaterThan(inactivePlan.captureGracePeriod, 0)
        XCTAssertTrue(inactivePlan.forceKeyframeBeforeStop)
        XCTAssertGreaterThan(lockedPlan.captureGracePeriod, 0)
        XCTAssertTrue(lockedPlan.forceKeyframeBeforeStop)
    }

    func testSleepStopsCaptureWithoutWaitingForAVisualTransition() {
        XCTAssertEqual(
            NetworkClient.sessionSuspensionPlan(for: .sleeping),
            SessionSuspensionPlan(
                captureGracePeriod: 0,
                forceKeyframeBeforeStop: false
            )
        )
    }

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

    func testInvalidVirtualDisplayMustBeRecreatedAfterWake() {
        XCTAssertEqual(
            NetworkClient.virtualDisplayRecoveryAction(
                hasManager: true,
                displayIsActive: false,
                displayHasBounds: false
            ),
            .recreate
        )
    }

    func testLiveVirtualDisplayIsPreservedAfterWake() {
        XCTAssertEqual(
            NetworkClient.virtualDisplayRecoveryAction(
                hasManager: true,
                displayIsActive: true,
                displayHasBounds: true
            ),
            .reuse
        )
    }
}
