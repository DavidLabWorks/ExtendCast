import Foundation

/// Ordered steps for tearing down a sender→receiver pipeline.
/// Capture must fully stop before the virtual display is destroyed, otherwise
/// ScreenCaptureKit / VideoToolbox can still deliver frames against a released
/// display or an invalidated encoder (force-quit of the Windows receiver).
enum ConnectionTeardownStep: Equatable {
    case detachFromRegistry
    case cancelNetwork
    case clearInputBounds
    case stopCapture
    case invalidateEncoder
    case destroyVirtualDisplay
}

/// Lock/sleep suspension must detach pipeline media synchronously before
/// awaiting SCStream stop. Otherwise unlock can install a replacement
/// encoder while the suspend path still holds (and later releases) the old
/// one — VT's unretained callback then crashes in dealloc.
enum SuspendedCaptureTeardownStep: Equatable {
    case detachMediaFromPipeline
    case stopCapture
    case invalidateEncoder
}

enum ConnectionTeardownPolicy {
    /// Synchronous bookkeeping that can run immediately on the main queue.
    static let immediateSteps: [ConnectionTeardownStep] = [
        .detachFromRegistry,
        .cancelNetwork,
        .clearInputBounds,
    ]

    /// Asynchronous hardware teardown — must run in this order after capture
    /// ownership has been retained outside `pipelines`.
    static let deferredSteps: [ConnectionTeardownStep] = [
        .stopCapture,
        .invalidateEncoder,
        .destroyVirtualDisplay,
    ]

    static var fullOrderedSteps: [ConnectionTeardownStep] {
        immediateSteps + deferredSteps
    }

    static let suspendedCaptureSteps: [SuspendedCaptureTeardownStep] = [
        .detachMediaFromPipeline,
        .stopCapture,
        .invalidateEncoder,
    ]
}
