import XCTest
@testable import BetterCastSender

final class PresentationCapacityTests: XCTestCase {
    func testWindowsSoftDecodeDemotesHiDPIPanel() {
        let envelope = PresentationCapacity.bind(
            width: 2880,
            height: 1920,
            fps: 60,
            retinaEnabled: true,
            serviceName: "Dang-Surface (Windows)"
        )

        XCTAssertTrue(envelope.appliedLimit)
        XCTAssertEqual(envelope.width, 1920)
        XCTAssertEqual(envelope.height, 1280)
        XCTAssertEqual(envelope.fps, 30)
        XCTAssertFalse(envelope.retinaEnabled)
    }

    func testLinuxSoftDecodeIsAlsoLimited() {
        let envelope = PresentationCapacity.bind(
            width: 2560,
            height: 1440,
            fps: 60,
            retinaEnabled: false,
            serviceName: "Studio (Linux)"
        )

        XCTAssertTrue(envelope.appliedLimit)
        XCTAssertEqual(envelope.width, 1920)
        XCTAssertEqual(envelope.height, 1080)
        XCTAssertEqual(envelope.fps, 30)
    }

    func testAppleReceiversKeepFullCapacity() {
        let envelope = PresentationCapacity.bind(
            width: 2880,
            height: 1920,
            fps: 60,
            retinaEnabled: true,
            serviceName: "iPad Pro"
        )

        XCTAssertFalse(envelope.appliedLimit)
        XCTAssertEqual(envelope.width, 2880)
        XCTAssertEqual(envelope.height, 1920)
        XCTAssertEqual(envelope.fps, 60)
        XCTAssertTrue(envelope.retinaEnabled)
    }

    func testWithinBudgetWindowsKeepsResolutionButCapsFPS() {
        let envelope = PresentationCapacity.bind(
            width: 1920,
            height: 1080,
            fps: 60,
            retinaEnabled: false,
            serviceName: "Desk PC (Windows)"
        )

        XCTAssertTrue(envelope.appliedLimit)
        XCTAssertEqual(envelope.width, 1920)
        XCTAssertEqual(envelope.height, 1080)
        XCTAssertEqual(envelope.fps, 30)
        XCTAssertFalse(envelope.retinaEnabled)
    }

    func testP2PAndLoopbackSkipSoftDecodeLimit() {
        let p2p = PresentationCapacity.bind(
            width: 2880,
            height: 1920,
            fps: 60,
            retinaEnabled: true,
            serviceName: "Dang-Surface (Windows)",
            isP2P: true
        )
        XCTAssertFalse(p2p.appliedLimit)
        XCTAssertEqual(p2p.width, 2880)
        XCTAssertEqual(p2p.fps, 60)

        let loopback = PresentationCapacity.bind(
            width: 2880,
            height: 1920,
            fps: 60,
            retinaEnabled: true,
            serviceName: "Dang-Surface (Windows)",
            isLoopback: true
        )
        XCTAssertFalse(loopback.appliedLimit)
        XCTAssertEqual(loopback.height, 1920)
    }

    func testHardwareDecodeSkipsSoftDecodeLimit() {
        let envelope = PresentationCapacity.bind(
            width: 2880,
            height: 1920,
            fps: 60,
            retinaEnabled: true,
            serviceName: "Dang-Surface (Windows)",
            hardwareDecode: true
        )

        XCTAssertFalse(envelope.appliedLimit)
        XCTAssertEqual(envelope.width, 2880)
        XCTAssertEqual(envelope.height, 1920)
        XCTAssertEqual(envelope.fps, 60)
        XCTAssertTrue(envelope.retinaEnabled)
        XCTAssertEqual(envelope.detail, "hardware-decode capacity")
    }
}
