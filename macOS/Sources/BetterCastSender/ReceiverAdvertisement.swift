import Network

enum ReceiverAdvertisedRoute: String, CaseIterable, Hashable {
    case wifi
    case ethernet
    case thunderbolt
    case peerToPeer = "p2p"
}

enum ReceiverDecodeCapability: String, Hashable {
    case hardware = "hw"
    case software = "sw"

    var supportsHardwareDecode: Bool {
        self == .hardware
    }
}

struct ReceiverAdvertisement {
    static let protocolVersion = "1"

    let routes: Set<ReceiverAdvertisedRoute>
    let routeEndpoints: [ReceiverAdvertisedRoute: Set<String>]
    let decodeCapability: ReceiverDecodeCapability

    init(
        routes: Set<ReceiverAdvertisedRoute>,
        routeEndpoints: [ReceiverAdvertisedRoute: Set<String>] = [:],
        decodeCapability: ReceiverDecodeCapability = .software
    ) {
        self.routes = routes
        self.routeEndpoints = routeEndpoints
        self.decodeCapability = decodeCapability
    }

    var txtRecord: NWTXTRecord {
        var entries = [
            "rv": Self.protocolVersion,
            "routes": routes.map(\.rawValue).sorted().joined(separator: ","),
            "decode": decodeCapability.rawValue,
        ]
        for (route, endpoints) in routeEndpoints where !endpoints.isEmpty {
            entries["ep_\(route.rawValue)"] = endpoints.sorted().joined(
                separator: ","
            )
        }
        return NWTXTRecord(entries)
    }

    static func parse(_ metadata: NWBrowser.Result.Metadata)
        -> ReceiverAdvertisement? {
        guard case .bonjour(let record) = metadata,
              record["rv"] == protocolVersion,
              let routeList = record["routes"] else {
            return nil
        }
        let routes = Set(
            routeList.split(separator: ",").compactMap {
                ReceiverAdvertisedRoute(rawValue: String($0))
            }
        )
        var routeEndpoints: [ReceiverAdvertisedRoute: Set<String>] = [:]
        for route in routes {
            guard let endpointList = record["ep_\(route.rawValue)"] else {
                continue
            }
            routeEndpoints[route] = Set(
                endpointList.split(separator: ",").map(String.init)
            )
        }
        let decodeCapability =
            record["decode"].flatMap(ReceiverDecodeCapability.init(rawValue:))
            ?? .software
        return ReceiverAdvertisement(
            routes: routes,
            routeEndpoints: routeEndpoints,
            decodeCapability: decodeCapability
        )
    }

    static func endpoint(
        from value: String,
        interfaceName: String? = nil
    ) -> NWEndpoint? {
        guard let separator = value.lastIndex(of: ":"),
              let portValue = UInt16(value[value.index(after: separator)...]),
              let port = NWEndpoint.Port(rawValue: portValue) else {
            return nil
        }
        var host = String(value[..<separator])
        guard !host.isEmpty else { return nil }
        if let interfaceName, !host.contains("%") {
            host += "%\(interfaceName)"
        }
        return .hostPort(host: NWEndpoint.Host(host), port: port)
    }
}
