import AppKit
import XCTest
@testable import BetterCastSender

@MainActor
final class MenuBarIconTests: XCTestCase {
    func testMenuBarIconUsesNativeTemplateRendering() {
        let image = makeExtendCastMenuBarIcon()

        XCTAssertTrue(image.isTemplate)
        XCTAssertEqual(image.size, NSSize(width: 18, height: 18))
        XCTAssertNotNil(image.tiffRepresentation)
    }

    func testMenuBarIconMatchesTheAppIconsCoreGeometry() {
        let paths = extendCastMenuBarIconPaths(
            in: CGRect(x: 0, y: 0, width: 18, height: 18)
        )

        XCTAssertEqual(paths.outerDisplay.boundingBox.minX, 1.2, accuracy: 0.01)
        XCTAssertEqual(paths.outerDisplay.boundingBox.maxX, 16.8, accuracy: 0.01)
        XCTAssertEqual(paths.innerDisplay.boundingBox.minX, 4.1, accuracy: 0.01)
        XCTAssertEqual(paths.innerDisplay.boundingBox.maxX, 13.9, accuracy: 0.01)
        XCTAssertEqual(paths.arrow.boundingBox.maxX, 11.9, accuracy: 0.01)
    }
}
