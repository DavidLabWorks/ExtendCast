import Foundation
import XCTest
@testable import BetterCastSender

final class SenderIdentityTests: XCTestCase {
    func testIdentityIsStableAndFramedAsFirstClassProtocolMessage() throws {
        let suiteName = "SenderIdentityTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = SenderIdentity.load(
            defaults: defaults,
            deviceName: "Studio Mac mini"
        )
        let second = SenderIdentity.load(
            defaults: defaults,
            deviceName: "Studio Mac mini"
        )

        XCTAssertEqual(first, second)
        XCTAssertFalse(first.deviceId.isEmpty)
        XCTAssertEqual(first.deviceName, "Studio Mac mini")

        let packet = try SenderIdentity.framedPacket(first)
        let bodyLength = packet.prefix(4).withUnsafeBytes {
            $0.loadUnaligned(as: UInt32.self).bigEndian
        }
        XCTAssertEqual(Int(bodyLength), packet.count - 4)
        XCTAssertEqual(packet[4], SenderIdentity.packetType)

        let decoded = try JSONDecoder().decode(
            SenderIdentity.Payload.self,
            from: packet.dropFirst(5)
        )
        XCTAssertEqual(decoded, first)
    }
}
