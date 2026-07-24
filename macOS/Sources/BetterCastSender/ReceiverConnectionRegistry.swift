import Foundation
import Network

struct ReceiverConnectionRegistry {
    private var pendingConnectionIDsByReceiverKey: [String: UUID] = [:]
    private var activeReceiverKeysByConnectionID: [UUID: String] = [:]

    mutating func begin(connectionID: UUID, receiverKey: String) -> Bool {
        guard pendingConnectionIDsByReceiverKey[receiverKey] == nil else {
            return false
        }
        guard !activeReceiverKeysByConnectionID.values.contains(receiverKey) else {
            return false
        }

        pendingConnectionIDsByReceiverKey[receiverKey] = connectionID
        return true
    }

    mutating func admitReady(
        connectionID: UUID,
        pendingKey: String,
        resolvedKey: String
    ) -> Bool {
        guard pendingConnectionIDsByReceiverKey[pendingKey] == connectionID else {
            return false
        }
        pendingConnectionIDsByReceiverKey.removeValue(forKey: pendingKey)

        guard !activeReceiverKeysByConnectionID.values.contains(resolvedKey) else {
            return false
        }

        activeReceiverKeysByConnectionID[connectionID] = resolvedKey
        return true
    }

    mutating func finishPending(connectionID: UUID, receiverKey: String) {
        guard pendingConnectionIDsByReceiverKey[receiverKey] == connectionID else {
            return
        }
        pendingConnectionIDsByReceiverKey.removeValue(forKey: receiverKey)
    }

    mutating func removeActive(connectionID: UUID) {
        activeReceiverKeysByConnectionID.removeValue(forKey: connectionID)
    }

    mutating func removeAll() {
        pendingConnectionIDsByReceiverKey.removeAll()
        activeReceiverKeysByConnectionID.removeAll()
    }

    func isPending(receiverKey: String) -> Bool {
        pendingConnectionIDsByReceiverKey[receiverKey] != nil
    }
}

enum ReceiverConnectionKey {
    static func unresolved(serviceName: String, endpoint: NWEndpoint) -> String {
        key(for: endpoint)
            ?? "name:\(normalizeServiceName(serviceName))"
    }

    static func resolved(
        serviceName: String,
        endpoint: NWEndpoint,
        remoteEndpoint: NWEndpoint?
    ) -> String {
        if let remoteEndpoint, let resolvedKey = key(for: remoteEndpoint) {
            return resolvedKey
        }
        return unresolved(serviceName: serviceName, endpoint: endpoint)
    }

    private static func key(for endpoint: NWEndpoint) -> String? {
        switch endpoint {
        case .hostPort(let host, let port):
            return "host:\(String(describing: host).lowercased()):\(port.rawValue)"
        case .service(let name, _, _, _):
            return "service:\(normalizeServiceName(name))"
        default:
            return nil
        }
    }

    private static func normalizeServiceName(_ name: String) -> String {
        name
            .replacingOccurrences(
                of: #" \(\d+\)$"#,
                with: "",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}
