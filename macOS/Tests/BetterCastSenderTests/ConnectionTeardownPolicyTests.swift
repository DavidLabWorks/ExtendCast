import XCTest
@testable import BetterCastSender

final class ConnectionTeardownPolicyTests: XCTestCase {
    func testDeferredTeardownStopsCaptureBeforeDestroyingVirtualDisplay() {
        let deferred = ConnectionTeardownPolicy.deferredSteps
        let stopIndex = deferred.firstIndex(of: .stopCapture)
        let invalidateIndex = deferred.firstIndex(of: .invalidateEncoder)
        let destroyIndex = deferred.firstIndex(of: .destroyVirtualDisplay)

        XCTAssertNotNil(stopIndex)
        XCTAssertNotNil(invalidateIndex)
        XCTAssertNotNil(destroyIndex)
        XCTAssertLessThan(stopIndex!, invalidateIndex!)
        XCTAssertLessThan(invalidateIndex!, destroyIndex!)
    }

    func testFullOrderKeepsNetworkDetachImmediateAndHardwareDeferred() {
        XCTAssertEqual(
            ConnectionTeardownPolicy.fullOrderedSteps,
            [
                .detachFromRegistry,
                .cancelNetwork,
                .clearInputBounds,
                .stopCapture,
                .invalidateEncoder,
                .destroyVirtualDisplay,
            ]
        )
    }
}
