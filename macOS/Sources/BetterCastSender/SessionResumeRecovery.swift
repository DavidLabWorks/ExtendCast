import Foundation

enum SessionResumeRecoveryAction: Equatable {
    case restartCapture
}

enum SessionSuspensionReason: Hashable {
    case inactive
    case locked
    case sleeping
}

extension NetworkClient {
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
}
