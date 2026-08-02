import Foundation

/// A thread-safe, capacity-one mailbox for real-time values.
/// New values replace stale work so playback latency cannot grow over time.
final class LatestFrameMailbox<Value> {
    private let lock = NSLock()
    private var pendingValue: Value?

    var pendingCount: Int {
        lock.withLock { pendingValue == nil ? 0 : 1 }
    }

    func replace(with value: Value) {
        lock.withLock {
            pendingValue = value
        }
    }

    func take() -> Value? {
        lock.withLock {
            defer { pendingValue = nil }
            return pendingValue
        }
    }

    func removeAll() {
        lock.withLock {
            pendingValue = nil
        }
    }
}
