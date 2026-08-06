import Foundation
import Network

/// Sender-owned view of the routes that can reach one remote receiver.
///
/// This catalog deliberately has no dependency on local receiver sessions.
/// An inbound sender connected to this Mac does not make an outbound route
/// available, and selecting an outbound route does not alter receiver state.
struct OutboundRouteCatalog {
    let remoteReceiver: DiscoveredService
    let discoveredReceivers: [DiscoveredService]
    let localAddresses: [ReceiverConnectionAddress]

    init(
        remoteReceiver: DiscoveredService,
        discoveredReceivers: [DiscoveredService],
        localAddresses: [ReceiverConnectionAddress]
    ) {
        self.remoteReceiver = remoteReceiver
        self.discoveredReceivers = discoveredReceivers
        self.localAddresses = localAddresses
    }

    var availableModes: [NetworkInterfacePreference] {
        var modes: [NetworkInterfacePreference] = [.auto]
        let lowercasedName = remoteReceiver.name.lowercased()
        let isAppleReceiver = !lowercasedName.contains("android")
            && !lowercasedName.contains("windows")
            && !lowercasedName.contains("linux")
        let baseName = remoteReceiver.name.hasSuffix(" P2P")
            ? String(remoteReceiver.name.dropLast(4))
            : remoteReceiver.name
        let hasP2PCompanion = discoveredReceivers.contains {
            $0.name == "\(baseName) P2P"
        }

        if isAppleReceiver
            && remoteReceiver.supportsApplePeerToPeerConnection
            && (hasP2PCompanion
                || remoteReceiver.supportsApplePeerToPeerConnection) {
            modes.append(.p2pOnly)
        }

        let hasActiveLocalWiFi = localAddresses.contains {
            $0.title == NetworkInterfacePreference.routerOnly.connectTitle
        }
        let wasDiscoveredOverWiFi = remoteReceiver.discoveryInterfaces.contains {
            $0.type == .wifi
        }
        if remoteReceiver.supportsWiFiConnection
            && (hasActiveLocalWiFi || wasDiscoveredOverWiFi) {
            modes.append(.routerOnly)
        }
        if remoteReceiver.supportsEthernetConnection {
            modes.append(.ethernet)
        }
        if remoteReceiver.supportsThunderboltConnection
            && !activeLocalThunderboltInterfaceNames.isEmpty {
            modes.append(.thunderboltBridge)
        }
        return modes
    }

    var candidateThunderboltInterfaceNames: Set<String> {
        let discoveredInterfaces = remoteReceiver.discoveryInterfaces.compactMap {
            $0.isThunderboltBridge ? $0.name.lowercased() : nil
        }
        return Set(discoveredInterfaces).union(
            activeLocalThunderboltInterfaceNames
        )
    }

    func resolve(
        _ requestedMode: NetworkInterfacePreference
    ) -> NetworkInterfacePreference {
        if requestedMode == .auto {
            return Self.preferredAutomaticMode(
                receiverName: remoteReceiver.name,
                availableModes: availableModes
            )
        }
        if availableModes.contains(requestedMode) {
            return requestedMode
        }
        if requestedMode == .wiredCable {
            if availableModes.contains(.thunderboltBridge) {
                return .thunderboltBridge
            }
            if availableModes.contains(.ethernet) {
                return .ethernet
            }
        }
        return .auto
    }

    func advertisedThunderboltRoute()
        -> AdvertisedThunderboltRoute? {
        let advertisedEndpoints = Set(
            remoteReceiver.advertisedRouteEndpoints[.thunderbolt, default: []]
                .compactMap(Self.endpointParts)
        )
        if advertisedEndpoints.count == 1,
           activeLocalThunderboltInterfaceNames.count == 1,
           let endpoint = advertisedEndpoints.first,
           let interfaceName = activeLocalThunderboltInterfaceNames.first {
            return AdvertisedThunderboltRoute(
                host: endpoint.host,
                interfaceName: interfaceName,
                port: endpoint.port
            )
        }
        return nil
    }

    func connectionEndpoint(
        for mode: NetworkInterfacePreference,
        resolvedRoute: BonjourResolvedRoute?,
        discoveredEndpoint: NWEndpoint,
        discoveredEndpointMatchesMode: Bool = false
    ) -> NWEndpoint {
        let peerRoute =
            mode == .thunderboltBridge ? advertisedThunderboltRoute() : nil
        return Self.preferredConnectionEndpoint(
            for: mode,
            resolvedRoute: resolvedRoute,
            discoveredEndpoint: discoveredEndpoint,
            advertisedThunderboltHost: peerRoute?.host,
            advertisedThunderboltPort: peerRoute?.port ?? BCConstants.tcpPort,
            thunderboltInterfaceName:
                peerRoute?.interfaceName
                    ?? activeLocalThunderboltInterfaceNames.first,
            discoveredEndpointMatchesPreference:
                discoveredEndpointMatchesMode
        )
    }

    static func preferredAutomaticMode(
        receiverName: String,
        availableModes: [NetworkInterfacePreference]
    ) -> NetworkInterfacePreference {
        guard receiverName.lowercased().contains("windows") else {
            return .auto
        }
        if availableModes.contains(.thunderboltBridge) {
            return .thunderboltBridge
        }
        if availableModes.contains(.ethernet) {
            return .ethernet
        }
        return .auto
    }

    private struct EndpointParts: Hashable {
        let host: String
        let port: UInt16
    }

    private static func endpointParts(_ endpoint: String) -> EndpointParts? {
        guard let separator = endpoint.lastIndex(of: ":"),
              let port = UInt16(endpoint[endpoint.index(after: separator)...])
        else {
            return nil
        }
        let host = String(endpoint[..<separator])
        guard !host.isEmpty else { return nil }
        return EndpointParts(host: host, port: port)
    }

    static func preferredConnectionEndpoint(
        for preference: NetworkInterfacePreference,
        resolvedRoute: BonjourResolvedRoute?,
        discoveredEndpoint: NWEndpoint,
        advertisedThunderboltHost: String?,
        advertisedThunderboltPort: UInt16 = BCConstants.tcpPort,
        thunderboltInterfaceName: String? = nil,
        discoveredEndpointMatchesPreference: Bool = false
    ) -> NWEndpoint {
        let cachedEndpoint =
            resolvedRoute?.supports(preference) == true
                ? resolvedRoute?.endpoint
                : nil
        let verifiedEndpoint =
            preference == .auto
                && resolvedRoute?.supports(.thunderboltBridge) == true
                && thunderboltInterfaceName == nil
                    ? nil
                    : cachedEndpoint
        if preference == .thunderboltBridge {
            // Only keep a "matching" discovered endpoint when it is already a
            // scoped Thunderbolt host/service. Bare Bonjour service names are
            // resolved by Network.framework and can be hijacked onto VPN/utun.
            if discoveredEndpointMatchesPreference,
               isThunderboltScopedEndpoint(
                discoveredEndpoint,
                interfaceName: thunderboltInterfaceName
               ) {
                return discoveredEndpoint
            }
            if let thunderboltInterfaceName {
                switch discoveredEndpoint {
                case .hostPort(let host, _):
                    if String(describing: host).lowercased()
                        .hasSuffix(
                            "%\(thunderboltInterfaceName.lowercased())"
                        ) {
                        return discoveredEndpoint
                    }
                case .service(_, _, _, let interface):
                    if interface?.name.lowercased()
                        == thunderboltInterfaceName.lowercased() {
                        return discoveredEndpoint
                    }
                default:
                    break
                }
            }
            if let advertisedThunderboltHost,
               let thunderboltInterfaceName,
               let port = NWEndpoint.Port(rawValue: advertisedThunderboltPort) {
                if let verifiedEndpoint,
                   case .hostPort(let verifiedHost, _) = verifiedEndpoint {
                    let verifiedHostText = String(describing: verifiedHost)
                    let verifiedAddress =
                        verifiedHostText.split(separator: "%", maxSplits: 1)
                            .first
                            .map(String.init)
                    let verifiedScope =
                        verifiedHostText.split(separator: "%", maxSplits: 1)
                            .dropFirst()
                            .first
                            .map(String.init)
                    if verifiedAddress == advertisedThunderboltHost,
                       verifiedScope
                        == thunderboltInterfaceName.lowercased() {
                        return verifiedEndpoint
                    }
                }
                return .hostPort(
                    host: NWEndpoint.Host(
                        "\(advertisedThunderboltHost)%\(thunderboltInterfaceName)"
                    ),
                    port: port
                )
            }
            if let verifiedEndpoint {
                return verifiedEndpoint
            }
        }
        return verifiedEndpoint ?? discoveredEndpoint
    }

    /// True when the endpoint is already bound to a Thunderbolt bridge scope,
    /// so Network.framework will not re-resolve it through VPN/proxy interfaces.
    private static func isThunderboltScopedEndpoint(
        _ endpoint: NWEndpoint,
        interfaceName: String?
    ) -> Bool {
        let scope = interfaceName?.lowercased()
        switch endpoint {
        case .hostPort(let host, _):
            let hostText = String(describing: host).lowercased()
            if let scope {
                return hostText.hasSuffix("%\(scope)")
            }
            return hostText.contains("%bridge")
        case .service(_, _, _, let interface):
            guard let interfaceName = interface?.name.lowercased() else {
                return false
            }
            if let scope {
                return interfaceName == scope
            }
            return interfaceName.hasPrefix("bridge")
        default:
            return false
        }
    }

    private var activeLocalThunderboltInterfaceNames: Set<String> {
        Set(localAddresses.compactMap {
            $0.title
                    == NetworkInterfacePreference.thunderboltBridge.connectTitle
                ? $0.interfaceName.lowercased()
                : nil
        })
    }
}
