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

    func testThunderboltPeerLookupUsesCurrentBridgeInterfaceNames() {
        let addresses = [
            ReceiverConnectionAddress(
                interfaceName: "en1",
                title: "Wi-Fi",
                address: "192.168.31.194:51820",
                usageHint: "Connect through the Wi-Fi network.",
                priority: 10
            ),
            ReceiverConnectionAddress(
                interfaceName: "bridge1",
                title: "Thunderbolt Bridge",
                address: "169.254.205.130:51820",
                usageHint: "Connect directly over Thunderbolt.",
                priority: 20
            ),
        ]

        XCTAssertEqual(
            ThunderboltPeerAddressProvider.bridgeInterfaceNames(
                from: addresses
            ),
            ["bridge1"]
        )
    }

    func testThunderboltPeerRouteKeepsHostPairedWithItsBridge() {
        let route = ThunderboltPeerAddressProvider.PeerRoute(
            host: "169.254.204.111",
            interfaceName: "bridge1"
        )

        XCTAssertEqual(
            NetworkClient.preferredThunderboltPeerRoute(
                receiverName: "Dang-Surface (Windows)",
                availableRoutes: [route],
                allowedInterfaceNames: ["bridge1"]
            ),
            route
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
                completion(.reachable)
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

    func testBonjourProbeAliasesShareConnectedReceiverIdentity() {
        XCTAssertEqual(
            NetworkClient.bonjourReceiverIdentity(
                "Dang-Surface (Windows) P2P"
            ),
            NetworkClient.bonjourReceiverIdentity(
                "Dang-Surface (Windows)"
            )
        )
        XCTAssertEqual(
            NetworkClient.bonjourReceiverIdentity(
                "Dang-Surface (Windows) (2)"
            ),
            NetworkClient.bonjourReceiverIdentity(
                "Dang-Surface (Windows)"
            )
        )
        XCTAssertEqual(
            NetworkClient.bonjourReceiverIdentity(
                "Dang-Surface (Windows) P2P (2)"
            ),
            NetworkClient.bonjourReceiverIdentity(
                "Dang-Surface (Windows)"
            )
        )
    }

    func testUnverifiedBonjourServiceIsNotShownAsAvailable() {
        let client = NetworkClient(
            bonjourReachabilityProbe: { _, completion in
                completion(.unreachable)
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
                completion(.reachable)
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
                completion(result ? .reachable : .unreachable)
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
                completion(.reachable)
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
        let client = NetworkClient(
            localConnectionAddressProvider: {
                [
                    ReceiverConnectionAddress(
                        interfaceName: "en0",
                        title: "Wi-Fi",
                        address: "192.168.31.194:51820",
                        usageHint: "Connect through the Wi-Fi network.",
                        priority: 10
                    ),
                    ReceiverConnectionAddress(
                        interfaceName: "bridge0",
                        title: "Thunderbolt Bridge",
                        address: "169.254.205.130:51820",
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
                DiscoveredNetworkInterface(name: "bridge0", type: .other),
            ]
        )

        XCTAssertEqual(
            client.availableConnectionModes(for: service),
            [.auto, .routerOnly, .thunderboltBridge]
        )
    }

    func testWindowsReceiverShowsBothModesFromCurrentLocalRoutes() {
        let client = NetworkClient(
            localConnectionAddressProvider: {
                [
                    ReceiverConnectionAddress(
                        interfaceName: "en1",
                        title: "Wi-Fi",
                        address: "192.168.31.194:51820",
                        usageHint: "Connect through the Wi-Fi network.",
                        priority: 10
                    ),
                    ReceiverConnectionAddress(
                        interfaceName: "bridge0",
                        title: "Thunderbolt Bridge",
                        address: "169.254.205.130:51820",
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
                DiscoveredNetworkInterface(
                    name: "bridge0",
                    type: .wiredEthernet
                ),
            ]
        )

        XCTAssertEqual(
            client.availableConnectionModes(for: service),
            [.auto, .routerOnly, .thunderboltBridge]
        )
    }

    func testMergedBonjourServiceKeepsEndpointForEachConnectionMode() {
        let wifiEndpoint = NWEndpoint.service(
            name: "Dang-Surface (Windows)",
            type: "_bettercast._tcp",
            domain: "local.",
            interface: nil
        )
        let thunderboltEndpoint = NWEndpoint.hostPort(
            host: "169.254.204.111%bridge0",
            port: 51820
        )
        let wifiService = DiscoveredService(
            name: "Dang-Surface (Windows)",
            endpoint: wifiEndpoint,
            discoveryInterfaces: [
                DiscoveredNetworkInterface(name: "en1", type: .wifi),
            ]
        )
        let thunderboltService = DiscoveredService(
            name: "Dang-Surface (Windows)",
            endpoint: thunderboltEndpoint,
            discoveryInterfaces: [
                DiscoveredNetworkInterface(
                    name: "bridge0",
                    type: .wiredEthernet
                ),
            ]
        )

        let merged = wifiService.mergingDiscoveryInterfaces(
            from: thunderboltService
        )

        XCTAssertEqual(
            merged.connectionEndpoint(for: .routerOnly),
            wifiEndpoint
        )
        XCTAssertEqual(
            merged.connectionEndpoint(for: .thunderboltBridge),
            thunderboltEndpoint
        )
    }

    func testWindowsReceiverDropsThunderboltWhenLocalBridgeDisappears() {
        let client = NetworkClient(
            localConnectionAddressProvider: {
                [
                    ReceiverConnectionAddress(
                        interfaceName: "en1",
                        title: "Wi-Fi",
                        address: "192.168.31.194:51820",
                        usageHint: "Connect through the Wi-Fi network.",
                        priority: 10
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
                DiscoveredNetworkInterface(
                    name: "bridge0",
                    type: .wiredEthernet
                ),
            ]
        )

        XCTAssertEqual(
            client.availableConnectionModes(for: service),
            [.auto, .routerOnly]
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

    func testLocalThunderboltDoesNotAddModeToWindowsReceiverFoundOnlyOverWiFi() {
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
            [.auto, .routerOnly]
        )
    }

    func testThunderboltModeRequiresTheSameLocalBridgeAsTheReceiver() {
        let client = NetworkClient(
            localConnectionAddressProvider: {
                [
                    ReceiverConnectionAddress(
                        interfaceName: "bridge1",
                        title: "Thunderbolt Bridge",
                        address: "169.254.205.130:51820",
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
                DiscoveredNetworkInterface(
                    name: "bridge0",
                    type: .wiredEthernet
                ),
            ]
        )

        XCTAssertEqual(
            client.availableConnectionModes(for: service),
            [.auto]
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

    func testConnectCardShowsSelectedThunderboltEndpoint() {
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
            },
            thunderboltPeerRouteProvider: {
                [
                    ThunderboltPeerAddressProvider.PeerRoute(
                        host: "169.254.204.111",
                        interfaceName: "bridge0"
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
                DiscoveredNetworkInterface(
                    name: "bridge0",
                    type: .wiredEthernet
                ),
            ]
        )

        XCTAssertEqual(
            client.connectionEndpointDescription(
                for: service,
                preference: .thunderboltBridge
            ),
            "169.254.204.111%bridge0:51820"
        )
    }

    func testConnectCardShowsVerifiedScopedThunderboltEndpoint() {
        let verifiedEndpoint = NWEndpoint.hostPort(
            host: "169.254.204.111%bridge0",
            port: 51820
        )
        let route = BonjourResolvedRoute(
            endpoint: verifiedEndpoint,
            interfaceNames: ["bridge0"],
            usesWiFi: false,
            usesWiredEthernet: true
        )
        let client = NetworkClient(
            bonjourReachabilityProbe: { _, completion in
                completion(
                    BonjourReachabilityResult(
                        isReachable: true,
                        resolvedRoute: route
                    )
                )
                return {}
            },
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
            },
            thunderboltPeerRouteProvider: {
                [
                    ThunderboltPeerAddressProvider.PeerRoute(
                        host: "169.254.204.111",
                        interfaceName: "bridge0"
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
                DiscoveredNetworkInterface(
                    name: "bridge0",
                    type: .wiredEthernet
                ),
            ]
        )

        client.updateDiscoveredServices([service], for: "TCP")

        XCTAssertEqual(
            client.connectionEndpointDescription(
                for: service,
                preference: .thunderboltBridge
            ),
            "169.254.204.111%bridge0:51820"
        )
    }

    func testConnectCardShowsManualHostAndPort() {
        let client = NetworkClient()
        let service = DiscoveredService(
            name: "192.168.31.235:51820",
            endpoint: .hostPort(host: "192.168.31.235", port: 51820)
        )

        XCTAssertEqual(
            client.connectionEndpointDescription(
                for: service,
                preference: .routerOnly
            ),
            "192.168.31.235:51820"
        )
    }

    func testConnectCardFormatsIPv6EndpointWithBrackets() {
        XCTAssertEqual(
            NetworkClient.endpointDescription(
                .hostPort(host: "fe80::1", port: 51820)
            ),
            "[fe80::1]:51820"
        )
    }

    func testConnectCardHidesIPv4InterfaceScope() {
        XCTAssertEqual(
            NetworkClient.endpointDescription(
                .hostPort(host: "192.168.31.235%en0", port: 51820)
            ),
            "192.168.31.235:51820"
        )
    }

    func testResolvedBonjourRoutesAreSelectedPerConnectionMode() {
        let wifiRoute = BonjourResolvedRoute(
            endpoint: .hostPort(
                host: "192.168.31.235%en0",
                port: 51820
            ),
            interfaceNames: ["en0"],
            usesWiFi: true,
            usesWiredEthernet: false
        )
        let thunderboltRoute = BonjourResolvedRoute(
            endpoint: .hostPort(
                host: "169.254.204.111%bridge0",
                port: 51820
            ),
            interfaceNames: ["bridge0"],
            usesWiFi: false,
            usesWiredEthernet: true
        )

        XCTAssertEqual(
            NetworkClient.preferredBonjourEndpoint(
                for: .routerOnly,
                resolvedRoutes: [thunderboltRoute, wifiRoute]
            ),
            wifiRoute.endpoint
        )
        XCTAssertEqual(
            NetworkClient.preferredBonjourEndpoint(
                for: .thunderboltBridge,
                resolvedRoutes: [wifiRoute, thunderboltRoute]
            ),
            thunderboltRoute.endpoint
        )
    }

    func testConnectCardUsesTheResolvedWiFiRouteWhenThunderboltAlsoExists() {
        let wifiRoute = BonjourResolvedRoute(
            endpoint: .hostPort(
                host: "192.168.31.235%en0",
                port: 51820
            ),
            interfaceNames: ["en0"],
            usesWiFi: true,
            usesWiredEthernet: false
        )
        let thunderboltRoute = BonjourResolvedRoute(
            endpoint: .hostPort(
                host: "169.254.204.111%bridge0",
                port: 51820
            ),
            interfaceNames: ["bridge0"],
            usesWiFi: false,
            usesWiredEthernet: true
        )
        let client = NetworkClient(
            bonjourReachabilityProbe: { _, completion in
                completion(
                    BonjourReachabilityResult(
                        isReachable: true,
                        resolvedRoutes: [thunderboltRoute, wifiRoute]
                    )
                )
                return {}
            },
            localConnectionAddressProvider: {
                [
                    ReceiverConnectionAddress(
                        interfaceName: "en0",
                        title: "Wi-Fi",
                        address: "192.168.31.194:51820",
                        usageHint: "Connect through the Wi-Fi network.",
                        priority: 10
                    ),
                    ReceiverConnectionAddress(
                        interfaceName: "bridge0",
                        title: "Thunderbolt Bridge",
                        address: "169.254.205.130:51820",
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
                DiscoveredNetworkInterface(
                    name: "bridge0",
                    type: .wiredEthernet
                ),
            ]
        )

        client.updateDiscoveredServices([service], for: "TCP")

        XCTAssertEqual(
            client.connectionEndpointDescription(
                for: service,
                preference: .routerOnly
            ),
            "192.168.31.235:51820"
        )
    }

    func testAvailableConnectReusesReachableBonjourWiFiEndpoint() {
        let resolvedEndpoint = NWEndpoint.hostPort(
            host: "192.168.31.235",
            port: 51820
        )
        let route = BonjourResolvedRoute(
            endpoint: resolvedEndpoint,
            interfaceNames: ["en1"],
            usesWiFi: true,
            usesWiredEthernet: false
        )

        XCTAssertEqual(
            NetworkClient.preferredBonjourEndpoint(
                for: .routerOnly,
                resolvedRoute: route
            ),
            resolvedEndpoint
        )
    }

    func testVerifiedThunderboltRouteWinsOverUnscopedARPPeer() {
        let verifiedEndpoint = NWEndpoint.hostPort(
            host: "169.254.204.111%bridge0",
            port: 51820
        )
        let route = BonjourResolvedRoute(
            endpoint: verifiedEndpoint,
            interfaceNames: ["bridge0"],
            usesWiFi: false,
            usesWiredEthernet: true
        )

        XCTAssertEqual(
            NetworkClient.preferredConnectionEndpoint(
                for: .thunderboltBridge,
                resolvedRoute: route,
                discoveredEndpoint: .service(
                    name: "Dang-Surface (Windows)",
                    type: "_bettercast._tcp",
                    domain: "local.",
                    interface: nil
                ),
                thunderboltPeerHost: "169.254.204.111"
            ),
            verifiedEndpoint
        )
    }

    func testThunderboltDeviceSwitchScopesTheNewPeerToCurrentBridge() {
        let oldRoute = BonjourResolvedRoute(
            endpoint: .hostPort(
                host: "169.254.204.111%bridge0",
                port: 51820
            ),
            interfaceNames: ["bridge0"],
            usesWiFi: false,
            usesWiredEthernet: true
        )

        XCTAssertEqual(
            NetworkClient.preferredConnectionEndpoint(
                for: .thunderboltBridge,
                resolvedRoute: oldRoute,
                discoveredEndpoint: .service(
                    name: "New-Surface (Windows)",
                    type: "_bettercast._tcp",
                    domain: "local.",
                    interface: nil
                ),
                thunderboltPeerHost: "169.254.204.222",
                thunderboltInterfaceName: "bridge0"
            ),
            .hostPort(
                host: "169.254.204.222%bridge0",
                port: 51820
            )
        )
    }

    func testThunderboltInterfaceSwitchReplacesOldScopeWhenPeerIsUnchanged() {
        let oldRoute = BonjourResolvedRoute(
            endpoint: .hostPort(
                host: "169.254.204.111%bridge0",
                port: 51820
            ),
            interfaceNames: ["bridge0"],
            usesWiFi: false,
            usesWiredEthernet: true
        )

        XCTAssertEqual(
            NetworkClient.preferredConnectionEndpoint(
                for: .thunderboltBridge,
                resolvedRoute: oldRoute,
                discoveredEndpoint: .service(
                    name: "Dang-Surface (Windows)",
                    type: "_bettercast._tcp",
                    domain: "local.",
                    interface: nil
                ),
                thunderboltPeerHost: "169.254.204.111",
                thunderboltInterfaceName: "bridge1"
            ),
            .hostPort(
                host: "169.254.204.111%bridge1",
                port: 51820
            )
        )
    }

    func testAutomaticIgnoresOldThunderboltRouteAfterBridgeDisappears() {
        let oldRoute = BonjourResolvedRoute(
            endpoint: .hostPort(
                host: "169.254.204.111%bridge0",
                port: 51820
            ),
            interfaceNames: ["bridge0"],
            usesWiFi: false,
            usesWiredEthernet: true
        )
        let currentWiFiEndpoint = NWEndpoint.hostPort(
            host: "192.168.31.235",
            port: 51820
        )

        XCTAssertEqual(
            NetworkClient.preferredConnectionEndpoint(
                for: .auto,
                resolvedRoute: oldRoute,
                discoveredEndpoint: currentWiFiEndpoint,
                thunderboltPeerHost: nil,
                thunderboltInterfaceName: nil
            ),
            currentWiFiEndpoint
        )
    }

    func testAutomaticDirectRouteFallbackUsesCurrentBonjourEndpoint() {
        let oldThunderboltEndpoint = NWEndpoint.hostPort(
            host: "169.254.204.111%bridge0",
            port: 51820
        )
        let currentBonjourEndpoint = NWEndpoint.hostPort(
            host: "192.168.31.235",
            port: 51820
        )

        XCTAssertEqual(
            NetworkClient.infrastructureFallbackEndpoint(
                shouldFallback: true,
                resolvedEndpoint: oldThunderboltEndpoint,
                discoveredEndpoint: currentBonjourEndpoint
            ),
            currentBonjourEndpoint
        )
    }

    func testAutomaticThunderboltFallbackUsesWiFiCandidate() {
        let wifiEndpoint = NWEndpoint.hostPort(
            host: "192.168.31.235",
            port: 51820
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
                DiscoveredNetworkInterface(name: "en1", type: .wifi),
                DiscoveredNetworkInterface(
                    name: "bridge0",
                    type: .wiredEthernet
                ),
            ],
            connectionEndpoints: [
                DiscoveredServiceEndpoint(
                    endpoint: wifiEndpoint,
                    discoveryInterfaces: [
                        DiscoveredNetworkInterface(
                            name: "en1",
                            type: .wifi
                        ),
                    ]
                ),
                DiscoveredServiceEndpoint(
                    endpoint: .hostPort(
                        host: "169.254.204.111%bridge0",
                        port: 51820
                    ),
                    discoveryInterfaces: [
                        DiscoveredNetworkInterface(
                            name: "bridge0",
                            type: .wiredEthernet
                        ),
                    ]
                ),
            ]
        )

        XCTAssertEqual(
            NetworkClient.infrastructureFallbackEndpoint(
                shouldFallback: true,
                resolvedEndpoint: .hostPort(
                    host: "169.254.204.111%bridge0",
                    port: 51820
                ),
                discoveredEndpoint:
                    service.infrastructureConnectionEndpoint
            ),
            wifiEndpoint
        )
    }

    func testCurrentScopedThunderboltCandidateBeatsOldVerifiedRoute() {
        let oldRoute = BonjourResolvedRoute(
            endpoint: .hostPort(
                host: "169.254.204.111%bridge0",
                port: 51820
            ),
            interfaceNames: ["bridge0"],
            usesWiFi: false,
            usesWiredEthernet: true
        )
        let currentEndpoint = NWEndpoint.hostPort(
            host: "169.254.204.222%bridge0",
            port: 51820
        )

        XCTAssertEqual(
            NetworkClient.preferredConnectionEndpoint(
                for: .thunderboltBridge,
                resolvedRoute: oldRoute,
                discoveredEndpoint: currentEndpoint,
                thunderboltPeerHost: nil,
                thunderboltInterfaceName: "bridge0"
            ),
            currentEndpoint
        )
    }

    func testCurrentScopedThunderboltCandidateBeatsStaleARPPeer() {
        let currentEndpoint = NWEndpoint.hostPort(
            host: "169.254.204.222%bridge0",
            port: 51820
        )

        XCTAssertEqual(
            NetworkClient.preferredConnectionEndpoint(
                for: .thunderboltBridge,
                resolvedRoute: nil,
                discoveredEndpoint: currentEndpoint,
                thunderboltPeerHost: "169.254.204.111",
                thunderboltInterfaceName: "bridge0",
                discoveredEndpointMatchesPreference: true
            ),
            currentEndpoint
        )
    }

    func testWiFiRouteIsNotMistakenForThunderboltWhenBridgeIsAvailable() {
        let wifiRoute = BonjourResolvedRoute(
            endpoint: .hostPort(host: "192.168.31.235", port: 51820),
            interfaceNames: ["en1", "bridge0"],
            usesWiFi: true,
            usesWiredEthernet: false
        )

        XCTAssertFalse(wifiRoute.supports(.thunderboltBridge))
    }

    func testEthernetRouteIsNotMistakenForThunderboltWhenBridgeIsAvailable() {
        let ethernetRoute = BonjourResolvedRoute(
            endpoint: .hostPort(host: "10.0.0.25", port: 51820),
            interfaceNames: ["en7", "bridge0"],
            usesWiFi: false,
            usesWiredEthernet: true
        )

        XCTAssertTrue(ethernetRoute.supports(.ethernet))
        XCTAssertFalse(ethernetRoute.supports(.thunderboltBridge))
    }

    func testLinkLocalEthernetIsNotThunderboltWithoutBridgeScope() {
        let ethernetRoute = BonjourResolvedRoute(
            endpoint: .hostPort(host: "169.254.20.25", port: 51820),
            interfaceNames: ["en7", "bridge0"],
            usesWiFi: false,
            usesWiredEthernet: true
        )

        XCTAssertTrue(ethernetRoute.supports(.ethernet))
        XCTAssertFalse(ethernetRoute.supports(.thunderboltBridge))
    }

    func testThunderboltARPPeerRemainsFallbackWithoutVerifiedRoute() {
        XCTAssertEqual(
            NetworkClient.preferredConnectionEndpoint(
                for: .thunderboltBridge,
                resolvedRoute: nil,
                discoveredEndpoint: .service(
                    name: "Dang-Surface (Windows)",
                    type: "_bettercast._tcp",
                    domain: "local.",
                    interface: nil
                ),
                thunderboltPeerHost: "169.254.204.111"
            ),
            .hostPort(host: "169.254.204.111", port: 51820)
        )
    }

    func testAvailableConnectDoesNotReuseRouteFromWrongInterface() {
        let resolvedEndpoint = NWEndpoint.hostPort(
            host: "169.254.204.111",
            port: 51820
        )
        let route = BonjourResolvedRoute(
            endpoint: resolvedEndpoint,
            interfaceNames: ["bridge0"],
            usesWiFi: false,
            usesWiredEthernet: true
        )

        XCTAssertNil(
            NetworkClient.preferredBonjourEndpoint(
                for: .routerOnly,
                resolvedRoute: route
            )
        )
    }

    func testAvailableConnectionWatchdogAllowsTCPAddressTimeoutToFinish() {
        XCTAssertGreaterThan(
            NetworkClient.availableConnectionAttemptTimeout,
            TimeInterval(NetworkClient.tcpConnectionTimeout)
        )
    }

    func testWindowsBonjourConnectionsPreferIPv4() {
        XCTAssertTrue(
            BonjourConnectionPolicy.prefersIPv4(
                receiverName: "Dang-Surface (Windows)"
            )
        )
        XCTAssertFalse(
            BonjourConnectionPolicy.prefersIPv4(
                receiverName: "Test iPad"
            )
        )
    }

    func testBonjourLocalNetworkConnectionsBypassSystemProxy() {
        let parameters = NWParameters.tcp

        BonjourConnectionPolicy.applyLocalNetworkPolicy(
            to: parameters,
            receiverName: "Dang-Surface (Windows)"
        )

        XCTAssertTrue(parameters.preferNoProxies)
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
                completion(.reachable)
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
