import Foundation
import XCTest
@testable import BetterCastSender

final class ConnectionDiagnosticsFileTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
    }

    func testEntriesPersistAcrossStoreInstances() throws {
        let firstStore = ConnectionDiagnosticsFile(
            directoryURL: temporaryDirectory,
            maximumFileSize: 1_024
        )
        firstStore.append("first connection event")

        let reopenedStore = ConnectionDiagnosticsFile(
            directoryURL: temporaryDirectory,
            maximumFileSize: 1_024
        )

        XCTAssertEqual(
            try reopenedStore.contents(),
            "first connection event\n"
        )
    }

    func testRotationKeepsPreviousAndCurrentConnectionEvents() throws {
        let store = ConnectionDiagnosticsFile(
            directoryURL: temporaryDirectory,
            maximumFileSize: 12
        )
        store.append("12345")
        store.append("67890")
        store.append("abc")

        XCTAssertEqual(
            try store.contents(),
            "12345\n67890\nabc\n"
        )
    }
}
