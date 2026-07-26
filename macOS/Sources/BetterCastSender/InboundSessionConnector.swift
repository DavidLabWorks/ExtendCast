import Network

/// An explicit fallback endpoint for receiving a stream from a Remote Sender.
///
/// These endpoints never participate in discovery. Normal Receiver operation
/// advertises its listener and waits for the Sender to connect.
enum InboundCompatibilityEndpoint: Equatable {
    case manual(host: String, port: UInt16)
    case adb(localPort: UInt16)

    var networkEndpoint: NWEndpoint {
        switch self {
        case .manual(let host, let port):
            return .hostPort(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(rawValue: port)!
            )
        case .adb(let localPort):
            return .hostPort(
                host: "localhost",
                port: NWEndpoint.Port(rawValue: localPort)!
            )
        }
    }
}

/// Creates an outbound transport only for an explicit Receiver compatibility
/// action. The resulting media session is still an Inbound Session.
final class InboundSessionConnector {
    typealias ConnectionFactory = (NWEndpoint) -> NWConnection
    typealias ConnectionHandler = (NWConnection) -> Void

    private let connectionFactory: ConnectionFactory
    private let connectionHandler: ConnectionHandler

    init(
        connectionFactory: @escaping ConnectionFactory = {
            endpoint in
            let tcpOptions = NWProtocolTCP.Options()
            tcpOptions.enableKeepalive = true
            tcpOptions.noDelay = true
            let parameters = NWParameters(tls: nil, tcp: tcpOptions)
            parameters.serviceClass = .interactiveVideo
            return NWConnection(to: endpoint, using: parameters)
        },
        connectionHandler: @escaping ConnectionHandler
    ) {
        self.connectionFactory = connectionFactory
        self.connectionHandler = connectionHandler
    }

    func connect(to endpoint: InboundCompatibilityEndpoint) {
        connectionHandler(connectionFactory(endpoint.networkEndpoint))
    }
}
