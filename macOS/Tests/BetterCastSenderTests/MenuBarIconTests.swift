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
}
