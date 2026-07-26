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
    let thunderboltPeerRoutes: [
        ThunderboltPeerAddressProvider.PeerRoute
    ]

    init(
        remoteReceiver: DiscoveredService,
        discoveredReceivers: [DiscoveredService],
        localAddresses: [ReceiverConnectionAddress],
        thunderboltPeerRoutes: [
            ThunderboltPeerAddressProvider.PeerRoute
        ] = []
    ) {
        self.remoteReceiver = remoteReceiver
        self.discoveredReceivers = discoveredReceivers
        self.localAddresses = localAddresses
        self.thunderboltPeerRoutes = thunderboltPeerRoutes
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
            && (hasP2PCompanion
                || remoteReceiver.supportsApplePeerToPeerConnection) {
            modes.append(.p2pOnly)
        }

        let isWindowsReceiver = lowercasedName.contains("windows")
        let hasActiveLocalWiFi = localAddresses.contains {
            $0.title == NetworkInterfacePreference.routerOnly.connectTitle
        }
        if remoteReceiver.supportsWiFiConnection
            || (isWindowsReceiver && hasActiveLocalWiFi) {
            modes.append(.routerOnly)
        }
        if remoteReceiver.supportsEthernetConnection {
            modes.append(.ethernet)
        }
        if isWindowsReceiver
            ? hasAvailableWindowsThunderboltRoute
            : remoteReceiver.supportsThunderboltConnection {
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

    func thunderboltPeerRoute(
        from availableRoutes: [
            ThunderboltPeerAddressProvider.PeerRoute
        ]? = nil
    ) -> ThunderboltPeerAddressProvider.PeerRoute? {
        Self.preferredThunderboltPeerRoute(
            receiverName: remoteReceiver.name,
            availableRoutes: availableRoutes ?? thunderboltPeerRoutes,
            allowedInterfaceNames: candidateThunderboltInterfaceNames
        )
    }

    func connectionEndpoint(
        for mode: NetworkInterfacePreference,
        resolvedRoute: BonjourResolvedRoute?,
        discoveredEndpoint: NWEndpoint,
        discoveredEndpointMatchesMode: Bool = false
    ) -> NWEndpoint {
        let peerRoute =
            mode == .thunderboltBridge ? thunderboltPeerRoute() : nil
        return Self.preferredConnectionEndpoint(
            for: mode,
            resolvedRoute: resolvedRoute,
            discoveredEndpoint: discoveredEndpoint,
            thunderboltPeerHost: peerRoute?.host,
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

    static func preferredThunderboltPeerRoute(
        receiverName: String,
        availableRoutes: [ThunderboltPeerAddressProvider.PeerRoute],
        allowedInterfaceNames: Set<String>
    ) -> ThunderboltPeerAddressProvider.PeerRoute? {
        guard receiverName.lowercased().contains("windows") else {
            return nil
        }
        let matchingRoutes = availableRoutes.filter {
            allowedInterfaceNames.contains($0.interfaceName.lowercased())
        }
        let uniqueRoutes = Array(Set(matchingRoutes.map {
            "\($0.host)%\($0.interfaceName)"
        }))
        guard uniqueRoutes.count == 1 else { return nil }
        return matchingRoutes.first
    }

    static func preferredConnectionEndpoint(
        for preference: NetworkInterfacePreference,
        resolvedRoute: BonjourResolvedRoute?,
        discoveredEndpoint: NWEndpoint,
        thunderboltPeerHost: String?,
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
            if discoveredEndpointMatchesPreference {
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
            if let thunderboltPeerHost,
               let thunderboltInterfaceName,
               let port = NWEndpoint.Port(rawValue: 51820) {
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
                    if verifiedAddress == thunderboltPeerHost,
                       verifiedScope
                        == thunderboltInterfaceName.lowercased() {
                        return verifiedEndpoint
                    }
                }
                return .hostPort(
                    host: NWEndpoint.Host(
                        "\(thunderboltPeerHost)%\(thunderboltInterfaceName)"
                    ),
                    port: port
                )
            }
            if let verifiedEndpoint {
                return verifiedEndpoint
            }
            if let thunderboltPeerHost,
               let port = NWEndpoint.Port(rawValue: 51820) {
                return .hostPort(
                    host: NWEndpoint.Host(thunderboltPeerHost),
                    port: port
                )
            }
        }
        return verifiedEndpoint ?? discoveredEndpoint
    }

    private var hasAvailableWindowsThunderboltRoute: Bool {
        guard !activeLocalThunderboltInterfaceNames.isEmpty else {
            return false
        }
        let discoveredThunderboltInterfaces = Set(
            remoteReceiver.discoveryInterfaces.compactMap {
                $0.isThunderboltBridge ? $0.name.lowercased() : nil
            }
        )
        if !activeLocalThunderboltInterfaceNames.isDisjoint(
            with: discoveredThunderboltInterfaces
        ) {
            return true
        }
        // A live bridge is enough to expose a candidate when there is only one
        // Windows Receiver identity. Bonjour/ARP can resolve the peer lazily
        // during the connection attempt; requiring it here hides the mode
        // before the transport probe has a chance to run.
        return hasSingleWindowsReceiverIdentity
            && matchingThunderboltPeerRouteCount <= 1
    }

    private var hasSingleWindowsReceiverIdentity: Bool {
        let receivers = discoveredReceivers + [remoteReceiver]
        let identities = Set(
            receivers.compactMap { receiver -> String? in
                guard receiver.name.lowercased().contains("windows") else {
                    return nil
                }
                return receiver.name
                    .replacingOccurrences(
                        of: #" P2P( \(\d+\))?$"#,
                        with: "",
                        options: .regularExpression
                    )
                    .replacingOccurrences(
                        of: #" \(\d+\)$"#,
                        with: "",
                        options: .regularExpression
                    )
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
            }
        )
        return identities.count == 1
    }

    private var matchingThunderboltPeerRouteCount: Int {
        Set(
            thunderboltPeerRoutes.compactMap { route -> String? in
                guard candidateThunderboltInterfaceNames.contains(
                    route.interfaceName.lowercased()
                ) else {
                    return nil
                }
                return "\(route.host)%\(route.interfaceName.lowercased())"
            }
        ).count
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
