import XCTest
import Network
@testable import BetterCastSender

final class ReceiverConnectionRegistryTests: XCTestCase {
    func testRejectsSecondAttemptForSameReceiver() {
        var registry = ReceiverConnectionRegistry()
        let firstConnectionID = UUID()
        let secondConnectionID = UUID()

        XCTAssertTrue(
            registry.begin(
                connectionID: firstConnectionID,
                receiverKey: "host:169.254.204.111:51820"
            )
        )
        XCTAssertFalse(
            registry.begin(
                connectionID: secondConnectionID,
                receiverKey: "host:169.254.204.111:51820"
            )
        )
    }

    func testLateReadyConnectionCannotReplaceNewAttempt() {
        var registry = ReceiverConnectionRegistry()
        let staleConnectionID = UUID()
        let currentConnectionID = UUID()
        let receiverKey = "host:169.254.204.111:51820"

        XCTAssertTrue(
            registry.begin(
                connectionID: staleConnectionID,
                receiverKey: receiverKey
            )
        )
        registry.finishPending(
            connectionID: staleConnectionID,
            receiverKey: receiverKey
        )
        XCTAssertTrue(
            registry.begin(
                connectionID: currentConnectionID,
                receiverKey: receiverKey
            )
        )

        XCTAssertFalse(
            registry.admitReady(
                connectionID: staleConnectionID,
                pendingKey: receiverKey,
                resolvedKey: receiverKey
            )
        )
        XCTAssertTrue(
            registry.admitReady(
                connectionID: currentConnectionID,
                pendingKey: receiverKey,
                resolvedKey: receiverKey
            )
        )
    }

    func testResolvedEndpointRejectsDuplicateDiscoveredThroughAnotherRoute() {
        var registry = ReceiverConnectionRegistry()
        let manualConnectionID = UUID()
        let bonjourConnectionID = UUID()
        let resolvedKey = "host:169.254.204.111:51820"

        XCTAssertTrue(
            registry.begin(
                connectionID: manualConnectionID,
                receiverKey: resolvedKey
            )
        )
        XCTAssertTrue(
            registry.admitReady(
                connectionID: manualConnectionID,
                pendingKey: resolvedKey,
                resolvedKey: resolvedKey
            )
        )

        let bonjourKey = "service:bettercast receiver windows"
        XCTAssertTrue(
            registry.begin(
                connectionID: bonjourConnectionID,
                receiverKey: bonjourKey
            )
        )
        XCTAssertFalse(
            registry.admitReady(
                connectionID: bonjourConnectionID,
                pendingKey: bonjourKey,
                resolvedKey: resolvedKey
            )
        )
    }

    func testResolvedHostKeyUnifiesBonjourAndManualRoutes() {
        let bonjourEndpoint = NWEndpoint.service(
            name: "BetterCast Receiver Windows",
            type: "_bettercast._tcp",
            domain: "local.",
            interface: nil
        )
        let remoteEndpoint = NWEndpoint.hostPort(
            host: "169.254.204.111",
            port: 51820
        )

        XCTAssertEqual(
            ReceiverConnectionKey.resolved(
                serviceName: "BetterCast Receiver Windows",
                endpoint: bonjourEndpoint,
                remoteEndpoint: remoteEndpoint
            ),
            ReceiverConnectionKey.unresolved(
                serviceName: "169.254.204.111:51820",
                endpoint: remoteEndpoint
            )
        )
    }
}
