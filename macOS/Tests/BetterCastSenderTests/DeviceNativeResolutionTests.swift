import XCTest
@testable import BetterCastSender

final class DeviceNativeResolutionTests: XCTestCase {
    func testNormalizesOddPixelsToEven() {
        let size = DeviceNativeResolution.normalizedPixelSize(width: 2881, height: 1921)
        XCTAssertEqual(size?.width, 2880)
        XCTAssertEqual(size?.height, 1920)
    }

    func testRejectsTinyPanels() {
        XCTAssertNil(DeviceNativeResolution.normalizedPixelSize(width: 320, height: 240))
    }

    func testDetectsExistingDimension() {
        let available = [(1920, 1080), (2560, 1600)]
        XCTAssertTrue(
            DeviceNativeResolution.matchesAvailableResolution(
                width: 1920,
                height: 1080,
                available: available
            )
        )
        XCTAssertFalse(
            DeviceNativeResolution.matchesAvailableResolution(
                width: 2880,
                height: 1920,
                available: available
            )
        )
    }

    func testSuggestedPPIFromPhysicalSize() {
        // 13" 3:2 panel at 2880x1920 ≈ 266 PPI
        let ppi = DeviceNativeResolution.suggestedPPI(
            pixelWidth: 2880,
            pixelHeight: 1920,
            physicalWidthMM: 275,
            physicalHeightMM: 183
        )
        XCTAssertEqual(ppi, 266)
    }

    func testSuggestedPPIFallsBackWithoutPhysicalSize() {
        XCTAssertEqual(
            DeviceNativeResolution.suggestedPPI(
                pixelWidth: 2880,
                pixelHeight: 1920,
                physicalWidthMM: nil,
                physicalHeightMM: nil
            ),
            DeviceNativeResolution.fallbackPPI
        )
    }
}
