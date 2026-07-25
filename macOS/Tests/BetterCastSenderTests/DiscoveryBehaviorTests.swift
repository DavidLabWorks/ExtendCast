import Network
import XCTest
@testable import BetterCastSender

@MainActor
final class DiscoveryBehaviorTests: XCTestCase {
    func testReceiverAddressesClassifyPhysicalConnections() {
        XCTAssertEqual(
            ReceiverConnectionAddressProvider.connectionAddress(
                interfaceName: "en0",
                displayName: "Wi-Fi",
                address: "192.168.1.20",
                port: 51820
            ),
            ReceiverConnectionAddress(
                interfaceName: "en0",
                title: "Wi-Fi",
                address: "192.168.1.20:51820",
                usageHint: "Connect through the Wi-Fi network.",
                priority: 10
            )
        )
        XCTAssertEqual(
            ReceiverConnectionAddressProvider.connectionAddress(
                interfaceName: "bridge0",
                displayName: "Thunderbolt Bridge",
                address: "169.254.204.111",
                port: 51820
            )?.title,
            "Thunderbolt Bridge"
        )
        XCTAssertEqual(
            ReceiverConnectionAddressProvider.connectionAddress(
                interfaceName: "en7",
                displayName: "USB 10/100/1000 LAN",
                address: "10.0.0.8",
                port: 51820
            )?.title,
            "Ethernet"
        )
        XCTAssertNil(
            ReceiverConnectionAddressProvider.connectionAddress(
                interfaceName: "utun4",
                displayName: nil,
                address: "198.19.0.1",
                port: 51820
            )
        )
    }

    func testReceiverAddressesHideLoopbackAndVirtualBridges() {
        XCTAssertNil(
            ReceiverConnectionAddressProvider.connectionAddress(
                interfaceName: "lo0",
                displayName: nil,
                address: "127.0.0.1",
                port: 51820
            )
        )
        XCTAssertNil(
            ReceiverConnectionAddressProvider.connectionAddress(
                interfaceName: "bridge100",
                displayName: nil,
                address: "192.168.128.1",
                port: 51820
            )
        )
    }

    func testThunderboltPeerAddressesKeepOnlyUsableBridgeNeighbors() {
        let output = """
        ? (169.254.83.107) at (incomplete) on bridge0 [bridge]
        ? (169.254.155.125) at 36:d1:62:9b:5c:c0 on bridge0 permanent [bridge]
        ? (169.254.204.111) at e4:9c:49:7a:85:68 on bridge0 [ethernet]
        ? (169.254.255.255) at ff:ff:ff:ff:ff:ff on bridge0 [bridge]
        ? (224.0.0.251) at 1:0:5e:0:0:fb on bridge0 ifscope permanent [ethernet]
        """

        XCTAssertEqual(
            ThunderboltPeerAddressProvider.parseARPOutput(output),
            ["169.254.204.111"]
        )
    }

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
                to: .unavailable(id: "receiver-1"),
                connectionIsActiveOrPending: true
            )
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

    func testDisconnectConfirmationUsesCurrentStateAfterGracePeriod() {
        XCTAssertTrue(
            ReceiverDisconnectConfirmation.shouldPresent(
                receiverName: "Office PC",
                selectedReceiverName: "Office PC",
                connectedReceiverNames: [],
                connectionIsActivePendingOrReconnecting: false
            )
        )
        XCTAssertFalse(
            ReceiverDisconnectConfirmation.shouldPresent(
                receiverName: "Office PC",
                selectedReceiverName: "Office PC",
                connectedReceiverNames: ["Office PC"],
                connectionIsActivePendingOrReconnecting: false
            )
        )
        XCTAssertFalse(
            ReceiverDisconnectConfirmation.shouldPresent(
                receiverName: "Office PC",
                selectedReceiverName: "Office PC",
                connectedReceiverNames: [],
                connectionIsActivePendingOrReconnecting: true
            )
        )
        XCTAssertFalse(
            ReceiverDisconnectConfirmation.shouldPresent(
                receiverName: "Office PC",
                selectedReceiverName: nil,
                connectedReceiverNames: [],
                connectionIsActivePendingOrReconnecting: false
            )
        )
    }

    func testReceiverDetailFollowsSameDeviceAfterReconnectChangesConnectionID() {
        let previousID = UUID()
        let replacementID = UUID()
        let replacement = ConnectedDisplayInfo(
            id: replacementID,
            name: "Office PC",
            resolution: "1920x1080",
            connectionMethod: "Thunderbolt Bridge",
            displayBounds: .zero,
            audioEnabled: true
        )

        XCTAssertEqual(
            ReceiverDetailAvailability.replacementConnectionID(
                selectedID: previousID,
                retainedDisplayName: "Office PC",
                currentDisplays: [replacement]
            ),
            replacementID
        )
        XCTAssertNil(
            ReceiverDetailAvailability.replacementConnectionID(
                selectedID: replacementID,
                retainedDisplayName: "Office PC",
                currentDisplays: [replacement]
            )
        )
    }

    func testConnectedDeviceListSubtitleIncludesConnectionMethod() {
        let display = ConnectedDisplayInfo(
            id: UUID(),
            name: "Office PC",
            resolution: "1920x1080",
            connectionMethod: "Thunderbolt Bridge",
            displayBounds: .zero,
            audioEnabled: true
        )

        XCTAssertEqual(
            display.deviceListSubtitle,
            "1920x1080 · Thunderbolt Bridge"
        )
    }

    func testBridgePathIsPresentedAsThunderboltConnection() {
        XCTAssertEqual(
            NetworkClient.physicalConnectionMethod(
                interfaceNames: ["bridge0"]
            ),
            "Thunderbolt Bridge"
        )
        XCTAssertNil(
            NetworkClient.physicalConnectionMethod(
                interfaceNames: ["en0"]
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
        let client = NetworkClient(localConnectionAddressProvider: { [] })
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

    func testWindowsReceiverOnlyShowsDiscoveredModesWithoutAnotherActiveInterface() {
        let client = NetworkClient(localConnectionAddressProvider: { [] })
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

    func testActiveLocalThunderboltBridgeAddsModeForWindowsReceiverFoundOverWiFi() {
        let client = NetworkClient(
            localConnectionAddressProvider: {
                [
                    ReceiverConnectionAddress(
                        interfaceName: "bridge0",
                        title: "Thunderbolt Bridge",
                        address: "169.254.204.112:51820",
                        usageHint: "Connect directly over Thunderbolt.",
                        priority: 20
                    ),
                ]
            }
        )
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
            ]
        )

        XCTAssertEqual(
            client.availableConnectionModes(for: service),
            [.auto, .routerOnly, .thunderboltBridge]
        )
    }

    func testWindowsAutomaticModePrefersThunderboltThenEthernet() {
        XCTAssertEqual(
            NetworkClient.preferredAutomaticConnectionMode(
                receiverName: "Dang-Surface (Windows)",
                availableModes: [.auto, .routerOnly, .ethernet, .thunderboltBridge]
            ),
            .thunderboltBridge
        )
        XCTAssertEqual(
            NetworkClient.preferredAutomaticConnectionMode(
                receiverName: "Office PC (Windows)",
                availableModes: [.auto, .routerOnly, .ethernet]
            ),
            .ethernet
        )
        XCTAssertEqual(
            NetworkClient.preferredAutomaticConnectionMode(
                receiverName: "Office PC (Windows)",
                availableModes: [.auto, .routerOnly]
            ),
            .auto
        )
    }

    func testWindowsUsesOnlyUnambiguousThunderboltPeer() {
        XCTAssertEqual(
            NetworkClient.preferredThunderboltPeerHost(
                receiverName: "Dang-Surface (Windows)",
                availablePeerHosts: ["169.254.204.111"]
            ),
            "169.254.204.111"
        )
        XCTAssertNil(
            NetworkClient.preferredThunderboltPeerHost(
                receiverName: "Dang-Surface (Windows)",
                availablePeerHosts: ["169.254.204.111", "169.254.204.112"]
            )
        )
        XCTAssertNil(
            NetworkClient.preferredThunderboltPeerHost(
                receiverName: "Test iPad",
                availablePeerHosts: ["169.254.204.111"]
            )
        )
    }

    func testAppleAutomaticModeKeepsPeerToPeerRoutingPolicy() {
        XCTAssertEqual(
            NetworkClient.preferredAutomaticConnectionMode(
                receiverName: "Test iPad",
                availableModes: [.auto, .p2pOnly, .thunderboltBridge]
            ),
            .auto
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
