import SwiftUI
import Network
import Combine
import AppKit
import Darwin
import SystemConfiguration

// MARK: - Receiver Video Window

/// Manages a separate NSWindow for displaying received video.
class ReceiverWindowController {
    private var window: NSWindow?
    private var lastVideoSize: CGSize = .zero
    private var resizeDebounceWork: DispatchWorkItem?

    var isOpen: Bool { window != nil }

    func open(renderer: ReceiverVideoRenderer) {
        guard window == nil else {
            window?.orderFront(nil)
            return
        }

        // Position the video window to the right of the main app window
        let mainFrame = NSApp.mainWindow?.frame
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)

        let videoWidth: CGFloat = 960
        let videoHeight: CGFloat = 540
        let videoOrigin: NSPoint
        if let mainFrame = mainFrame {
            // Place to the right of the main window, or if no room, to the left
            let rightX = mainFrame.maxX + 12
            if rightX + videoWidth <= screenFrame.maxX {
                videoOrigin = NSPoint(x: rightX, y: mainFrame.midY - videoHeight / 2)
            } else {
                let leftX = mainFrame.minX - videoWidth - 12
                videoOrigin = NSPoint(x: max(leftX, screenFrame.minX), y: mainFrame.midY - videoHeight / 2)
            }
        } else {
            videoOrigin = NSPoint(
                x: screenFrame.midX - videoWidth / 2,
                y: screenFrame.midY - videoHeight / 2
            )
        }

        let w = NSWindow(
            contentRect: NSRect(origin: videoOrigin, size: NSSize(width: videoWidth, height: videoHeight)),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        w.title = "ExtendCast — Receiving"
        w.backgroundColor = .black
        w.isReleasedWhenClosed = false
        w.contentMinSize = NSSize(width: 320, height: 180)
        w.collectionBehavior = [.fullScreenPrimary]

        // Place the renderer view as the window content
        w.contentView = renderer.view
        renderer.view.frame = w.contentView!.bounds
        renderer.view.autoresizingMask = [.width, .height]
        renderer.layout()

        // Show without stealing focus from the main window
        w.orderFront(nil)

        // Watch for window close
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: w,
            queue: .main
        ) { [weak self] _ in
            self?.window = nil
            self?.lastVideoSize = .zero
        }

        self.window = w
    }

    /// Resize window to match the video's aspect ratio, keeping the same area on screen.
    /// Uses debouncing to avoid rapid flip-flopping during Android rotation transitions.
    func resizeToFitVideo(_ size: CGSize) {
        guard window != nil, size.width > 0, size.height > 0 else { return }
        guard size != lastVideoSize else { return }
        lastVideoSize = size

        // Cancel any pending resize — only the last size wins
        resizeDebounceWork?.cancel()

        let work = DispatchWorkItem { [weak self] in
            self?.performResize(to: size)
        }
        resizeDebounceWork = work

        // Wait 300ms for dimensions to stabilize (Android sends transitional frames during rotation)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func performResize(to size: CGSize) {
        guard let w = window, size.width > 0, size.height > 0 else { return }

        let screenFrame = w.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let aspect = size.width / size.height

        // Target: preserve roughly the same window area, but match aspect ratio
        let currentFrame = w.frame
        let currentArea = currentFrame.width * currentFrame.height
        // newW * newH = currentArea, newW / newH = aspect
        // newH = sqrt(currentArea / aspect), newW = aspect * newH
        var newHeight = sqrt(currentArea / aspect)
        var newWidth = aspect * newHeight

        // Clamp to screen bounds with some padding
        let maxW = screenFrame.width * 0.9
        let maxH = screenFrame.height * 0.9
        if newWidth > maxW {
            newWidth = maxW
            newHeight = newWidth / aspect
        }
        if newHeight > maxH {
            newHeight = maxH
            newWidth = newHeight * aspect
        }

        // Keep the window centered on its current center
        let centerX = currentFrame.midX
        let centerY = currentFrame.midY
        var newOriginX = centerX - newWidth / 2
        var newOriginY = centerY - newHeight / 2

        // Ensure the window stays on screen
        newOriginX = max(screenFrame.minX, min(newOriginX, screenFrame.maxX - newWidth))
        newOriginY = max(screenFrame.minY, min(newOriginY, screenFrame.maxY - newHeight))

        let newFrame = NSRect(x: newOriginX, y: newOriginY, width: newWidth, height: newHeight)
        // Use animate: false to avoid stuck mid-animation when rapid resizes overlap
        w.setFrame(newFrame, display: true, animate: false)
    }

    func close() {
        resizeDebounceWork?.cancel()
        resizeDebounceWork = nil
        window?.close()
        window = nil
    }

    func updateTitle(senderCount: Int) {
        guard let w = window else { return }
        if senderCount > 0 {
            w.title = "ExtendCast — \(senderCount) sender\(senderCount == 1 ? "" : "s")"
        } else {
            w.title = "ExtendCast — Receiving"
        }
    }
}

// MARK: - Receiver Manager

/// Singleton that owns receiver state so it survives sidebar navigation.
class ReceiverManager: ObservableObject {
    static let shared = ReceiverManager()

    let networkListener = ReceiverNetworkListener()
    let videoDecoder = ReceiverVideoDecoder()
    let videoRenderer = ReceiverVideoRenderer()
    let windowController = ReceiverWindowController()
    @Published var isRunning = false

    private var cancellables = Set<AnyCancellable>()

    private init() {
        // Forward child objectWillChange so SwiftUI redraws when nested state changes
        networkListener.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // Auto-open/close window when clients connect/disconnect
        networkListener.$connectedClients
            .receive(on: DispatchQueue.main)
            .sink { [weak self] clients in
                guard let self = self else { return }
                if !clients.isEmpty {
                    self.windowController.open(renderer: self.videoRenderer)
                    self.windowController.updateTitle(senderCount: clients.count)
                } else if self.windowController.isOpen {
                    // Don't close window during ADB reconnect — it causes flicker
                    let isReconnecting = self.networkListener.isReconnecting
                    if !isReconnecting {
                        self.windowController.close()
                    }
                }
            }
            .store(in: &cancellables)

        // Auto-resize window when video dimensions change (e.g. portrait Android)
        videoRenderer.$videoSize
            .receive(on: DispatchQueue.main)
            .sink { [weak self] size in
                self?.windowController.resizeToFitVideo(size)
            }
            .store(in: &cancellables)
    }

    func start() {
        guard !isRunning else { return }
        networkListener.setup(decoder: videoDecoder, renderer: videoRenderer)
        videoRenderer.onInput = { [weak self] event in
            self?.networkListener.sendInputEvent(event)
        }
        networkListener.start()
        isRunning = true
        LogManager.shared.log("ReceiverMode: Started listening")
    }

    func stop() {
        windowController.close()
        networkListener.stop()
        videoDecoder.reset()
        videoRenderer.flush()
        isRunning = false
        LogManager.shared.log("ReceiverMode: Stopped")
    }

    func showWindow() {
        windowController.open(renderer: videoRenderer)
    }
}

// MARK: - Receiver Connection Addresses

struct ReceiverConnectionAddress: Identifiable, Equatable {
    let interfaceName: String
    let title: String
    let address: String
    let usageHint: String
    let priority: Int

    var id: String { "\(interfaceName)-\(address)" }
}

enum ReceiverConnectionAddressProvider {
    static func availableAddresses(port: UInt16) -> [ReceiverConnectionAddress] {
        let displayNames = hardwarePortDisplayNames()

        return interfaceIPv4Addresses().compactMap { interfaceName, address in
            connectionAddress(
                interfaceName: interfaceName,
                displayName: displayNames[interfaceName],
                address: address,
                port: port
            )
        }
        .sorted {
            if $0.priority != $1.priority {
                return $0.priority < $1.priority
            }
            if $0.title != $1.title {
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
            return $0.address.localizedStandardCompare($1.address) == .orderedAscending
        }
    }

    static func connectionAddress(
        interfaceName: String,
        displayName: String?,
        address: String,
        port: UInt16
    ) -> ReceiverConnectionAddress? {
        let lowerInterface = interfaceName.lowercased()
        let lowerDisplayName = displayName?.lowercased() ?? ""
        let isProxyAddress = address.hasPrefix("198.18.")
            || address.hasPrefix("198.19.")
            || lowerDisplayName.contains("mihomo")
            || lowerDisplayName.contains("clash")
            || lowerDisplayName.contains("proxy")

        guard !address.hasPrefix("127."),
              !isProxyAddress,
              !["lo", "awdl", "llw", "ap", "anpi", "vmenet"].contains(where: lowerInterface.hasPrefix),
              !lowerInterface.hasPrefix("bridge1"),
              !lowerInterface.hasPrefix("bridge2"),
              !lowerInterface.hasPrefix("bridge100") else {
            return nil
        }

        let title: String
        let usageHint: String
        let priority: Int

        if lowerInterface == "bridge0" || lowerDisplayName.contains("thunderbolt") {
            title = "Thunderbolt Bridge"
            usageHint = "Connect directly over Thunderbolt."
            priority = 20
        } else if lowerDisplayName.contains("wi-fi")
                    || lowerDisplayName.contains("airport")
                    || lowerInterface == "en0" {
            title = "Wi-Fi"
            usageHint = "Connect through the Wi-Fi network."
            priority = 10
        } else if lowerDisplayName.contains("ethernet")
                    || lowerInterface.hasPrefix("en") {
            title = "Ethernet"
            usageHint = "Connect through the wired local network."
            priority = 30
        } else {
            return nil
        }

        return ReceiverConnectionAddress(
            interfaceName: interfaceName,
            title: title,
            address: "\(address):\(port)",
            usageHint: usageHint,
            priority: priority
        )
    }

    private static func hardwarePortDisplayNames() -> [String: String] {
        guard let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else {
            return [:]
        }

        return interfaces.reduce(into: [:]) { names, interface in
            guard let bsdName = SCNetworkInterfaceGetBSDName(interface) as String? else {
                return
            }
            let displayName = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String?
            names[bsdName] = displayName ?? bsdName
        }
    }

    private static func interfaceIPv4Addresses() -> [(String, String)] {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else {
            return []
        }
        defer { freeifaddrs(pointer) }

        var results: [(String, String)] = []
        var current: UnsafeMutablePointer<ifaddrs>? = first

        while let interface = current?.pointee {
            defer { current = interface.ifa_next }

            guard let socketAddress = interface.ifa_addr,
                  socketAddress.pointee.sa_family == UInt8(AF_INET),
                  interface.ifa_flags & UInt32(IFF_UP) != 0,
                  interface.ifa_flags & UInt32(IFF_RUNNING) != 0 else {
                continue
            }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                socketAddress,
                socklen_t(socketAddress.pointee.sa_len),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard result == 0 else { continue }

            results.append((
                String(cString: interface.ifa_name),
                String(cString: host)
            ))
        }

        return results
    }
}

private struct ReceiverOnOffToggle: View {
    @Binding var isOn: Bool
    let accessibilityLabel: String

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                isOn.toggle()
            }
        } label: {
            Text(isOn ? "On" : "Off")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isOn ? Color.white : Color.secondary)
                .frame(width: 74, height: 32)
                .background(isOn ? Color.green : Color.secondary.opacity(0.12))
                .clipShape(Capsule())
                .overlay {
                    Capsule()
                        .stroke(
                            isOn ? Color.green.opacity(0.8) : Color.secondary.opacity(0.2),
                            lineWidth: 1
                        )
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

// MARK: - Receiver Mode View (sidebar detail — controls only)

/// Receiver mode detail view — shows controls and status, video opens in separate window.
struct ReceiverModeView: View {
    @ObservedObject private var manager = ReceiverManager.shared
    @ObservedObject private var listener = ReceiverManager.shared.networkListener
    @AppStorage("receiverAutoStartEnabled") private var receiverAutoStartEnabled = false
    @State private var availableAddresses: [ReceiverConnectionAddress] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                sectionTitle("Status")

                DashboardCard {
                    HStack(spacing: 12) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 10, height: 10)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(statusTitle)
                                .font(.system(size: 14, weight: .semibold))

                            if let detail = statusDetail {
                                Text(detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Spacer()

                        ReceiverOnOffToggle(
                            isOn: listeningBinding,
                            accessibilityLabel: "Receiver Listening"
                        )
                    }
                }

                if manager.isRunning {
                    sectionTitle("Available Connections")

                    DashboardCard {
                        if availableAddresses.isEmpty {
                            HStack(spacing: 10) {
                                Image(systemName: "network.slash")
                                    .foregroundStyle(.secondary)
                                Text("No active Wi-Fi, Ethernet, or Thunderbolt connection detected.")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                        } else {
                            VStack(spacing: 0) {
                                ForEach(Array(availableAddresses.enumerated()), id: \.element.id) { index, connection in
                                    connectionRow(connection)
                                    if index < availableAddresses.count - 1 {
                                        Divider()
                                            .padding(.vertical, 14)
                                    }
                                }
                            }
                        }
                    }
                }

                if manager.isRunning && !manager.networkListener.connectedClients.isEmpty {
                    sectionTitle("Connected Senders")

                    DashboardCard {
                        VStack(spacing: 12) {
                            HStack {
                                Circle()
                                    .fill(Color.green)
                                    .frame(width: 10, height: 10)
                                Text("\(manager.networkListener.connectedClients.count) sender\(manager.networkListener.connectedClients.count == 1 ? "" : "s") connected")
                                    .font(.system(size: 14, weight: .semibold))
                                Spacer()
                            }

                            Button {
                                manager.showWindow()
                            } label: {
                                Label("Show Video Window", systemImage: "macwindow")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                        }
                    }
                }

                sectionTitle("Settings")

                DashboardCard {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Start Listening at Launch")
                                .font(.system(size: 14, weight: .semibold))
                            Text("Automatically start receiver listening when ExtendCast opens.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        ReceiverOnOffToggle(
                            isOn: $receiverAutoStartEnabled,
                            accessibilityLabel: "Start Listening at Launch"
                        )
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Receiver")
        .onAppear {
            if manager.isRunning {
                refreshAvailableAddresses()
            }
        }
        .onChange(of: manager.isRunning) { _, isRunning in
            if isRunning {
                refreshAvailableAddresses()
            } else {
                availableAddresses = []
            }
        }
        .onReceive(
            Timer.publish(every: 5, on: .main, in: .common).autoconnect()
        ) { _ in
            guard manager.isRunning else { return }
            refreshAvailableAddresses()
        }
    }

    // MARK: - Status Helpers

    private var isConnected: Bool {
        manager.isRunning && !manager.networkListener.connectedClients.isEmpty
    }

    private var statusColor: Color {
        if isConnected { return .green }
        if listener.status?.hasPrefix("Failed") == true { return .red }
        if manager.isRunning { return .green }
        return .secondary
    }

    private var statusTitle: String {
        if isConnected {
            let count = manager.networkListener.connectedClients.count
            return "\(count) sender\(count == 1 ? "" : "s") connected on port \(listeningPort)"
        }
        if manager.isRunning { return "Listening on port \(listeningPort)" }
        return "Receiver is not listening"
    }

    private var statusDetail: String? {
        guard manager.isRunning else {
            return "Turn listening on to accept incoming connections."
        }
        if listener.status?.hasPrefix("Failed") == true {
            return listener.status
        }
        return isConnected ? "Video is playing in a separate window." : nil
    }

    private var listeningPort: UInt16 {
        manager.networkListener.tcpListener?.port?.rawValue ?? BCConstants.tcpPort
    }

    private var listeningBinding: Binding<Bool> {
        Binding(
            get: { manager.isRunning },
            set: { shouldListen in
                if shouldListen {
                    manager.start()
                } else {
                    manager.stop()
                }
            }
        )
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 4)
    }

    private func connectionRow(_ connection: ReceiverConnectionAddress) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(connection.title)
                    .font(.system(size: 14, weight: .semibold))

                Text(connection.address)
                    .font(.system(size: 16, weight: .semibold, design: .monospaced))
                    .textSelection(.enabled)

                Text(connection.usageHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 20)

            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(connection.address, forType: .string)
            }
            .buttonStyle(.bordered)
        }
        .padding(.vertical, 4)
    }

    private func refreshAvailableAddresses() {
        let port = listeningPort
        DispatchQueue.global(qos: .utility).async {
            let addresses = ReceiverConnectionAddressProvider.availableAddresses(port: port)
            DispatchQueue.main.async {
                guard addresses != availableAddresses else { return }
                availableAddresses = addresses
            }
        }
    }
}
