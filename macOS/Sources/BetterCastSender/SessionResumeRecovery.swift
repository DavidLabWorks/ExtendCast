import Foundation

enum SessionResumeRecoveryAction: Equatable {
    case restartCapture
}

struct SessionSuspensionPlan: Equatable {
    let captureGracePeriod: TimeInterval
    let forceKeyframeBeforeStop: Bool
}

enum VirtualDisplayRecoveryAction: Equatable {
    case reuse
    case recreate
}

enum SessionSuspensionReason: Hashable {
    case inactive
    case locked
    case sleeping
}

extension NetworkClient {
    static func sessionSuspensionPlan(
        for reason: SessionSuspensionReason
    ) -> SessionSuspensionPlan {
        switch reason {
        case .inactive, .locked:
            // Session resign-active arrives before the lock notification on
            // many macOS versions. Keep capture alive just long enough for the
            // LoginWindow transition to reach the remote display, then stop
            // the pipeline so a long lock cannot accumulate media.
            return SessionSuspensionPlan(
                captureGracePeriod: 1.25,
                forceKeyframeBeforeStop: true
            )
        case .sleeping:
            return SessionSuspensionPlan(
                captureGracePeriod: 0,
                forceKeyframeBeforeStop: false
            )
        }
    }

    static func sessionResumeRecoveryAction(
        usesVirtualDisplay _: Bool
    ) -> SessionResumeRecoveryAction {
        // The display is the user's desktop. Session recovery only replaces
        // the media pipeline so its identity, arrangement, and contents stay
        // intact across lock and unlock.
        .restartCapture
    }

    static func shouldScheduleSessionRecovery(
        scheduledDeadline: Date?,
        proposedDeadline: Date
    ) -> Bool {
        guard let scheduledDeadline else { return true }
        return proposedDeadline < scheduledDeadline
    }

    static func virtualDisplayRecoveryAction(
        hasManager: Bool,
        displayIsActive: Bool,
        displayHasBounds: Bool
    ) -> VirtualDisplayRecoveryAction {
        hasManager && displayIsActive && displayHasBounds ? .reuse : .recreate
    }
}
