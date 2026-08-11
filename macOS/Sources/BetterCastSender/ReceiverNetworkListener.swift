import Foundation
import Network
import CoreMedia

struct ReceiverConnectedSender: Identifiable, Equatable {
    let connectionID: ObjectIdentifier
    var deviceID: String?
    var deviceName: String
    let connectionMode: String
    let host: String
    let port: UInt16

    var id: ObjectIdentifier { connectionID }

    var endpoint: String {
        Self.displayEndpoint(host: host, port: port)
    }

    static func displayEndpoint(host: String, port: UInt16) -> String {
        var displayHost = host
        if displayHost.hasPrefix("[") && displayHost.hasSuffix("]") {
            displayHost.removeFirst()
            displayHost.removeLast()
        }

        let unscopedHost = String(displayHost.split(separator: "%", maxSplits: 1)[0])
        let mappedIPv4Prefix = "::ffff:"
        if unscopedHost.lowercased().hasPrefix(mappedIPv4Prefix) {
            let ipv4 = String(unscopedHost.dropFirst(mappedIPv4Prefix.count))
            if IPv4Address(ipv4) != nil {
                displayHost = ipv4
            }
        }

        return displayHost.contains(":")
            ? "[\(displayHost)]:\(port)"
            : "\(displayHost):\(port)"
    }
}

/// Network listener for receiver mode — accepts incoming TCP/UDP connections from senders.
class ReceiverNetworkListener: ObservableObject, ReceiverVideoDecoderDelegate {
    private(set) var tcpListener: NWListener?
    private var udpListener: NWListener?
    private var advertisementRefreshTimer: DispatchSourceTimer?
    private var lastAdvertisedRoutes: Set<ReceiverAdvertisedRoute> = []
    private var lastAdvertisedRouteEndpoints: [
        ReceiverAdvertisedRoute: Set<String>
    ] = [:]

    @Published var status: String? = "Initializing..."
    @Published var connectedClients: [NWConnection] = []
    @Published private(set) var connectedSenders: [ReceiverConnectedSender] = []
    private var connectedSendersByConnection: [
        ObjectIdentifier: ReceiverConnectedSender
    ] = [:]
    private var lastPlaybackAcknowledgementByConnection: [
        ObjectIdentifier: Date
    ] = [:]

    private let networkQueue = DispatchQueue(label: "com.bettercast.receiver-network", qos: .userInteractive)
    private lazy var inboundCompatibilityConnector =
        InboundSessionConnector { [weak self] connection in
            self?.handleNewConnection(connection, type: .tcp)
        }

    var videoRenderer: ReceiverVideoRenderer?
    var videoDecoder: ReceiverVideoDecoder?
    var adbInputInjector: ADBInputInjector?

    // Per-connection format detection: true = has type byte, false = legacy, nil = unknown

    // Auto-reconnect state
    private var lastADBPort: UInt16?       // remote port on Android
    private var lastADBLocalPort: UInt16?  // local port for ADB tunnel
    private var lastADBPath: String?
    private var lastADBSerial: String?
    private var reconnectTimer: Timer?
    private var heartbeatTimer: Timer?
    private var staleFrameTimer: Timer?
    private var lastDecodedFrameTime: Date = .distantPast
    private(set) var isReconnecting = false
    private var isConnectingADB = false
    private var wirelessADBEnabled = false
    private var isStopped = false
    private var reconnectAttempts = 0
    private static let maxReconnectAttempts = 15

    init() {}

    func setup(decoder: ReceiverVideoDecoder, renderer: ReceiverVideoRenderer) {
        self.videoDecoder = decoder
        self.videoRenderer = renderer
        decoder.delegate = self
        renderer.onFramePresented = { [weak self] metadata in
            self?.sendPlaybackAcknowledgement(metadata)
        }
    }

    func start() {
        isStopped = false
        reconnectAttempts = 0
        // Start listeners on background queue to avoid blocking UI
        networkQueue.async { [weak self] in
            self?.startTCP()
            self?.startUDP()
        }
        // Heartbeat + stale frame timers must be on main thread (need a run loop)
        DispatchQueue.main.async { [weak self] in
            self?.startHeartbeat()
            self?.startStaleFrameWatchdog()
        }
    }

    func stop() {
        isStopped = true
        isReconnecting = false
        reconnectAttempts = 0
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        staleFrameTimer?.invalidate()
        staleFrameTimer = nil
        tcpListener?.cancel()
        tcpListener = nil
        advertisementRefreshTimer?.cancel()
        advertisementRefreshTimer = nil
        lastAdvertisedRoutes = []
        lastAdvertisedRouteEndpoints = [:]
        udpListener?.cancel()
        udpListener = nil
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        lastADBPort = nil
        lastADBLocalPort = nil
        wirelessADBEnabled = false
        for connection in connectedClients {
            connection.cancel()
        }
        connectedClients.removeAll()
        connectedSendersByConnection.removeAll()
        lastPlaybackAcknowledgementByConnection.removeAll()
        connectedSenders.removeAll()
    }

    // MARK: - ADB

    func connectViaADB(port: UInt16) {
        guard !isConnectingADB else {
            LogManager.shared.log("Receiver: ADB connect already in progress, skipping")
            return
        }
        isConnectingADB = true

        DispatchQueue.main.async {
            self.status = "Setting up ADB tunnel..."
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let adbPaths = [
                "/usr/local/bin/adb",
                "/opt/homebrew/bin/adb",
                "\(NSHomeDirectory())/Library/Android/sdk/platform-tools/adb",
                "/Users/\(NSUserName())/Library/Android/sdk/platform-tools/adb"
            ]
            let adbPath = adbPaths.first { FileManager.default.fileExists(atPath: $0) }

            guard let adb = adbPath else {
                DispatchQueue.main.async {
                    self?.status = "ADB not found. Install Android SDK or add adb to PATH."
                }
                self?.isConnectingADB = false
                return
            }

            let deviceSerial = self?.findADBDevice(adb: adb)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: adb)
            var args: [String] = []
            if let serial = deviceSerial {
                args += ["-s", serial]
            }
            // Use a different local port to avoid conflict with our own receiver.
            let localPort = port + 1  // e.g., 41821 → android:41820
            args += ["forward", "tcp:\(localPort)", "tcp:\(port)"]
            process.arguments = args
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            do {
                try process.run()
                process.waitUntilExit()

                let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

                if process.terminationStatus == 0 {
                    LogManager.shared.log("Receiver: ADB forward localhost:\(localPort) → android:\(port)")
                    self?.lastADBPort = port
                    self?.lastADBLocalPort = localPort
                    self?.lastADBPath = adb
                    self?.lastADBSerial = deviceSerial
                    let injector = ADBInputInjector(adbPath: adb, deviceSerial: deviceSerial)
                    DispatchQueue.main.async {
                        self?.adbInputInjector = injector
                    }
                    self?.connectCompatibility(to: .adb(localPort: localPort))
                    self?.isConnectingADB = false
                } else {
                    self?.isConnectingADB = false
                    DispatchQueue.main.async {
                        self?.status = "ADB forward failed: \(output.trimmingCharacters(in: .whitespacesAndNewlines))"
                    }
                }
            } catch {
                self?.isConnectingADB = false
                DispatchQueue.main.async {
                    self?.status = "Failed to run ADB: \(error.localizedDescription)"
                }
            }
        }
    }

    private func findADBDevice(adb: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: adb)
        process.arguments = ["devices"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()

            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let lines = output.components(separatedBy: "\n")
                .filter { $0.contains("\tdevice") }
                .map { $0.components(separatedBy: "\t").first ?? "" }
                .filter { !$0.isEmpty }

            if lines.count <= 1 { return nil }

            let usbDevices = lines.filter { !$0.contains(":") }
            return usbDevices.first ?? lines.first
        } catch {
            return nil
        }
    }

    private func enableWirelessADB(adb: String, serial: String?) {
        let ipProcess = Process()
        ipProcess.executableURL = URL(fileURLWithPath: adb)
        var ipArgs: [String] = []
        if let s = serial { ipArgs += ["-s", s] }
        ipArgs += ["shell", "ip", "route", "show", "dev", "wlan0"]
        ipProcess.arguments = ipArgs
        let ipPipe = Pipe()
        ipProcess.standardOutput = ipPipe
        ipProcess.standardError = ipPipe

        do {
            try ipProcess.run()
            ipProcess.waitUntilExit()
            let ipOutput = String(data: ipPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

            guard let range = ipOutput.range(of: #"src\s+(\d+\.\d+\.\d+\.\d+)"#, options: .regularExpression),
                  let ipRange = ipOutput[range].range(of: #"\d+\.\d+\.\d+\.\d+"#, options: .regularExpression) else {
                LogManager.shared.log("Receiver: Cannot determine device WiFi IP — wireless ADB skipped")
                return
            }
            let deviceIp = String(ipOutput[ipRange])

            let tcpipProcess = Process()
            tcpipProcess.executableURL = URL(fileURLWithPath: adb)
            var tcpipArgs: [String] = []
            if let s = serial { tcpipArgs += ["-s", s] }
            tcpipArgs += ["tcpip", "5555"]
            tcpipProcess.arguments = tcpipArgs
            let tcpipPipe = Pipe()
            tcpipProcess.standardOutput = tcpipPipe
            tcpipProcess.standardError = tcpipPipe

            try tcpipProcess.run()
            tcpipProcess.waitUntilExit()

            Thread.sleep(forTimeInterval: 1.5)

            let connectProcess = Process()
            connectProcess.executableURL = URL(fileURLWithPath: adb)
            connectProcess.arguments = ["connect", "\(deviceIp):5555"]
            let connectPipe = Pipe()
            connectProcess.standardOutput = connectPipe
            connectProcess.standardError = connectPipe

            try connectProcess.run()
            connectProcess.waitUntilExit()
            let connectOutput = String(data: connectPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

            if connectOutput.contains("connected") || connectOutput.contains("already") {
                LogManager.shared.log("Receiver: Wireless ADB enabled (\(deviceIp):5555)")
                DispatchQueue.main.async {
                    self.status = "ADB connected (wireless enabled)"
                }
            }
        } catch {
            LogManager.shared.log("Receiver: Wireless ADB setup error: \(error)")
        }
    }

    // MARK: - TCP/UDP

    /// Explicit compatibility fallback. Normal Receiver operation advertises
    /// the listener and waits for the Remote Sender to connect.
    func connectManuallyToRemoteSender(host: String, port: UInt16) {
        connectCompatibility(to: .manual(host: host, port: port))
    }

    private func connectCompatibility(
        to endpoint: InboundCompatibilityEndpoint
    ) {
        LogManager.shared.log(
            "Receiver: Starting explicit compatibility connection to "
                + "\(endpoint.networkEndpoint)"
        )
        DispatchQueue.main.async {
            self.status = "Starting compatibility connection..."
        }
        inboundCompatibilityConnector.connect(to: endpoint)
    }

    private func startHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let heartbeatEvent = InputEvent(type: .command, keyCode: 888)
            guard let data = try? JSONEncoder().encode(heartbeatEvent) else { return }
            var packet = Data()
            var length32 = UInt32(data.count).bigEndian
            packet.append(Data(bytes: &length32, count: 4))
            packet.append(data)

            self.networkQueue.async {
                for connection in self.connectedClients {
                    connection.send(content: packet, completion: .contentProcessed({ _ in }))
                }
            }
        }
    }

    enum ConnectionType {
        case tcp
        case udp
    }

    private func startTCP() {
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.enableKeepalive = true
        tcpOptions.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcpOptions)
        parameters.includePeerToPeer = true
        parameters.allowLocalEndpointReuse = true
        parameters.serviceClass = .interactiveVideo

        // Try preferred port first, fall back to OS-assigned port
        let preferredPort: NWEndpoint.Port = NWEndpoint.Port(integerLiteral: BCConstants.tcpPort)
        var listener: NWListener
        do {
            listener = try NWListener(using: parameters, on: preferredPort)
            LogManager.shared.log("Receiver (TCP): Binding to port \(preferredPort)")
        } catch {
            LogManager.shared.log("Receiver (TCP): Port \(preferredPort) unavailable (\(error.localizedDescription)), using system-assigned port")
            do {
                listener = try NWListener(using: parameters)
            } catch {
                LogManager.shared.log("Receiver (TCP): Failed to create listener: \(error)")
                return
            }
        }

        let macName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        updateAdvertisement(listener: listener, name: macName)

        listener.stateUpdateHandler = { [weak self] state in
            self?.handleListenerState(state, type: "TCP", listener: listener)
        }

        listener.newConnectionHandler = { [weak self] connection in
            LogManager.shared.log("Receiver (TCP): New connection from \(connection.endpoint)")
            self?.handleNewConnection(connection, type: .tcp)
        }

        listener.start(queue: networkQueue)
        self.tcpListener = listener
        let refreshTimer = DispatchSource.makeTimerSource(queue: networkQueue)
        refreshTimer.schedule(deadline: .now() + 2, repeating: 2)
        refreshTimer.setEventHandler { [weak self, weak listener] in
            guard let self, let listener else { return }
            self.updateAdvertisement(listener: listener, name: macName)
        }
        refreshTimer.resume()
        advertisementRefreshTimer = refreshTimer
    }

    private func updateAdvertisement(listener: NWListener, name: String) {
        let advertisedPort =
            listener.port?.rawValue ?? BCConstants.tcpPort
        let localRoutes = ReceiverConnectionAddressProvider
            .availableAddresses(port: advertisedPort)
        var routes = Set(
            localRoutes.compactMap { address -> ReceiverAdvertisedRoute? in
                switch address.title {
                case "Wi-Fi": return .wifi
                case "Ethernet": return .ethernet
                case "Thunderbolt Bridge": return .thunderbolt
                default: return nil
                }
            }
        )
        if routes.contains(.wifi) {
            routes.insert(.peerToPeer)
        }
        let routeEndpoints = Dictionary(
            grouping: localRoutes.compactMap {
                address -> (ReceiverAdvertisedRoute, String)? in
                switch address.title {
                case "Wi-Fi": return (.wifi, address.address)
                case "Ethernet": return (.ethernet, address.address)
                case "Thunderbolt Bridge":
                    return (.thunderbolt, address.address)
                default: return nil
                }
            },
            by: \.0
        ).mapValues { Set($0.map(\.1)) }
        let advertisement = ReceiverAdvertisement(
            routes: routes,
            routeEndpoints: routeEndpoints
        )
        guard routes != lastAdvertisedRoutes
                || routeEndpoints != lastAdvertisedRouteEndpoints else {
            return
        }
        lastAdvertisedRoutes = routes
        lastAdvertisedRouteEndpoints = routeEndpoints
        listener.service = NWListener.Service(
            name: name,
            type: "_bettercast._tcp",
            txtRecord: advertisement.txtRecord
        )
        LogManager.shared.log(
            "Receiver: Advertising routes "
                + routes.map(\.rawValue).sorted().joined(separator: ",")
        )
    }

    private func startUDP() {
        do {
            let parameters = NWParameters.udp
            parameters.includePeerToPeer = true
            parameters.allowLocalEndpointReuse = true
            parameters.serviceClass = .responsiveData
            parameters.preferNoProxies = true

            let listener = try NWListener(
                using: parameters,
                on: NWEndpoint.Port(rawValue: BCConstants.udpPort)!
            )
            listener.stateUpdateHandler = { [weak self] state in
                self?.handleListenerState(state, type: "UDP", listener: listener)
            }

            listener.newConnectionHandler = { [weak self] connection in
                LogManager.shared.log("Receiver (UDP): New connection from \(connection.endpoint)")
                self?.handleNewConnection(connection, type: .udp)
            }

            listener.start(queue: networkQueue)
            self.udpListener = listener
        } catch {
            LogManager.shared.log("Receiver (UDP): Error \(error)")
        }
    }

    private func handleListenerState(_ state: NWListener.State, type: String, listener: NWListener? = nil) {
        DispatchQueue.main.async {
            switch state {
            case .ready:
                let portStr: String
                if let port = listener?.port {
                    portStr = " on port \(port)"
                } else {
                    portStr = ""
                }
                if type == "TCP" {
                    self.status = "Ready\(portStr). Advertising as _bettercast._tcp"
                }
                LogManager.shared.log("Receiver (\(type)): Ready\(portStr)")
            case .failed(let error):
                if type == "TCP" {
                    self.status = "Failed: \(error.localizedDescription)"
                    LogManager.shared.log("Receiver (TCP): Failed — \(error). Check if port \(BCConstants.tcpPort) is in use or if macOS firewall is blocking incoming connections.")
                } else {
                    LogManager.shared.log("Receiver (\(type)): Failed \(error)")
                }
            default:
                break
            }
        }
    }

    private func handleNewConnection(_ connection: NWConnection, type: ConnectionType) {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                LogManager.shared.log("Receiver: \(type) Connection ready")
                DispatchQueue.main.async {
                    if let self = self {
                        if !self.connectedClients.contains(where: { $0 === connection }) {
                            self.connectedClients.append(connection)
                        }
                        if type == .tcp {
                            self.registerConnectedSender(connection)
                        }
                        if self.lastADBPort != nil && !self.wirelessADBEnabled,
                           let adb = self.lastADBPath {
                            self.wirelessADBEnabled = true
                            // Delay 5s — adb tcpip 5555 kills USB tunnel momentarily
                            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5.0) {
                                self.enableWirelessADB(adb: adb, serial: self.lastADBSerial)
                            }
                        }
                        // Request a keyframe immediately so the sender sends a fresh IDR.
                        // Without this, the receiver may only get P-frames (undeccodable)
                        // until the next natural keyframe interval.
                        self.sendInputEvent(InputEvent(type: .command, keyCode: 999))
                    }
                }
                if type == .udp {
                    self?.receiveUDP(on: connection)
                } else {
                    self?.receiveTCP(on: connection)
                }
            case .failed(let error):
                LogManager.shared.log("Receiver: Connection failed \(error)")
                self?.removeConnection(connection)
            case .cancelled:
                self?.removeConnection(connection)
            default:
                break
            }
        }
        connection.start(queue: networkQueue)
    }

    private func receiveTCP(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] content, contentContext, isComplete, error in
            if let error = error {
                LogManager.shared.log("Receiver (TCP): Error \(error)")
                connection.cancel()
                return
            }

            if isComplete && (content == nil || content!.isEmpty) {
                LogManager.shared.log("Receiver (TCP): Stream closed by peer")
                connection.cancel()
                return
            }

            if let content = content, content.count == 4 {
                let length = content.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
                let bodyLength = Int(length)

                connection.receive(minimumIncompleteLength: bodyLength, maximumLength: bodyLength) { body, bodyContext, bodyComplete, bodyError in
                    if let bodyError = bodyError {
                        LogManager.shared.log("Receiver (TCP): Body read error \(bodyError)")
                        connection.cancel()
                        return
                    }
                    if let body = body, !body.isEmpty {
                        self?.handleReceivedBody(body, connection: connection)
                    }
                    if bodyComplete && (body == nil || body!.isEmpty) {
                        connection.cancel()
                        return
                    }
                    self?.receiveTCP(on: connection)
                }
            } else {
                self?.receiveTCP(on: connection)
            }
        }
    }

    private func handleReceivedBody(_ body: Data, connection: NWConnection) {
        let typeByte = body[body.startIndex]
        let payload = Data(body.dropFirst(1))
        if typeByte == 0x01 && !payload.isEmpty {
            videoDecoder?.decode(
                data: payload,
                sourceConnectionID: ObjectIdentifier(connection)
            )
        } else if typeByte == 0x02 {
            // TODO: route to audio decoder
        } else if typeByte == 0x03 {
            registerSenderIdentity(payload, for: connection)
        }
    }

    // UDP Reassembly
    private var udpBuffer: [UInt32: (total: Int, chunks: [UInt16: Data], time: Date)] = [:]
    private let udpLock = NSLock()
    private var udpPacketsReceived = 0
    private var udpFramesReassembled = 0
    private var udpFramesIncomplete = 0
    private var lastStatsTime = Date()

    private func receiveUDP(on connection: NWConnection) {
        connection.receiveMessage { [weak self] content, contentContext, isComplete, error in
            if let error = error {
                LogManager.shared.log("Receiver (UDP): Error \(error)")
                return
            }

            if let content = content, !content.isEmpty {
                self?.handleUDPPacket(
                    content,
                    sourceConnectionID: ObjectIdentifier(connection)
                )
            }
            self?.receiveUDP(on: connection)
        }
    }

    private var lastDecodedFrameId: UInt32 = 0
    private var lastKeyframeRequest = Date.distantPast

    private func handleUDPPacket(
        _ data: Data,
        sourceConnectionID: ObjectIdentifier
    ) {
        guard data.count > 8 else { return }

        let header = data.prefix(8)
        let payload = data.dropFirst(8)

        let frameID = header.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self).bigEndian }
        let chunkID = header.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt16.self).bigEndian }
        let totalChunks = header.withUnsafeBytes { $0.load(fromByteOffset: 6, as: UInt16.self).bigEndian }

        udpLock.lock()
        defer { udpLock.unlock() }

        if lastDecodedFrameId == 0 { lastDecodedFrameId = frameID &- 1 }

        udpPacketsReceived += 1

        if udpBuffer[frameID] == nil {
            udpBuffer[frameID] = (total: Int(totalChunks), chunks: [:], time: Date())
        }

        udpBuffer[frameID]?.chunks[chunkID] = payload

        if let entry = udpBuffer[frameID], entry.chunks.count == entry.total {
            udpFramesReassembled += 1

            let diff = Int(frameID) - Int(lastDecodedFrameId)
            if diff > 1 && diff < 1000 {
                if Date().timeIntervalSince(lastKeyframeRequest) > 2.0 {
                    sendInputEvent(
                        InputEvent(type: .command, keyCode: 999),
                        to: sourceConnectionID
                    )
                    lastKeyframeRequest = Date()
                }
            }
            lastDecodedFrameId = frameID

            let sortedChunks = entry.chunks.sorted { $0.key < $1.key }
            var fullData = Data()
            for (_, chunkData) in sortedChunks {
                fullData.append(chunkData)
            }

            self.videoDecoder?.decode(
                data: fullData,
                sourceConnectionID: sourceConnectionID
            )
            udpBuffer.removeValue(forKey: frameID)
        }

        if udpPacketsReceived % 100 == 0 {
            for (key, val) in udpBuffer {
                if val.time.timeIntervalSinceNow < -1.0 {
                    udpBuffer.removeValue(forKey: key)
                }
            }
        }
    }

    private func removeConnection(_ connection: NWConnection) {
        let connId = ObjectIdentifier(connection)
        DispatchQueue.main.async {
            self.connectedClients.removeAll(where: { $0 === connection })
            self.connectedSendersByConnection.removeValue(forKey: connId)
            self.lastPlaybackAcknowledgementByConnection.removeValue(
                forKey: connId
            )
            self.publishConnectedSenders()
            // Do NOT reset wirelessADBEnabled — once enabled, it stays enabled
            // to prevent re-running adb tcpip 5555 on every reconnect
            guard !self.isStopped else { return }
            if self.connectedClients.isEmpty && self.lastADBPort != nil {
                self.startReconnectTimer()
            }
        }
    }

    private func registerConnectedSender(_ connection: NWConnection) {
        let connectionID = ObjectIdentifier(connection)
        let endpoint = Self.remoteEndpoint(for: connection)
        connectedSendersByConnection[connectionID] = ReceiverConnectedSender(
            connectionID: connectionID,
            deviceID: nil,
            deviceName: "Unknown Sender",
            connectionMode: Self.connectionMode(for: connection),
            host: endpoint.host,
            port: endpoint.port
        )
        publishConnectedSenders()
    }

    private func registerSenderIdentity(
        _ payload: Data,
        for connection: NWConnection
    ) {
        guard let identity = try? JSONDecoder().decode(
            SenderIdentity.Payload.self,
            from: payload
        ),
        identity.protocolVersion == 1,
        !identity.deviceId.isEmpty,
        !identity.deviceName.isEmpty else {
            LogManager.shared.log("Receiver: Invalid sender identity")
            return
        }

        DispatchQueue.main.async {
            let connectionID = ObjectIdentifier(connection)
            let endpoint = Self.remoteEndpoint(for: connection)
            let existing = self.connectedSendersByConnection[connectionID]
            let sender = ReceiverConnectedSender(
                connectionID: connectionID,
                deviceID: identity.deviceId,
                deviceName: identity.deviceName,
                connectionMode: existing?.connectionMode
                    ?? Self.connectionMode(for: connection),
                host: existing?.host ?? endpoint.host,
                port: existing?.port ?? endpoint.port
            )
            self.connectedSendersByConnection[connectionID] = sender
            self.publishConnectedSenders()
            LogManager.shared.log(
                "Receiver: Identified \(identity.deviceName) "
                    + "(\(identity.deviceId)) at "
                    + sender.endpoint
            )
        }
    }

    private func publishConnectedSenders() {
        connectedSenders = connectedSendersByConnection.values.sorted {
            let nameOrder = $0.deviceName.localizedCaseInsensitiveCompare(
                $1.deviceName
            )
            if nameOrder != .orderedSame {
                return nameOrder == .orderedAscending
            }
            return $0.endpoint < $1.endpoint
        }
    }

    private static func remoteEndpoint(
        for connection: NWConnection
    ) -> (host: String, port: UInt16) {
        guard case .hostPort(let host, let port) = connection.endpoint else {
            return (String(describing: connection.endpoint), 0)
        }
        return (String(describing: host), port.rawValue)
    }

    private static func connectionMode(for connection: NWConnection) -> String {
        guard let path = connection.currentPath else {
            return "Local Network"
        }
        let interfaceNames = path.availableInterfaces.map {
            $0.name.lowercased()
        }
        if interfaceNames.contains(where: {
            $0 == "awdl0" || $0 == "llw0"
        }) {
            return "Wi-Fi Direct"
        }
        if interfaceNames.contains(where: {
            $0 == "bridge0" || $0.contains("thunderbolt")
        }) {
            return "Thunderbolt Bridge"
        }
        if path.usesInterfaceType(.wifi) {
            return "Wi-Fi"
        }
        if path.usesInterfaceType(.wiredEthernet) {
            return "Ethernet"
        }
        if path.usesInterfaceType(.loopback) {
            return "Compatibility"
        }
        return "Local Network"
    }

    private func startReconnectTimer() {
        guard !isReconnecting, !isStopped else { return }
        isReconnecting = true
        reconnectAttempts = 0
        stopReconnectTimer()
        LogManager.shared.log("Receiver: Connection lost. Will auto-reconnect via ADB...")
        DispatchQueue.main.async {
            self.status = "Reconnecting via ADB..."
        }

        reconnectTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.attemptADBReconnect()
        }
        attemptADBReconnect()
    }

    private func stopReconnectTimer() {
        reconnectTimer?.invalidate()
        reconnectTimer = nil
    }

    private func attemptADBReconnect() {
        guard let port = lastADBPort, !isStopped else { return }

        reconnectAttempts += 1
        if reconnectAttempts > Self.maxReconnectAttempts {
            stopReconnectTimer()
            isReconnecting = false
            LogManager.shared.log("Receiver: ADB auto-reconnect failed after \(Self.maxReconnectAttempts) attempts")
            DispatchQueue.main.async {
                self.status = "Reconnect failed. Tap 'Connect via ADB' to retry."
            }
            return
        }

        LogManager.shared.log("Receiver: ADB reconnect attempt \(reconnectAttempts)/\(Self.maxReconnectAttempts)")
        DispatchQueue.main.async {
            self.status = "Reconnecting via ADB (\(self.reconnectAttempts)/\(Self.maxReconnectAttempts))..."
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            let adb: String
            if let saved = self.lastADBPath, FileManager.default.fileExists(atPath: saved) {
                adb = saved
            } else {
                let adbPaths = [
                    "/usr/local/bin/adb",
                    "/opt/homebrew/bin/adb",
                    "\(NSHomeDirectory())/Library/Android/sdk/platform-tools/adb",
                    "/Users/\(NSUserName())/Library/Android/sdk/platform-tools/adb"
                ]
                guard let found = adbPaths.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
                    return
                }
                adb = found
            }

            let deviceSerial = self.findADBDevice(adb: adb)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: adb)
            var args: [String] = []
            if let serial = deviceSerial {
                args += ["-s", serial]
            }
            let localPort = port + 1
            args += ["forward", "tcp:\(localPort)", "tcp:\(port)"]
            process.arguments = args
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            do {
                try process.run()
                process.waitUntilExit()

                if process.terminationStatus == 0 {
                    self.lastADBPath = adb
                    self.lastADBSerial = deviceSerial
                    self.lastADBLocalPort = localPort

                    let injector = ADBInputInjector(adbPath: adb, deviceSerial: deviceSerial)
                    DispatchQueue.main.async {
                        self.adbInputInjector = injector
                        // Don't reset isReconnecting/reconnectAttempts or stop timer here.
                        // The ADB forward succeeds but the TCP connection may still fail.
                        // Reset happens in didDecode() when frames actually arrive.
                    }
                    self.connectCompatibility(
                        to: .adb(localPort: localPort)
                    )
                }
            } catch {
                LogManager.shared.log("Receiver: ADB reconnect error: \(error)")
            }
        }
    }

    // MARK: - Stale Frame Watchdog

    /// Detects when video frames stop arriving while clients are connected,
    /// and requests a keyframe to recover (e.g. after Android encoder restart).
    private func startStaleFrameWatchdog() {
        staleFrameTimer?.invalidate()
        staleFrameTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            guard let self = self, !self.connectedClients.isEmpty else { return }
            let neverGotFrames = (self.lastDecodedFrameTime == .distantPast)
            let staleDuration = Date().timeIntervalSince(self.lastDecodedFrameTime)

            if neverGotFrames || staleDuration > 3.0 {
                if !neverGotFrames {
                    LogManager.shared.log("Receiver: No frames for \(Int(staleDuration))s — requesting keyframe")
                    self.videoRenderer?.flushForFormatChange()
                    self.videoDecoder?.reset()
                }
                self.sendInputEvent(InputEvent(type: .command, keyCode: 999))
            }
        }
    }

    // MARK: - VideoDecoderDelegate

    func didDecode(frame: ReceiverDecodedVideoFrame) {
        videoRenderer?.offer(frame)
        DispatchQueue.main.async {
            self.lastDecodedFrameTime = Date()
            if self.isReconnecting {
                self.isReconnecting = false
                self.reconnectAttempts = 0
                self.stopReconnectTimer()
                LogManager.shared.log(
                    "Receiver: Connection recovered — stream active"
                )
            }
        }
    }

    func decoderDidChangeFormat() {
        LogManager.shared.log("Receiver: Format changed — flushing display layer")
        videoRenderer?.flushForFormatChange()
    }

    func decoderNeedsKeyframe() {
        LogManager.shared.log("Receiver: Requesting keyframe from sender")
        sendInputEvent(InputEvent(type: .command, keyCode: 999))
    }

    static func transmissionRepeatCount(for event: InputEvent) -> Int {
        if event.type == .command,
           (event.keyCode == 666 || event.keyCode == 888) {
            return 1
        }

        let isCritical = event.type == .leftMouseDown
            || event.type == .leftMouseUp
            || event.type == .rightMouseDown
            || event.type == .rightMouseUp
            || event.type == .keyDown
            || event.type == .keyUp
            || event.type == .command
        return isCritical ? 3 : 1
    }

    func requestFreshVideoFrame() {
        sendInputEvent(InputEvent(type: .command, keyCode: 999))
    }

    private func sendPlaybackAcknowledgement(
        _ metadata: ReceiverVideoFrameMetadata
    ) {
        guard let connectionID = metadata.sourceConnectionID else { return }

        let now = Date()
        if let lastSent = lastPlaybackAcknowledgementByConnection[connectionID],
           now.timeIntervalSince(lastSent) < 0.25 {
            return
        }
        lastPlaybackAcknowledgementByConnection[connectionID] = now

        sendInputEvent(
            InputEvent(
                type: .command,
                keyCode: 666,
                streamID: String(metadata.streamID),
                sequence: String(metadata.sequence),
                presentationTimestampNanoseconds: String(
                    metadata.presentationTimestampNanoseconds
                )
            ),
            to: connectionID
        )
    }

    func sendInputEvent(
        _ event: InputEvent,
        to sourceConnectionID: ObjectIdentifier? = nil
    ) {
        if event.type != .command {
            adbInputInjector?.inject(event)
        }

        let repeatCount = Self.transmissionRepeatCount(for: event)

        guard let data = try? JSONEncoder().encode(event) else { return }

        var packet = Data()
        var length32 = UInt32(data.count).bigEndian
        packet.append(Data(bytes: &length32, count: 4))
        packet.append(data)

        networkQueue.async { [weak self] in
            guard let self = self else { return }
            for connection in self.connectedClients {
                if let sourceConnectionID,
                   ObjectIdentifier(connection) != sourceConnectionID {
                    continue
                }
                for _ in 0..<repeatCount {
                    connection.send(content: packet, completion: .contentProcessed { _ in })
                }
            }
        }
    }
}

/// Injects input events into Android via `adb shell input` commands.
class ADBInputInjector {
    private let adbPath: String
    private let deviceSerial: String?
    private var screenWidth: Int = 1080
    private var screenHeight: Int = 2400
    private let queue = DispatchQueue(label: "com.bettercast.adb-input", qos: .userInteractive)
    private var isMouseDown = false
    private var lastScrollTime: Date = .distantPast

    init(adbPath: String, deviceSerial: String?) {
        self.adbPath = adbPath
        self.deviceSerial = deviceSerial
        fetchScreenSize()
    }

    private func fetchScreenSize() {
        queue.async { [weak self] in
            guard let self = self else { return }
            let output = self.runADB(["shell", "wm", "size"])
            if let match = output.range(of: #"(\d+)x(\d+)"#, options: .regularExpression) {
                let sizeStr = String(output[match])
                let parts = sizeStr.split(separator: "x")
                if parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]) {
                    self.screenWidth = w
                    self.screenHeight = h
                }
            }
        }
    }

    func inject(_ event: InputEvent) {
        queue.async { [weak self] in
            self?.handleEvent(event)
        }
    }

    private func handleEvent(_ event: InputEvent) {
        let px = Int(event.x * Double(screenWidth))
        let py = Int(event.y * Double(screenHeight))

        switch event.type {
        case .leftMouseDown:
            isMouseDown = true
        case .leftMouseUp:
            if isMouseDown {
                isMouseDown = false
                runADB(["shell", "input", "tap", "\(px)", "\(py)"])
            }
        case .scrollWheel:
            let now = Date()
            guard now.timeIntervalSince(lastScrollTime) > 0.3 else { return }
            lastScrollTime = now
            let swipeDistance = 200
            let dy = event.deltaY > 0 ? -swipeDistance : swipeDistance
            let endY = min(max(py + dy, 0), screenHeight)
            runADB(["shell", "input", "swipe", "\(px)", "\(py)", "\(px)", "\(endY)", "100"])
        case .keyDown:
            if let androidKey = macToAndroidKeyCode(event.keyCode) {
                runADB(["shell", "input", "keyevent", "\(androidKey)"])
            }
        case .rightMouseDown:
            runADB(["shell", "input", "keyevent", "4"])
        default:
            break
        }
    }

    @discardableResult
    private func runADB(_ args: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: adbPath)
        var fullArgs: [String] = []
        if let serial = deviceSerial {
            fullArgs += ["-s", serial]
        }
        fullArgs += args
        process.arguments = fullArgs
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }

    private func macToAndroidKeyCode(_ macKey: UInt16) -> Int? {
        switch macKey {
        case 36: return 66   // Return
        case 51: return 67   // Delete
        case 53: return 4    // Escape -> Back
        case 48: return 61   // Tab
        case 49: return 62   // Space
        case 123: return 21  // Left
        case 124: return 22  // Right
        case 125: return 20  // Down
        case 126: return 19  // Up
        case 115: return 122 // Home
        case 119: return 123 // End
        case 116: return 92  // Page Up
        case 121: return 93  // Page Down
        case 72: return 24   // Volume Up
        case 73: return 25   // Volume Down
        default: return nil
        }
    }
}
