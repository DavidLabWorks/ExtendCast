import Foundation

/// Keeps capture bounded by the receiver's real presentation progress. Frames
/// rejected here have not entered VideoToolbox, so the H.264 reference chain
/// remains intact.
final class StreamFeedbackController {
    var onTargetFPSChanged: ((Int) -> Void)?
    private let lock = NSLock()
    private let maximumFPS: Int
    private var currentTargetFPS: Int
    private var activeStreamID: UInt64?
    private var latestEncodedTimestamp: UInt64 = 0
    private var nextAdmissionNanoseconds: UInt64 = 0
    private var recoveryStartedNanoseconds: UInt64?

    init(maximumFPS: Int) {
        self.maximumFPS = max(1, maximumFPS)
        currentTargetFPS = max(1, maximumFPS)
    }

    var targetFPS: Int {
        lock.withLock { currentTargetFPS }
    }

    func reset() {
        lock.withLock {
            activeStreamID = nil
            latestEncodedTimestamp = 0
            currentTargetFPS = maximumFPS
            nextAdmissionNanoseconds = 0
            recoveryStartedNanoseconds = nil
        }
    }

    func noteEncodedFrame(streamID: UInt64, timestampNanoseconds: UInt64) {
        lock.withLock {
            if activeStreamID != streamID {
                activeStreamID = streamID
                latestEncodedTimestamp = timestampNanoseconds
                currentTargetFPS = maximumFPS
                nextAdmissionNanoseconds = 0
                recoveryStartedNanoseconds = nil
                return
            }
            latestEncodedTimestamp = max(latestEncodedTimestamp, timestampNanoseconds)
        }
    }

    func notePresentedFrame(
        streamID: UInt64,
        timestampNanoseconds: UInt64,
        nowNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) {
        let changedTarget = lock.withLock { () -> Int? in
            guard activeStreamID == streamID,
                  latestEncodedTimestamp >= timestampNanoseconds else {
                return nil
            }

            let previousTarget = currentTargetFPS
            let lag = latestEncodedTimestamp - timestampNanoseconds
            if lag >= 400_000_000 {
                currentTargetFPS = min(maximumFPS, 30)
                recoveryStartedNanoseconds = nil
            } else if lag >= 180_000_000 {
                currentTargetFPS = min(maximumFPS, 45)
                recoveryStartedNanoseconds = nil
            } else if lag <= 80_000_000 && currentTargetFPS < maximumFPS {
                if let recoveryStartedNanoseconds,
                   nowNanoseconds - recoveryStartedNanoseconds >= 2_000_000_000 {
                    currentTargetFPS = min(maximumFPS, currentTargetFPS + 15)
                    self.recoveryStartedNanoseconds = nowNanoseconds
                } else if recoveryStartedNanoseconds == nil {
                    recoveryStartedNanoseconds = nowNanoseconds
                }
            } else {
                recoveryStartedNanoseconds = nil
            }
            return currentTargetFPS == previousTarget ? nil : currentTargetFPS
        }
        if let changedTarget {
            onTargetFPSChanged?(changedTarget)
        }
    }

    func shouldEncodeFrame(
        nowNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) -> Bool {
        lock.withLock {
            guard nowNanoseconds >= nextAdmissionNanoseconds else {
                return false
            }
            let interval = UInt64(1_000_000_000 / max(currentTargetFPS, 1))
            nextAdmissionNanoseconds = nowNanoseconds + interval
            return true
        }
    }
}

private extension NSLock {
    func withLock<Result>(_ body: () -> Result) -> Result {
        lock()
        defer { unlock() }
        return body()
    }
}
