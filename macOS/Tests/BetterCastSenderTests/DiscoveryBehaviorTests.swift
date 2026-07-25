import Network
import XCTest
@testable import BetterCastSender

@MainActor
final class DiscoveryBehaviorTests: XCTestCase {
    func testReceiverDisconnectTransitionShowsAlertOnlyForSameDevice() {
        XCTAssertEqual(
            ReceiverDetailAvailability.disconnectedReceiverName(
                from: .available(id: "receiver-1", name: "Office PC"),
                to: .unavailable(id: "receiver-1")
            ),
            "Office PC"
        )
        XCTAssertNil(
            ReceiverDetailAvailability.disconnectedReceiverName(
                from: .available(id: "receiver-1", name: "Office PC"),
                to: .unavailable(id: "receiver-2")
            )
        )
        XCTAssertNil(
            ReceiverDetailAvailability.disconnectedReceiverName(
                from: .available(id: "receiver-1", name: "Office PC"),
                to: .none
            )
        )
    }

    func testReceiverHeartbeatTimeoutDoesNotWaitFifteenSeconds() {
        let now = Date()

        XCTAssertFalse(
            NetworkClient.receiverConnectionHasTimedOut(
                lastHeartbeat: now.addingTimeInterval(-4.9),
                now: now
            )
        )
        XCTAssertTrue(
            NetworkClient.receiverConnectionHasTimedOut(
                lastHeartbeat: now.addingTimeInterval(-5.1),
                now: now
            )
        )
    }

    func testReachabilityRecheckPolicyUsesFocusAndSkipsConnectedDevices() {
        XCTAssertEqual(
            NetworkClient.bonjourReachabilityRecheckInterval(
                isFocused: true,
                isConnected: false
            ),
            3
        )
        XCTAssertEqual(
            NetworkClient.bonjourReachabilityRecheckInterval(
                isFocused: false,
                isConnected: false
            ),
            20
        )
        XCTAssertNil(
            NetworkClient.bonjourReachabilityRecheckInterval(
                isFocused: true,
                isConnected: true
            )
        )
    }

    func testConnectedReceiverDoesNotStartBonjourReachabilityProbe() {
        var probeCount = 0
        let client = NetworkClient(
            bonjourReachabilityProbe: { _, completion in
                probeCount += 1
                completion(true)
                return {}
            }
        )
        let service = DiscoveredService(
            name: "Connected Receiver",
            endpoint: .service(
                name: "Connected Receiver",
                type: "_bettercast._tcp",
                domain: "local.",
                interface: nil
            )
        )
        client.connectedServices = [service]

        client.updateDiscoveredServices([service], for: "TCP")

        XCTAssertEqual(probeCount, 0)
    }

    func testUnverifiedBonjourServiceIsNotShownAsAvailable() {
        let client = NetworkClient(
            bonjourReachabilityProbe: { _, completion in
                completion(false)
                return {}
            }
        )
        let staleService = DiscoveredService(
            name: "Offline Receiver",
            endpoint: .service(
                name: "Offline Receiver",
                type: "_bettercast._tcp",
                domain: "local.",
                interface: nil
            )
        )

        client.updateDiscoveredServices([staleService], for: "TCP")

        XCTAssertTrue(client.foundServices.isEmpty)
    }

    func testReachableBonjourServiceIsShownAsAvailable() {
        let client = NetworkClient(
            bonjourReachabilityProbe: { _, completion in
                completion(true)
                return {}
            }
        )
        let service = DiscoveredService(
            name: "Online Receiver",
            endpoint: .service(
                name: "Online Receiver",
                type: "_bettercast._tcp",
                domain: "local.",
                interface: nil
            )
        )

        client.updateDiscoveredServices([service], for: "TCP")

        XCTAssertEqual(client.foundServices.map(\.name), ["Online Receiver"])
    }

    func testConfirmedUnreachableServiceSkipsBrowseRemovalGracePeriod() async throws {
        var probeResults = [true, false]
        let client = NetworkClient(
            discoveryRemovalDelay: 10,
            bonjourReachabilityRecheckInterval: 0.01,
            bonjourReachabilityProbe: { _, completion in
                let result = probeResults.isEmpty ? false : probeResults.removeFirst()
                completion(result)
                return {}
            }
        )
        let service = DiscoveredService(
            name: "Receiver Going Offline",
            endpoint: .service(
                name: "Receiver Going Offline",
                type: "_bettercast._tcp",
                domain: "local.",
                interface: nil
            )
        )

        client.updateDiscoveredServices([service], for: "TCP")
        XCTAssertEqual(client.foundServices.map(\.name), ["Receiver Going Offline"])

        try await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertTrue(client.foundServices.isEmpty)
    }

    func testTransientBrowseRemovalKeepsDeviceVisibleDuringGracePeriod() async throws {
        let client = NetworkClient(
            discoveryRemovalDelay: 0.1,
            bonjourReachabilityProbe: { _, completion in
                completion(true)
                return {}
            }
        )
        let service = DiscoveredService(
            name: "Test Receiver",
            endpoint: .service(
                name: "Test Receiver",
                type: "_bettercast._tcp",
                domain: "local.",
                interface: nil
            )
        )

        client.updateDiscoveredServices([service], for: "TCP")
        client.updateDiscoveredServices([], for: "TCP")

        XCTAssertEqual(client.foundServices.map(\.name), ["Test Receiver"])
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(client.foundServices.map(\.name), ["Test Receiver"])

        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(client.foundServices.isEmpty)
    }

    func testBridgeDiscoveryInterfaceEnablesOnlyThunderboltMode() {
        let service = DiscoveredService(
            name: "Test Receiver",
            endpoint: .service(
                name: "Test Receiver",
                type: "_bettercast._tcp",
                domain: "local.",
                interface: nil
            ),
            discoveryInterfaces: [
                DiscoveredNetworkInterface(name: "bridge0", type: .other),
            ]
        )

        XCTAssertTrue(service.supportsThunderboltConnection)
        XCTAssertFalse(service.supportsEthernetConnection)
    }

    func testWiFiDiscoveryDoesNotClaimWiredSupport() {
        let service = DiscoveredService(
            name: "Test Receiver",
            endpoint: .service(
                name: "Test Receiver",
                type: "_bettercast._tcp",
                domain: "local.",
                interface: nil
            ),
            discoveryInterfaces: [
                DiscoveredNetworkInterface(name: "en0", type: .wifi),
            ]
        )

        XCTAssertFalse(service.supportsEthernetConnection)
        XCTAssertFalse(service.supportsThunderboltConnection)
    }

    func testConnectionModeProvidesMatchingConnectCardCopy() {
        XCTAssertEqual(NetworkInterfacePreference.auto.connectTitle, "Automatic")
        XCTAssertEqual(NetworkInterfacePreference.p2pOnly.connectTitle, "Wi-Fi Direct")
        XCTAssertEqual(NetworkInterfacePreference.routerOnly.connectTitle, "Wi-Fi")
        XCTAssertEqual(NetworkInterfacePreference.ethernet.connectTitle, "Ethernet")
        XCTAssertEqual(
            NetworkInterfacePreference.thunderboltBridge.connectTitle,
            "Thunderbolt Bridge"
        )
        XCTAssertFalse(NetworkInterfacePreference.allCases.contains(.wiredCable))

        for mode in NetworkInterfacePreference.allCases {
            XCTAssertFalse(mode.connectDescription.isEmpty)
            XCTAssertFalse(mode.connectHelp.isEmpty)
            XCTAssertFalse(mode.connectSystemImage.isEmpty)
        }
    }

    func testOnlyWiFiDirectAllowsUDP() {
        XCTAssertTrue(NetworkInterfacePreference.p2pOnly.allowsUDP)
        XCTAssertFalse(NetworkInterfacePreference.auto.allowsUDP)
        XCTAssertFalse(NetworkInterfacePreference.routerOnly.allowsUDP)
        XCTAssertFalse(NetworkInterfacePreference.ethernet.allowsUDP)
        XCTAssertFalse(NetworkInterfacePreference.thunderboltBridge.allowsUDP)
    }

    func testUnavailableWiredCopyNamesTheSelectedRoute() {
        XCTAssertEqual(
            NetworkInterfacePreference.ethernet.unavailableDescription,
            "This device was not found over Ethernet"
        )
        XCTAssertEqual(
            NetworkInterfacePreference.thunderboltBridge.unavailableDescription,
            "This device was not found over Thunderbolt Bridge"
        )
    }

    func testWindowsReceiverShowsWiFiAndThunderboltSeparately() {
        let client = NetworkClient()
        let service = DiscoveredService(
            name: "Dang-Surface (Windows)",
            endpoint: .service(
                name: "Dang-Surface (Windows)",
                type: "_bettercast._tcp",
                domain: "local.",
                interface: nil
            ),
            discoveryInterfaces: [
                DiscoveredNetworkInterface(name: "en0", type: .wifi),
                DiscoveredNetworkInterface(name: "bridge0", type: .other),
            ]
        )

        XCTAssertEqual(
            client.availableConnectionModes(for: service),
            [.auto, .routerOnly, .thunderboltBridge]
        )
    }

    func testEthernetDiscoveryDoesNotClaimThunderboltSupport() {
        let client = NetworkClient()
        let service = DiscoveredService(
            name: "Office PC (Windows)",
            endpoint: .service(
                name: "Office PC (Windows)",
                type: "_bettercast._tcp",
                domain: "local.",
                interface: nil
            ),
            discoveryInterfaces: [
                DiscoveredNetworkInterface(name: "en7", type: .wiredEthernet),
            ]
        )

        XCTAssertEqual(
            client.availableConnectionModes(for: service),
            [.auto, .ethernet]
        )
    }

    func testWindowsReceiverOnlyShowsDiscoveredConnectionModes() {
        let client = NetworkClient()
        let service = DiscoveredService(
            name: "Office PC (Windows)",
            endpoint: .service(
                name: "Office PC (Windows)",
                type: "_bettercast._tcp",
                domain: "local.",
                interface: nil
            ),
            discoveryInterfaces: [
                DiscoveredNetworkInterface(name: "en0", type: .wifi),
            ]
        )

        XCTAssertEqual(
            client.availableConnectionModes(for: service),
            [.auto, .routerOnly]
        )
    }

    func testAppleP2PCompanionAddsWiFiDirectMode() {
        let client = NetworkClient(
            bonjourReachabilityProbe: { _, completion in
                completion(true)
                return {}
            }
        )
        let service = DiscoveredService(
            name: "Test iPad",
            endpoint: .service(
                name: "Test iPad",
                type: "_bettercast._tcp",
                domain: "local.",
                interface: nil
            ),
            discoveryInterfaces: [
                DiscoveredNetworkInterface(name: "en0", type: .wifi),
            ]
        )
        let p2pService = DiscoveredService(
            name: "Test iPad P2P",
            endpoint: .service(
                name: "Test iPad P2P",
                type: "_bettercast._tcp",
                domain: "local.",
                interface: nil
            ),
            discoveryInterfaces: [
                DiscoveredNetworkInterface(name: "awdl0", type: .other),
            ]
        )
        client.updateDiscoveredServices([service, p2pService], for: "TCP")

        XCTAssertEqual(
            client.availableConnectionModes(for: service),
            [.auto, .p2pOnly, .routerOnly]
        )
    }

    func testUnsupportedSelectionFallsBackWhenOpeningDevice() {
        let client = NetworkClient()
        let service = DiscoveredService(
            name: "Office PC (Windows)",
            endpoint: .service(
                name: "Office PC (Windows)",
                type: "_bettercast._tcp",
                domain: "local.",
                interface: nil
            ),
            discoveryInterfaces: [
                DiscoveredNetworkInterface(name: "en0", type: .wifi),
            ]
        )
        client.interfacePreference = .p2pOnly
        client.connectionType = "UDP"

        client.loadSettings(for: service)

        XCTAssertEqual(client.interfacePreference, .auto)
        XCTAssertEqual(client.connectionType, "TCP")
    }
}
