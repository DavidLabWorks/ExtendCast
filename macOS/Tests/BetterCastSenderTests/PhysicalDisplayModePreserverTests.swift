import XCTest
@testable import BetterCastSender

final class PhysicalDisplayModePreserverTests: XCTestCase {
    func testModeKeyMatchesWithinRefreshTolerance() {
        let a = PhysicalDisplayModePreserver.ModeKey(
            width: 2560,
            height: 1440,
            pixelWidth: 5120,
            pixelHeight: 2880,
            refreshRate: 60
        )
        let b = PhysicalDisplayModePreserver.ModeKey(
            width: 2560,
            height: 1440,
            pixelWidth: 5120,
            pixelHeight: 2880,
            refreshRate: 59.94
        )
        XCTAssertTrue(a.matches(b))
    }

    func testModeKeyRejectsDimensionMismatch() {
        let a = PhysicalDisplayModePreserver.ModeKey(
            width: 2560,
            height: 1440,
            pixelWidth: 5120,
            pixelHeight: 2880,
            refreshRate: 60
        )
        let b = PhysicalDisplayModePreserver.ModeKey(
            width: 1920,
            height: 1080,
            pixelWidth: 3840,
            pixelHeight: 2160,
            refreshRate: 60
        )
        XCTAssertFalse(a.matches(b))
    }

    func testResolveDisplayIDFallsBackToDisplayID() {
        let entry = PhysicalDisplayModePreserver.Entry(
            uuid: "AAAA",
            displayID: 1,
            mode: PhysicalDisplayModePreserver.ModeKey(
                width: 1920,
                height: 1080,
                pixelWidth: 1920,
                pixelHeight: 1080,
                refreshRate: 60
            ),
            originX: 1728,
            originY: 0
        )
        // Without real CoreGraphics UUIDs, fall back to display ID when online.
        XCTAssertEqual(
            PhysicalDisplayModePreserver.resolveDisplayID(for: entry, online: [1, 2]),
            1
        )
        XCTAssertNil(
            PhysicalDisplayModePreserver.resolveDisplayID(for: entry, online: [2, 3])
        )
    }

    func testOriginsMatchWithinTolerance() {
        XCTAssertTrue(
            PhysicalDisplayModePreserver.originsMatch(
                CGPoint(x: 1728, y: 1117),
                CGPoint(x: 1728.4, y: 1116.6)
            )
        )
        XCTAssertFalse(
            PhysicalDisplayModePreserver.originsMatch(
                CGPoint(x: 1728, y: 1117),
                CGPoint(x: -1440, y: 0)
            )
        )
    }

    func testSnapshotEmptyWhenNoEntries() {
        let snapshot = PhysicalDisplayModePreserver.Snapshot(entries: [])
        XCTAssertTrue(snapshot.isEmpty)
        XCTAssertEqual(
            PhysicalDisplayModePreserver.restore(
                snapshot,
                excluding: [],
                virtualDisplayID: nil,
                virtualOrigin: nil
            ),
            0
        )
    }
}
