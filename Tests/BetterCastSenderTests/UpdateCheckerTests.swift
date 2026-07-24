import XCTest
@testable import BetterCastSender

final class UpdateCheckerTests: XCTestCase {
    func testParsesCommonGitHubReleaseTagFormats() {
        XCTAssertEqual(UpdateChecker.versionComponents(from: "v1.2.3"), [1, 2, 3])
        XCTAssertEqual(UpdateChecker.versionComponents(from: "release-2.5"), [2, 5])
        XCTAssertEqual(UpdateChecker.versionComponents(from: "1.0.0-beta.1"), [1, 0, 0])
        XCTAssertEqual(UpdateChecker.versionComponents(from: "latest"), [])
    }

    func testComparesEveryVersionComponent() {
        XCTAssertTrue(UpdateChecker.isVersion("v1.0.1", newerThan: "1.0.0"))
        XCTAssertTrue(UpdateChecker.isVersion("v1.0.10", newerThan: "1.0.9"))
        XCTAssertTrue(UpdateChecker.isVersion("v2.0.0", newerThan: "1.99.99"))
    }

    func testEquivalentOrOlderVersionDoesNotTriggerUpdate() {
        XCTAssertFalse(UpdateChecker.isVersion("v1.0", newerThan: "1.0.0"))
        XCTAssertFalse(UpdateChecker.isVersion("v1.0.0", newerThan: "1.0.1"))
        XCTAssertFalse(UpdateChecker.isVersion("latest", newerThan: "1.0.0"))
    }
}
