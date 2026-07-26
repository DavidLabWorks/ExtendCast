import SwiftUI
import AppKit
import Network
import Security
import ScreenCaptureKit
import IOKit.graphics


final class SenderAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(mainWindowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: nil
        )
    }

    @objc private func mainWindowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              !(window is NSPanel),
              window.canBecomeMain else {
            return
        }

        // Wait until AppKit has removed the closing window before checking whether
        // another app window is still visible. MenuBarExtra panels are ignored.
        DispatchQueue.main.async {
            let hasVisibleAppWindow = NSApplication.shared.windows.contains {
                !($0 is NSPanel) && $0.canBecomeMain && $0.isVisible
            }
            if !hasVisibleAppWindow {
                NSApplication.shared.setActivationPolicy(.accessory)
            }
        }
    }
}

@main
struct BetterCastSenderApp: App {
    static let mainWindowID = "main"
    static let menuIconSystemName = "display.2"

    @NSApplicationDelegateAdaptor(SenderAppDelegate.self) private var appDelegate
    @StateObject private var networkClient = NetworkClient()
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @AppStorage("hasCompletedTour") private var hasCompletedTour = false
    @AppStorage("receiverAutoStartEnabled") private var receiverAutoStartEnabled = false
    @State private var didStartAppServices = false

    var body: some Scene {
        WindowGroup(id: Self.mainWindowID) {
            if hasCompletedOnboarding {
                mainView
            } else {
                OnboardingView(onComplete: {
                    hasCompletedOnboarding = true
                })
                .frame(minWidth: 520, minHeight: 600)
                .background(Color(nsColor: .windowBackgroundColor))
            }
        }

        MenuBarExtra {
            StatusBarMenuView(client: networkClient)
        } label: {
            Image(systemName: Self.menuIconSystemName)
                .accessibilityLabel(
                    networkClient.connectedDisplays.isEmpty
                        ? "ExtendCast — No connected displays"
                        : "ExtendCast — \(networkClient.connectedDisplays.count) connected"
                )
        }
        .menuBarExtraStyle(.window)
    }

    enum SidebarSelection: Hashable {
        case devices
        case recent
        case connect
        case receive
        case settings
        case device(UUID)
        case discovered(String) // Unconnected device by service name
        case logs
    }

    @State private var sidebarSelection: SidebarSelection? = .devices
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var showTour = false

    private var mainView: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(selection: $sidebarSelection) {
                networkClient.quitApp()
            }
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 350)
        } detail: {
            DetailPanelView(client: networkClient, selection: $sidebarSelection, hasCompletedOnboarding: $hasCompletedOnboarding)
        }
        .frame(minWidth: 750, minHeight: 540)
        .overlay {
            if showTour {
                GuidedTourOverlay(
                    selection: $sidebarSelection,
                    onDismiss: {
                        withAnimation { showTour = false }
                        hasCompletedTour = true
                    }
                )
                .transition(.opacity)
            }
        }
        .onAppear {
            guard !didStartAppServices else { return }
            didStartAppServices = true
            networkClient.checkScreenRecordingPermission()
            networkClient.startBrowsing()
            networkClient.startSavedAutoConnections()
            migrateReceiverAutoStartPreferenceIfNeeded()
            startReceiverIfConfigured()
            UpdateChecker.shared.checkForUpdates()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                InputHandler.shared.checkAccessibility()
            }
            if !hasCompletedTour {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    withAnimation { showTour = true }
                }
            }
        }
        .onChange(of: hasCompletedTour) { completed in
            if !completed {
                sidebarSelection = .devices
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    withAnimation { showTour = true }
                }
            }
        }
    }

    private func startReceiverIfConfigured() {
        let receiver = ReceiverManager.shared
        if receiverAutoStartEnabled, !receiver.isRunning {
            receiver.start()
        }
    }

    private func migrateReceiverAutoStartPreferenceIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "receiverAutoStartEnabled") == nil,
              defaults.object(forKey: "receiverListeningEnabled") != nil else {
            return
        }
        receiverAutoStartEnabled = defaults.bool(forKey: "receiverListeningEnabled")
    }
}

// MARK: - Menu Bar

struct StatusBarMenuView: View {
    @ObservedObject var client: NetworkClient
    @Environment(\.openWindow) private var openWindow

    private var availableServices: [DiscoveredService] {
        client.foundServices.filter { service in
            guard case .service = service.endpoint else { return false }
            guard !client.connectedServices.contains(where: { $0.name == service.name }) else {
                return false
            }
            if service.name.hasSuffix(" P2P"),
               client.foundServices.contains(where: {
                   $0.name == String(service.name.dropLast(4))
               }) {
                return false
            }
            return true
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: BetterCastSenderApp.menuIconSystemName)
                    .foregroundStyle(.tint)
                Text("ExtendCast")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider()

            deviceSectionTitle("Connected")

            if client.connectedDisplays.isEmpty {
                emptyDeviceRow("No connected devices")
            } else {
                ForEach(client.connectedDisplays) { display in
                    HStack(spacing: 10) {
                        Image(systemName: "display")
                            .foregroundStyle(.secondary)
                            .frame(width: 16)
                        Text(display.name)
                            .lineLimit(1)
                        Spacer(minLength: 12)
                        Button {
                            client.disconnectConnection(display.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.borderless)
                        .help("Disconnect \(display.name)")
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                }
            }

            Divider()
                .padding(.top, 6)

            deviceSectionTitle("Available Devices")

            if availableServices.isEmpty {
                emptyDeviceRow("No available devices")
            } else {
                ForEach(availableServices, id: \.name) { service in
                    HStack(spacing: 10) {
                        Image(systemName: "display")
                            .foregroundStyle(.secondary)
                            .frame(width: 16)
                        Text(service.name)
                            .lineLimit(1)
                        Spacer(minLength: 12)

                        if client.isConnecting(to: service) {
                            ProgressView()
                                .controlSize(.small)
                                .frame(width: 16, height: 16)
                                .help("Connecting to \(service.name)")
                        } else {
                            Button {
                                client.connect(to: service)
                            } label: {
                                Image(systemName: "plus.circle.fill")
                                    .foregroundStyle(.tint)
                            }
                            .buttonStyle(.borderless)
                            .help("Connect to \(service.name)")
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                }
            }

            Divider()
                .padding(.top, 6)

            HStack(spacing: 8) {
                Button {
                    showMainWindow()
                } label: {
                    Label("Open ExtendCast", systemImage: "macwindow")
                }

                Spacer()

                Button {
                    client.quitApp()
                } label: {
                    Label("Quit", systemImage: "power")
                }
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .frame(width: 300)
    }

    private func deviceSectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 4)
    }

    private func emptyDeviceRow(_ title: String) -> some View {
        Text(title)
            .font(.callout)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func showMainWindow() {
        NSApplication.shared.setActivationPolicy(.regular)
        if let window = NSApplication.shared.windows.first(where: {
            $0.canBecomeMain && !($0 is NSPanel)
        }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: BetterCastSenderApp.mainWindowID)
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

// MARK: - Tour Anchor Store (global coordinates)

/// Stores sidebar item frames in global coordinate space for the tour spotlight.
class TourAnchorStore: ObservableObject {
    static let shared = TourAnchorStore()
    @Published var globalFrames: [String: CGRect] = [:]
    @Published var overlayOrigin: CGPoint = .zero

    /// Returns the frame of a tour anchor relative to the overlay.
    func frame(for key: String) -> CGRect? {
        guard let gf = globalFrames[key] else { return nil }
        return CGRect(
            x: gf.minX - overlayOrigin.x,
            y: gf.minY - overlayOrigin.y,
            width: gf.width,
            height: gf.height
        )
    }
}

extension View {
    /// Tags this view so the guided tour can spotlight it.
    func tourAnchor(_ key: String) -> some View {
        self.background(
            GeometryReader { geo in
                Color.clear
                    .onAppear {
                        TourAnchorStore.shared.globalFrames[key] = geo.frame(in: .global)
                    }
                    .onChange(of: geo.frame(in: .global).origin.x) { _ in
                        TourAnchorStore.shared.globalFrames[key] = geo.frame(in: .global)
                    }
                    .onChange(of: geo.frame(in: .global).origin.y) { _ in
                        TourAnchorStore.shared.globalFrames[key] = geo.frame(in: .global)
                    }
            }
        )
    }
}

// MARK: - Guided Tour

struct TourStep {
    let title: String
    let description: String
    let icon: String
    let sidebarTarget: BetterCastSenderApp.SidebarSelection?
    let anchorKey: String?  // key into TourAnchorKey dict to spotlight
}

struct GuidedTourOverlay: View {
    @Binding var selection: BetterCastSenderApp.SidebarSelection?
    @ObservedObject var anchorStore: TourAnchorStore = .shared
    let onDismiss: () -> Void
    @State private var currentStep = 0

    private let steps: [TourStep] = [
        TourStep(
            title: "Welcome to ExtendCast",
            description: "Let's take a quick tour of the app. ExtendCast turns any device into a wireless extended display for your Mac.",
            icon: "hand.wave.fill",
            sidebarTarget: nil,
            anchorKey: nil
        ),
        TourStep(
            title: "Device Settings",
            description: "Open Devices to configure display mode, resolution, Retina, bitrate, frame rate, and audio for each receiver.",
            icon: "gearshape",
            sidebarTarget: .devices,
            anchorKey: "sidebar_devices_section"
        ),
        TourStep(
            title: "Receive Screen",
            description: "ExtendCast can also receive streams from other Macs. Start listening here and incoming video opens in a separate window.",
            icon: "display.and.arrow.down",
            sidebarTarget: .receive,
            anchorKey: "sidebar_receive"
        ),
        TourStep(
            title: "Settings",
            description: "Configure app-wide permissions, setup tools, and app controls.",
            icon: "gearshape.2",
            sidebarTarget: .settings,
            anchorKey: "sidebar_settings"
        ),
        TourStep(
            title: "Logs",
            description: "View detailed connection and streaming logs for troubleshooting. Useful if something isn't working right.",
            icon: "text.alignleft",
            sidebarTarget: .logs,
            anchorKey: "sidebar_logs"
        ),
        TourStep(
            title: "You're All Set!",
            description: "Connect a receiver device from the sidebar or use \"Receive Screen\" to receive from another Mac. Enjoy your extended display!",
            icon: "checkmark.circle.fill",
            sidebarTarget: .devices,
            anchorKey: nil
        ),
    ]

    var body: some View {
        let step = steps[currentStep]
        let spotlightRect = step.anchorKey.flatMap { anchorStore.frame(for: $0) }

        GeometryReader { geo in
            let size = geo.size

            ZStack {
                // Dimmed background with spotlight cutout
                SpotlightCutoutShape(spotlight: spotlightRect, cornerRadius: 8)
                    .fill(Color.black.opacity(0.6))
                    .onTapGesture { }

                // Highlight border around the spotlighted item
                if let rect = spotlightRect {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.accentColor, lineWidth: 2)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.accentColor.opacity(0.08))
                        )
                        .frame(width: rect.width + 12, height: rect.height + 6)
                        .position(x: rect.midX, y: rect.midY)
                }

                // Tour card — positioned near the spotlight or centered
                tourCard
                    .frame(maxWidth: 380)
                    .position(cardPosition(in: size, spotlight: spotlightRect))
            }
            .onAppear {
                anchorStore.overlayOrigin = CGPoint(
                    x: geo.frame(in: .global).minX,
                    y: geo.frame(in: .global).minY
                )
            }
        }
        .animation(.easeInOut(duration: 0.35), value: currentStep)
        .onChange(of: currentStep) { _ in
            if let target = steps[currentStep].sidebarTarget {
                withAnimation(.easeInOut(duration: 0.2)) {
                    selection = target
                }
            }
        }
    }

    /// Positions the card to the right of the spotlight, or centered if no spotlight.
    private func cardPosition(in size: CGSize, spotlight: CGRect?) -> CGPoint {
        guard let spot = spotlight else {
            return CGPoint(x: size.width / 2, y: size.height / 2)
        }

        let cardWidth: CGFloat = 380
        let cardHeight: CGFloat = 260
        let padding: CGFloat = 20

        // Try to place to the right of the spotlight
        let rightX = spot.maxX + padding + cardWidth / 2
        let leftX = spot.minX - padding - cardWidth / 2

        let x: CGFloat
        if rightX + cardWidth / 2 < size.width {
            x = rightX
        } else if leftX - cardWidth / 2 > 0 {
            x = leftX
        } else {
            x = size.width / 2
        }

        // Vertically align with spotlight center, clamped to window
        let y = min(max(spot.midY, cardHeight / 2 + 20), size.height - cardHeight / 2 - 20)

        return CGPoint(x: x, y: y)
    }

    private var tourCard: some View {
        let step = steps[currentStep]

        return VStack(spacing: 16) {
            Image(systemName: step.icon)
                .font(.system(size: 36))
                .foregroundColor(.accentColor)
                .padding(.top, 8)

            Text(step.title)
                .font(.system(size: 18, weight: .bold))

            Text(step.description)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            // Progress dots
            HStack(spacing: 6) {
                ForEach(0..<steps.count, id: \.self) { i in
                    Circle()
                        .fill(i == currentStep ? Color.accentColor : Color.gray.opacity(0.4))
                        .frame(width: 7, height: 7)
                }
            }
            .padding(.top, 4)

            // Navigation
            HStack {
                if currentStep > 0 {
                    Button("Back") {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            currentStep -= 1
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                }

                Spacer()

                Button("Skip Tour") {
                    onDismiss()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .font(.system(size: 12))

                Spacer()

                if currentStep < steps.count - 1 {
                    Button("Next") {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            currentStep += 1
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                } else {
                    Button("Done") {
                        onDismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .tint(.green)
                }
            }
        }
        .padding(24)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(nsColor: .windowBackgroundColor))
                .shadow(color: .black.opacity(0.3), radius: 20, y: 8)
        )
    }
}

/// Shape that fills the entire rect but cuts out a rounded-rect spotlight hole.
struct SpotlightCutoutShape: Shape {
    var spotlight: CGRect?
    var cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRect(rect)
        if let spot = spotlight {
            let cutout = Path(roundedRect: spot.insetBy(dx: -6, dy: -6), cornerRadius: cornerRadius)
            path = path.subtracting(cutout)
        }
        return path
    }
}

// MARK: - Onboarding View

struct OnboardingView: View {
    let onComplete: () -> Void

    @State private var currentStep = 0
    @State private var screenRecordingGranted = false
    @State private var accessibilityGranted = false
    @State private var pollTimer: Timer?

    private let steps = ["Screen Recording", "Accessibility", "Ready"]

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 80, height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .shadow(color: .black.opacity(0.15), radius: 8, y: 4)

                Text("Welcome to ExtendCast")
                    .font(.system(size: 26, weight: .bold))

                Text("A few permissions are needed to get started")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 40)
            .padding(.bottom, 30)

            // Step indicators
            HStack(spacing: 24) {
                ForEach(0..<steps.count, id: \.self) { index in
                    StepIndicator(
                        number: index + 1,
                        title: steps[index],
                        isActive: currentStep == index,
                        isCompleted: stepCompleted(index)
                    )
                    if index < steps.count - 1 {
                        Rectangle()
                            .fill(stepCompleted(index) ? Color.green : Color(nsColor: .separatorColor))
                            .frame(height: 2)
                            .frame(maxWidth: 40)
                    }
                }
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 30)

            // Step content
            VStack(spacing: 20) {
                switch currentStep {
                case 0:
                    screenRecordingStep
                case 1:
                    accessibilityStep
                default:
                    readyStep
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 40)

            Spacer()

            // Navigation buttons
            HStack {
                if currentStep > 0 {
                    Button("Back") {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            currentStep -= 1
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }

                Spacer()

                if currentStep < 2 {
                    Button(stepCompleted(currentStep) ? "Next" : "Skip") {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            currentStep += 1
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                } else {
                    Button("Get Started") {
                        onComplete()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(.green)
                }
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 30)
        }
        .onAppear {
            checkPermissions()
            startPolling()
        }
        .onDisappear {
            pollTimer?.invalidate()
        }
    }

    // MARK: - Step Views

    private var screenRecordingStep: some View {
        PermissionStepCard(
            icon: "record.circle",
            iconColor: .red,
            title: "Screen Recording",
            description: "ExtendCast needs Screen Recording permission to capture your display and stream it to receivers.",
            isGranted: screenRecordingGranted,
            actionTitle: "Open Screen Recording Settings",
            action: {
                // macOS 13+ deep link
                if let url = URL(string: "x-apple.systempreferences:com.apple.PrivacySecurity.extension?Privacy_ScreenCapture") {
                    NSWorkspace.shared.open(url)
                }
                // Fallback for older macOS
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                    NSWorkspace.shared.open(url)
                }
            }
        )
    }

    private var accessibilityStep: some View {
        PermissionStepCard(
            icon: "hand.point.up.left",
            iconColor: .blue,
            title: "Accessibility",
            description: "Accessibility permission lets ExtendCast relay mouse and keyboard input from your receivers back to this Mac.",
            isGranted: accessibilityGranted,
            actionTitle: "Open Accessibility Settings",
            action: {
                let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(options)
            }
        )
    }

    private var readyStep: some View {
        VStack(spacing: 16) {
            DashboardCard {
                VStack(spacing: 16) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.green)

                    Text("You're all set!")
                        .font(.system(size: 20, weight: .semibold))

                    VStack(alignment: .leading, spacing: 8) {
                        permissionRow("Screen Recording", granted: screenRecordingGranted)
                        permissionRow("Accessibility", granted: accessibilityGranted)
                    }
                    .padding(.top, 4)

                    if !screenRecordingGranted || !accessibilityGranted {
                        Text("Some permissions are missing. You can grant them later in System Settings, but some features won't work until they're enabled.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
        }
    }

    private func permissionRow(_ name: String, granted: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(granted ? .green : .orange)
            Text(name)
                .font(.system(size: 14))
            Spacer()
            Text(granted ? "Granted" : "Not granted")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(granted ? .green : .orange)
        }
    }

    // MARK: - Helpers

    private func stepCompleted(_ step: Int) -> Bool {
        switch step {
        case 0: return screenRecordingGranted
        case 1: return accessibilityGranted
        case 2: return true
        default: return false
        }
    }

    private func checkPermissions() {
        // Screen Recording: check via CGPreflightScreenCaptureAccess (macOS 10.15+)
        screenRecordingGranted = CGPreflightScreenCaptureAccess()

        // Accessibility: check without prompting
        accessibilityGranted = AXIsProcessTrusted()
    }

    private func startPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
            checkPermissions()
            // Auto-advance when permission is granted on current step
            if currentStep == 0 && screenRecordingGranted {
                withAnimation(.easeInOut(duration: 0.2)) {
                    currentStep = 1
                }
            } else if currentStep == 1 && accessibilityGranted {
                withAnimation(.easeInOut(duration: 0.2)) {
                    currentStep = 2
                }
            }
        }
    }
}

// MARK: - Step Indicator

struct StepIndicator: View {
    let number: Int
    let title: String
    let isActive: Bool
    let isCompleted: Bool

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(isCompleted ? Color.green : (isActive ? Color.accentColor : Color(nsColor: .separatorColor)))
                    .frame(width: 32, height: 32)
                if isCompleted {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                } else {
                    Text("\(number)")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(isActive ? .white : .secondary)
                }
            }
            Text(title)
                .font(.system(size: 11, weight: isActive ? .semibold : .regular))
                .foregroundStyle(isActive ? .primary : .secondary)
        }
    }
}

// MARK: - Permission Step Card

struct PermissionStepCard: View {
    let icon: String
    let iconColor: Color
    let title: String
    let description: String
    let isGranted: Bool
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        DashboardCard {
            VStack(spacing: 16) {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(iconColor.opacity(0.12))
                            .frame(width: 48, height: 48)
                        Image(systemName: icon)
                            .font(.system(size: 22))
                            .foregroundStyle(iconColor)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(title)
                                .font(.system(size: 16, weight: .semibold))
                            if isGranted {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            }
                        }
                        Text(description)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if isGranted {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Permission granted")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.green)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.green.opacity(0.08))
                    )
                } else {
                    Button(action: action) {
                        HStack {
                            Image(systemName: "gear")
                            Text(actionTitle)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
            .padding(.vertical, 4)
        }
    }
}

// MARK: - Dashboard Card Container (fallback for pre-macOS 26)

struct DashboardCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .shadow(color: .black.opacity(0.05), radius: 4, x: 0, y: 1)
            )
    }
}

extension DashboardCard {
    init(padded: Bool = true, @ViewBuilder content: () -> Content) {
        self.content = content()
    }
}

struct CompactDisconnectButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color.red.opacity(isEnabled ? 1 : 0.45))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.red.opacity(configuration.isPressed ? 0.12 : 0.06))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.red.opacity(0.08), lineWidth: 0.5)
            }
    }
}

// MARK: - Sidebar (native List)

struct SidebarView: View {
    @Binding var selection: BetterCastSenderApp.SidebarSelection?
    let quitAction: () -> Void

    var body: some View {
        List {
            Section {
                HStack(spacing: 8) {
                    SidebarIcon(name: "sidebar-sender", usesSharedIcon: true, size: 13)
                    Text("Sender")
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 2)
                .accessibilityAddTraits(.isHeader)

                sidebarRow("Devices", icon: "sidebar-devices", tag: .devices, usesSharedIcon: true)
                    .padding(.leading, 16)
                    .tourAnchor("sidebar_devices_section")
                sidebarRow("Recent", icon: "sidebar-recent", tag: .recent, usesSharedIcon: true)
                    .padding(.leading, 16)
                sidebarRow("Connect", icon: "sidebar-connect", tag: .connect, usesSharedIcon: true)
                    .padding(.leading, 16)
            }

            Section {
                sidebarRow("Receiver", icon: "sidebar-receiver", tag: .receive, usesSharedIcon: true)
                    .tourAnchor("sidebar_receive")
                sidebarRow("Settings", icon: "sidebar-settings", tag: .settings, usesSharedIcon: true)
                    .tourAnchor("sidebar_settings")
                sidebarRow("Logs", icon: "sidebar-logs", tag: .logs, usesSharedIcon: true)
                    .tourAnchor("sidebar_logs")
            }
        }
        .navigationTitle("ExtendCast")
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button(role: .destructive) {
                    quitAction()
                } label: {
                    SidebarIcon(name: "sidebar-power", usesSharedIcon: true)
                }
                .buttonStyle(.borderless)
                .help("Quit ExtendCast")
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    // Apple Music-style sidebar row: tinted icon+text when selected, subtle matte bg
    @ViewBuilder
    private func sidebarRow(
        _ title: String,
        subtitle: String? = nil,
        icon: String,
        tag: BetterCastSenderApp.SidebarSelection,
        iconTint: Color? = nil,
        usesSharedIcon: Bool = false
    ) -> some View {
        let isSelected = isSidebarSelectionActive(tag)
        let tint = iconTint ?? .accentColor

        Button {
            selection = tag
        } label: {
            HStack(alignment: .center, spacing: 8) {
                SidebarIcon(name: icon, usesSharedIcon: usesSharedIcon)
                    .foregroundColor(isSelected ? tint : .secondary)

                if let subtitle = subtitle {
                    VStack(alignment: .leading) {
                        Text(title)
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(isSelected ? tint.opacity(0.7) : .secondary)
                    }
                } else {
                    Text(title)
                }
            }
            .foregroundColor(isSelected ? tint : .primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(
            isSelected
                ? RoundedRectangle(cornerRadius: 6)
                    .fill(tint.opacity(0.1))
                : nil
        )
    }

    private func isSidebarSelectionActive(_ tag: BetterCastSenderApp.SidebarSelection) -> Bool {
        if selection == tag { return true }
        guard tag == .devices else { return false }
        switch selection {
        case .device, .discovered:
            return true
        default:
            return false
        }
    }
}

private struct SidebarIcon: View {
    let name: String
    var usesSharedIcon = false
    var size: CGFloat = 17

    var body: some View {
        if usesSharedIcon,
           let url = sharedIconURL(named: name),
           let image = NSImage(contentsOf: url),
           image.isValid {
            Image(nsImage: image)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
        } else {
            Image(systemName: fallbackSystemImageName(for: name))
                .frame(width: size, height: size)
        }
    }

    private func sharedIconURL(named name: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: "svg", subdirectory: "SidebarIcons")
    }

    private func fallbackSystemImageName(for name: String) -> String {
        switch name {
        case "sidebar-sender":
            return "paperplane"
        case "sidebar-devices":
            return "display.2"
        case "sidebar-recent":
            return "clock.arrow.circlepath"
        case "sidebar-connect":
            return "link"
        case "sidebar-receiver":
            return "display.and.arrow.down"
        case "sidebar-settings":
            return "gearshape"
        case "sidebar-logs":
            return "text.alignleft"
        case "sidebar-power":
            return "power"
        default:
            return name
        }
    }
}

// MARK: - ADB Connect Row

struct ADBConnectRow: View {
    @ObservedObject var client: NetworkClient
    @State private var expanded = false

    var body: some View {
        DisclosureGroup("Android (ADB)", isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Button(client.adbInProgress ? "Setting up..." : "Wireless") {
                        client.connectADBWireless()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.green)
                    .disabled(client.adbInProgress)

                    Button("USB") {
                        client.connectADBUSB()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.blue)
                }
                if !client.adbStatus.isEmpty {
                    Text(client.adbStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Detail Panel

private struct CustomResolutionEditorRequest: Identifiable {
    let id = UUID()
    let resolution: VirtualDisplayManager.Resolution?
}

enum ReceiverDetailAvailability: Equatable {
    case none
    case available(id: String, name: String)
    case unavailable(id: String)

    var receiverName: String? {
        guard case .available(_, let name) = self else { return nil }
        return name
    }

    static func disconnectedReceiverName(
        from previous: ReceiverDetailAvailability,
        to current: ReceiverDetailAvailability,
        connectionIsActiveOrPending: Bool = false
    ) -> String? {
        guard !connectionIsActiveOrPending else { return nil }
        guard case .available(let previousID, let name) = previous,
              case .unavailable(let currentID) = current,
              previousID == currentID else {
            return nil
        }
        return name
    }

    static func replacementConnectionID(
        selectedID: UUID,
        retainedDisplayName: String?,
        currentDisplays: [ConnectedDisplayInfo]
    ) -> UUID? {
        guard !currentDisplays.contains(where: { $0.id == selectedID }),
              let retainedDisplayName else {
            return nil
        }
        return currentDisplays.first {
            $0.name == retainedDisplayName
        }?.id
    }
}

private struct ReceiverDisconnectAlert: Identifiable {
    let id = UUID()
    let receiverName: String
}

enum ReceiverDisconnectConfirmation {
    static func shouldPresent(
        receiverName: String,
        selectedReceiverName: String?,
        connectedReceiverNames: Set<String>,
        connectionIsActivePendingOrReconnecting: Bool
    ) -> Bool {
        selectedReceiverName == receiverName
            && !connectedReceiverNames.contains(receiverName)
            && !connectionIsActivePendingOrReconnecting
    }
}

struct DetailPanelView: View {
    @ObservedObject var client: NetworkClient
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var launchAtLoginManager = LaunchAtLoginManager()
    @State private var customResolutionEditorRequest: CustomResolutionEditorRequest?
    @State private var receiverDisconnectAlert: ReceiverDisconnectAlert?
    @State private var receiverDisconnectConfirmationWorkItem: DispatchWorkItem?
    @State private var pendingReceiverDisconnectName: String?
    @State private var retainedConnectedDisplaysByID: [UUID: ConnectedDisplayInfo] = [:]
    @State private var retainedDiscoveredServicesByName: [String: DiscoveredService] = [:]
    @Binding var selection: BetterCastSenderApp.SidebarSelection?
    @Binding var hasCompletedOnboarding: Bool
    @AppStorage("hasCompletedTour") private var hasCompletedTour = false

    var body: some View {
        detailContent
            .onChange(of: receiverDetailAvailability) { previous, current in
                receiverDisconnectConfirmationWorkItem?.cancel()
                receiverDisconnectConfirmationWorkItem = nil
                pendingReceiverDisconnectName = nil

                let receiverName = previous.receiverName
                let connectionIsActiveOrPending = receiverName.flatMap {
                    retainedDiscoveredServicesByName[$0]
                }.map(client.hasActiveOrPendingConnection) ?? false
                let connectionIsActivePendingOrReconnecting =
                    connectionIsActiveOrPending
                    || receiverName.map(client.isReconnecting) == true
                guard let receiverName = ReceiverDetailAvailability
                    .disconnectedReceiverName(
                        from: previous,
                        to: current,
                        connectionIsActiveOrPending:
                            connectionIsActivePendingOrReconnecting
                    ) else {
                    return
                }

                pendingReceiverDisconnectName = receiverName
                let confirmationWorkItem = DispatchWorkItem {
                    let selectedReceiverName: String?
                    switch selection {
                    case .device(let id):
                        selectedReceiverName =
                            client.connectedDisplays.first { $0.id == id }?.name
                            ?? retainedConnectedDisplaysByID[id]?.name
                    case .discovered(let name):
                        selectedReceiverName = name
                    default:
                        selectedReceiverName = nil
                    }
                    let retainedService =
                        retainedDiscoveredServicesByName[receiverName]
                    let connectionIsActiveOrPending = retainedService.map(
                        client.hasActiveOrPendingConnection
                    ) ?? false
                    let shouldPresent =
                        ReceiverDisconnectConfirmation.shouldPresent(
                            receiverName: receiverName,
                            selectedReceiverName: selectedReceiverName,
                            connectedReceiverNames: Set(
                                client.connectedDisplays.map(\.name)
                            ),
                            connectionIsActivePendingOrReconnecting:
                                connectionIsActiveOrPending
                                || client.isReconnecting(receiverName)
                        )

                    pendingReceiverDisconnectName = nil
                    receiverDisconnectConfirmationWorkItem = nil
                    guard shouldPresent,
                          receiverDisconnectAlert == nil else {
                        return
                    }
                    receiverDisconnectAlert = ReceiverDisconnectAlert(
                        receiverName: receiverName
                    )
                }
                receiverDisconnectConfirmationWorkItem = confirmationWorkItem
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + 0.8,
                    execute: confirmationWorkItem
                )
            }
            .onReceive(client.$connectedDisplays) { displays in
                if let pendingReceiverDisconnectName,
                   displays.contains(where: {
                       $0.name == pendingReceiverDisconnectName
                   }) {
                    receiverDisconnectConfirmationWorkItem?.cancel()
                    receiverDisconnectConfirmationWorkItem = nil
                    self.pendingReceiverDisconnectName = nil
                }
                if case .device(let selectedID) = selection,
                   let replacementID = ReceiverDetailAvailability
                       .replacementConnectionID(
                           selectedID: selectedID,
                           retainedDisplayName:
                               retainedConnectedDisplaysByID[selectedID]?.name,
                           currentDisplays: displays
                       ) {
                    selection = .device(replacementID)
                }
                for display in displays {
                    retainedConnectedDisplaysByID[display.id] = display
                }
            }
            .onReceive(client.$foundServices) { services in
                for service in services {
                    retainedDiscoveredServicesByName[service.name] = service
                }
            }
            .onChange(
                of: focusedReceiverNameForReachability,
                initial: true
            ) { _, name in
                client.setFocusedBonjourServiceName(name)
            }
            .onDisappear {
                receiverDisconnectConfirmationWorkItem?.cancel()
                client.setFocusedBonjourServiceName(nil)
            }
            .alert(item: $receiverDisconnectAlert) { alert in
                Alert(
                    title: Text("Receiver Disconnected"),
                    message: Text(
                        "\(alert.receiverName) is no longer available. "
                            + "Check the receiver and network connection, then try again."
                    ),
                    dismissButton: .default(Text("OK")) {
                        selection = .devices
                    }
                )
            }
    }

    @ViewBuilder
    private var detailContent: some View {
        switch selection {
        case .device(let id):
            if let display = client.connectedDisplays.first(where: { $0.id == id })
                ?? retainedConnectedDisplaysByID[id] {
                DeviceDetailView(display: display, client: client, selection: $selection)
            } else {
                receiverUnavailableView
            }
        case .discovered(let name):
            if let service = client.foundServices.first(where: { $0.name == name })
                ?? retainedDiscoveredServicesByName[name] {
                DiscoveredDeviceView(service: service, client: client, selection: $selection)
            } else {
                receiverUnavailableView
            }
        case .receive:
            ReceiverModeView()
        case .recent:
            RecentConnectionsView(client: client, selection: $selection)
        case .connect:
            ManualConnectView(client: client)
        case .logs:
            LogView()
                .navigationTitle("Logs")
        case .settings:
            settingsForm
        case .devices, nil:
            DevicesView(client: client, selection: $selection)
        }
    }

    private var receiverDetailAvailability: ReceiverDetailAvailability {
        switch selection {
        case .device(let id):
            let detailID = "connected:\(id.uuidString)"
            if let display = client.connectedDisplays.first(where: { $0.id == id }) {
                return .available(id: detailID, name: display.name)
            }
            return .unavailable(id: detailID)
        case .discovered(let name):
            let detailID = "discovered:\(name)"
            if client.foundServices.contains(where: { $0.name == name }) {
                return .available(id: detailID, name: name)
            }
            if let retainedService = retainedDiscoveredServicesByName[name],
               client.hasActiveOrPendingConnection(to: retainedService) {
                return .available(id: detailID, name: name)
            }
            return .unavailable(id: detailID)
        default:
            return .none
        }
    }

    private var focusedReceiverNameForReachability: String? {
        guard scenePhase == .active,
              case .discovered(let name) = selection else {
            return nil
        }
        return name
    }

    private var receiverUnavailableView: some View {
        ContentUnavailableView(
            "Receiver Disconnected",
            systemImage: "display.trianglebadge.exclamationmark",
            description: Text("This receiver is no longer available.")
        )
        .navigationTitle("Receiver")
    }

    // MARK: - Settings (native Form)

    private var settingsForm: some View {
        Form {
            Section("General") {
                SettingsActionRow(
                    title: "Launch at Login",
                    description: "Automatically open ExtendCast after you sign in to this Mac."
                ) {
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { launchAtLoginManager.isEnabled },
                            set: { launchAtLoginManager.setEnabled($0) }
                        )
                    )
                    .labelsHidden()
                }

                if launchAtLoginManager.needsApproval {
                    SettingsActionRow(
                        title: "Approval Required",
                        description: "Allow ExtendCast under Open at Login in macOS System Settings."
                    ) {
                        Button("Open Login Items") {
                            launchAtLoginManager.openSystemSettings()
                        }
                    }
                }

                if let errorMessage = launchAtLoginManager.errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("Custom Resolutions") {
                if client.customResolutions.isEmpty {
                    Text("No custom resolutions.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(client.customResolutions, id: \.self) { resolution in
                        HStack {
                            Text("\(resolution.name) · \(resolution.displaySizeLabel)")
                                .lineLimit(1)
                            Spacer()
                            Button {
                                customResolutionEditorRequest = CustomResolutionEditorRequest(
                                    resolution: resolution
                                )
                            } label: {
                                Image(systemName: "pencil")
                            }
                            .buttonStyle(.borderless)
                            .help("Edit")

                            Button(role: .destructive) {
                                client.removeCustomResolution(resolution)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("Delete")
                        }
                    }
                }

                Button {
                    customResolutionEditorRequest = CustomResolutionEditorRequest(
                        resolution: nil
                    )
                } label: {
                    Label("Add Resolution", systemImage: "plus")
                }
            }

            Section("Controls") {
                SettingsActionRow(
                    title: "Screen Recording",
                    description: "Open macOS Privacy & Security to allow ExtendCast to capture displays."
                ) {
                    Button("Open Settings") {
                        client.openPrivacySettings()
                    }
                }

                SettingsActionRow(
                    title: "Reset Screen Permission",
                    description: "Clear the current screen-capture authorization if macOS is using an outdated permission record."
                ) {
                    Button("Reset") {
                        client.resetScreenCapturePermissions()
                    }
                }

                SettingsActionRow(
                    title: "Restart ExtendCast",
                    description: "Quit and reopen the app to apply permission or system-level changes."
                ) {
                    Button("Restart") {
                        client.restartApp()
                    }
                }

                SettingsActionRow(
                    title: "Setup Wizard",
                    description: "Run the initial setup and permission checks again."
                ) {
                    Button("Open") {
                        hasCompletedOnboarding = false
                    }
                }

                SettingsActionRow(
                    title: "Guided Tour",
                    description: "Replay the walkthrough of devices, receiving, settings, and logs."
                ) {
                    Button("Replay") {
                        hasCompletedTour = false
                        selection = .devices
                    }
                }
            }

            Section("About") {
                LabeledContent("Version") {
                    HStack(spacing: 8) {
                        Text("ExtendCast \(UpdateChecker.displayVersion)")
                            .foregroundStyle(.secondary)

                        Button {
                            updateChecker.checkForUpdates()
                        } label: {
                            if updateChecker.isChecking {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                        }
                        .buttonStyle(.borderless)
                        .disabled(updateChecker.isChecking)
                        .help("Check for Updates")
                    }
                }

                if updateChecker.checkedOnce {
                    if updateChecker.updateAvailable, let version = updateChecker.latestVersion {
                        HStack {
                            Label("Update available: \(version)", systemImage: "arrow.down.circle.fill")
                                .foregroundColor(.green)
                            Spacer()
                            Button("Download") {
                                if let urlStr = updateChecker.downloadURL, let url = URL(string: urlStr) {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                    } else {
                        Label("You're on the latest version", systemImage: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .onAppear {
            launchAtLoginManager.refresh()
        }
        .sheet(item: $customResolutionEditorRequest) { request in
            CustomResolutionEditor(
                originalResolution: request.resolution,
                existingResolutions: VirtualDisplayManager.defaultResolutions
                    + client.customResolutions
            ) { width, height, ppi, label in
                client.saveCustomResolution(
                    request.resolution,
                    width: width,
                    height: height,
                    ppi: ppi,
                    label: label
                )
            }
        }
    }

    @ObservedObject private var updateChecker = UpdateChecker.shared
}

// MARK: - Primary Navigation Pages

struct DevicesView: View {
    @ObservedObject var client: NetworkClient
    @Binding var selection: BetterCastSenderApp.SidebarSelection?

    private var availableServices: [DiscoveredService] {
        client.foundServices.filter { service in
            let isADBSynthetic = service.name.contains("Android (USB)") || service.name.contains("Android (WiFi ADB)")
            let hasMDNSAndroid = client.foundServices.contains {
                $0.name.lowercased().contains("android")
                    && !$0.name.contains("Android (USB)")
                    && !$0.name.contains("Android (WiFi ADB)")
            }
            let isP2PDuplicate = service.name.hasSuffix(" P2P")
                && client.foundServices.contains { $0.name == String(service.name.dropLast(4)) }
            let isAndroid = service.name.lowercased().contains("android")
            let isConnected = client.connectedDisplays.contains {
                $0.name == service.name
                    || (isAndroid
                        && ($0.name.contains("Android (USB)") || $0.name.contains("Android (WiFi ADB)")))
            }
            let isManualHistoryEntry: Bool
            if case .hostPort(let host, let port) = service.endpoint {
                isManualHistoryEntry = service.name == "\(host):\(port.rawValue)"
            } else {
                isManualHistoryEntry = false
            }
            return !(isADBSynthetic && hasMDNSAndroid)
                && !isP2PDuplicate
                && !isConnected
                && !isManualHistoryEntry
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if !client.connectedDisplays.isEmpty {
                    DashboardCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Connected")
                                .font(.system(size: 14, weight: .semibold))

                            ForEach(client.connectedDisplays) { display in
                                HStack(spacing: 12) {
                                    Image(systemName: deviceIcon(for: display.name))
                                        .font(.system(size: 20))
                                        .foregroundStyle(.green)
                                        .frame(width: 28)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(display.name)
                                            .font(.system(size: 13, weight: .medium))
                                        Text(display.deviceListSubtitle)
                                            .font(.system(size: 11))
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer()

                                    Button("Settings") {
                                        selection = .device(display.id)
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)

                                    Button("Disconnect") {
                                        client.disconnectConnection(display.id)
                                    }
                                    .buttonStyle(CompactDisconnectButtonStyle())
                                }
                                .padding(.vertical, 4)

                                if display.id != client.connectedDisplays.last?.id {
                                    Divider()
                                }
                            }
                        }
                    }
                }

                if !availableServices.isEmpty {
                    DashboardCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Available")
                                .font(.system(size: 14, weight: .semibold))

                            ForEach(availableServices, id: \.name) { service in
                                HStack(spacing: 12) {
                                    Image(systemName: deviceIcon(for: service.name))
                                        .font(.system(size: 20))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 28)

                                    Text(service.name)
                                        .font(.system(size: 13, weight: .medium))

                                    Spacer()

                                    Button("Settings") {
                                        selection = .discovered(service.name)
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                                .padding(.vertical, 4)

                                if service.name != availableServices.last?.name {
                                    Divider()
                                }
                            }
                        }
                    }
                }

                if client.connectedDisplays.isEmpty && availableServices.isEmpty {
                    DashboardCard {
                        VStack(spacing: 12) {
                            if client.isDiscoveringDevices {
                                ProgressView()
                                Text("Searching for devices on your network...")
                                    .foregroundStyle(.secondary)
                            } else {
                                Image(systemName: "display.badge.questionmark")
                                    .font(.system(size: 30, weight: .light))
                                    .foregroundStyle(.secondary)
                                Text("No Devices Found")
                                    .font(.headline)
                                Text("Open ExtendCast on the receiver and make sure both devices are on the same local network.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                                Button("Search Again") {
                                    client.startBrowsing()
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 28)
                    }
                }
            }
            .padding(20)
        }
        .navigationTitle("Devices")
    }

    private func deviceIcon(for name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("android") { return "apps.iphone" }
        if lower.contains("ipad") || lower.contains("ios") { return "ipad" }
        if lower.contains("windows") { return "pc" }
        if lower.contains("linux") { return "desktopcomputer" }
        return "display"
    }
}

struct RecentConnectionsView: View {
    @ObservedObject var client: NetworkClient
    @Binding var selection: BetterCastSenderApp.SidebarSelection?

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if client.manualConnectionHistory.isEmpty {
                    DashboardCard {
                        VStack(spacing: 12) {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.system(size: 32, weight: .light))
                                .foregroundStyle(.secondary)
                            Text("No Recent Connections")
                                .font(.headline)
                            Text("Devices appear here after a successful manual connection.")
                                .foregroundStyle(.secondary)
                            Button("Connect Manually") {
                                selection = .connect
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 28)
                    }
                } else {
                    DashboardCard {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("Recent Connections")
                                    .font(.system(size: 14, weight: .semibold))
                                Spacer()
                                Button {
                                    client.refreshManualConnectionAvailability()
                                } label: {
                                    Label("Refresh", systemImage: "arrow.clockwise")
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(client.isRefreshingManualConnectionAvailability)
                            }

                            ForEach(client.manualConnectionHistory) { item in
                                HStack(spacing: 12) {
                                    Image(systemName: "pc")
                                        .font(.system(size: 20))
                                        .foregroundStyle(connectionColor(for: item))
                                        .frame(width: 28)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.host)
                                            .font(.system(size: 13, weight: .medium))
                                        Text("Port \(item.port)")
                                            .font(.system(size: 11))
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer()
                                    connectionStatus(for: item)

                                    if let display = connectedDisplay(for: item) {
                                        Button("Settings") {
                                            selection = .device(display.id)
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                    } else {
                                        if client.manualConnectionAvailability[item.id] == .permissionRequired {
                                            Button("Open Privacy") {
                                                client.openLocalNetworkPrivacySettings()
                                            }
                                            .buttonStyle(.bordered)
                                            .controlSize(.small)
                                        } else {
                                            Button("Settings") {
                                                client.prepareRecentConnectionSettings(item)
                                                selection = .discovered(item.displayName)
                                            }
                                            .buttonStyle(.bordered)
                                            .controlSize(.small)

                                            Button("Connect") {
                                                client.connectRecentManualConnection(item)
                                            }
                                            .buttonStyle(.borderedProminent)
                                            .controlSize(.small)
                                            .disabled(client.manualConnectionAvailability[item.id] != .available)
                                        }

                                        Button {
                                            client.removeManualConnectionHistory(item)
                                        } label: {
                                            Image(systemName: "trash")
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                        .tint(.red)
                                        .help("Remove from Recent")
                                    }
                                }
                                .padding(.vertical, 4)

                                if item.id != client.manualConnectionHistory.last?.id {
                                    Divider()
                                }
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
        .navigationTitle("Recent")
        .onAppear { client.refreshManualConnectionAvailabilityIfNeeded() }
    }

    @ViewBuilder
    private func connectionStatus(for item: ManualConnectionHistoryItem) -> some View {
        if connectedDisplay(for: item) != nil {
            Label("Connected", systemImage: "circle.fill")
                .foregroundStyle(.green)
        } else {
            switch client.manualConnectionAvailability[item.id] ?? .unknown {
            case .unknown:
                Text("Unknown")
                    .foregroundStyle(.secondary)
            case .checking:
                HStack(spacing: 5) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Checking")
                }
                .foregroundStyle(.secondary)
            case .available:
                Label("Available", systemImage: "circle.fill")
                    .foregroundStyle(.green)
            case .unavailable:
                Label("Unavailable", systemImage: "circle.fill")
                    .foregroundStyle(.red)
            case .permissionRequired:
                Label("Local Network Off", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
    }

    private func connectionColor(for item: ManualConnectionHistoryItem) -> Color {
        if connectedDisplay(for: item) != nil { return .green }
        switch client.manualConnectionAvailability[item.id] ?? .unknown {
        case .available: return .green
        case .unavailable: return .red
        case .permissionRequired: return .orange
        case .unknown, .checking: return .secondary
        }
    }

    private func connectedDisplay(for item: ManualConnectionHistoryItem) -> ConnectedDisplayInfo? {
        client.connectedDisplays.first { $0.name == item.displayName }
    }
}

struct ManualConnectView: View {
    @ObservedObject var client: NetworkClient

    var body: some View {
        Form {
            Section {
                TextField("IP address or hostname", text: $client.manualHost)
                    .textFieldStyle(.roundedBorder)

                TextField("Port", text: $client.manualPort)
                    .textFieldStyle(.roundedBorder)

                Button("Connect") {
                    client.connectManual()
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    client.manualHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || UInt16(client.manualPort) == nil
                )
            } header: {
                Text("Manual IP")
            } footer: {
                Text("Successful manual connections are saved in Recent.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Connect")
    }
}

// MARK: - Display Overview (arrangement view)

/// A display item in the arrangement view — either the built-in display or a BetterCast virtual display.
struct DisplayItem: Identifiable {
    let id: String
    let name: String
    let width: CGFloat   // pixels
    let height: CGFloat  // pixels
    let originX: CGFloat // CG coordinate origin
    let originY: CGFloat
    let isBuiltIn: Bool
    var connectionId: UUID? = nil
    var cgDisplayID: CGDirectDisplayID? = nil
}

/// Captures lightweight, on-demand previews for active displays.
class DisplayThumbnailProvider: ObservableObject {
    @Published private(set) var thumbnails: [String: NSImage] = [:] // keyed by DisplayItem.id
    @Published private(set) var isRefreshing = false
    private let captureQueue = DispatchQueue(label: "com.bettercast.display-thumbnails", qos: .utility)

    func refresh(displays: [DisplayItem]) {
        guard !isRefreshing else { return }
        isRefreshing = true

        captureQueue.async { [weak self] in
            var newThumbs: [String: NSImage] = [:]

            for display in displays {
                let displayID: CGDirectDisplayID
                if display.isBuiltIn {
                    displayID = CGMainDisplayID()
                    // Try to find actual built-in display
                    var onlineDisplays = [CGDirectDisplayID](repeating: 0, count: 16)
                    var displayCount: UInt32 = 0
                    CGGetOnlineDisplayList(16, &onlineDisplays, &displayCount)
                    let builtIn = onlineDisplays.prefix(Int(displayCount)).first { CGDisplayIsBuiltin($0) != 0 }
                    if let builtIn = builtIn {
                        if let cgImage = CGDisplayCreateImage(builtIn) {
                            newThumbs[display.id] = Self.makeThumbnail(from: cgImage)
                        }
                        continue
                    }
                } else if let did = display.cgDisplayID {
                    displayID = did
                } else {
                    continue
                }

                if let cgImage = CGDisplayCreateImage(displayID) {
                    newThumbs[display.id] = Self.makeThumbnail(from: cgImage)
                }
            }

            DispatchQueue.main.async {
                self?.thumbnails = newThumbs
                self?.isRefreshing = false
            }
        }
    }

    private static func makeThumbnail(from image: CGImage) -> NSImage {
        let maxDimension: CGFloat = 480
        let sourceWidth = CGFloat(image.width)
        let sourceHeight = CGFloat(image.height)
        let scale = min(1, maxDimension / max(sourceWidth, sourceHeight))
        let width = max(1, Int(sourceWidth * scale))
        let height = max(1, Int(sourceHeight * scale))

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        }

        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let thumbnail = context.makeImage() else {
            return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        }
        return NSImage(cgImage: thumbnail, size: NSSize(width: width, height: height))
    }
}

/// macOS System Settings–style display arrangement overview with drag and live previews.
struct DisplayOverviewView: View {
    @ObservedObject var client: NetworkClient
    @Binding var selection: BetterCastSenderApp.SidebarSelection?
    @State private var selectedDisplayId: String? = nil
    @StateObject private var thumbProvider = DisplayThumbnailProvider()

    private var displays: [DisplayItem] {
        var items: [DisplayItem] = []

        // Built-in display
        if let builtinScreen = NSScreen.builtin ?? NSScreen.main {
            let frame = builtinScreen.frame
            items.append(DisplayItem(
                id: "builtin",
                name: builtinScreen.localizedName,
                width: frame.width,
                height: frame.height,
                originX: frame.origin.x,
                originY: frame.origin.y,
                isBuiltIn: true
            ))
        }

        // Connected BetterCast displays
        for display in client.connectedDisplays {
            let b = display.displayBounds
            let w = b.width > 0 ? b.width : 1920
            let h = b.height > 0 ? b.height : 1080
            items.append(DisplayItem(
                id: display.id.uuidString,
                name: display.name,
                width: w,
                height: h,
                originX: b.origin.x,
                originY: b.origin.y,
                isBuiltIn: false,
                connectionId: display.id,
                cgDisplayID: display.cgDisplayID
            ))
        }

        return items
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Display arrangement area
                DashboardCard {
                    VStack(spacing: 12) {
                        HStack {
                            Text("Displays")
                                .font(.system(size: 14, weight: .semibold))
                            Spacer()
                            Button {
                                thumbProvider.refresh(displays: displays)
                            } label: {
                                Label(
                                    thumbProvider.thumbnails.isEmpty ? "Load Preview" : "Refresh Preview",
                                    systemImage: "arrow.clockwise"
                                )
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                            .disabled(thumbProvider.isRefreshing)

                            Button {
                                openDisplaySettings()
                            } label: {
                                Label("Arrange...", systemImage: "rectangle.3.group")
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                        }

                        displayArrangementView
                            .frame(height: 240)
                            .frame(maxWidth: .infinity)
                    }
                }

                // Selected display info
                if let selected = displays.first(where: { $0.id == selectedDisplayId }) {
                    selectedDisplayCard(selected)
                }

                // Transfer speed
                if !client.connectedDisplays.isEmpty {
                    DashboardCard {
                        HStack {
                            Text("Transfer Speed")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(client.transferRate)
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundStyle(.green)
                        }
                    }
                }
            }
            .padding(20)
        }
        .navigationTitle("Overview")
    }

    // MARK: - Display Arrangement (draggable + live preview)

    private var displayArrangementView: some View {
        GeometryReader { geo in
            let allDisplays = displays
            let layout = computeLayout(displays: allDisplays, containerSize: geo.size)

            ZStack {
                ForEach(allDisplays) { display in
                    if let info = layout.positions[display.id] {
                        displayThumbnail(display: display, width: info.thumbW, height: info.thumbH)
                            .position(x: info.centerX, y: info.centerY)
                            .onTapGesture {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    selectedDisplayId = display.id
                                }
                            }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .windowBackgroundColor).opacity(0.5))
            )
        }
    }

    private func displayThumbnail(display: DisplayItem, width: CGFloat, height: CGFloat) -> some View {
        let isSelected = selectedDisplayId == display.id

        return VStack(spacing: 4) {
            ZStack {
                // Live preview or fallback
                if let thumb = thumbProvider.thumbnails[display.id] {
                    Image(nsImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: width, height: height)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                } else {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(display.isBuiltIn
                            ? Color(nsColor: .controlBackgroundColor)
                            : Color.accentColor.opacity(0.1))
                }

                // Border
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(
                        isSelected ? Color.accentColor : Color.gray.opacity(0.5),
                        lineWidth: isSelected ? 2.5 : 1
                    )
            }
            .frame(width: width, height: height)
            .shadow(color: isSelected ? Color.accentColor.opacity(0.3) : .clear, radius: 4)

            Text(displayLabel(display))
                .font(.system(size: 9))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .lineLimit(1)
                .frame(width: max(width, 60))
        }
    }

    private func displayLabel(_ display: DisplayItem) -> String {
        if display.isBuiltIn { return "Built-in Display" }
        let name = display.name
        if name.count > 20 { return String(name.prefix(18)) + "..." }
        return name
    }

    // MARK: - Layout Computation

    private struct LayoutInfo {
        var positions: [String: ThumbPosition] = [:]
        var scale: CGFloat = 1
    }

    private struct ThumbPosition {
        var centerX: CGFloat
        var centerY: CGFloat
        var thumbW: CGFloat
        var thumbH: CGFloat
    }

    /// Compute positions based on actual CG display origins, scaled to fit the container.
    private func computeLayout(displays: [DisplayItem], containerSize: CGSize) -> LayoutInfo {
        guard !displays.isEmpty else { return LayoutInfo() }

        // Find the bounding box of all displays in CG coordinates
        var minX = CGFloat.infinity, minY = CGFloat.infinity
        var maxX = -CGFloat.infinity, maxY = -CGFloat.infinity
        for d in displays {
            minX = min(minX, d.originX)
            minY = min(minY, d.originY)
            maxX = max(maxX, d.originX + d.width)
            maxY = max(maxY, d.originY + d.height)
        }
        let totalW = maxX - minX
        let totalH = maxY - minY

        // Scale to fit in container with padding
        let padW = containerSize.width * 0.85
        let padH = containerSize.height * 0.7
        let scale = min(padW / max(totalW, 1), padH / max(totalH, 1), 0.15)

        // Center offset
        let scaledTotalW = totalW * scale
        let scaledTotalH = totalH * scale
        let offsetX = (containerSize.width - scaledTotalW) / 2
        let offsetY = (containerSize.height - scaledTotalH) / 2 - 10

        var info = LayoutInfo(scale: scale)
        for d in displays {
            let thumbW = d.width * scale
            let thumbH = d.height * scale
            let x = (d.originX - minX) * scale + offsetX
            let y = (d.originY - minY) * scale + offsetY
            info.positions[d.id] = ThumbPosition(
                centerX: x + thumbW / 2,
                centerY: y + thumbH / 2,
                thumbW: thumbW,
                thumbH: thumbH
            )
        }
        return info
    }

    private func openDisplaySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Selected Display Card

    private func selectedDisplayCard(_ display: DisplayItem) -> some View {
        DashboardCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: display.isBuiltIn ? "laptopcomputer" : "display")
                        .font(.system(size: 18))
                        .foregroundColor(display.isBuiltIn ? .secondary : .green)
                    Text(display.isBuiltIn ? "Built-in Display" : display.name)
                        .font(.system(size: 14, weight: .semibold))
                    Spacer()
                }

                HStack(spacing: 20) {
                    LabeledContent("Resolution") {
                        Text("\(Int(display.width)) x \(Int(display.height))")
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("Position") {
                        Text("(\(Int(display.originX)), \(Int(display.originY)))")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: 13))

                if !display.isBuiltIn, let connId = display.connectionId {
                    HStack {
                        Button("View Settings") {
                            selection = .device(connId)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
        }
    }

}

// Helper to find the built-in screen
private extension NSScreen {
    static var builtin: NSScreen? {
        NSScreen.screens.first { screen in
            // Built-in displays have a specific device description key
            if let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                return CGDisplayIsBuiltin(screenNumber) != 0
            }
            return false
        }
    }
}

// MARK: - Unified Device View (connected + discovered)

struct DeviceDetailView: View {
    let display: ConnectedDisplayInfo
    @ObservedObject var client: NetworkClient
    @ObservedObject private var transferStats: TransferStats
    @Binding var selection: BetterCastSenderApp.SidebarSelection?

    init(
        display: ConnectedDisplayInfo,
        client: NetworkClient,
        selection: Binding<BetterCastSenderApp.SidebarSelection?>
    ) {
        self.display = display
        self.client = client
        self.transferStats = client.transferStats
        self._selection = selection
    }

    private var applyButton: some View {
        Button {
            client.applySettings(for: display.id)
        } label: {
            Text(client.pendingSettingsRequireReconnect(for: display.id) ? "Apply & Reconnect" : "Apply")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.blue)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.primary.opacity(0.14), lineWidth: 0.5)
                }
        }
        .buttonStyle(.plain)
        .disabled(!client.hasPendingSettings(for: display.id))
        .opacity(client.hasPendingSettings(for: display.id) ? 1 : 0.45)
        .help("Apply Settings")
    }

    private var disconnectButton: some View {
        Button("Disconnect") {
            client.disconnectConnection(display.id)
            selection = .devices
        }
        .buttonStyle(CompactDisconnectButtonStyle())
    }

    private var connectionStatusBar: some View {
        Form {
            Section {
                HStack(spacing: 10) {
                    Circle()
                        .fill(.green)
                        .frame(width: 8, height: 8)

                    Text("Connected via \(display.connectionMethod)")
                        .font(.system(size: 13, weight: .semibold))

                    Text(display.resolution)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)

                    Spacer()

                    applyButton
                    disconnectButton
                }
                .padding(.vertical, 2)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(height: 82)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    var body: some View {
        Form {
            DeviceStreamSettingsSections(
                client: client,
                audioStreaming: Binding(
                    get: { display.audioEnabled },
                    set: { client.setAudioEnabled($0, for: display.id) }
                ),
                autoConnect: Binding(
                    get: { client.isAutoConnectEnabled(for: display.id) },
                    set: { client.setAutoConnectEnabled($0, for: display.id) }
                ),
                availableConnectionModes: client.availableConnectionModes(for: display.id),
                protocolDisabled: client.isProtocolLocked(for: display.id)
            )

            Section("Arrangement") {
                Button {
                    client.openDisplaySettings()
                } label: {
                    Label("Arrange Displays…", systemImage: "rectangle.3.group")
                }
            }

            Section("Status") {
                LabeledContent("Current") {
                    Text(display.resolution)
                }

                if display.displayBounds != .zero {
                    LabeledContent("Position") {
                        Text("(\(Int(display.displayBounds.origin.x)), \(Int(display.displayBounds.origin.y)))")
                    }
                }

                LabeledContent("Transfer Speed") {
                    Text(transferStats.rate)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.green)
                }
            }

        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .top, spacing: 0) {
            connectionStatusBar
        }
        .navigationTitle(display.name)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    selection = .devices
                } label: {
                    Label("Devices", systemImage: "chevron.left")
                }
                .help("Back to Devices")
            }
        }
        .onAppear {
            client.loadSettings(for: display.id)
        }
    }
}

/// The complete set of settings owned by one sender-to-receiver stream.
/// Shared by connected and discovered device pages so both stay in sync.
struct DeviceStreamSettingsSections: View {
    @ObservedObject var client: NetworkClient
    @Binding var audioStreaming: Bool
    @Binding var autoConnect: Bool
    let availableConnectionModes: [NetworkInterfacePreference]
    let protocolDisabled: Bool

    var body: some View {
        Group {
            Section("Connection") {
                HStack {
                    Picker("Mode", selection: connectionMode) {
                        ForEach(availableConnectionModes) { preference in
                            Text(preference.displayName).tag(preference)
                        }
                    }
                    InfoTip(text: client.interfacePreference.connectHelp)
                }

                Text(client.interfacePreference.connectDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Toggle("Auto-Connect", isOn: $autoConnect)
                    InfoTip(text: "Automatically reconnects to this device using the selected Mode.")
                }

                HStack {
                    Picker("Protocol", selection: $client.connectionType) {
                        Text("TCP (Recommended)").tag("TCP")
                        Text("UDP (Lower Latency)").tag("UDP")
                    }
                    .disabled(protocolDisabled || !client.interfacePreference.allowsUDP)
                    InfoTip(
                        text: protocolDisabled
                            ? "Manual IP and ADB connections use TCP."
                            : client.interfacePreference.protocolHelp
                    )
                }

                Text(client.interfacePreference.protocolDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Display") {
                HStack {
                    Picker("Use as", selection: $client.useVirtualDisplay) {
                        Text("Extended Display").tag(true)
                        Text("Mirror Built-in").tag(false)
                    }
                    InfoTip(text: "Extended creates a separate virtual monitor. Mirror duplicates your main display.")
                }

                HStack {
                    Picker("Dimensions", selection: $client.selectedResolution) {
                        ForEach(client.availableResolutions, id: \.self) { resolution in
                            Text("\(resolution.name) · \(resolution.displaySizeLabel)")
                                .tag(resolution)
                        }
                    }
                    .disabled(!client.useVirtualDisplay)
                    InfoTip(text: "Resolution of the virtual display. Higher resolutions use more bandwidth.")
                }

                HStack {
                    Toggle("Retina (HiDPI)", isOn: $client.isRetina)
                        .disabled(!client.useVirtualDisplay)
                    InfoTip(text: "Doubles pixel density. Sharper text but uses more bandwidth.")
                }
            }

            Section("Quality") {
                HStack {
                    Picker("Bitrate", selection: $client.selectedQuality) {
                        ForEach(StreamQuality.allCases) { quality in
                            Text(quality.name).tag(quality)
                        }
                    }
                    InfoTip(text: "Higher quality uses more bandwidth. Use Low/Medium on WiFi, High/Ultra on P2P or cable.")
                }

                HStack {
                    Picker("Frame Rate", selection: $client.selectedFPS) {
                        Text("30 FPS").tag(30)
                        Text("60 FPS").tag(60)
                    }
                    InfoTip(text: "Higher frame rates improve motion smoothness but require more encoding and network bandwidth.")
                }

                HStack {
                    Toggle("Audio Streaming", isOn: $audioStreaming)
                    InfoTip(text: "Streams system audio to the receiver.")
                }
            }
        }
    }

    private var connectionMode: Binding<NetworkInterfacePreference> {
        Binding(
            get: { client.interfacePreference },
            set: { preference in
                client.interfacePreference = preference
                if !preference.allowsUDP {
                    client.connectionType = "TCP"
                }
            }
        )
    }
}

struct CustomResolutionEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var width: Int
    @State private var height: Int
    @State private var ppi: Int
    @State private var label: String
    let originalResolution: VirtualDisplayManager.Resolution?
    let existingResolutions: [VirtualDisplayManager.Resolution]
    let onSave: (Int, Int, Int, String) -> Void

    init(
        originalResolution: VirtualDisplayManager.Resolution?,
        existingResolutions: [VirtualDisplayManager.Resolution],
        onSave: @escaping (Int, Int, Int, String) -> Void
    ) {
        self._width = State(initialValue: originalResolution?.width ?? 1600)
        self._height = State(initialValue: originalResolution?.height ?? 1000)
        self._ppi = State(initialValue: originalResolution?.ppi ?? 220)
        let originalName = originalResolution?.name ?? ""
        if let openingParenthesis = originalName.lastIndex(of: "("),
           originalName.hasSuffix(")") {
            let labelStart = originalName.index(after: openingParenthesis)
            let labelEnd = originalName.index(before: originalName.endIndex)
            self._label = State(initialValue: String(originalName[labelStart..<labelEnd]))
        } else {
            self._label = State(initialValue: "")
        }
        self.originalResolution = originalResolution
        self.existingResolutions = existingResolutions
        self.onSave = onSave
    }

    private var trimmedLabel: String {
        label.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isLabelValid: Bool {
        !trimmedLabel.isEmpty
            && !trimmedLabel.contains("(")
            && !trimmedLabel.contains(")")
    }

    private var isValid: Bool {
        (640...7680).contains(width)
            && (480...4320).contains(height)
            && width.isMultiple(of: 2)
            && height.isMultiple(of: 2)
            && (72...500).contains(ppi)
            && isLabelValid
    }

    private var isDuplicate: Bool {
        existingResolutions.contains {
            $0.width == width
                && $0.height == height
                && $0 != originalResolution
        }
    }

    private var equivalentDisplaySize: String {
        let diagonal = VirtualDisplayManager.Resolution.equivalentDiagonalInches(
            width: width,
            height: height,
            ppi: ppi
        )
        return String(format: "%.1f″", diagonal)
    }

    private var validationMessage: String {
        if isDuplicate {
            return "This resolution already exists."
        }
        if !(640...7680).contains(width) || !(480...4320).contains(height) {
            return "Width: 640–7680 pixels. Height: 480–4320 pixels."
        }
        if !width.isMultiple(of: 2) || !height.isMultiple(of: 2) {
            return "Width and height must both be even numbers."
        }
        if !(72...500).contains(ppi) {
            return "PPI must be between 72 and 500."
        }
        if trimmedLabel.isEmpty {
            return "Label is required."
        }
        if trimmedLabel.contains("(") || trimmedLabel.contains(")") {
            return "Label cannot contain parentheses."
        }
        return "macOS will recognize this as approximately a \(equivalentDisplaySize) display when Retina is enabled. Standard mode uses up to 110 PPI."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(originalResolution == nil ? "Add Custom Resolution" : "Edit Custom Resolution")
                .font(.title2.bold())

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    Text("Width")
                    TextField("Width", value: $width, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Height")
                    TextField("Height", value: $height, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Pixel Density")
                    HStack(spacing: 6) {
                        TextField("Density", value: $ppi, format: .number.grouping(.never))
                            .textFieldStyle(.roundedBorder)
                        Text("PPI")
                            .foregroundStyle(.secondary)
                    }
                }
                GridRow {
                    Text("Label")
                    TextField("Required", text: $label)
                        .textFieldStyle(.roundedBorder)
                }
            }

            Text(validationMessage)
                .font(.caption)
                .foregroundStyle(!isValid || isDuplicate ? .red : .secondary)

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                Button("Save") {
                    onSave(width, height, ppi, trimmedLabel)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isValid || isDuplicate)
            }
        }
        .padding(24)
        .frame(width: 420)
    }
}

struct DiscoveredDeviceView: View {
    let service: DiscoveredService
    @ObservedObject var client: NetworkClient
    @Binding var selection: BetterCastSenderApp.SidebarSelection?

    private var isAndroid: Bool {
        service.name.lowercased().contains("android")
    }

    private var isManualConnection: Bool {
        if case .hostPort = service.endpoint { return true }
        return false
    }

    /// Check if this device is connected via any method (direct or ADB)
    private var connectedDisplay: ConnectedDisplayInfo? {
        if let d = client.connectedDisplays.first(where: { $0.name == service.name }) { return d }
        if isAndroid {
            return client.connectedDisplays.first(where: {
                $0.name.contains("Android (USB)") || $0.name.contains("Android (WiFi ADB)")
            })
        }
        return nil
    }

    var body: some View {
        if let display = connectedDisplay {
            // Connected — show per-device settings
            DeviceDetailView(display: display, client: client, selection: $selection)
        } else {
            // Not connected — show connect options
            connectForm
        }
    }

    private var connectForm: some View {
        Form {
            Section("Connect") {
                if isAndroid {
                    HStack {
                        Image(systemName: "cable.connector")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading) {
                            Text("ADB (USB)")
                                .fontWeight(.medium)
                            Text("60 FPS — best quality, requires USB cable")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Connect") {
                            client.connectADBUSB()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        InfoTip(text: "Streams via USB using Android Debug Bridge. Highest quality with no network needed. Plug in your Android device first.")
                    }

                    HStack {
                        Image(systemName: "wifi")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading) {
                            Text("ADB (WiFi)")
                                .fontWeight(.medium)
                            Text("60 FPS — wireless ADB tunnel, needs USB first")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Connect") {
                            client.connectADBWireless()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(client.adbInProgress)
                        InfoTip(text: "Wireless ADB tunnel. Connect USB once to pair, then unplug and stream wirelessly at full quality.")
                    }
                }

                HStack {
                    Image(systemName: client.interfacePreference.connectSystemImage)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading) {
                        Text(client.interfacePreference.connectTitle)
                            .fontWeight(.medium)
                        Text(connectCardDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if selectedModeIsAvailable {
                            Text("Endpoint: \(connectEndpointDescription ?? "Resolving…")")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    Spacer()
                    Button {
                        connect(using: client.interfacePreference)
                    } label: {
                        if client.isConnecting(to: service) {
                            HStack(spacing: 5) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Connecting…")
                            }
                        } else {
                            Text("Connect")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(
                        !selectedModeIsAvailable
                            || client.isConnecting(to: service)
                    )
                    InfoTip(text: client.interfacePreference.connectHelp)
                }
            }

            if isAndroid && !client.adbStatus.isEmpty {
                Section("ADB Status") {
                    Text(client.adbStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            DeviceStreamSettingsSections(
                client: client,
                audioStreaming: $client.audioStreamingEnabled,
                autoConnect: Binding(
                    get: { client.isAutoConnectEnabled(for: service) },
                    set: { client.setAutoConnectEnabled($0, for: service) }
                ),
                availableConnectionModes: client.availableConnectionModes(for: service),
                protocolDisabled: isManualConnection
            )
        }
        .formStyle(.grouped)
        .navigationTitle(service.name)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    selection = .devices
                } label: {
                    Label("Devices", systemImage: "chevron.left")
                }
                .help("Back to Devices")
            }
        }
        .onAppear {
            client.loadSettings(for: service)
        }
    }

    private func connect(using preference: NetworkInterfacePreference) {
        if isManualConnection {
            client.connectManualService(service, using: preference)
        } else {
            client.connect(
                to: service,
                using: preference,
                restoringSavedSettings: false
            )
        }
    }

    private var selectedModeIsAvailable: Bool {
        client.availableConnectionModes(for: service)
            .contains(client.interfacePreference)
    }

    private var connectCardDescription: String {
        if !selectedModeIsAvailable {
            return client.interfacePreference.unavailableDescription
        }
        return client.interfacePreference.connectDescription
    }

    private var connectEndpointDescription: String? {
        client.connectionEndpointDescription(
            for: service,
            preference: client.interfacePreference
        )
    }
}

// MARK: - Info Tip

struct InfoTip: View {
    let text: String
    @State private var isShowing = false

    var body: some View {
        Button {
            isShowing.toggle()
        } label: {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isShowing, arrowEdge: .trailing) {
            Text(text)
                .font(.caption)
                .padding(10)
                .frame(maxWidth: 260)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Settings Action Row

struct SettingsActionRow<Content: View>: View {
    let title: String
    let description: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            content
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Connected Display Info

struct ConnectedDisplayInfo: Identifiable {
    let id: UUID
    let name: String
    let resolution: String
    let connectionMethod: String
    let displayBounds: CGRect
    var audioEnabled: Bool
    var cgDisplayID: CGDirectDisplayID? = nil

    var deviceListSubtitle: String {
        "\(resolution) · \(connectionMethod)"
    }
}

struct DiscoveredNetworkInterface: Hashable {
    let name: String
    let type: NWInterface.InterfaceType

    var isThunderboltBridge: Bool {
        let lowercasedName = name.lowercased()
        return lowercasedName.contains("bridge")
            || lowercasedName.contains("thunderbolt")
    }

    var isEthernet: Bool {
        type == .wiredEthernet && !isThunderboltBridge
    }
}

struct DiscoveredServiceEndpoint {
    let endpoint: NWEndpoint
    let discoveryInterfaces: [DiscoveredNetworkInterface]

    func supports(_ preference: NetworkInterfacePreference) -> Bool {
        switch preference {
        case .auto:
            return true
        case .routerOnly:
            return discoveryInterfaces.contains { $0.type == .wifi }
        case .ethernet:
            return discoveryInterfaces.contains(where: \.isEthernet)
        case .thunderboltBridge:
            return discoveryInterfaces.contains(where: \.isThunderboltBridge)
        case .wiredCable:
            return discoveryInterfaces.contains {
                $0.isEthernet || $0.isThunderboltBridge
            }
        case .p2pOnly:
            return discoveryInterfaces.contains {
                let name = $0.name.lowercased()
                return name == "awdl0" || name == "llw0"
            }
        }
    }
}

struct DiscoveredService: Identifiable {
    let id = UUID()
    let name: String
    let endpoint: NWEndpoint
    let discoveryInterfaces: [DiscoveredNetworkInterface]
    let connectionEndpoints: [DiscoveredServiceEndpoint]

    init(
        name: String,
        endpoint: NWEndpoint,
        discoveryInterfaces: [DiscoveredNetworkInterface] = [],
        connectionEndpoints: [DiscoveredServiceEndpoint]? = nil
    ) {
        self.name = name
        self.endpoint = endpoint
        self.discoveryInterfaces = discoveryInterfaces
        self.connectionEndpoints = connectionEndpoints ?? [
            DiscoveredServiceEndpoint(
                endpoint: endpoint,
                discoveryInterfaces: discoveryInterfaces
            ),
        ]
    }

    var supportsEthernetConnection: Bool {
        discoveryInterfaces.contains(where: \.isEthernet)
    }

    var supportsThunderboltConnection: Bool {
        discoveryInterfaces.contains(where: \.isThunderboltBridge)
    }

    var supportsWiFiConnection: Bool {
        discoveryInterfaces.contains { $0.type == .wifi }
    }

    var supportsApplePeerToPeerConnection: Bool {
        discoveryInterfaces.contains { interface in
            let name = interface.name.lowercased()
            return name == "awdl0" || name == "llw0"
        }
    }

    func mergingDiscoveryInterfaces(from other: DiscoveredService) -> DiscoveredService {
        var mergedEndpoints = connectionEndpoints
        for candidate in other.connectionEndpoints where
            !mergedEndpoints.contains(where: {
                $0.endpoint == candidate.endpoint
                    && $0.discoveryInterfaces == candidate.discoveryInterfaces
            }) {
            mergedEndpoints.append(candidate)
        }

        return DiscoveredService(
            name: name,
            endpoint: Self.unscopedServiceEndpoint(endpoint),
            discoveryInterfaces: Array(
                Set(discoveryInterfaces + other.discoveryInterfaces)
            ).sorted { $0.name < $1.name },
            connectionEndpoints: mergedEndpoints
        )
    }

    func connectionEndpoint(
        for preference: NetworkInterfacePreference
    ) -> NWEndpoint {
        connectionEndpoints.first { $0.supports(preference) }?.endpoint
            ?? endpoint
    }

    func hasConnectionEndpoint(
        for preference: NetworkInterfacePreference
    ) -> Bool {
        connectionEndpoints.contains { $0.supports(preference) }
    }

    var infrastructureConnectionEndpoint: NWEndpoint {
        connectionEndpoints.first { $0.supports(.routerOnly) }?.endpoint
            ?? connectionEndpoints.first { $0.supports(.ethernet) }?.endpoint
            ?? endpoint
    }

    private static func unscopedServiceEndpoint(
        _ endpoint: NWEndpoint
    ) -> NWEndpoint {
        guard case .service(let name, let type, let domain, _) = endpoint else {
            return endpoint
        }
        return .service(
            name: name,
            type: type,
            domain: domain,
            interface: nil
        )
    }
}

struct BonjourResolvedRoute {
    let endpoint: NWEndpoint
    let interfaceNames: [String]
    let usesWiFi: Bool
    let usesWiredEthernet: Bool

    init(
        endpoint: NWEndpoint,
        interfaceNames: [String],
        usesWiFi: Bool,
        usesWiredEthernet: Bool
    ) {
        self.endpoint = endpoint
        self.interfaceNames = interfaceNames
        self.usesWiFi = usesWiFi
        self.usesWiredEthernet = usesWiredEthernet
    }

    private var hostDescription: String? {
        guard case .hostPort(let host, _) = endpoint else {
            return nil
        }
        return String(describing: host).lowercased()
    }

    var scopedInterfaceName: String? {
        guard let hostDescription,
              let separator = hostDescription.lastIndex(of: "%") else {
            return nil
        }
        return String(hostDescription[hostDescription.index(after: separator)...])
    }

    private var isThunderboltRoute: Bool {
        guard !usesWiFi else { return false }
        if let scopedInterfaceName {
            return scopedInterfaceName.contains("bridge")
                || scopedInterfaceName.contains("thunderbolt")
        }
        return false
    }

    func supports(_ preference: NetworkInterfacePreference) -> Bool {
        switch preference {
        case .auto:
            return true
        case .routerOnly:
            return usesWiFi
        case .ethernet:
            return usesWiredEthernet && !isThunderboltRoute
        case .thunderboltBridge:
            return isThunderboltRoute
        case .wiredCable:
            return usesWiredEthernet && !usesWiFi
        case .p2pOnly:
            return interfaceNames.contains {
                let name = $0.lowercased()
                return name == "awdl0" || name == "llw0"
            }
        }
    }
}

enum BonjourConnectionPolicy {
    static func prefersIPv4(receiverName: String) -> Bool {
        receiverName.lowercased().contains("windows")
    }

    static func applyLocalNetworkPolicy(
        to parameters: NWParameters,
        receiverName: String
    ) {
        // Bonjour receivers are always on the local network. A system proxy can
        // accept the TCP probe on loopback and create a false-positive Available
        // device while the real receiver remains unreachable.
        parameters.preferNoProxies = true

        guard prefersIPv4(receiverName: receiverName),
              let ipOptions =
                parameters.defaultProtocolStack.internetProtocol
                    as? NWProtocolIP.Options else {
            return
        }
        ipOptions.version = .v4
    }
}

struct BonjourReachabilityResult {
    let isReachable: Bool
    let resolvedRoutes: [BonjourResolvedRoute]

    init(
        isReachable: Bool,
        resolvedRoute: BonjourResolvedRoute?
    ) {
        self.isReachable = isReachable
        resolvedRoutes = resolvedRoute.map { [$0] } ?? []
    }

    init(
        isReachable: Bool,
        resolvedRoutes: [BonjourResolvedRoute]
    ) {
        self.isReachable = isReachable
        self.resolvedRoutes = resolvedRoutes
    }

    var resolvedRoute: BonjourResolvedRoute? {
        resolvedRoutes.first
    }

    static let reachable = BonjourReachabilityResult(
        isReachable: true,
        resolvedRoute: nil
    )
    static let unreachable = BonjourReachabilityResult(
        isReachable: false,
        resolvedRoute: nil
    )
}

typealias BonjourReachabilityProbe = (
    DiscoveredService,
    @escaping (BonjourReachabilityResult) -> Void
) -> () -> Void

private enum ConnectDiagnostics {
    static let tag = "[DEBUG-CONNECT-7F3A]"

    static func log(_ message: String) {
        LogManager.shared.log("\(tag) \(message)")
    }

    static func stateSummary(_ state: NWConnection.State) -> String {
        switch state {
        case .setup:
            return "setup"
        case .preparing:
            return "preparing"
        case .ready:
            return "ready"
        case .waiting(let error):
            return "waiting error=\(error)"
        case .failed(let error):
            return "failed error=\(error)"
        case .cancelled:
            return "cancelled"
        @unknown default:
            return "unknown"
        }
    }

    static func pathSummary(_ path: NWPath?) -> String {
        guard let path else { return "path=nil" }
        let interfaces = path.availableInterfaces.map {
            "\($0.name):\($0.type)"
        }.joined(separator: ",")
        return [
            "status=\(path.status)",
            "local=\(String(describing: path.localEndpoint))",
            "remote=\(String(describing: path.remoteEndpoint))",
            "interfaces=[\(interfaces)]",
            "usesWiFi=\(path.usesInterfaceType(.wifi))",
            "usesWired=\(path.usesInterfaceType(.wiredEthernet))",
            "usesOther=\(path.usesInterfaceType(.other))",
            "ipv4=\(path.supportsIPv4)",
            "ipv6=\(path.supportsIPv6)",
            "dns=\(path.supportsDNS)",
            "expensive=\(path.isExpensive)",
            "constrained=\(path.isConstrained)",
        ].joined(separator: " ")
    }
}

private final class BonjourTCPReachabilityCheck {
    private let connection: NWConnection
    private let completion: (BonjourReachabilityResult) -> Void
    private let service: DiscoveredService
    private let startedAt = Date()
    private let lock = NSLock()
    private var isFinished = false

    init(
        service: DiscoveredService,
        completion: @escaping (BonjourReachabilityResult) -> Void
    ) {
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.connectionTimeout = 2
        let parameters = NWParameters(tls: nil, tcp: tcpOptions)
        parameters.includePeerToPeer = true
        if service.supportsWiFiConnection
            && !service.supportsThunderboltConnection {
            parameters.requiredInterfaceType = .wifi
            parameters.includePeerToPeer = false
        } else if service.supportsThunderboltConnection
                    && !service.supportsWiFiConnection {
            parameters.prohibitedInterfaceTypes = [.loopback, .wifi]
            parameters.includePeerToPeer = false
        }
        BonjourConnectionPolicy.applyLocalNetworkPolicy(
            to: parameters,
            receiverName: service.name
        )
        connection = NWConnection(to: service.endpoint, using: parameters)
        self.service = service
        self.completion = completion
    }

    func start() {
        ConnectDiagnostics.log(
            "probe start service=\(service.name) endpoint=\(service.endpoint) " +
            "preferIPv4=\(BonjourConnectionPolicy.prefersIPv4(receiverName: service.name)) " +
            "preferNoProxies=true"
        )
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            let elapsed = Date().timeIntervalSince(self.startedAt)
            ConnectDiagnostics.log(
                String(
                    format: "probe state service=%@ elapsed=%.3fs state=%@ %@",
                    self.service.name,
                    elapsed,
                    ConnectDiagnostics.stateSummary(state),
                    ConnectDiagnostics.pathSummary(self.connection.currentPath)
                )
            )
            switch state {
            case .ready:
                let path = self.connection.currentPath
                let pathInterfaces = path?.availableInterfaces ?? []
                let resolvedRoute = path?.remoteEndpoint.map {
                    BonjourResolvedRoute(
                        endpoint: $0,
                        interfaceNames: pathInterfaces.map(\.name),
                        usesWiFi: path?.usesInterfaceType(.wifi) ?? false,
                        usesWiredEthernet: path?.usesInterfaceType(.wiredEthernet) ?? false
                    )
                }
                self.finish(
                    result: BonjourReachabilityResult(
                        isReachable: true,
                        resolvedRoute: resolvedRoute
                    )
                )
            case .waiting, .failed:
                self.finish(result: .unreachable)
            default:
                break
            }
        }
        connection.start(queue: .global(qos: .utility))

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2.5) {
            ConnectDiagnostics.log(
                "probe watchdog service=\(self.service.name) elapsed=2.500s " +
                ConnectDiagnostics.pathSummary(self.connection.currentPath)
            )
            self.finish(result: .unreachable)
        }
    }

    func cancel() {
        lock.lock()
        let shouldCancel = !isFinished
        isFinished = true
        lock.unlock()

        if shouldCancel {
            ConnectDiagnostics.log(
                "probe cancel service=\(service.name) " +
                ConnectDiagnostics.pathSummary(connection.currentPath)
            )
            connection.stateUpdateHandler = nil
            connection.cancel()
        }
    }

    private func finish(result: BonjourReachabilityResult) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        lock.unlock()

        connection.stateUpdateHandler = nil
        connection.cancel()
        ConnectDiagnostics.log(
            "probe finish service=\(service.name) reachable=\(result.isReachable) " +
            "resolved=\(String(describing: result.resolvedRoute?.endpoint))"
        )
        completion(result)
    }
}

private final class BonjourTCPReachabilitySweep {
    private let lock = NSLock()
    private let completion: (BonjourReachabilityResult) -> Void
    private var checks: [BonjourTCPReachabilityCheck] = []
    private var remainingChecks = 0
    private var anyRouteWasReachable = false
    private var resolvedRoutes: [BonjourResolvedRoute] = []
    private var isFinished = false

    init(
        service: DiscoveredService,
        completion: @escaping (BonjourReachabilityResult) -> Void
    ) {
        self.completion = completion
        let candidates = service.connectionEndpoints.isEmpty
            ? [
                DiscoveredServiceEndpoint(
                    endpoint: service.endpoint,
                    discoveryInterfaces: service.discoveryInterfaces
                ),
            ]
            : service.connectionEndpoints
        remainingChecks = candidates.count
        checks = candidates.map { candidate in
            let candidateService = DiscoveredService(
                name: service.name,
                endpoint: candidate.endpoint,
                discoveryInterfaces: candidate.discoveryInterfaces
            )
            return BonjourTCPReachabilityCheck(
                service: candidateService
            ) { [weak self] result in
                self?.received(result)
            }
        }
    }

    func start() {
        checks.forEach { $0.start() }
    }

    func cancel() {
        finish(result: nil)
    }

    private func received(_ result: BonjourReachabilityResult) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        if result.isReachable {
            anyRouteWasReachable = true
            for route in result.resolvedRoutes where
                !resolvedRoutes.contains(where: {
                    $0.endpoint == route.endpoint
                }) {
                resolvedRoutes.append(route)
            }
        }
        remainingChecks -= 1
        let allFinished = remainingChecks == 0
        let finalResult = BonjourReachabilityResult(
            isReachable: anyRouteWasReachable,
            resolvedRoutes: resolvedRoutes
        )
        lock.unlock()
        if allFinished {
            finish(result: finalResult)
        }
    }

    private func finish(result: BonjourReachabilityResult?) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        let activeChecks = checks
        checks.removeAll()
        lock.unlock()

        activeChecks.forEach { $0.cancel() }
        if let result {
            completion(result)
        }
    }
}

struct ManualConnectionHistoryItem: Codable, Hashable, Identifiable {
    let host: String
    let port: UInt16

    var id: String {
        "\(host.lowercased()):\(port)"
    }

    var displayName: String {
        "\(host):\(port)"
    }

    var isLinkLocalAddress: Bool {
        Self.isLinkLocalHost(host)
    }

    static func isLinkLocalHost(_ host: String) -> Bool {
        host.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .hasPrefix("169.254.")
    }
}

enum ManualConnectionAvailability: Equatable {
    case unknown
    case checking
    case available
    case unavailable
    case permissionRequired
}

enum StreamQuality: Int, CaseIterable, Identifiable {
    case low = 5_000_000
    case medium = 10_000_000
    case high = 20_000_000
    case ultra = 50_000_000
    case extreme = 100_000_000

    var id: Int { self.rawValue }
    var name: String {
        switch self {
        case .low: return "Low (5 Mbps)"
        case .medium: return "Medium (10 Mbps)"
        case .high: return "High (20 Mbps)"
        case .ultra: return "Ultra (50 Mbps)"
        case .extreme: return "Extreme (100 Mbps)"
        }
    }
}

enum NetworkInterfacePreference: String, CaseIterable, Identifiable {
    case auto = "Auto (Apple Default)"
    case p2pOnly = "Force P2P (WiFi Direct)"
    case routerOnly = "Force Router/WiFi"
    case ethernet = "Ethernet"
    case thunderboltBridge = "Thunderbolt Bridge"
    // Kept only to migrate profiles saved before wired modes were separated.
    case wiredCable = "USB / Thunderbolt Cable"

    var id: String { self.rawValue }

    static var allCases: [NetworkInterfacePreference] {
        [.auto, .p2pOnly, .routerOnly, .ethernet, .thunderboltBridge]
    }

    var displayName: String {
        switch self {
        case .auto: return "Automatic (Best Available)"
        case .p2pOnly: return "Wi-Fi Direct (P2P)"
        case .routerOnly: return "Wi-Fi"
        case .ethernet: return "Ethernet"
        case .thunderboltBridge: return "Thunderbolt Bridge"
        case .wiredCable: return "Wired Connection (Legacy)"
        }
    }

    var connectTitle: String {
        switch self {
        case .auto: return "Automatic"
        case .p2pOnly: return "Wi-Fi Direct"
        case .routerOnly: return "Wi-Fi"
        case .ethernet: return "Ethernet"
        case .thunderboltBridge: return "Thunderbolt Bridge"
        case .wiredCable: return "Wired Connection"
        }
    }

    var connectDescription: String {
        switch self {
        case .auto:
            return "Use the best available connection"
        case .p2pOnly:
            return "Connect directly using peer-to-peer Wi-Fi"
        case .routerOnly:
            return "Connect through the Wi-Fi network"
        case .ethernet:
            return "Connect through a wired Ethernet network"
        case .thunderboltBridge:
            return "Connect directly over Thunderbolt"
        case .wiredCable:
            return "Connect through a wired network"
        }
    }

    var connectHelp: String {
        switch self {
        case .auto:
            return "Automatically chooses the best available route for this connection."
        case .p2pOnly:
            return "Requires Apple peer-to-peer Wi-Fi and does not fall back to the local network or a cable."
        case .routerOnly:
            return "Requires Wi-Fi and does not fall back to peer-to-peer Wi-Fi or a cable."
        case .ethernet:
            return "Requires the Ethernet interface on which this device was discovered and does not fall back to Wi-Fi."
        case .thunderboltBridge:
            return "Requires the Thunderbolt Bridge interface on which this device was discovered and does not fall back to Wi-Fi."
        case .wiredCable:
            return "Uses a legacy wired preference. Select Ethernet or Thunderbolt Bridge instead."
        }
    }

    var connectSystemImage: String {
        switch self {
        case .auto: return "arrow.triangle.branch"
        case .p2pOnly: return "point.3.connected.trianglepath.dotted"
        case .routerOnly: return "wifi"
        case .ethernet: return "network"
        case .thunderboltBridge: return "bolt.horizontal.circle"
        case .wiredCable: return "cable.connector"
        }
    }

    var allowsUDP: Bool {
        self == .p2pOnly
    }

    var protocolDescription: String {
        if allowsUDP {
            return "TCP is more reliable; UDP may reduce latency but can drop frames."
        }
        return "TCP is required for this connection mode."
    }

    var protocolHelp: String {
        if allowsUDP {
            return "TCP guarantees ordered delivery. UDP avoids retransmission delays but may lose frames."
        }
        return "UDP is available only when Mode is set to Wi-Fi Direct."
    }

    var unavailableDescription: String {
        switch self {
        case .ethernet:
            return "This device was not found over Ethernet"
        case .thunderboltBridge:
            return "This device was not found over Thunderbolt Bridge"
        case .wiredCable:
            return "This device was not found over a wired network"
        default:
            return "This connection mode is not available for this device"
        }
    }
}

struct ReceiverSettings: Codable, Equatable {
    var resolutionWidth: Int
    var resolutionHeight: Int
    var resolutionPPI: Int
    var resolutionName: String
    var retinaEnabled: Bool
    var qualityRawValue: Int
    var fps: Int
    var useVirtualDisplay: Bool
    var audioStreamingEnabled: Bool
    // Optional for backward compatibility with profiles saved before build 37.
    var connectionType: String?
    var interfacePreferenceRawValue: String?
}

// Per-connection pipeline: each device gets its own virtual display, screen capture, and encoder
struct ConnectionPipeline {
    let id: UUID
    let connection: NWConnection
    let service: DiscoveredService
    var lastHeartbeat: Date
    var settings: ReceiverSettings

    // Per-connection components (isolated pipeline)
    var virtualDisplayManager: VirtualDisplayManager?
    var screenRecorder: ScreenRecorder?
    var videoEncoder: VideoEncoder?
    var audioEncoder: AudioEncoder?

    // Adaptive: P2P (AWDL) connections get full quality; infrastructure gets throttled
    var isP2P: Bool = false
    // Loopback connections (ADB tunnel via lo0) — high bandwidth, skip backpressure
    var isLoopback: Bool = false
    // WiFi ADB vs USB ADB — WiFi has much less bandwidth, needs throttling
    var isWiFiADB: Bool = false
    // ADB/localhost connections always use TCP framing regardless of global protocol setting
    var forceTCP: Bool = false
    // iOS/Mac Swift receivers don't strip the type byte — send raw payloads for them
    var supportsTypeByte: Bool = true
    // Receiver-reported screen dimensions (pixels) — used to match aspect ratio
    var reportedScreenWidth: Int? = nil
    var reportedScreenHeight: Int? = nil
    var connectionPreference: NetworkInterfacePreference = .auto
}

final class TransferStats: ObservableObject {
    @Published var rate = "0 Mbps"
}

class NetworkClient: ObservableObject, VideoEncoderDelegate, AudioEncoderDelegate {
    static let tcpConnectionTimeout = 10
    static let availableConnectionAttemptTimeout: TimeInterval = 15

    static func preferredBonjourEndpoint(
        for preference: NetworkInterfacePreference,
        resolvedRoute: BonjourResolvedRoute?
    ) -> NWEndpoint? {
        guard let resolvedRoute, resolvedRoute.supports(preference) else {
            return nil
        }
        return resolvedRoute.endpoint
    }

    static func preferredBonjourEndpoint(
        for preference: NetworkInterfacePreference,
        resolvedRoutes: [BonjourResolvedRoute]
    ) -> NWEndpoint? {
        resolvedRoutes.first { $0.supports(preference) }?.endpoint
    }

    static func preferredBonjourRoute(
        for preference: NetworkInterfacePreference,
        resolvedRoutes: [BonjourResolvedRoute]
    ) -> BonjourResolvedRoute? {
        resolvedRoutes.first { $0.supports(preference) }
    }

    static func preferredConnectionEndpoint(
        for preference: NetworkInterfacePreference,
        resolvedRoute: BonjourResolvedRoute?,
        discoveredEndpoint: NWEndpoint,
        thunderboltPeerHost: String?,
        thunderboltInterfaceName: String? = nil,
        discoveredEndpointMatchesPreference: Bool = false
    ) -> NWEndpoint {
        OutboundRouteCatalog.preferredConnectionEndpoint(
            for: preference,
            resolvedRoute: resolvedRoute,
            discoveredEndpoint: discoveredEndpoint,
            thunderboltPeerHost: thunderboltPeerHost,
            thunderboltInterfaceName: thunderboltInterfaceName,
            discoveredEndpointMatchesPreference:
                discoveredEndpointMatchesPreference
        )
    }

    static func infrastructureFallbackEndpoint(
        shouldFallback: Bool,
        resolvedEndpoint: NWEndpoint?,
        discoveredEndpoint: NWEndpoint
    ) -> NWEndpoint {
        shouldFallback
            ? discoveredEndpoint
            : resolvedEndpoint ?? discoveredEndpoint
    }

    static func endpointDescription(_ endpoint: NWEndpoint) -> String? {
        guard case .hostPort(let host, let port) = endpoint else {
            return nil
        }
        let rawHostDescription = String(describing: host)
        let hostDescription: String
        if rawHostDescription.contains("."),
           !rawHostDescription.hasPrefix("169.254."),
           let scopeSeparator = rawHostDescription.lastIndex(of: "%") {
            hostDescription = String(
                rawHostDescription[..<scopeSeparator]
            )
        } else {
            hostDescription = rawHostDescription
        }
        let formattedHost =
            hostDescription.contains(":") && !hostDescription.hasPrefix("[")
                ? "[\(hostDescription)]"
                : hostDescription
        return "\(formattedHost):\(port.rawValue)"
    }

    static func bonjourReceiverIdentity(_ name: String) -> String {
        let withoutNumericSuffix = name
            .replacingOccurrences(
                of: #" \(\d+\)$"#,
                with: "",
                options: .regularExpression
            )
        return withoutNumericSuffix
            .replacingOccurrences(
                of: #" P2P$"#,
                with: "",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private enum PreferenceKey {
        static let resolutionWidth = "senderResolutionWidth"
        static let resolutionHeight = "senderResolutionHeight"
        static let resolutionPPI = "senderResolutionPPI"
        static let resolutionName = "senderResolutionName"
        static let customResolutions = "senderCustomResolutionsV1"
        static let retina = "senderRetina"
        static let quality = "senderQuality"
        static let fps = "senderFPS"
        static let useVirtualDisplay = "senderUseVirtualDisplay"
        static let audioStreaming = "senderAudioStreaming"
        static let connectionType = "senderConnectionType"
        static let interfacePreference = "senderInterfacePreference"
        static let autoConnectReceiverKeys = "senderAutoConnectReceiverKeysV1"
        static let manualHost = "senderManualHost"
        static let manualPort = "senderManualPort"
        static let receiverProfiles = "senderReceiverProfilesV1"
        static let manualConnectionHistory = "senderManualConnectionHistoryV1"
    }

    private var browsers: [String: NWBrowser] = [:]
    private var discoveredServicesByProtocol: [String: [String: DiscoveredService]] = [:]
    private var latestDiscoveredServiceNames: [String: Set<String>] = [:]
    private var discoveryRemovalWorkItems: [String: DispatchWorkItem] = [:]
    private var browserRecoveryWorkItems: [String: DispatchWorkItem] = [:]
    private var browserRecoveryAttempts: [String: Int] = [:]
    private var discoverySearchWorkItem: DispatchWorkItem?
    private let discoveryRemovalDelay: TimeInterval
    private let backgroundBonjourReachabilityRecheckInterval: TimeInterval
    private let focusedBonjourReachabilityRecheckInterval: TimeInterval
    private let bonjourReachabilityProbe: BonjourReachabilityProbe
    private let localConnectionAddressProvider: () -> [ReceiverConnectionAddress]
    private let thunderboltPeerRouteProvider:
        () -> [ThunderboltPeerAddressProvider.PeerRoute]
    private var cachedThunderboltPeerRoutes:
        [ThunderboltPeerAddressProvider.PeerRoute] = []
    private var lastThunderboltPeerRouteRefresh = Date.distantPast
    private static let thunderboltPeerRouteCacheInterval: TimeInterval = 1
    private var focusedBonjourServiceName: String?
    private var browsedTCPServicesByName: [String: DiscoveredService] = [:]
    private var reachableTCPServiceNames: Set<String> = []
    private var resolvedBonjourRoutesByName:
        [String: [BonjourResolvedRoute]] = [:]
    private var bonjourReachabilityProbeIDs: [String: UUID] = [:]
    private var bonjourReachabilityProbeCancellations: [String: () -> Void] = [:]
    private var bonjourReachabilityRecheckWorkItems: [String: DispatchWorkItem] = [:]
    private var pipelines: [UUID: ConnectionPipeline] = [:]
    private var receiverProfiles: [String: ReceiverSettings] = [:]
    @Published private var autoConnectReceiverKeys: Set<String> = []
    private var suppressedAutoConnectReceiverKeys: Set<String> = []
    private var manualAvailabilityProbes: [String: NWConnection] = [:]
    private var manualAvailabilityProbeGeneration = UUID()
    private var lastManualAvailabilityRefresh: Date?

    @Published var status: String = "Idle"
    @Published var foundServices: [DiscoveredService] = []
    @Published private(set) var isDiscoveringDevices = true
    @Published var connectedServices: [DiscoveredService] = []
    private var connectionRegistry = ReceiverConnectionRegistry()
    private var pendingConnectionsByID: [UUID: NWConnection] = [:]
    private var reconnectingServiceNames: Set<String> = []
    @Published var useVirtualDisplay: Bool = true {
        didSet { persistSettings() }
    }
    @Published var audioStreamingEnabled: Bool = true {
        didSet { persistSettings() }
    }
    @Published var connectedDisplays: [ConnectedDisplayInfo] = [] // Per-device display info

    // Input event deduplication (receiver sends critical events 3x over UDP for reliability)
    private var recentEventIds: Set<UInt64> = []
    private var recentEventIdQueue: [UInt64] = [] // FIFO to cap set size
    private let maxRecentEvents = 200

    private func isDuplicateEvent(_ eventId: UInt64) -> Bool {
        if recentEventIds.contains(eventId) {
            return true
        }
        recentEventIds.insert(eventId)
        recentEventIdQueue.append(eventId)
        if recentEventIdQueue.count > maxRecentEvents {
            let old = recentEventIdQueue.removeFirst()
            recentEventIds.remove(old)
        }
        return false
    }

    // Fragmentation State
    private var udpFrameId: UInt32 = 0

    // Transfer Stats
    let transferStats = TransferStats()
    var transferRate: String { transferStats.rate }
    private var bytesSentWindow: Int = 0
    private var lastStatsTime: Date = Date()

    // Settings
    @Published var selectedResolution: VirtualDisplayManager.Resolution = VirtualDisplayManager.defaultResolutions[1] {
        didSet { persistSettings() }
    }
    @Published private(set) var customResolutions: [VirtualDisplayManager.Resolution] = []
    @Published var isRetina: Bool = false {
        didSet { persistSettings() }
    }
    @Published var connectionType: String = "TCP" {
        didSet { persistSettings() }
    }

    @Published var selectedQuality: StreamQuality = .high {
        didSet { persistSettings() }
    }
    @Published var selectedFPS: Int = 60 {
        didSet { persistSettings() }
    }

    // Manual Interface Toggle — default Auto so Windows/Linux/Android receivers work out of the box
    @Published var interfacePreference: NetworkInterfacePreference = .auto {
        didSet { persistSettings() }
    }

    // Manual connection
    @Published var manualHost: String = "" {
        didSet { persistSettings() }
    }
    @Published var manualPort: String = "51820" {
        didSet { persistSettings() }
    }
    @Published private(set) var manualConnectionHistory: [ManualConnectionHistoryItem] = []
    @Published private(set) var manualConnectionAvailability: [String: ManualConnectionAvailability] = [:]
    @Published private(set) var isRefreshingManualConnectionAvailability = false

    var isConnected: Bool { !pipelines.isEmpty }

    static let receiverHeartbeatTimeout: TimeInterval = 5

    static func receiverConnectionHasTimedOut(
        lastHeartbeat: Date,
        now: Date
    ) -> Bool {
        now.timeIntervalSince(lastHeartbeat) > receiverHeartbeatTimeout
    }

    static func bonjourReachabilityRecheckInterval(
        isFocused: Bool,
        isConnected: Bool,
        focusedInterval: TimeInterval = 3,
        backgroundInterval: TimeInterval = 20
    ) -> TimeInterval? {
        guard !isConnected else { return nil }
        return isFocused ? focusedInterval : backgroundInterval
    }

    func setFocusedBonjourServiceName(_ name: String?) {
        guard focusedBonjourServiceName != name else { return }
        let previouslyFocusedName = focusedBonjourServiceName
        focusedBonjourServiceName = name

        if let previouslyFocusedName {
            scheduleBonjourReachabilityProbe(for: previouslyFocusedName)
        }
        if let name,
           let service = browsedTCPServicesByName[name],
           !isReceiverConnected(name),
           bonjourReachabilityProbeIDs[name] == nil {
            startBonjourReachabilityProbe(for: service)
        }
    }

    func startBrowsing() {
        cancelBonjourReachabilityChecks()
        discoveryRemovalWorkItems.values.forEach { $0.cancel() }
        discoveryRemovalWorkItems.removeAll()
        browserRecoveryWorkItems.values.forEach { $0.cancel() }
        browserRecoveryWorkItems.removeAll()
        browserRecoveryAttempts.removeAll()
        discoverySearchWorkItem?.cancel()

        browsers.values.forEach { $0.cancel() }
        browsers.removeAll()
        discoveredServicesByProtocol.removeAll()
        latestDiscoveredServiceNames.removeAll()
        foundServices = foundServices.filter {
            if case .hostPort = $0.endpoint { return true }
            return false
        }

        isDiscoveringDevices = true
        let searchWork = DispatchWorkItem { [weak self] in
            self?.isDiscoveringDevices = false
        }
        discoverySearchWorkItem = searchWork
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: searchWork)

        startBrowser(protocolType: "TCP")
    }

    private func startBrowser(protocolType: String) {
        let serviceType: String
        let parameters: NWParameters
        serviceType = "_bettercast._tcp"
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.enableKeepalive = true
        tcpOptions.noDelay = true
        parameters = NWParameters(tls: nil, tcp: tcpOptions)
        // Discovery stays unrestricted. The selected per-device mode is applied
        // only when that receiver is connected.
        parameters.includePeerToPeer = true
        LogManager.shared.log("Sender: Browsing for \(serviceType)...")

        let browser = NWBrowser(
            for: .bonjour(type: serviceType, domain: nil),
            using: parameters
        )
        browsers[protocolType] = browser

        browser.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                switch state {
                case .ready:
                    self?.status = "Browsing..."
                    self?.browserRecoveryAttempts[protocolType] = 0
                case .failed(let error):
                    self?.status = "\(protocolType) browsing failed: \(error.localizedDescription)"
                    self?.scheduleBrowserRecovery(for: protocolType)
                default:
                    break
                }
            }
        }

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                var servicesByName: [String: DiscoveredService] = [:]
                for result in results {
                    if case .service(let name, _, _, _) = result.endpoint {
                        let discoveredService = DiscoveredService(
                            name: name,
                            endpoint: result.endpoint,
                            discoveryInterfaces: result.interfaces.map {
                                DiscoveredNetworkInterface(
                                    name: $0.name,
                                    type: $0.type
                                )
                            }
                        )
                        if let existing = servicesByName[name] {
                            servicesByName[name] =
                                existing.mergingDiscoveryInterfaces(
                                    from: discoveredService
                                )
                        } else {
                            servicesByName[name] = discoveredService
                        }
                    }
                }
                self.updateDiscoveredServices(
                    Array(servicesByName.values),
                    for: protocolType
                )
            }
        }

        browser.start(queue: .main)
    }

    func updateDiscoveredServices(
        _ services: [DiscoveredService],
        for protocolType: String
    ) {
        if protocolType == "TCP" {
            updateBrowsedTCPServices(services)
            return
        }

        applyDiscoveredServices(services, for: protocolType)
    }

    private func updateBrowsedTCPServices(_ services: [DiscoveredService]) {
        var servicesByName: [String: DiscoveredService] = [:]
        for service in services {
            let existing = servicesByName[service.name]
            servicesByName[service.name] =
                existing?.mergingDiscoveryInterfaces(from: service)
                    ?? service
        }
        let removedNames = Set(browsedTCPServicesByName.keys)
            .subtracting(servicesByName.keys)

        for name in removedNames {
            bonjourReachabilityProbeCancellations.removeValue(forKey: name)?()
            bonjourReachabilityProbeIDs.removeValue(forKey: name)
            bonjourReachabilityRecheckWorkItems.removeValue(forKey: name)?.cancel()
            reachableTCPServiceNames.remove(name)
            resolvedBonjourRoutesByName.removeValue(forKey: name)
        }

        browsedTCPServicesByName = servicesByName

        for service in services where
            !reachableTCPServiceNames.contains(service.name)
                && bonjourReachabilityProbeIDs[service.name] == nil {
            startBonjourReachabilityProbe(for: service)
        }

        publishReachableTCPServices()
    }

    private func startBonjourReachabilityProbe(for service: DiscoveredService) {
        let name = service.name
        guard browsedTCPServicesByName[name] != nil,
              !isReceiverConnected(name) else {
            return
        }

        bonjourReachabilityRecheckWorkItems.removeValue(forKey: name)?.cancel()
        bonjourReachabilityProbeCancellations.removeValue(forKey: name)?()

        let probeID = UUID()
        bonjourReachabilityProbeIDs[name] = probeID
        let cancellation = bonjourReachabilityProbe(service) { [weak self] result in
            let finish: () -> Void = {
                guard let self else { return }
                self.finishBonjourReachabilityProbe(
                    name: name,
                    probeID: probeID,
                    result: result
                )
            }
            if Thread.isMainThread {
                finish()
            } else {
                DispatchQueue.main.async(execute: finish)
            }
        }

        guard bonjourReachabilityProbeIDs[name] == probeID else {
            cancellation()
            return
        }
        bonjourReachabilityProbeCancellations[name] = cancellation
    }

    private func finishBonjourReachabilityProbe(
        name: String,
        probeID: UUID,
        result: BonjourReachabilityResult
    ) {
        guard bonjourReachabilityProbeIDs[name] == probeID else { return }

        bonjourReachabilityProbeIDs.removeValue(forKey: name)
        bonjourReachabilityProbeCancellations.removeValue(forKey: name)?()

        if result.isReachable {
            reachableTCPServiceNames.insert(name)
            if !result.resolvedRoutes.isEmpty {
                resolvedBonjourRoutesByName[name] = result.resolvedRoutes
                let routeSummary = result.resolvedRoutes.map {
                    "\($0.endpoint) via \($0.interfaceNames.joined(separator: ","))"
                }.joined(separator: "; ")
                LogManager.shared.log(
                    "Sender: Resolved \(name) routes: \(routeSummary)"
                )
            }
            publishReachableTCPServices()
        } else {
            reachableTCPServiceNames.remove(name)
            resolvedBonjourRoutesByName.removeValue(forKey: name)
            removeDiscoveredServiceImmediately(name, for: "TCP")
        }

        scheduleBonjourReachabilityProbe(for: name)
    }

    private func scheduleBonjourReachabilityProbe(for name: String) {
        bonjourReachabilityRecheckWorkItems.removeValue(forKey: name)?.cancel()
        guard let service = browsedTCPServicesByName[name],
              bonjourReachabilityProbeIDs[name] == nil,
              let recheckInterval = recheckInterval(for: name) else {
            return
        }
        let recheck = DispatchWorkItem { [weak self] in
            guard let self,
                  !self.isReceiverConnected(name) else {
                return
            }
            self.startBonjourReachabilityProbe(for: service)
        }
        bonjourReachabilityRecheckWorkItems[name] = recheck
        DispatchQueue.main.asyncAfter(
            deadline: .now() + recheckInterval,
            execute: recheck
        )
    }

    private func recheckInterval(for name: String) -> TimeInterval? {
        Self.bonjourReachabilityRecheckInterval(
            isFocused: focusedBonjourServiceName == name,
            isConnected: isReceiverConnected(name),
            focusedInterval: focusedBonjourReachabilityRecheckInterval,
            backgroundInterval: backgroundBonjourReachabilityRecheckInterval
        )
    }

    private func isReceiverConnected(_ name: String) -> Bool {
        let identity = Self.bonjourReceiverIdentity(name)
        return connectedServices.contains {
            Self.bonjourReceiverIdentity($0.name) == identity
        }
    }

    private func refreshBonjourReachabilityProbeScheduling() {
        for (name, service) in browsedTCPServicesByName {
            if isReceiverConnected(name) {
                bonjourReachabilityProbeCancellations.removeValue(forKey: name)?()
                bonjourReachabilityProbeIDs.removeValue(forKey: name)
                bonjourReachabilityRecheckWorkItems.removeValue(forKey: name)?.cancel()
            } else if bonjourReachabilityProbeIDs[name] == nil,
                      bonjourReachabilityRecheckWorkItems[name] == nil {
                startBonjourReachabilityProbe(for: service)
            }
        }
    }

    private func publishReachableTCPServices() {
        let services = browsedTCPServicesByName.values.filter {
            reachableTCPServiceNames.contains($0.name)
        }
        applyDiscoveredServices(Array(services), for: "TCP")
    }

    private func removeDiscoveredServiceImmediately(
        _ name: String,
        for protocolType: String
    ) {
        let removalKey = "\(protocolType):\(name)"
        discoveryRemovalWorkItems.removeValue(forKey: removalKey)?.cancel()
        latestDiscoveredServiceNames[protocolType]?.remove(name)
        discoveredServicesByProtocol[protocolType]?.removeValue(forKey: name)
        rebuildFoundServices()
    }

    private func applyDiscoveredServices(
        _ services: [DiscoveredService],
        for protocolType: String
    ) {
        let currentServicesByName = Dictionary(
            uniqueKeysWithValues: services.map { ($0.name, $0) }
        )
        let currentNames = Set(currentServicesByName.keys)
        latestDiscoveredServiceNames[protocolType] = currentNames

        var retainedServices = discoveredServicesByProtocol[protocolType] ?? [:]
        for (name, service) in currentServicesByName {
            let removalKey = "\(protocolType):\(name)"
            discoveryRemovalWorkItems.removeValue(forKey: removalKey)?.cancel()
            retainedServices[name] = service
        }

        let missingNames = Set(retainedServices.keys).subtracting(currentNames)
        for name in missingNames {
            let removalKey = "\(protocolType):\(name)"
            guard discoveryRemovalWorkItems[removalKey] == nil else { continue }

            let removalWork = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.discoveryRemovalWorkItems.removeValue(forKey: removalKey)
                guard self.latestDiscoveredServiceNames[protocolType]?.contains(name) != true else {
                    return
                }
                self.discoveredServicesByProtocol[protocolType]?.removeValue(forKey: name)
                self.rebuildFoundServices()
            }
            discoveryRemovalWorkItems[removalKey] = removalWork
            DispatchQueue.main.asyncAfter(
                deadline: .now() + discoveryRemovalDelay,
                execute: removalWork
            )
        }

        discoveredServicesByProtocol[protocolType] = retainedServices
        rebuildFoundServices()

        if !services.isEmpty {
            isDiscoveringDevices = false
            discoverySearchWorkItem?.cancel()
            discoverySearchWorkItem = nil
        } else if !missingNames.isEmpty {
            scheduleBrowserRecovery(for: protocolType)
        }
    }

    private func scheduleBrowserRecovery(for protocolType: String) {
        guard browsers[protocolType] != nil,
              browserRecoveryWorkItems[protocolType] == nil else {
            return
        }
        let attempt = (browserRecoveryAttempts[protocolType] ?? 0) + 1
        guard attempt <= 3 else { return }
        browserRecoveryAttempts[protocolType] = attempt

        let recoveryWork = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.browserRecoveryWorkItems.removeValue(forKey: protocolType)
            self.browsers[protocolType]?.cancel()
            self.startBrowser(protocolType: protocolType)
        }
        browserRecoveryWorkItems[protocolType] = recoveryWork
        let delay = attempt == 1 ? 0.25 : TimeInterval(attempt)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: recoveryWork)
    }

    private func rebuildFoundServices() {
        let manualServices = foundServices.filter {
            if case .hostPort = $0.endpoint { return true }
            return false
        }
        var servicesByName: [String: DiscoveredService] = [:]
        // A Bonjour name is displayed only after its TCP endpoint is reachable.
        // UDP metadata is merged only for receivers that passed that check.
        for (name, tcpService) in discoveredServicesByProtocol["TCP"] ?? [:] {
            if let udpService = discoveredServicesByProtocol["UDP"]?[name] {
                servicesByName[name] = tcpService.mergingDiscoveryInterfaces(
                    from: udpService
                )
            } else {
                servicesByName[name] = tcpService
            }
        }
        var services = servicesByName.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        for service in manualServices where !services.contains(where: { $0.name == service.name }) {
            services.append(service)
        }
        foundServices = services

        // Each receiver owns its auto-connect preference. Multiple available
        // receivers can connect in parallel.
        for service in services where shouldAutoConnect(to: service) {
            if connectedServices.contains(where: { $0.name == service.name })
                || isConnecting(to: service) {
                continue
            }
            if service.name.contains("Android (USB)")
                || service.name.contains("Android (WiFi ADB)") {
                continue
            }
            if service.name.hasSuffix(" P2P")
                && services.contains(where: { $0.name == String(service.name.dropLast(4)) }) {
                continue
            }
            LogManager.shared.log("Sender: Auto-connecting to \(service.name)")
            connect(to: service, autoConnectAttempt: true)
        }
    }

    // Heartbeat
    private var lastHeartbeatTime: Date = Date()
    private var heartbeatTimer: Timer?
    private var connectionRefusedCount: Int = 0

    // Hard-Lock AWDL Logic
    private let interfaceMonitor = NWPathMonitor()
    private var cachedAWDLInterface: NWInterface?
    private var cachedInfraInterface: NWInterface?
    private var cachedNetworkInterfacesByName: [String: NWInterface] = [:]
    private var workspaceSessionObservers: [NSObjectProtocol] = []
    private var distributedSessionObservers: [NSObjectProtocol] = []
    private var sessionRecoveryWorkItem: DispatchWorkItem?

    init(
        discoveryRemovalDelay: TimeInterval = 8.0,
        bonjourReachabilityRecheckInterval: TimeInterval = 20.0,
        focusedBonjourReachabilityRecheckInterval: TimeInterval = 3.0,
        bonjourReachabilityProbe: BonjourReachabilityProbe? = nil,
        localConnectionAddressProvider: @escaping () -> [ReceiverConnectionAddress] = {
            ReceiverConnectionAddressProvider.availableAddresses(port: 51820)
        },
        thunderboltPeerRouteProvider:
            @escaping () -> [ThunderboltPeerAddressProvider.PeerRoute] = {
                ThunderboltPeerAddressProvider.availablePeerRoutes()
        }
    ) {
        self.discoveryRemovalDelay = discoveryRemovalDelay
        backgroundBonjourReachabilityRecheckInterval =
            bonjourReachabilityRecheckInterval
        self.focusedBonjourReachabilityRecheckInterval =
            focusedBonjourReachabilityRecheckInterval
        self.localConnectionAddressProvider = localConnectionAddressProvider
        self.thunderboltPeerRouteProvider = thunderboltPeerRouteProvider
        self.bonjourReachabilityProbe = bonjourReachabilityProbe ?? { service, completion in
            let check = BonjourTCPReachabilitySweep(
                service: service,
                completion: completion
            )
            check.start()
            return {
                check.cancel()
            }
        }
        let defaults = UserDefaults.standard
        if let customResolutionData = defaults.data(forKey: PreferenceKey.customResolutions),
           let savedCustomResolutions = try? JSONDecoder().decode(
               [VirtualDisplayManager.Resolution].self,
               from: customResolutionData
           ) {
            customResolutions = savedCustomResolutions
        }
        let savedWidth = defaults.integer(forKey: PreferenceKey.resolutionWidth)
        let savedHeight = defaults.integer(forKey: PreferenceKey.resolutionHeight)
        if let savedResolution = VirtualDisplayManager.defaultResolutions.first(where: {
            $0.width == savedWidth && $0.height == savedHeight
        }) {
            selectedResolution = savedResolution
        } else if savedWidth > 0, savedHeight > 0 {
            let savedPPI = defaults.integer(forKey: PreferenceKey.resolutionPPI)
            selectedResolution = VirtualDisplayManager.Resolution(
                width: savedWidth,
                height: savedHeight,
                ppi: savedPPI > 0 ? savedPPI : 220,
                hiDPI: false,
                name: defaults.string(forKey: PreferenceKey.resolutionName)
                    ?? "\(savedWidth) x \(savedHeight) (Custom)"
            )
        }
        if defaults.object(forKey: PreferenceKey.retina) != nil {
            isRetina = defaults.bool(forKey: PreferenceKey.retina)
        }
        if let savedQuality = StreamQuality(rawValue: defaults.integer(forKey: PreferenceKey.quality)) {
            selectedQuality = savedQuality
        }
        let savedFPS = defaults.integer(forKey: PreferenceKey.fps)
        if savedFPS == 30 || savedFPS == 60 {
            selectedFPS = savedFPS
        }
        if defaults.object(forKey: PreferenceKey.useVirtualDisplay) != nil {
            useVirtualDisplay = defaults.bool(forKey: PreferenceKey.useVirtualDisplay)
        }
        if defaults.object(forKey: PreferenceKey.audioStreaming) != nil {
            audioStreamingEnabled = defaults.bool(forKey: PreferenceKey.audioStreaming)
        }
        if let savedConnectionType = defaults.string(forKey: PreferenceKey.connectionType),
           savedConnectionType == "TCP" || savedConnectionType == "UDP" {
            connectionType = savedConnectionType
        }
        if let rawInterfacePreference = defaults.string(forKey: PreferenceKey.interfacePreference),
           let savedInterfacePreference = NetworkInterfacePreference(rawValue: rawInterfacePreference) {
            interfacePreference = savedInterfacePreference
        }
        autoConnectReceiverKeys = Set(
            defaults.stringArray(forKey: PreferenceKey.autoConnectReceiverKeys) ?? []
        )
        manualHost = defaults.string(forKey: PreferenceKey.manualHost) ?? ""
        manualPort = defaults.string(forKey: PreferenceKey.manualPort) ?? "51820"
        if let profilesData = defaults.data(forKey: PreferenceKey.receiverProfiles),
           let profiles = try? JSONDecoder().decode([String: ReceiverSettings].self, from: profilesData) {
            receiverProfiles = profiles
        }
        if let historyData = defaults.data(forKey: PreferenceKey.manualConnectionHistory) {
            if let history = try? JSONDecoder().decode(
                [ManualConnectionHistoryItem].self,
                from: historyData
            ) {
                manualConnectionHistory = history.filter { !$0.isLinkLocalAddress }
                if manualConnectionHistory.count != history.count,
                   let data = try? JSONEncoder().encode(manualConnectionHistory) {
                    defaults.set(data, forKey: PreferenceKey.manualConnectionHistory)
                }
            }
        }

        LogManager.shared.log(
            "Sender: App Starting — ExtendCast \(UpdateChecker.displayVersion)"
        )
        ConnectDiagnostics.log(
            "app start version=\(UpdateChecker.displayVersion) " +
            "os=\(ProcessInfo.processInfo.operatingSystemVersionString)"
        )

        // We can't monitor recursively in init easily, but we can start it.
        interfaceMonitor.pathUpdateHandler = { [weak self] path in
            let interfaces = path.availableInterfaces
            DispatchQueue.main.async { [weak self] in
                self?.cachedNetworkInterfacesByName = Dictionary(
                    interfaces.map {
                        ($0.name.lowercased(), $0)
                    },
                    uniquingKeysWith: { first, _ in first }
                )
                for interface in interfaces {
                    // Cache AWDL
                    if interface.name.contains("awdl") || interface.name.contains("llw") {
                        let isNew = (self?.cachedAWDLInterface == nil)
                        self?.cachedAWDLInterface = interface

                        if isNew {
                            LogManager.shared.log(
                                "Network: Found P2P Interface: \(interface.name) " +
                                "(\(interface.type))"
                            )
                        }
                    }
                    // Cache Infra WiFi (en0 typically) — only log on first discovery
                    if interface.type == .wifi
                        && !interface.name.contains("awdl")
                        && !interface.name.contains("llw") {
                        let isNew = self?.cachedInfraInterface == nil
                        self?.cachedInfraInterface = interface
                        if isNew {
                            LogManager.shared.log(
                                "Network: Found Infra Interface: \(interface.name) " +
                                "(\(interface.type))"
                            )
                        }
                    }
                }
            }
        }
        interfaceMonitor.start(queue: .global())
        startSessionLifecycleMonitoring()
    }

    deinit {
        cancelBonjourReachabilityChecks()
        discoveryRemovalWorkItems.values.forEach { $0.cancel() }
        browserRecoveryWorkItems.values.forEach { $0.cancel() }
        discoverySearchWorkItem?.cancel()
        sessionRecoveryWorkItem?.cancel()
        workspaceSessionObservers.forEach {
            NSWorkspace.shared.notificationCenter.removeObserver($0)
        }
        distributedSessionObservers.forEach {
            DistributedNotificationCenter.default().removeObserver($0)
        }
        interfaceMonitor.cancel()
        heartbeatTimer?.invalidate()
    }

    private func cancelBonjourReachabilityChecks() {
        bonjourReachabilityProbeCancellations.values.forEach { $0() }
        bonjourReachabilityProbeCancellations.removeAll()
        bonjourReachabilityProbeIDs.removeAll()
        bonjourReachabilityRecheckWorkItems.values.forEach { $0.cancel() }
        bonjourReachabilityRecheckWorkItems.removeAll()
        browsedTCPServicesByName.removeAll()
        reachableTCPServiceNames.removeAll()
        resolvedBonjourRoutesByName.removeAll()
    }

    private func startSessionLifecycleMonitoring() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let resumeNotifications: [(Notification.Name, String, TimeInterval)] = [
            (NSWorkspace.sessionDidBecomeActiveNotification, "session became active", 1.0),
            (NSWorkspace.didWakeNotification, "system woke", 3.0)
        ]
        for (name, reason, delay) in resumeNotifications {
            let observer = workspaceCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.scheduleCaptureRecovery(reason: reason, delay: delay)
            }
            workspaceSessionObservers.append(observer)
        }

        let unlockObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleCaptureRecovery(reason: "screen unlocked", delay: 1.0)
        }
        distributedSessionObservers.append(unlockObserver)
    }

    private func scheduleCaptureRecovery(reason: String, delay: TimeInterval) {
        guard !pipelines.isEmpty else { return }

        // macOS commonly emits wake, session-active and screen-unlocked events
        // together. Coalesce them so one unlock causes one capture restart.
        sessionRecoveryWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.recoverCaptureAfterSessionResume(reason: reason)
        }
        sessionRecoveryWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func recoverCaptureAfterSessionResume(reason: String) {
        let connectionIds = Array(pipelines.keys)
        guard !connectionIds.isEmpty else { return }

        LogManager.shared.log(
            "Sender: \(reason.capitalized); restarting capture for " +
            "\(connectionIds.count) display(s) while preserving virtual displays"
        )

        for connectionId in connectionIds {
            pipelines[connectionId]?.screenRecorder?.stopCapture()
            pipelines[connectionId]?.screenRecorder = nil
            pipelines[connectionId]?.videoEncoder = nil
            pipelines[connectionId]?.audioEncoder = nil
        }

        // Give ScreenCaptureKit a short window to tear down the stale stream
        // before starting its replacement. startPipeline reuses the existing
        // VirtualDisplayManager and its stable display identity.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self else { return }
            for connectionId in connectionIds where self.pipelines[connectionId] != nil {
                self.startPipeline(for: connectionId)
            }
        }
    }

    private func currentReceiverSettings() -> ReceiverSettings {
        ReceiverSettings(
            resolutionWidth: selectedResolution.width,
            resolutionHeight: selectedResolution.height,
            resolutionPPI: selectedResolution.ppi,
            resolutionName: selectedResolution.name,
            retinaEnabled: isRetina,
            qualityRawValue: selectedQuality.rawValue,
            fps: selectedFPS,
            useVirtualDisplay: useVirtualDisplay,
            audioStreamingEnabled: audioStreamingEnabled,
            connectionType: interfacePreference.allowsUDP ? connectionType : "TCP",
            interfacePreferenceRawValue: interfacePreference.rawValue
        )
    }

    var availableResolutions: [VirtualDisplayManager.Resolution] {
        var resolutions = VirtualDisplayManager.defaultResolutions + customResolutions
        if !resolutions.contains(selectedResolution) {
            resolutions.append(selectedResolution)
        }
        return resolutions.sorted {
            if $0.width != $1.width {
                return $0.width < $1.width
            }
            return $0.height < $1.height
        }
    }

    private func persistCustomResolutions() {
        if let data = try? JSONEncoder().encode(customResolutions) {
            UserDefaults.standard.set(data, forKey: PreferenceKey.customResolutions)
        }
    }

    private func replaceCachedResolution(
        _ original: VirtualDisplayManager.Resolution,
        with replacement: VirtualDisplayManager.Resolution
    ) {
        for key in Array(receiverProfiles.keys) {
            guard var settings = receiverProfiles[key],
                  settings.resolutionWidth == original.width,
                  settings.resolutionHeight == original.height else {
                continue
            }
            settings.resolutionWidth = replacement.width
            settings.resolutionHeight = replacement.height
            settings.resolutionPPI = replacement.ppi
            settings.resolutionName = replacement.name
            receiverProfiles[key] = settings
        }

        for id in Array(pipelines.keys) {
            guard var settings = pipelines[id]?.settings,
                  settings.resolutionWidth == original.width,
                  settings.resolutionHeight == original.height else {
                continue
            }
            settings.resolutionWidth = replacement.width
            settings.resolutionHeight = replacement.height
            settings.resolutionPPI = replacement.ppi
            settings.resolutionName = replacement.name
            pipelines[id]?.settings = settings
        }

        persistReceiverProfiles()
    }

    func saveCustomResolution(
        _ original: VirtualDisplayManager.Resolution?,
        width: Int,
        height: Int,
        ppi: Int,
        label: String
    ) {
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (640...7680).contains(width), (480...4320).contains(height) else {
            return
        }
        guard width.isMultiple(of: 2), height.isMultiple(of: 2) else { return }
        guard (72...500).contains(ppi) else { return }
        guard !trimmedLabel.isEmpty,
              !trimmedLabel.contains("("),
              !trimmedLabel.contains(")") else {
            return
        }
        guard !VirtualDisplayManager.defaultResolutions.contains(where: {
            $0.width == width && $0.height == height
        }) else {
            return
        }
        guard !customResolutions.contains(where: {
            $0.width == width
                && $0.height == height
                && $0 != original
        }) else {
            return
        }

        let resolution = VirtualDisplayManager.Resolution(
            width: width,
            height: height,
            ppi: ppi,
            hiDPI: false,
            name: "\(width) x \(height) (\(trimmedLabel))"
        )

        if let original,
           let index = customResolutions.firstIndex(of: original) {
            customResolutions[index] = resolution
            replaceCachedResolution(original, with: resolution)
            if selectedResolution == original {
                selectedResolution = resolution
            }
        } else {
            customResolutions.append(resolution)
        }

        persistCustomResolutions()
    }

    func removeCustomResolution(_ resolution: VirtualDisplayManager.Resolution) {
        guard customResolutions.contains(resolution) else { return }
        customResolutions.removeAll { $0 == resolution }
        persistCustomResolutions()

        let fallback = VirtualDisplayManager.defaultResolutions[1]
        replaceCachedResolution(resolution, with: fallback)
        if selectedResolution == resolution {
            selectedResolution = fallback
        }
    }

    private func applyReceiverSettings(_ settings: ReceiverSettings) {
        if let resolution = VirtualDisplayManager.defaultResolutions.first(where: {
            $0.width == settings.resolutionWidth && $0.height == settings.resolutionHeight
        }) {
            selectedResolution = resolution
        } else {
            selectedResolution = VirtualDisplayManager.Resolution(
                width: settings.resolutionWidth,
                height: settings.resolutionHeight,
                ppi: settings.resolutionPPI,
                hiDPI: false,
                name: settings.resolutionName
            )
        }
        isRetina = settings.retinaEnabled
        selectedQuality = StreamQuality(rawValue: settings.qualityRawValue) ?? .high
        selectedFPS = settings.fps == 30 ? 30 : 60
        useVirtualDisplay = settings.useVirtualDisplay
        audioStreamingEnabled = settings.audioStreamingEnabled
        if let savedConnectionType = settings.connectionType,
           savedConnectionType == "TCP" || savedConnectionType == "UDP" {
            connectionType = savedConnectionType
        }
        if let rawPreference = settings.interfacePreferenceRawValue,
           let savedPreference = NetworkInterfacePreference(rawValue: rawPreference) {
            interfacePreference = savedPreference
        }
        if !interfacePreference.allowsUDP {
            connectionType = "TCP"
        }
    }

    private func receiverProfileKey(for service: DiscoveredService) -> String {
        switch service.endpoint {
        case .hostPort(let host, let port):
            return "host:\(String(describing: host).lowercased()):\(port.rawValue)"
        case .service(let name, _, _, _):
            let normalizedName = name
                .replacingOccurrences(of: #" \(\d+\)$"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            return "service:\(normalizedName)"
        default:
            return "name:\(service.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
        }
    }

    private func outboundRouteCatalog(
        for service: DiscoveredService,
        localAddresses: [ReceiverConnectionAddress]? = nil,
        thunderboltPeerRoutes: [
            ThunderboltPeerAddressProvider.PeerRoute
        ]? = nil
    ) -> OutboundRouteCatalog {
        OutboundRouteCatalog(
            remoteReceiver: service,
            discoveredReceivers: foundServices,
            localAddresses:
                localAddresses ?? localConnectionAddressProvider(),
            thunderboltPeerRoutes:
                thunderboltPeerRoutes ?? currentThunderboltPeerRoutes()
        )
    }

    private func currentThunderboltPeerRoutes(
        forceRefresh: Bool = false
    ) -> [ThunderboltPeerAddressProvider.PeerRoute] {
        let now = Date()
        if forceRefresh
            || now.timeIntervalSince(lastThunderboltPeerRouteRefresh)
                >= Self.thunderboltPeerRouteCacheInterval {
            cachedThunderboltPeerRoutes = thunderboltPeerRouteProvider()
            lastThunderboltPeerRouteRefresh = now
        }
        return cachedThunderboltPeerRoutes
    }

    func availableConnectionModes(
        for service: DiscoveredService
    ) -> [NetworkInterfacePreference] {
        outboundRouteCatalog(for: service).availableModes
    }

    static func preferredAutomaticConnectionMode(
        receiverName: String,
        availableModes: [NetworkInterfacePreference]
    ) -> NetworkInterfacePreference {
        OutboundRouteCatalog.preferredAutomaticMode(
            receiverName: receiverName,
            availableModes: availableModes
        )
    }

    static func preferredThunderboltPeerHost(
        receiverName: String,
        availablePeerHosts: [String]
    ) -> String? {
        guard receiverName.lowercased().contains("windows") else { return nil }
        let uniqueHosts = Array(Set(availablePeerHosts))
        guard uniqueHosts.count == 1 else { return nil }
        return uniqueHosts[0]
    }

    static func preferredThunderboltPeerRoute(
        receiverName: String,
        availableRoutes: [ThunderboltPeerAddressProvider.PeerRoute],
        allowedInterfaceNames: Set<String>
    ) -> ThunderboltPeerAddressProvider.PeerRoute? {
        OutboundRouteCatalog.preferredThunderboltPeerRoute(
            receiverName: receiverName,
            availableRoutes: availableRoutes,
            allowedInterfaceNames: allowedInterfaceNames
        )
    }

    private func resolvedConnectionPreference(
        _ preference: NetworkInterfacePreference,
        for service: DiscoveredService
    ) -> NetworkInterfacePreference {
        outboundRouteCatalog(for: service).resolve(preference)
    }

    func connectionEndpointDescription(
        for service: DiscoveredService,
        preference: NetworkInterfacePreference
    ) -> String? {
        if case .hostPort = service.endpoint {
            return Self.endpointDescription(service.endpoint)
        }

        let localAddresses = localConnectionAddressProvider()
        let routeCatalog = outboundRouteCatalog(
            for: service,
            localAddresses: localAddresses
        )
        let selectedPreference = routeCatalog.resolve(preference)
        let lowercasedName = service.name.lowercased()
        let isAppleReceiver = !lowercasedName.contains("android")
            && !lowercasedName.contains("windows")
            && !lowercasedName.contains("linux")
        let allowsAppleP2P = selectedPreference == .auto
            || selectedPreference == .p2pOnly
        if isAppleReceiver,
           allowsAppleP2P,
           let p2pEndpoint = discoveredServicesByProtocol["TCP"]?[
               service.name + " P2P"
           ]?.endpoint {
            return Self.endpointDescription(p2pEndpoint)
        }

        let resolvedRoute = Self.preferredBonjourRoute(
            for: selectedPreference,
            resolvedRoutes:
                resolvedBonjourRoutesByName[service.name] ?? []
        )
        let endpoint = routeCatalog.connectionEndpoint(
            for: selectedPreference,
            resolvedRoute: resolvedRoute,
            discoveredEndpoint: service.connectionEndpoint(
                for: selectedPreference
            )
        )
        return Self.endpointDescription(endpoint)
    }

    func availableConnectionModes(
        for connectionId: UUID
    ) -> [NetworkInterfacePreference] {
        guard let pipeline = pipelines[connectionId] else { return [.auto] }
        let supportedModes = availableConnectionModes(for: pipeline.service)
        return NetworkInterfacePreference.allCases.filter {
            supportedModes.contains($0) || pipeline.connectionPreference == $0
        }
    }

    func isAutoConnectEnabled(for service: DiscoveredService) -> Bool {
        autoConnectReceiverKeys.contains(receiverProfileKey(for: service))
    }

    private func shouldAutoConnect(to service: DiscoveredService) -> Bool {
        let key = receiverProfileKey(for: service)
        return autoConnectReceiverKeys.contains(key)
            && !suppressedAutoConnectReceiverKeys.contains(key)
    }

    private func suppressAutoConnect(for service: DiscoveredService) {
        let key = receiverProfileKey(for: service)
        guard autoConnectReceiverKeys.contains(key) else { return }
        suppressedAutoConnectReceiverKeys.insert(key)
        LogManager.shared.log("Sender: Auto-connect paused for \(service.name) after manual disconnect")
    }

    private func resumeAutoConnect(for service: DiscoveredService) {
        let key = receiverProfileKey(for: service)
        if suppressedAutoConnectReceiverKeys.remove(key) != nil {
            LogManager.shared.log("Sender: Auto-connect resumed for \(service.name)")
        }
    }

    func isAutoConnectEnabled(for connectionId: UUID) -> Bool {
        guard let service = pipelines[connectionId]?.service else { return false }
        return isAutoConnectEnabled(for: service)
    }

    func setAutoConnectEnabled(_ enabled: Bool, for service: DiscoveredService) {
        let key = receiverProfileKey(for: service)
        if enabled {
            suppressedAutoConnectReceiverKeys.remove(key)
            autoConnectReceiverKeys.insert(key)
            var updatedSettings = receiverProfiles[key] ?? currentReceiverSettings()
            if case .hostPort = service.endpoint {
                updatedSettings.connectionType = "TCP"
            }
            saveSettings(updatedSettings, for: service)
        } else {
            autoConnectReceiverKeys.remove(key)
        }
        persistAutoConnectReceiverKeys()

        guard enabled,
              !suppressedAutoConnectReceiverKeys.contains(key),
              !connectedServices.contains(where: { $0.name == service.name }),
              !isConnecting(to: service) else {
            return
        }

        if case .hostPort = service.endpoint {
            if let item = manualConnectionHistory.first(where: { $0.displayName == service.name }) {
                if manualConnectionAvailability[item.id] == .available {
                    connectRecentManualConnection(item, autoConnectAttempt: true)
                } else {
                    refreshManualConnectionAvailability()
                }
            }
        } else if foundServices.contains(where: { $0.name == service.name }) {
            LogManager.shared.log("Sender: Auto-connect enabled for available device \(service.name)")
            connect(to: service, autoConnectAttempt: true)
        }
    }

    func setAutoConnectEnabled(_ enabled: Bool, for connectionId: UUID) {
        guard let service = pipelines[connectionId]?.service else { return }
        setAutoConnectEnabled(enabled, for: service)
    }

    private func persistAutoConnectReceiverKeys() {
        UserDefaults.standard.set(
            autoConnectReceiverKeys.sorted(),
            forKey: PreferenceKey.autoConnectReceiverKeys
        )
    }

    private func settings(for service: DiscoveredService) -> ReceiverSettings {
        receiverProfiles[receiverProfileKey(for: service)] ?? currentReceiverSettings()
    }

    private func persistReceiverProfiles() {
        guard let data = try? JSONEncoder().encode(receiverProfiles) else {
            LogManager.shared.log("Sender: Failed to encode saved receiver settings")
            return
        }
        UserDefaults.standard.set(data, forKey: PreferenceKey.receiverProfiles)
    }

    private func saveSettings(_ settings: ReceiverSettings, for service: DiscoveredService) {
        receiverProfiles[receiverProfileKey(for: service)] = settings
        persistReceiverProfiles()
        LogManager.shared.log("Sender: Saved settings for \(service.name)")
    }

    func loadSettings(for service: DiscoveredService) {
        let key = receiverProfileKey(for: service)
        if var settings = receiverProfiles[key] {
            if case .hostPort = service.endpoint {
                settings.connectionType = "TCP"
            }
            applyReceiverSettings(settings)
            LogManager.shared.log("Sender: Loaded saved settings for \(service.name)")
        }

        let resolvedPreference = resolvedConnectionPreference(
            interfacePreference,
            for: service
        )
        guard resolvedPreference != interfacePreference else {
            return
        }
        interfacePreference = resolvedPreference
        connectionType = "TCP"
        if var settings = receiverProfiles[key] {
            settings.interfacePreferenceRawValue = resolvedPreference.rawValue
            settings.connectionType = "TCP"
            saveSettings(settings, for: service)
        }
    }

    func loadSettings(for connectionId: UUID) {
        guard let pipeline = pipelines[connectionId] else { return }
        applyReceiverSettings(pipeline.settings)
    }

    private func service(for item: ManualConnectionHistoryItem) -> DiscoveredService? {
        guard let port = NWEndpoint.Port(rawValue: item.port) else { return nil }
        return DiscoveredService(
            name: item.displayName,
            endpoint: .hostPort(host: NWEndpoint.Host(item.host), port: port)
        )
    }

    private func rememberManualConnection(host: String, port: UInt16) {
        let item = ManualConnectionHistoryItem(host: host, port: port)
        manualConnectionHistory.removeAll { $0.id == item.id }
        if item.isLinkLocalAddress {
            manualConnectionAvailability.removeValue(forKey: item.id)
            LogManager.shared.log(
                "Sender: Not saving \(item.displayName) to Recent because 169.254 link-local addresses can change after Thunderbolt reconnects"
            )
            if let data = try? JSONEncoder().encode(manualConnectionHistory) {
                UserDefaults.standard.set(data, forKey: PreferenceKey.manualConnectionHistory)
            }
            return
        }
        manualConnectionHistory.insert(item, at: 0)
        if manualConnectionHistory.count > 10 {
            manualConnectionHistory.removeLast(manualConnectionHistory.count - 10)
        }
        if let data = try? JSONEncoder().encode(manualConnectionHistory) {
            UserDefaults.standard.set(data, forKey: PreferenceKey.manualConnectionHistory)
        }
    }

    private func rememberSuccessfulManualConnection(for service: DiscoveredService) {
        guard case .hostPort(let host, let port) = service.endpoint,
              service.name == "\(host):\(port.rawValue)" else {
            return
        }

        rememberManualConnection(
            host: String(describing: host),
            port: port.rawValue
        )
        manualConnectionAvailability[service.name.lowercased()] = .available
    }

    func selectManualConnection(_ item: ManualConnectionHistoryItem) {
        manualHost = item.host
        manualPort = String(item.port)
        guard let service = service(for: item) else { return }
        loadSettings(for: service)
    }

    func prepareRecentConnectionSettings(_ item: ManualConnectionHistoryItem) {
        selectManualConnection(item)
        guard let service = service(for: item) else { return }
        if !foundServices.contains(where: { $0.name == service.name }) {
            foundServices.append(service)
        }
    }

    func connectRecentManualConnection(
        _ item: ManualConnectionHistoryItem,
        autoConnectAttempt: Bool = false
    ) {
        selectManualConnection(item)
        connectManual(autoConnectAttempt: autoConnectAttempt)
    }

    func connectedDisplayId(for item: ManualConnectionHistoryItem) -> UUID? {
        pipelines.first { _, pipeline in
            guard case .hostPort(let host, let port) = pipeline.service.endpoint else {
                return false
            }
            return String(describing: host).caseInsensitiveCompare(item.host) == .orderedSame
                && port.rawValue == item.port
        }?.key
    }

    func isConnecting(to service: DiscoveredService) -> Bool {
        connectionRegistry.isPending(
            receiverKey: ReceiverConnectionKey.unresolved(
                serviceName: service.name,
                endpoint: service.endpoint
            )
        )
    }

    func hasActiveOrPendingConnection(to service: DiscoveredService) -> Bool {
        isConnecting(to: service)
            || connectedServices.contains { $0.name == service.name }
            || connectedDisplays.contains { $0.name == service.name }
    }

    func isReconnecting(_ serviceName: String) -> Bool {
        reconnectingServiceNames.contains(serviceName)
    }

    private func beginConnectionAttempt(
        for service: DiscoveredService,
        connectionID: UUID
    ) -> String? {
        let receiverKey = ReceiverConnectionKey.unresolved(
            serviceName: service.name,
            endpoint: service.endpoint
        )
        guard connectionRegistry.begin(
            connectionID: connectionID,
            receiverKey: receiverKey
        ) else {
            LogManager.shared.log(
                "Sender: Connection already active or pending for \(service.name)"
            )
            return nil
        }
        return receiverKey
    }

    private func trackPendingConnection(
        _ connection: NWConnection,
        connectionID: UUID
    ) {
        pendingConnectionsByID[connectionID] = connection
    }

    private func finishPendingConnection(
        connectionID: UUID,
        receiverKey: String
    ) {
        pendingConnectionsByID.removeValue(forKey: connectionID)
        connectionRegistry.finishPending(
            connectionID: connectionID,
            receiverKey: receiverKey
        )
    }

    private func admitReadyConnection(
        _ connection: NWConnection,
        connectionID: UUID,
        pendingKey: String,
        service: DiscoveredService
    ) -> Bool {
        pendingConnectionsByID.removeValue(forKey: connectionID)
        let resolvedKey = ReceiverConnectionKey.resolved(
            serviceName: service.name,
            endpoint: service.endpoint,
            remoteEndpoint: connection.currentPath?.remoteEndpoint
        )
        guard connectionRegistry.admitReady(
            connectionID: connectionID,
            pendingKey: pendingKey,
            resolvedKey: resolvedKey
        ) else {
            LogManager.shared.log(
                "Sender: Rejected duplicate or expired connection to \(service.name)"
            )
            connection.cancel()
            return false
        }
        return true
    }

    func removeManualConnectionHistory(_ item: ManualConnectionHistoryItem) {
        guard !pipelines.values.contains(where: { $0.service.name == item.displayName }) else {
            return
        }

        if let probe = manualAvailabilityProbes.removeValue(forKey: item.id) {
            probe.stateUpdateHandler = nil
            probe.cancel()
        }
        manualConnectionAvailability.removeValue(forKey: item.id)
        manualConnectionHistory.removeAll { $0.id == item.id }
        foundServices.removeAll { $0.name == item.displayName }
        if let service = service(for: item) {
            autoConnectReceiverKeys.remove(receiverProfileKey(for: service))
            persistAutoConnectReceiverKeys()
        }

        if let data = try? JSONEncoder().encode(manualConnectionHistory) {
            UserDefaults.standard.set(data, forKey: PreferenceKey.manualConnectionHistory)
        }
        isRefreshingManualConnectionAvailability = !manualAvailabilityProbes.isEmpty
    }

    func openLocalNetworkPrivacySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_LocalNetwork"
        ) else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    func refreshManualConnectionAvailability() {
        lastManualAvailabilityRefresh = Date()
        manualAvailabilityProbes.values.forEach { $0.cancel() }
        manualAvailabilityProbes.removeAll()
        manualAvailabilityProbeGeneration = UUID()
        let generation = manualAvailabilityProbeGeneration

        guard !manualConnectionHistory.isEmpty else {
            manualConnectionAvailability.removeAll()
            isRefreshingManualConnectionAvailability = false
            return
        }

        isRefreshingManualConnectionAvailability = true
        for item in manualConnectionHistory {
            manualConnectionAvailability[item.id] = .checking
            startManualAvailabilityProbe(item, attempt: 1, generation: generation)
        }
    }

    func refreshManualConnectionAvailabilityIfNeeded() {
        guard !isRefreshingManualConnectionAvailability else { return }
        if let lastManualAvailabilityRefresh,
           Date().timeIntervalSince(lastManualAvailabilityRefresh) < 15 {
            return
        }
        refreshManualConnectionAvailability()
    }

    func startSavedAutoConnections() {
        let hasSavedManualAutoConnect = manualConnectionHistory.contains { item in
            if item.isLinkLocalAddress { return false }
            guard let service = service(for: item) else { return false }
            return isAutoConnectEnabled(for: service)
        }
        if hasSavedManualAutoConnect {
            refreshManualConnectionAvailability()
        }
    }

    private func startManualAvailabilityProbe(
        _ item: ManualConnectionHistoryItem,
        attempt: Int,
        generation: UUID
    ) {
        guard generation == manualAvailabilityProbeGeneration else { return }
        guard let port = NWEndpoint.Port(rawValue: item.port) else {
            manualConnectionAvailability[item.id] = .unavailable
            isRefreshingManualConnectionAvailability =
                manualConnectionAvailability.values.contains(.checking)
            return
        }

        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.connectionTimeout = 3
        let parameters = NWParameters(tls: nil, tcp: tcpOptions)
        let connection = NWConnection(
            host: NWEndpoint.Host(item.host),
            port: port,
            using: parameters
        )
        manualAvailabilityProbes[item.id] = connection

        connection.stateUpdateHandler = { [weak self, weak connection] state in
            DispatchQueue.main.async {
                guard let self, let connection,
                      generation == self.manualAvailabilityProbeGeneration,
                      self.manualAvailabilityProbes[item.id] === connection else {
                    return
                }
                switch state {
                case .ready:
                    self.finishManualAvailabilityProbe(item.id, result: .available)
                    if let service = self.service(for: item),
                       self.shouldAutoConnect(to: service),
                       !self.connectedServices.contains(where: { $0.name == service.name }),
                       !self.isConnecting(to: service) {
                        LogManager.shared.log("Sender: Auto-connecting to available recent device \(service.name)")
                        self.connectRecentManualConnection(item, autoConnectAttempt: true)
                    }
                case .waiting(let error), .failed(let error):
                    if self.isLocalNetworkPermissionError(error) {
                        self.finishManualAvailabilityProbe(
                            item.id,
                            result: .permissionRequired
                        )
                    } else {
                        self.retryOrFinishManualAvailabilityProbe(
                            item,
                            attempt: attempt,
                            generation: generation
                        )
                    }
                default:
                    break
                }
            }
        }
        connection.start(queue: .global(qos: .utility))

        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self, weak connection] in
            guard let self, let connection,
                  generation == self.manualAvailabilityProbeGeneration,
                  self.manualAvailabilityProbes[item.id] === connection else {
                return
            }
            self.retryOrFinishManualAvailabilityProbe(
                item,
                attempt: attempt,
                generation: generation
            )
        }
    }

    private func isLocalNetworkPermissionError(_ error: NWError) -> Bool {
        // Network.framework surfaces local-network privacy denial as the
        // DNS-SD kDNSServiceErr_PolicyDenied value, not necessarily as text.
        if case .dns(let code) = error, code == -65_570 {
            return true
        }

        let description = String(describing: error).lowercased()
        return description.contains("policy denied")
            || description.contains("local network prohibited")
            || description.contains("prohibited")
    }

    private func retryOrFinishManualAvailabilityProbe(
        _ item: ManualConnectionHistoryItem,
        attempt: Int,
        generation: UUID
    ) {
        guard let connection = manualAvailabilityProbes.removeValue(forKey: item.id) else {
            return
        }
        connection.stateUpdateHandler = nil
        connection.cancel()

        if attempt < 2 {
            // USB4/link-local routes can briefly report "no route" while ARP settles.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.startManualAvailabilityProbe(
                    item,
                    attempt: attempt + 1,
                    generation: generation
                )
            }
        } else {
            manualConnectionAvailability[item.id] = .unavailable
            isRefreshingManualConnectionAvailability =
                manualConnectionAvailability.values.contains(.checking)
        }
    }

    private func finishManualAvailabilityProbe(
        _ id: String,
        result: ManualConnectionAvailability
    ) {
        guard let connection = manualAvailabilityProbes.removeValue(forKey: id) else { return }
        connection.stateUpdateHandler = nil
        connection.cancel()
        manualConnectionAvailability[id] = result
        isRefreshingManualConnectionAvailability = !manualAvailabilityProbes.isEmpty
    }

    private func persistSettings() {
        let defaults = UserDefaults.standard
        defaults.set(selectedResolution.width, forKey: PreferenceKey.resolutionWidth)
        defaults.set(selectedResolution.height, forKey: PreferenceKey.resolutionHeight)
        defaults.set(selectedResolution.ppi, forKey: PreferenceKey.resolutionPPI)
        defaults.set(selectedResolution.name, forKey: PreferenceKey.resolutionName)
        defaults.set(isRetina, forKey: PreferenceKey.retina)
        defaults.set(selectedQuality.rawValue, forKey: PreferenceKey.quality)
        defaults.set(selectedFPS, forKey: PreferenceKey.fps)
        defaults.set(useVirtualDisplay, forKey: PreferenceKey.useVirtualDisplay)
        defaults.set(audioStreamingEnabled, forKey: PreferenceKey.audioStreaming)
        defaults.set(
            interfacePreference.allowsUDP ? connectionType : "TCP",
            forKey: PreferenceKey.connectionType
        )
        defaults.set(interfacePreference.rawValue, forKey: PreferenceKey.interfacePreference)
        defaults.set(manualHost, forKey: PreferenceKey.manualHost)
        defaults.set(manualPort, forKey: PreferenceKey.manualPort)
    }

    private func cachedInterface(
        for preference: NetworkInterfacePreference,
        service: DiscoveredService?
    ) -> NWInterface? {
        let discoveredInterfaces = service?.discoveryInterfaces ?? []
        let matchingInterface: DiscoveredNetworkInterface?
        switch preference {
        case .ethernet:
            matchingInterface = discoveredInterfaces.first(where: \.isEthernet)
        case .thunderboltBridge:
            matchingInterface = discoveredInterfaces.first(where: \.isThunderboltBridge)
        case .wiredCable:
            matchingInterface = discoveredInterfaces.first {
                $0.isThunderboltBridge || $0.isEthernet
            }
        default:
            matchingInterface = nil
        }
        if let matchingInterface,
           let cachedInterface =
               cachedNetworkInterfacesByName[matchingInterface.name.lowercased()] {
            return cachedInterface
        }

        switch preference {
        case .ethernet:
            return cachedNetworkInterfacesByName.values.first {
                $0.type == .wiredEthernet
                    && !$0.name.lowercased().contains("bridge")
                    && !$0.name.lowercased().contains("thunderbolt")
            }
        case .thunderboltBridge:
            return cachedNetworkInterfacesByName.values.first {
                let name = $0.name.lowercased()
                return name.contains("bridge") || name.contains("thunderbolt")
            }
        case .wiredCable:
            return cachedNetworkInterfacesByName.values.first {
                let name = $0.name.lowercased()
                return $0.type == .wiredEthernet
                    || name.contains("bridge")
                    || name.contains("thunderbolt")
            }
        default:
            return nil
        }
    }

    private func configureParameters(
        _ parameters: NWParameters,
        preference: NetworkInterfacePreference,
        service: DiscoveredService? = nil
    ) {
        parameters.includePeerToPeer = true

        if preference == .p2pOnly, let awdl = cachedAWDLInterface {
             LogManager.shared.log("Parameters: Binding to P2P Interface \(awdl.name) ✅")
             parameters.requiredInterface = awdl
             parameters.serviceClass = .interactiveVideo
             parameters.prohibitedInterfaceTypes = [.loopback, .wiredEthernet]
             return // Skip the rest
        }

        switch preference {
        case .auto:
            parameters.serviceClass = .interactiveVideo

        case .p2pOnly:
             // Direct binding to AWDL interface
             if let awdl = cachedAWDLInterface {
                 LogManager.shared.log("Sender: Hard-Locking to Interface: \(awdl.name) ✅")
                 parameters.requiredInterface = awdl
                 // Since we require a specific interface, prohibited list is irrelevant/redundant
             } else {
                 LogManager.shared.log("Sender: AWDL Interface not found yet. Falling back to Prohibition Strategy (Banning Infra). ⚠️")

                 // Ban the interface object directly, NOT the type
                 if let infra = cachedInfraInterface {
                      LogManager.shared.log("Sender: Banning Infra Interface: \(infra.name) 🚫")
                      parameters.prohibitedInterfaces = [infra]
                 } else {
                      LogManager.shared.log("Sender: Infra Interface not found either? Falling back to Type prohibition (Risky).")
                      // If we can't find en0 object, we can't ban it specifically.
                      // Fallback to banning Wired/Loopback only.
                 }

                 parameters.serviceClass = .interactiveVideo
             }

             // Always ban these types
             parameters.prohibitedInterfaceTypes = [.loopback, .wiredEthernet]
             parameters.preferNoProxies = true

        case .routerOnly:
            parameters.serviceClass = .interactiveVideo
            parameters.requiredInterfaceType = .wifi
            parameters.includePeerToPeer = false

        case .ethernet:
            parameters.serviceClass = .interactiveVideo
            parameters.prohibitedInterfaceTypes = [.loopback, .wifi]
            parameters.includePeerToPeer = false
            parameters.preferNoProxies = true
            if let ethernetInterface = cachedInterface(
                for: .ethernet,
                service: service
            ) {
                parameters.requiredInterface = ethernetInterface
                LogManager.shared.log(
                    "Parameters: Ethernet mode - requiring \(ethernetInterface.name)"
                )
            } else {
                parameters.requiredInterfaceType = .wiredEthernet
                LogManager.shared.log("Parameters: Ethernet mode - requiring wired Ethernet")
            }

        case .thunderboltBridge:
            parameters.serviceClass = .interactiveVideo
            parameters.prohibitedInterfaceTypes = [.loopback, .wifi]
            parameters.includePeerToPeer = false
            parameters.preferNoProxies = true
            if let thunderboltInterface = cachedInterface(
                for: .thunderboltBridge,
                service: service
            ) {
                parameters.requiredInterface = thunderboltInterface
                LogManager.shared.log(
                    "Parameters: Thunderbolt Bridge mode - requiring \(thunderboltInterface.name)"
                )
            } else {
                LogManager.shared.log(
                    "Parameters: Thunderbolt Bridge mode - using scoped endpoint routing"
                )
            }

        case .wiredCable:
            parameters.serviceClass = .interactiveVideo
            parameters.prohibitedInterfaceTypes = [.loopback, .wifi]
            parameters.includePeerToPeer = false
            parameters.preferNoProxies = true
            if let wiredInterface = cachedInterface(
                for: .wiredCable,
                service: service
            ) {
                parameters.requiredInterface = wiredInterface
            }
        }
    }

    private func connectUsingInfrastructureFallback(
        serviceName: String,
        endpoint: NWEndpoint,
        connectionType: String,
        autoConnectAttempt: Bool
    ) {
        let parameters: NWParameters
        if connectionType == "UDP" {
            parameters = NWParameters.udp
        } else {
            let tcpOptions = NWProtocolTCP.Options()
            tcpOptions.enableKeepalive = true
            tcpOptions.noDelay = true
            tcpOptions.connectionTimeout = Self.tcpConnectionTimeout
            parameters = NWParameters(tls: nil, tcp: tcpOptions)
        }
        parameters.serviceClass = .interactiveVideo
        BonjourConnectionPolicy.applyLocalNetworkPolicy(
            to: parameters,
            receiverName: serviceName
        )
        connectWithParameters(
            service: DiscoveredService(name: serviceName, endpoint: endpoint),
            parameters: parameters,
            forceTCP: false,
            autoConnectAttempt: autoConnectAttempt
        )
    }

    func connect(
        to service: DiscoveredService,
        using interfacePreferenceOverride: NetworkInterfacePreference? = nil,
        restoringSavedSettings: Bool = true,
        autoConnectAttempt: Bool = false
    ) {
        ConnectDiagnostics.log(
            "connect requested service=\(service.name) endpoint=\(service.endpoint) " +
            "override=\(String(describing: interfacePreferenceOverride?.rawValue)) " +
            "restoreSettings=\(restoringSavedSettings) auto=\(autoConnectAttempt)"
        )
        // Check the display name first for a fast UI-level duplicate guard.
        if connectedServices.contains(where: { $0.name == service.name }) {
            ConnectDiagnostics.log(
                "connect rejected service=\(service.name) reason=already-connected"
            )
            LogManager.shared.log("Sender: Already connected to \(service.name)")
            return
        }
        if autoConnectAttempt {
            guard shouldAutoConnect(to: service) else {
                LogManager.shared.log("Sender: Auto-connect skipped for manually disconnected \(service.name)")
                return
            }
        } else {
            resumeAutoConnect(for: service)
        }
        let connectionId = UUID()
        guard let pendingKey = beginConnectionAttempt(
            for: service,
            connectionID: connectionId
        ) else { return }

        let localConnectionAddresses = localConnectionAddressProvider()
        let routeCatalog = outboundRouteCatalog(
            for: service,
            localAddresses: localConnectionAddresses,
            thunderboltPeerRoutes:
                currentThunderboltPeerRoutes(forceRefresh: true)
        )
        var receiverSettings = restoringSavedSettings ? settings(for: service) : currentReceiverSettings()
        let requestedInterfacePreference = interfacePreferenceOverride
            ?? receiverSettings.interfacePreferenceRawValue
                .flatMap { NetworkInterfacePreference(rawValue: $0) }
            ?? interfacePreference
        let selectedInterfacePreference =
            routeCatalog.resolve(requestedInterfacePreference)
        let selectedConnectionType = selectedInterfacePreference.allowsUDP
            ? receiverSettings.connectionType ?? connectionType
            : "TCP"
        let shouldFallbackToInfrastructure = requestedInterfacePreference == .auto
            && selectedInterfacePreference != .auto
        receiverSettings.connectionType = selectedConnectionType
        receiverSettings.interfacePreferenceRawValue =
            requestedInterfacePreference == .auto
                ? NetworkInterfacePreference.auto.rawValue
                : selectedInterfacePreference.rawValue
        applyReceiverSettings(receiverSettings)
        saveSettings(receiverSettings, for: service)

        let discoveredInterfaces = service.discoveryInterfaces.map {
            "\($0.name):\($0.type)"
        }.joined(separator: ",")
        let cachedRoutes = resolvedBonjourRoutesByName[service.name] ?? []
        let availableModes = routeCatalog.availableModes
            .map(\.rawValue)
            .joined(separator: ",")
        let cachedEndpoint = cachedRoutes.map {
            String(describing: $0.endpoint)
        }.joined(separator: ",")
        let cachedRouteInterfaces = cachedRoutes.map {
            $0.interfaceNames.joined(separator: ",")
        }.joined(separator: ";")
        let localAddresses = localConnectionAddresses.map {
            "\($0.interfaceName):\($0.address):\($0.title)"
        }.joined(separator: ",")
        let cachedInterfaces = cachedNetworkInterfacesByName.values
            .map { "\($0.name):\($0.type)" }
            .sorted()
            .joined(separator: ",")
        ConnectDiagnostics.log(
            "attempt id=\(connectionId.uuidString) service=\(service.name) " +
            "requested=\(requestedInterfacePreference.rawValue) " +
            "selected=\(selectedInterfacePreference.rawValue) protocol=\(selectedConnectionType) " +
            "availableModes=[\(availableModes)] discoveryInterfaces=[\(discoveredInterfaces)]"
        )
        ConnectDiagnostics.log(
            "attempt route id=\(connectionId.uuidString) cachedEndpoint=\(cachedEndpoint) " +
            "cachedRouteInterfaces=[\(cachedRouteInterfaces)]"
        )
        ConnectDiagnostics.log(
            "local network id=\(connectionId.uuidString) addresses=[\(localAddresses)] " +
            "nwInterfaces=[\(cachedInterfaces)] " +
            "cachedInfra=\(String(describing: cachedInfraInterface?.name)) " +
            "cachedAWDL=\(String(describing: cachedAWDLInterface?.name))"
        )

        let deviceCount = pipelines.count + 1
        self.status = "Connecting to \(service.name) (Device #\(deviceCount))..."

        // Smart routing: Apple receivers (iOS/Mac) get P2P/AWDL, others get infrastructure
        let nameLower = service.name.lowercased()
        // Manual IP connections (e.g. "10.0.0.5:51820") are never Apple receivers
        let isManualIP = service.name.contains(":") && service.name.first?.isNumber == true
        let isAppleReceiver = !isManualIP && !nameLower.contains("android") && !nameLower.contains("windows") && !nameLower.contains("linux")

        let parameters: NWParameters
        switch selectedConnectionType {
        case "UDP":
            parameters = NWParameters.udp
        default: // TCP
            let tcpOptions = NWProtocolTCP.Options()
            tcpOptions.enableKeepalive = true
            tcpOptions.noDelay = true
            tcpOptions.connectionTimeout = Self.tcpConnectionTimeout
            parameters = NWParameters(tls: nil, tcp: tcpOptions)
            parameters.serviceClass = .interactiveVideo
        }
        configureParameters(
            parameters,
            preference: selectedInterfacePreference,
            service: service
        )
        BonjourConnectionPolicy.applyLocalNetworkPolicy(
            to: parameters,
            receiverName: service.name
        )

        // For Apple devices, prefer the P2P endpoint if available (AWDL low-latency)
        let discoveredService =
            discoveredServicesByProtocol[selectedConnectionType]?[service.name]
                ?? service
        let discoveredEndpoint = discoveredService.connectionEndpoint(
            for: selectedInterfacePreference
        )
        let resolvedBonjourEndpoint = Self.preferredBonjourEndpoint(
            for: selectedInterfacePreference,
            resolvedRoutes:
                resolvedBonjourRoutesByName[service.name] ?? []
        )
        let infrastructureEndpoint = Self.infrastructureFallbackEndpoint(
            shouldFallback: shouldFallbackToInfrastructure,
            resolvedEndpoint: resolvedBonjourEndpoint,
            discoveredEndpoint:
                discoveredService.infrastructureConnectionEndpoint
        )
        let thunderboltPeerRoute = routeCatalog.thunderboltPeerRoute()
        let thunderboltInterfaceName = thunderboltPeerRoute?.interfaceName
            ?? localConnectionAddresses
                .first { $0.title == "Thunderbolt Bridge" }?
                .interfaceName
        let resolvedRoute = Self.preferredBonjourRoute(
            for: selectedInterfacePreference,
            resolvedRoutes:
                resolvedBonjourRoutesByName[service.name] ?? []
        )
        var connectEndpoint = routeCatalog.connectionEndpoint(
            for: selectedInterfacePreference,
            resolvedRoute: resolvedRoute,
            discoveredEndpoint: discoveredEndpoint,
            discoveredEndpointMatchesMode:
                discoveredService.hasConnectionEndpoint(
                    for: selectedInterfacePreference
                )
        )
        if selectedConnectionType == "UDP",
           case .hostPort(let host, _) = connectEndpoint {
            connectEndpoint = .hostPort(
                host: host,
                port: NWEndpoint.Port(rawValue: BCConstants.udpPort)!
            )
        }
        if let resolvedBonjourEndpoint,
           connectEndpoint == resolvedBonjourEndpoint {
            LogManager.shared.log(
                "Sender: Using verified Bonjour endpoint \(resolvedBonjourEndpoint) for \(service.name)"
            )
        } else if thunderboltPeerRoute != nil {
            LogManager.shared.log(
                "Sender: Using current Thunderbolt Bridge peer \(connectEndpoint) " +
                "for \(service.name)"
            )
        }
        let allowsAppleP2P = selectedInterfacePreference == .auto
            || selectedInterfacePreference == .p2pOnly
        if isAppleReceiver && allowsAppleP2P {
            if let p2pService = discoveredServicesByProtocol[selectedConnectionType]?[service.name + " P2P"] {
                // Use the P2P-advertised endpoint for AWDL connection
                connectEndpoint = p2pService.endpoint
                parameters.includePeerToPeer = true
                if let awdl = cachedAWDLInterface {
                    parameters.requiredInterface = awdl
                    LogManager.shared.log("Sender: Apple receiver — using P2P endpoint + AWDL (\(awdl.name)) for \(service.name)")
                } else {
                    if let infra = cachedInfraInterface {
                        LogManager.shared.log("Sender: Apple receiver — using P2P endpoint, banning infra for \(service.name)")
                        parameters.prohibitedInterfaces = [infra]
                    }
                    parameters.prohibitedInterfaceTypes = [.loopback, .wiredEthernet]
                    parameters.serviceClass = .interactiveVideo
                }
            } else {
                // No separate P2P endpoint — force AWDL by banning infrastructure.
                // The 5-second timeout will fall back to infra if AWDL can't be established.
                parameters.includePeerToPeer = true
                parameters.serviceClass = .interactiveVideo
                if let awdl = cachedAWDLInterface {
                    parameters.requiredInterface = awdl
                    LogManager.shared.log("Sender: Apple receiver — requiring AWDL (\(awdl.name)) for \(service.name)")
                } else if let infra = cachedInfraInterface {
                    parameters.prohibitedInterfaces = [infra]
                    parameters.prohibitedInterfaceTypes = [.loopback, .wiredEthernet]
                    LogManager.shared.log("Sender: Apple receiver — banning infra, forcing P2P for \(service.name)")
                } else {
                    LogManager.shared.log("Sender: Apple receiver — enabling P2P discovery for \(service.name)")
                }
            }
        } else {
            // Automatic non-Apple connections use infrastructure. Explicit
            // per-device P2P mode keeps its AWDL restriction.
            if selectedInterfacePreference == .auto {
                parameters.includePeerToPeer = false
            }
            parameters.serviceClass = .interactiveVideo
            LogManager.shared.log(
                "Sender: Connecting \(service.name) via \(selectedInterfacePreference.rawValue) / \(selectedConnectionType)"
            )
        }

        let requiredInterfaceName: String
        switch selectedInterfacePreference {
        case .routerOnly:
            requiredInterfaceName = cachedInfraInterface?.name ?? "type=wifi"
        case .ethernet:
            requiredInterfaceName = cachedInterface(
                for: .ethernet,
                service: service
            )?.name ?? "type=wiredEthernet"
        case .thunderboltBridge:
            requiredInterfaceName = cachedInterface(
                for: .thunderboltBridge,
                service: service
            )?.name
                ?? thunderboltInterfaceName.map { "scope=\($0)" }
                ?? "bridge-unavailable"
        case .p2pOnly:
            requiredInterfaceName = cachedAWDLInterface?.name ?? "awdl-unavailable"
        case .auto, .wiredCable:
            requiredInterfaceName = "automatic"
        }
        ConnectDiagnostics.log(
            "connection start id=\(connectionId.uuidString) service=\(service.name) " +
            "endpoint=\(connectEndpoint) discoveredEndpoint=\(discoveredEndpoint) " +
            "verifiedEndpoint=\(String(describing: resolvedBonjourEndpoint)) " +
            "requiredInterface=\(requiredInterfaceName) " +
            "includeP2P=\(parameters.includePeerToPeer) " +
            "preferNoProxies=\(parameters.preferNoProxies) " +
            "preferIPv4=\(BonjourConnectionPolicy.prefersIPv4(receiverName: service.name)) " +
            "watchdog=\(Self.availableConnectionAttemptTimeout)s"
        )

        let connection = NWConnection(to: connectEndpoint, using: parameters)
        trackPendingConnection(connection, connectionID: connectionId)
        let connectionStartedAt = Date()

        // Automatic mode tries the preferred direct/wired route first, then
        // retries without interface restrictions when that route is unavailable.
        var connectionTimedOut = false
        let timeoutWork = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            // Only retry if still not connected (no pipeline created yet)
            if self.pipelines[connectionId] == nil && !connectionTimedOut {
                connectionTimedOut = true
                let elapsed = Date().timeIntervalSince(connectionStartedAt)
                ConnectDiagnostics.log(
                    String(
                        format: "connection watchdog id=%@ service=%@ elapsed=%.3fs endpoint=%@ %@",
                        connectionId.uuidString,
                        service.name,
                        elapsed,
                        String(describing: connectEndpoint),
                        ConnectDiagnostics.pathSummary(connection.currentPath)
                    )
                )
                self.finishPendingConnection(
                    connectionID: connectionId,
                    receiverKey: pendingKey
                )
                connection.cancel()

                if !shouldFallbackToInfrastructure {
                    self.status = "Selected connection method unavailable"
                    LogManager.shared.log(
                        "Sender: Connection to \(service.name) timed out on explicitly selected \(selectedInterfacePreference.displayName)"
                    )
                    return
                }

                LogManager.shared.log(
                    "Sender: Preferred \(selectedInterfacePreference.displayName) route to \(service.name) timed out — retrying via infrastructure"
                )
                self.connectUsingInfrastructureFallback(
                    serviceName: service.name,
                    endpoint: infrastructureEndpoint,
                    connectionType: selectedConnectionType,
                    autoConnectAttempt: autoConnectAttempt
                )
            }
        }
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.availableConnectionAttemptTimeout,
            execute: timeoutWork
        )

        connection.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                let elapsed = Date().timeIntervalSince(connectionStartedAt)
                ConnectDiagnostics.log(
                    String(
                        format: "connection state id=%@ service=%@ elapsed=%.3fs state=%@ endpoint=%@ %@",
                        connectionId.uuidString,
                        service.name,
                        elapsed,
                        ConnectDiagnostics.stateSummary(state),
                        String(describing: connectEndpoint),
                        ConnectDiagnostics.pathSummary(connection.currentPath)
                    )
                )
                switch state {
                case .ready:
                    timeoutWork.cancel() // Connection succeeded, cancel timeout
                    guard let self,
                          self.admitReadyConnection(
                            connection,
                            connectionID: connectionId,
                            pendingKey: pendingKey,
                            service: service
                          ) else {
                        return
                    }

                    self.rememberSuccessfulManualConnection(for: service)

                    // Detect link type before creating pipeline
                    var isP2P = false
                    var isLoopback = false
                    if let path = connection.currentPath {
                        let interfaces = path.availableInterfaces.map { $0.debugDescription }.joined(separator: ", ")
                        LogManager.shared.log("Sender: Connected via Path: \(path)")
                        LogManager.shared.log("Sender: Interfaces: \(interfaces)")

                        if interfaces.contains("awdl") {
                            isP2P = true
                            LogManager.shared.log("Sender: P2P Direct Link (AWDL) Active ✅")
                        } else if interfaces.contains("lo0") || interfaces.contains("loopback") {
                            isLoopback = true
                            LogManager.shared.log("Sender: Loopback/ADB tunnel — high bandwidth mode 🔌")
                        } else {
                            LogManager.shared.log("Sender: Likely using Router/Infrastructure ⚠️")
                        }
                    }

                    // Create pipeline for this connection
                    var pipeline = ConnectionPipeline(
                        id: connectionId,
                        connection: connection,
                        service: service,
                        lastHeartbeat: Date(),
                        settings: receiverSettings
                    )
                    pipeline.isP2P = isP2P
                    pipeline.isLoopback = isLoopback
                    pipeline.connectionPreference = selectedInterfacePreference
                    // iOS/Mac Swift receivers don't handle the type byte in TCP framing
                    // Match Mac/iOS Swift receivers that don't handle the type byte.
                    // Bonjour appends " (2)", " (3)" etc. for duplicate names, so we can't use exact match.
                    // Android/Windows/Linux receivers contain their platform keyword and DO support typeByte.
                    let nameLower = service.name.lowercased()
                    let isLegacyReceiver = nameLower.hasPrefix("bettercast receiver")
                        && !nameLower.contains("android") && !nameLower.contains("windows") && !nameLower.contains("linux")
                    pipeline.supportsTypeByte = !isLegacyReceiver
                    self.pipelines[connectionId] = pipeline
                    self.sendIdentityIfSupported(for: connectionId)
                    self.connectedServices.append(service)
                    self.updateConnectedDisplays()

                    let count = self.pipelines.count
                    self.status = "Connected to \(count) device(s)"
                    LogManager.shared.log("Sender: Connected to \(service.name) (Total: \(count), P2P: \(isP2P), typeByte: \(pipeline.supportsTypeByte))")

                    // Start per-connection pipeline (each device gets its own display/encoder/recorder)
                    self.startPipeline(for: connectionId)

                    // Start shared services on first connection
                    if count == 1 {
                        self.startHeartbeatMonitor()
                        self.startStatsTimer()
                    }

                    self.receive(on: connection, connectionId: connectionId)
                case .failed(let error):
                    timeoutWork.cancel()
                    self?.finishPendingConnection(
                        connectionID: connectionId,
                        receiverKey: pendingKey
                    )
                    LogManager.shared.log("Sender: Connection to \(service.name) failed: \(error)")
                    if shouldFallbackToInfrastructure {
                        LogManager.shared.log(
                            "Sender: Preferred \(selectedInterfacePreference.displayName) route to \(service.name) failed — retrying via infrastructure"
                        )
                        self?.connectUsingInfrastructureFallback(
                            serviceName: service.name,
                            endpoint: infrastructureEndpoint,
                            connectionType: selectedConnectionType,
                            autoConnectAttempt: autoConnectAttempt
                        )
                        return
                    }
                    self?.removeConnection(connectionId)

                    let remaining = self?.pipelines.count ?? 0
                    if remaining == 0 {
                        self?.status = "All connections failed"
                    } else {
                        self?.status = "Connected to \(remaining) device(s)"
                    }
                case .waiting(let error):
                    self?.status = "Waiting... \(error.localizedDescription)"
                default:
                    break
                }
            }
        }

        connection.start(queue: .main)
    }

    func connectManual(
        using interfacePreferenceOverride: NetworkInterfacePreference? = nil,
        autoConnectAttempt: Bool = false
    ) {
        let host = manualHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return }
        guard let portNum = UInt16(manualPort), portNum > 0,
              let port = NWEndpoint.Port(rawValue: portNum) else {
            LogManager.shared.log("Sender: Invalid port '\(manualPort)'")
            return
        }
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: port
        )
        let service = DiscoveredService(name: "\(host):\(portNum)", endpoint: endpoint)

        // Add to foundServices so it appears in the Devices list with status/disconnect
        if !foundServices.contains(where: { $0.name == service.name }) {
            foundServices.append(service)
        }

        // Manual IP connections use TCP. Localhost stays unrestricted for ADB;
        // other hosts honor the saved per-device interface mode.
        let isLocalhost = host == "localhost" || host == "127.0.0.1"

        if isLocalhost {
            let tcpOptions = NWProtocolTCP.Options()
            tcpOptions.enableKeepalive = true
            tcpOptions.noDelay = true
            let parameters = NWParameters(tls: nil, tcp: tcpOptions)
            parameters.serviceClass = .interactiveVideo
            LogManager.shared.log("Sender: Manual connect to \(host):\(portNum) (localhost/ADB mode, no interface restrictions)")
            connectWithParameters(service: service, parameters: parameters, forceTCP: true)
        } else {
            let tcpOptions = NWProtocolTCP.Options()
            tcpOptions.enableKeepalive = true
            tcpOptions.noDelay = true
            let parameters = NWParameters(tls: nil, tcp: tcpOptions)
            let receiverSettings = settings(for: service)
            let preference = interfacePreferenceOverride
                ?? receiverSettings.interfacePreferenceRawValue
                    .flatMap { NetworkInterfacePreference(rawValue: $0) }
                ?? interfacePreference
            let resolvedPreference = resolvedConnectionPreference(
                preference,
                for: service
            )
            configureParameters(
                parameters,
                preference: resolvedPreference,
                service: service
            )
            LogManager.shared.log(
                "Sender: Manual connect to \(host):\(portNum) via \(resolvedPreference.rawValue) / TCP"
            )
            connectWithParameters(
                service: service,
                parameters: parameters,
                forceTCP: true,
                autoConnectAttempt: autoConnectAttempt
            )
        }
    }

    func connectManualService(
        _ service: DiscoveredService,
        using interfacePreferenceOverride: NetworkInterfacePreference? = nil,
        autoConnectAttempt: Bool = false
    ) {
        guard case .hostPort(let host, let port) = service.endpoint else {
            connect(
                to: service,
                using: interfacePreferenceOverride,
                restoringSavedSettings: false,
                autoConnectAttempt: autoConnectAttempt
            )
            return
        }
        manualHost = String(describing: host)
        manualPort = String(port.rawValue)
        connectManual(
            using: interfacePreferenceOverride,
            autoConnectAttempt: autoConnectAttempt
        )
    }

    // MARK: - ADB Wireless

    @Published var adbStatus: String = ""
    @Published var adbInProgress: Bool = false

    /// Run an ADB shell command and return trimmed stdout
    private func runAdb(_ args: [String]) -> (output: String, success: Bool) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/adb")
        process.arguments = args
        let pipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = pipe
        process.standardError = errPipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return (output, process.terminationStatus == 0)
        } catch {
            return ("", false)
        }
    }

    /// Get the Android device's WiFi IP address via ADB
    /// - Parameter serial: Optional device serial to target (required when multiple devices connected)
    private func getDeviceIP(serial: String? = nil) -> String? {
        let deviceArgs: [String] = serial.map { ["-s", $0] } ?? []

        // Method 1: ip route — look for wlan0 specifically (not cellular)
        let routeResult = runAdb(deviceArgs + ["shell", "ip", "route"])
        if routeResult.success {
            let lines = routeResult.output.components(separatedBy: "\n")
            for line in lines {
                // Must be wlan0 to avoid picking up cellular IP
                if line.contains("wlan0") && line.contains("src") {
                    let parts = line.components(separatedBy: " ")
                    if let srcIdx = parts.firstIndex(of: "src"), srcIdx + 1 < parts.count {
                        let ip = parts[srcIdx + 1]
                        if isPrivateIP(ip) { return ip }
                    }
                }
            }
        }

        // Method 2: ip addr show wlan0 — parse inet line
        let addrResult = runAdb(deviceArgs + ["shell", "ip", "addr", "show", "wlan0"])
        if addrResult.success {
            let lines = addrResult.output.components(separatedBy: "\n")
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("inet ") {
                    // "inet 192.168.1.100/24 ..."
                    let parts = trimmed.components(separatedBy: " ")
                    if parts.count >= 2 {
                        let ip = parts[1].components(separatedBy: "/").first ?? ""
                        if isPrivateIP(ip) { return ip }
                    }
                }
            }
        }

        return nil
    }

    /// Check if IP is a private/local address (not cellular)
    private func isPrivateIP(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".")
        guard parts.count == 4 else { return false }
        // 192.168.x.x, 10.x.x.x, 172.16-31.x.x
        if ip.hasPrefix("192.168.") || ip.hasPrefix("10.") { return true }
        if ip.hasPrefix("172."), let second = Int(parts[1]), (16...31).contains(second) { return true }
        return false
    }

    /// Full ADB wireless handoff: USB → tcpip → forward → connect
    func connectADBWireless() {
        guard !adbInProgress else { return }
        adbInProgress = true
        adbStatus = "Checking device..."

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            // 1. Check for connected devices (USB and/or WiFi)
            let devices = self.runAdb(["devices"])
            let allLines = devices.output.components(separatedBy: "\n").filter { $0.contains("\tdevice") }
            let usbLines = allLines.filter { !$0.contains(":") }
            let wifiLines = allLines.filter { $0.contains(":") }

            // If already connected via WiFi ADB, just set up port forwarding directly
            if let wifiLine = wifiLines.first {
                let wifiSerial = wifiLine.components(separatedBy: "\t").first ?? ""
                LogManager.shared.log("ADB Wireless: Already connected via WiFi: \(wifiSerial)")

                // Disconnect existing streaming pipeline
                DispatchQueue.main.async {
                    self.adbStatus = "Setting up wireless tunnel..."
                    let adbNames = ["Android (USB)", "Android (WiFi ADB)", "localhost:51820"]
                    for name in adbNames {
                        if let entry = self.pipelines.first(where: { $0.value.service.name == name }) {
                            self.removeConnection(entry.key)
                            LogManager.shared.log("ADB Wireless: Disconnected existing '\(name)'")
                        }
                    }
                }
                Thread.sleep(forTimeInterval: 0.3)

                // Set up port forwarding through existing WiFi connection
                let forwardResult = self.runAdb(["-s", wifiSerial, "forward", "tcp:51820", "tcp:51820"])
                LogManager.shared.log("ADB Wireless: forward result: \(forwardResult.output)")

                DispatchQueue.main.async {
                    self.adbStatus = "Connecting stream..."
                    LogManager.shared.log("ADB Wireless: Tunnel ready via existing WiFi — connecting to localhost:51820")
                    self.connectADBTunnel(displayName: "Android (WiFi ADB)")

                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        self.adbStatus = "Wireless ADB active"
                        self.adbInProgress = false
                    }
                }
                return
            }

            // No WiFi ADB — need USB device to do the handoff
            guard !usbLines.isEmpty else {
                DispatchQueue.main.async {
                    self.adbStatus = "No USB or WiFi device found"
                    self.adbInProgress = false
                    LogManager.shared.log("ADB Wireless: No USB or WiFi ADB device connected")
                }
                return
            }

            let serial = usbLines[0].components(separatedBy: "\t").first ?? ""
            DispatchQueue.main.async {
                self.adbStatus = "Found: \(serial)"
                LogManager.shared.log("ADB Wireless: Found USB device \(serial)")
            }

            // 2. Get device IP over USB (pass serial to avoid "more than one device" error)
            guard let deviceIP = self.getDeviceIP(serial: serial) else {
                DispatchQueue.main.async {
                    self.adbStatus = "Cannot get device IP"
                    self.adbInProgress = false
                    LogManager.shared.log("ADB Wireless: Failed to get device IP via 'ip route'")
                }
                return
            }

            DispatchQueue.main.async {
                self.adbStatus = "Device IP: \(deviceIP)"
                LogManager.shared.log("ADB Wireless: Device IP is \(deviceIP)")
            }

            // 3. Disconnect existing ADB connection first (tcpip will kill USB tunnel anyway)
            DispatchQueue.main.async {
                self.adbStatus = "Switching to wireless — disconnecting USB..."
                let adbNames = ["Android (USB)", "Android (WiFi ADB)", "localhost:51820"]
                for name in adbNames {
                    if let entry = self.pipelines.first(where: { $0.value.service.name == name }) {
                        self.removeConnection(entry.key)
                        LogManager.shared.log("ADB Wireless: Disconnected existing '\(name)' before switching")
                    }
                }
            }
            Thread.sleep(forTimeInterval: 0.5)

            // 4. Enable TCP/IP mode on device
            DispatchQueue.main.async {
                self.adbStatus = "Switching to wireless — enabling TCP mode..."
                LogManager.shared.log("ADB Wireless: Running 'adb tcpip 5555'...")
            }
            let tcpipResult = self.runAdb(["-s", serial, "tcpip", "5555"])
            LogManager.shared.log("ADB Wireless: tcpip result: \(tcpipResult.output)")

            // Wait for ADB daemon to restart
            Thread.sleep(forTimeInterval: 3.0)

            // 5. Connect to device over WiFi
            DispatchQueue.main.async {
                self.adbStatus = "Switching to wireless — connecting \(deviceIP)..."
                LogManager.shared.log("ADB Wireless: Connecting to \(deviceIP):5555...")
            }

            var connected = false
            for attempt in 1...10 {
                let connectResult = self.runAdb(["connect", "\(deviceIP):5555"])
                LogManager.shared.log("ADB Wireless: connect attempt \(attempt): \(connectResult.output)")
                if connectResult.output.contains("connected") {
                    connected = true
                    break
                }
                Thread.sleep(forTimeInterval: 1.5)
            }

            guard connected else {
                DispatchQueue.main.async {
                    self.adbStatus = "WiFi connect failed — check WiFi"
                    self.adbInProgress = false
                    LogManager.shared.log("ADB Wireless: Failed to connect over WiFi after 10 attempts")
                }
                return
            }

            // 6. Set up port forwarding (through the WiFi ADB connection)
            DispatchQueue.main.async {
                self.adbStatus = "Switching to wireless — setting up tunnel..."
                LogManager.shared.log("ADB Wireless: Setting up port forward on \(deviceIP):5555...")
            }
            let forwardResult = self.runAdb(["-s", "\(deviceIP):5555", "forward", "tcp:51820", "tcp:51820"])
            LogManager.shared.log("ADB Wireless: forward result: \(forwardResult.output)")

            // 7. Connect sender to localhost:51820 (tunneled through WiFi ADB)
            DispatchQueue.main.async {
                self.adbStatus = "Connecting stream..."
                LogManager.shared.log("ADB Wireless: Tunnel ready — connecting to localhost:51820")
                self.connectADBTunnel(displayName: "Android (WiFi ADB)")

                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    self.adbStatus = "Wireless ADB active"
                    self.adbInProgress = false
                    LogManager.shared.log("ADB Wireless: Setup complete — streaming via WiFi ADB tunnel")
                }
            }
        }
    }

    /// Quick ADB USB-only: just forward port and connect (no wireless handoff)
    func connectADBUSB() {
        adbStatus = "Forwarding port..."
        LogManager.shared.log("ADB USB: Setting up port forward...")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            // Find USB device serial (filter out wireless connections which contain ":")
            let devices = self.runAdb(["devices"])
            let usbLines = devices.output.components(separatedBy: "\n").filter {
                $0.contains("\tdevice") && !$0.contains(":")
            }
            let serial = usbLines.first?.components(separatedBy: "\t").first

            // Use -s serial if available (handles multiple-device case)
            let deviceArgs: [String] = serial.map { ["-s", $0] } ?? []
            let forwardResult = self.runAdb(deviceArgs + ["forward", "tcp:51820", "tcp:51820"])
            LogManager.shared.log("ADB USB: forward result: \(forwardResult.output)")

            DispatchQueue.main.async {
                self.adbStatus = "Connecting..."
                self.connectADBTunnel(displayName: "Android (USB)")

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.adbStatus = "USB ADB active"
                    LogManager.shared.log("ADB USB: Connected via USB tunnel")
                }
            }
        }
    }

    /// Connect to ADB-forwarded port with a proper device name that shows in the device list
    private func connectADBTunnel(displayName: String) {
        guard let port = NWEndpoint.Port(rawValue: BCConstants.tcpPort) else { return }
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host("localhost"),
            port: port
        )
        let service = DiscoveredService(name: displayName, endpoint: endpoint)

        // Add to foundServices so it shows in the device list
        if !foundServices.contains(where: { $0.name == displayName }) {
            foundServices.append(service)
        }

        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.enableKeepalive = true
        tcpOptions.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcpOptions)
        parameters.serviceClass = .interactiveVideo

        LogManager.shared.log("Sender: ADB connect '\(displayName)' via localhost:51820")
        connectWithParameters(service: service, parameters: parameters, forceTCP: true)
    }

    private func connectWithParameters(
        service: DiscoveredService,
        parameters: NWParameters,
        forceTCP: Bool = false,
        autoConnectAttempt: Bool = false
    ) {
        if connectedServices.contains(where: { $0.name == service.name }) {
            LogManager.shared.log("Sender: Already connected to \(service.name)")
            return
        }
        if autoConnectAttempt {
            guard shouldAutoConnect(to: service) else {
                LogManager.shared.log("Sender: Auto-connect skipped for manually disconnected \(service.name)")
                return
            }
        } else {
            resumeAutoConnect(for: service)
        }
        let connectionId = UUID()
        guard let pendingKey = beginConnectionAttempt(
            for: service,
            connectionID: connectionId
        ) else { return }

        var receiverSettings = settings(for: service)
        if forceTCP {
            receiverSettings.connectionType = "TCP"
        }
        applyReceiverSettings(receiverSettings)
        saveSettings(receiverSettings, for: service)

        let deviceCount = pipelines.count + 1
        self.status = "Connecting to \(service.name) (Device #\(deviceCount))..."

        let connection = NWConnection(to: service.endpoint, using: parameters)
        trackPendingConnection(connection, connectionID: connectionId)

        let timeoutWork = DispatchWorkItem { [weak self, weak connection] in
            guard let self, let connection,
                  self.pipelines[connectionId] == nil else {
                return
            }
            self.finishPendingConnection(
                connectionID: connectionId,
                receiverKey: pendingKey
            )
            connection.cancel()
            LogManager.shared.log(
                "Sender: Connection to \(service.name) timed out after 10 seconds"
            )
            if self.pipelines.isEmpty {
                self.status = "Connection timed out"
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: timeoutWork)

        connection.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                switch state {
                case .ready:
                    timeoutWork.cancel()
                    guard let self,
                          self.admitReadyConnection(
                            connection,
                            connectionID: connectionId,
                            pendingKey: pendingKey,
                            service: service
                          ) else {
                        return
                    }
                    self.rememberSuccessfulManualConnection(for: service)
                    // Detect link type
                    var isP2P = false
                    var isLoopback = false
                    if let path = connection.currentPath {
                        let interfaces = path.availableInterfaces.map { $0.debugDescription }.joined(separator: ", ")
                        LogManager.shared.log("Sender: Connected via Path: \(path)")
                        LogManager.shared.log("Sender: Interfaces: \(interfaces)")

                        if interfaces.contains("awdl") {
                            isP2P = true
                            LogManager.shared.log("Sender: P2P Direct Link (AWDL) Active ✅")
                        } else if interfaces.contains("lo0") || interfaces.contains("loopback") {
                            isLoopback = true
                            LogManager.shared.log("Sender: Loopback/ADB tunnel — high bandwidth mode 🔌")
                        } else {
                            LogManager.shared.log("Sender: Likely using Router/Infrastructure ⚠️")
                        }
                    }

                    var pipeline = ConnectionPipeline(
                        id: connectionId,
                        connection: connection,
                        service: service,
                        lastHeartbeat: Date(),
                        settings: receiverSettings
                    )
                    pipeline.isP2P = isP2P
                    pipeline.isLoopback = isLoopback
                    pipeline.forceTCP = forceTCP
                    pipeline.isWiFiADB = isLoopback && service.name.contains("WiFi")
                    // iOS/Mac Swift receivers don't handle the type byte in TCP framing
                    // Android and desktop (C++/Qt) receivers do strip it
                    // Match Mac/iOS Swift receivers that don't handle the type byte.
                    // Bonjour appends " (2)", " (3)" etc. for duplicate names, so we can't use exact match.
                    // Android/Windows/Linux receivers contain their platform keyword and DO support typeByte.
                    let nameLower = service.name.lowercased()
                    let isLegacyReceiver = nameLower.hasPrefix("bettercast receiver")
                        && !nameLower.contains("android") && !nameLower.contains("windows") && !nameLower.contains("linux")
                    pipeline.supportsTypeByte = !isLegacyReceiver
                    self.pipelines[connectionId] = pipeline
                    self.sendIdentityIfSupported(for: connectionId)
                    self.connectedServices.append(service)
                    self.updateConnectedDisplays()

                    let count = self.pipelines.count
                    self.status = "Connected to \(count) device(s)"
                    LogManager.shared.log("Sender: Connected to \(service.name) (Total: \(count), P2P: \(isP2P), typeByte: \(pipeline.supportsTypeByte))")

                    self.startPipeline(for: connectionId)

                    if count == 1 {
                        self.startHeartbeatMonitor()
                        self.startStatsTimer()
                    }

                    self.receive(on: connection, connectionId: connectionId)
                case .failed(let error):
                    timeoutWork.cancel()
                    LogManager.shared.log("Sender: Connection to \(service.name) failed: \(error)")
                    self?.finishPendingConnection(
                        connectionID: connectionId,
                        receiverKey: pendingKey
                    )
                    self?.removeConnection(connectionId)

                    let remaining = self?.pipelines.count ?? 0
                    if remaining == 0 {
                        self?.status = "All connections failed"
                    } else {
                        self?.status = "Connected to \(remaining) device(s)"
                    }
                case .waiting(let error):
                    self?.status = "Waiting... \(error.localizedDescription)"
                default:
                    break
                }
            }
        }

        connection.start(queue: .main)
    }

    // MARK: - App Controls
    func checkScreenRecordingPermission() {
        // Trigger generic check.
        // For macOS 11+, requesting CGWindowList or SCShareableContent triggers the prompt if mostly bundled correctly.
        // We use SCShareableContent.current asynchronously to trigger it without blocking main thread hard.
        Task {
            do {
                _ = try await SCShareableContent.current
                LogManager.shared.log("Permission Check: Screen Recording access appears active ✅")
            } catch {
                LogManager.shared.log("Permission Check: Screen Recording access might be missing or pending. Watch for System Popup. ⚠️")
            }
        }
    }

    func openDisplaySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }


    func openPrivacySettings() {
        // macOS 13+ Deep Link
        if let url = URL(string: "x-apple.systempreferences:com.apple.PrivacySecurity.extension?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
        // Fallback for older macOS
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    func resetScreenCapturePermissions() {
        LogManager.shared.log("Permissions: Resetting ScreenCapture and Accessibility permissions...")

        var allSuccess = true

        // Reset Screen Recording
        let screenCapture = Process()
        screenCapture.executableURL = URL(fileURLWithPath: BCConstants.tccutilPath)
        screenCapture.arguments = ["reset", "ScreenCapture", "com.extendcast.app"]
        do {
            try screenCapture.run()
            screenCapture.waitUntilExit()
            if screenCapture.terminationStatus == 0 {
                LogManager.shared.log("Permissions: Screen Recording reset OK")
            } else {
                LogManager.shared.log("Permissions: Screen Recording reset failed (Code \(screenCapture.terminationStatus))")
                allSuccess = false
            }
        } catch {
            LogManager.shared.log("Permissions: Error resetting Screen Recording - \(error)")
            allSuccess = false
        }

        // Reset Accessibility (for mouse/keyboard control)
        let accessibility = Process()
        accessibility.executableURL = URL(fileURLWithPath: BCConstants.tccutilPath)
        accessibility.arguments = ["reset", "Accessibility", "com.extendcast.app"]
        do {
            try accessibility.run()
            accessibility.waitUntilExit()
            if accessibility.terminationStatus == 0 {
                LogManager.shared.log("Permissions: Accessibility reset OK")
            } else {
                LogManager.shared.log("Permissions: Accessibility reset failed (Code \(accessibility.terminationStatus))")
                allSuccess = false
            }
        } catch {
            LogManager.shared.log("Permissions: Error resetting Accessibility - \(error)")
            allSuccess = false
        }

        if allSuccess {
            LogManager.shared.log("Permissions: All reset! Restarting to re-prompt...")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.restartApp()
            }
        } else {
            LogManager.shared.log("Permissions: Some resets failed. Check Settings manually.")
            openPrivacySettings()
        }
    }

    func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    func restartApp() {
        let url = URL(fileURLWithPath: Bundle.main.bundlePath)
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true

        NSWorkspace.shared.openApplication(at: url, configuration: config) { app, error in
            if error == nil {
                DispatchQueue.main.async {
                    NSApplication.shared.terminate(nil)
                }
            } else {
                LogManager.shared.log("Sender: Failed to restart - \(error?.localizedDescription ?? "")")
            }
        }
    }

    // MARK: - Dynamic Updates
    func isProtocolLocked(for connectionId: UUID) -> Bool {
        guard let service = pipelines[connectionId]?.service else { return true }
        if case .hostPort = service.endpoint {
            return true
        }
        return false
    }

    private func editedSettings(for connectionId: UUID) -> ReceiverSettings? {
        guard pipelines[connectionId] != nil else { return nil }

        var settings = currentReceiverSettings()
        settings.audioStreamingEnabled =
            connectedDisplays.first(where: { $0.id == connectionId })?.audioEnabled
            ?? settings.audioStreamingEnabled
        return settings
    }

    func hasPendingSettings(for connectionId: UUID) -> Bool {
        guard let pipeline = pipelines[connectionId],
              let editedSettings = editedSettings(for: connectionId) else {
            return false
        }
        return pipeline.settings != editedSettings
    }

    func pendingSettingsRequireReconnect(for connectionId: UUID) -> Bool {
        guard let pipeline = pipelines[connectionId],
              let editedSettings = editedSettings(for: connectionId) else {
            return false
        }
        return pipeline.settings.connectionType != editedSettings.connectionType
            || pipeline.settings.interfacePreferenceRawValue
                != editedSettings.interfacePreferenceRawValue
    }

    /// Applies the current form values to one connection.
    /// - Returns: `true` when changing transport settings requires a reconnect.
    @discardableResult
    func applySettings(for connectionId: UUID) -> Bool {
        guard let pipeline = pipelines[connectionId],
              let updatedSettings = editedSettings(for: connectionId) else {
            return false
        }

        let connectionSettingsChanged = pendingSettingsRequireReconnect(for: connectionId)

        saveSettings(updatedSettings, for: pipeline.service)
        performApplySettings(
            updatedSettings,
            to: connectionId,
            reconnect: connectionSettingsChanged
        )
        objectWillChange.send()
        return connectionSettingsChanged
    }

    private func performApplySettings(
        _ updatedSettings: ReceiverSettings,
        to connectionId: UUID,
        reconnect: Bool
    ) {
        guard let pipeline = pipelines[connectionId] else { return }

        if reconnect {
            let service = pipeline.service
            reconnectingServiceNames.insert(service.name)
            LogManager.shared.log(
                "Sender: Connection settings changed for \(service.name); reconnecting..."
            )
            removeConnection(connectionId)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self else { return }
                if case .hostPort = service.endpoint {
                    self.connectManualService(service)
                } else {
                    self.connect(to: service)
                }
                self.reconnectingServiceNames.remove(service.name)
            }
            return
        }

        LogManager.shared.log(
            "Sender: Applying stream settings for \(pipeline.service.name)..."
        )
        pipelines[connectionId]?.settings = updatedSettings
        pipeline.screenRecorder?.stopCapture()
        pipelines[connectionId]?.screenRecorder = nil
        pipelines[connectionId]?.videoEncoder = nil
        pipelines[connectionId]?.audioEncoder = nil

        if updatedSettings.useVirtualDisplay,
           let displayManager = pipeline.virtualDisplayManager {
            let resolution = virtualDisplayResolution(for: connectionId)
            if !displayManager.updateDisplay(
                resolution: resolution,
                refreshRate: updatedSettings.fps
            ) {
                displayManager.destroyDisplay()
                pipelines[connectionId]?.virtualDisplayManager = nil
                InputHandler.shared.removeDisplayBounds(for: connectionId)
                LogManager.shared.log(
                    "Sender: In-place display update failed; will recreate for " +
                    pipeline.service.name
                )
            }
        } else if let displayManager = pipeline.virtualDisplayManager {
            displayManager.destroyDisplay()
            pipelines[connectionId]?.virtualDisplayManager = nil
            InputHandler.shared.removeDisplayBounds(for: connectionId)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, self.pipelines[connectionId] != nil else { return }
            self.startPipeline(for: connectionId)
        }
    }

    func startHeartbeatMonitor() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if !self.pipelines.isEmpty {
                let now = Date()
                var disconnectedIds: [UUID] = []

                for (id, pipeline) in self.pipelines {
                    if Self.receiverConnectionHasTimedOut(
                        lastHeartbeat: pipeline.lastHeartbeat,
                        now: now
                    ) {
                        LogManager.shared.log(
                            "Sender: Connection to \(pipeline.service.name) timed out "
                                + "(No heartbeat for \(Int(Self.receiverHeartbeatTimeout))s)"
                        )
                        disconnectedIds.append(id)
                    }
                }

                for id in disconnectedIds {
                    self.removeConnection(id)
                }
            }
        }
    }

    func removeConnection(_ connectionId: UUID) {
        guard let pipeline = pipelines[connectionId] else { return }

        // Tear down this connection's pipeline
        pipeline.screenRecorder?.stopCapture()
        pipeline.virtualDisplayManager?.destroyDisplay()
        pipeline.connection.cancel()
        InputHandler.shared.removeDisplayBounds(for: connectionId)

        pipelines.removeValue(forKey: connectionId)
        connectionRegistry.removeActive(connectionID: connectionId)
        connectedServices.removeAll { $0.name == pipeline.service.name }

        let remaining = pipelines.count
        LogManager.shared.log("Sender: Disconnected from \(pipeline.service.name). Remaining: \(remaining)")

        if remaining == 0 {
            status = "Disconnected"
            heartbeatTimer?.invalidate()
        } else {
            status = "Connected to \(remaining) device(s)"
        }
        updateConnectedDisplays()
    }

    func disconnect() {
        pendingConnectionsByID.values.forEach { $0.cancel() }
        pendingConnectionsByID.removeAll()
        for (id, pipeline) in pipelines {
            suppressAutoConnect(for: pipeline.service)
            pipeline.screenRecorder?.stopCapture()
            pipeline.virtualDisplayManager?.destroyDisplay()
            pipeline.connection.cancel()
            InputHandler.shared.removeDisplayBounds(for: id)
        }
        pipelines.removeAll()
        connectionRegistry.removeAll()
        connectedServices.removeAll()
        connectedDisplays.removeAll()
        status = "Disconnected"
        heartbeatTimer?.invalidate()
    }

    func disconnectService(_ service: DiscoveredService) {
        suppressAutoConnect(for: service)
        if let entry = pipelines.first(where: { $0.value.service.name == service.name }) {
            removeConnection(entry.key)
        }
    }

    func disconnectConnection(_ connectionId: UUID) {
        if let service = pipelines[connectionId]?.service {
            suppressAutoConnect(for: service)
        }
        removeConnection(connectionId)
    }

    func setAudioEnabled(_ enabled: Bool, for connectionId: UUID) {
        if let idx = connectedDisplays.firstIndex(where: { $0.id == connectionId }) {
            connectedDisplays[idx].audioEnabled = enabled
            let name = connectedDisplays[idx].name
            LogManager.shared.log("Sender: Audio \(enabled ? "enabled" : "disabled") for \(name)")
        }
    }

    static func physicalConnectionMethod(
        interfaceNames: [String]
    ) -> String? {
        let lowercasedNames = interfaceNames.map { $0.lowercased() }
        if lowercasedNames.contains(where: {
            $0.contains("bridge") || $0.contains("thunderbolt")
        }) {
            return "Thunderbolt Bridge"
        }
        return nil
    }

    private func connectionMethodName(for pipeline: ConnectionPipeline) -> String {
        let serviceName = pipeline.service.name.lowercased()
        if serviceName.contains("android (usb)") {
            return "USB (ADB)"
        }
        if serviceName.contains("android (wifi adb)") {
            return "Wi-Fi (ADB)"
        }
        if pipeline.isP2P || pipeline.connectionPreference == .p2pOnly {
            return "Wi-Fi Direct"
        }
        if pipeline.isLoopback {
            return "Local Tunnel"
        }
        if let path = pipeline.connection.currentPath,
           let physicalMethod = Self.physicalConnectionMethod(
               interfaceNames: path.availableInterfaces.map(\.name)
           ) {
            return physicalMethod
        }

        switch pipeline.connectionPreference {
        case .routerOnly:
            return "Wi-Fi"
        case .ethernet:
            return "Ethernet"
        case .thunderboltBridge:
            return "Thunderbolt Bridge"
        case .wiredCable:
            if pipeline.service.supportsThunderboltConnection {
                return "Thunderbolt Bridge"
            }
            return "Ethernet"
        case .auto:
            if let path = pipeline.connection.currentPath {
                if path.usesInterfaceType(.wifi) {
                    return "Wi-Fi"
                }
                if path.usesInterfaceType(.wiredEthernet) {
                    return "Ethernet"
                }
                if path.usesInterfaceType(.other)
                    && pipeline.service.supportsThunderboltConnection {
                    return "Thunderbolt Bridge"
                }
            }
            return "Local Network"
        case .p2pOnly:
            return "Wi-Fi Direct"
        }
    }

    func updateConnectedDisplays() {
        connectedDisplays = pipelines.map { (id, pipeline) in
            let bounds = InputHandler.shared.getDisplayBounds(for: id)
            let res = bounds.width > 0 ? "\(Int(bounds.width))x\(Int(bounds.height))" : "Initializing..."
            return ConnectedDisplayInfo(
                id: id,
                name: pipeline.service.name,
                resolution: res,
                connectionMethod: connectionMethodName(for: pipeline),
                displayBounds: bounds,
                audioEnabled: connectedDisplays.first(where: { $0.id == id })?.audioEnabled
                    ?? pipeline.settings.audioStreamingEnabled,
                cgDisplayID: pipeline.virtualDisplayManager?.displayID
            )
        }
        refreshBonjourReachabilityProbeScheduling()
    }

    private func startStatsTimer() {
        // Simple timer to update transfer rate UI
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            if self.pipelines.isEmpty { timer.invalidate(); return }

            let bytes = self.bytesSentWindow
            self.bytesSentWindow = 0

            let mbps = Double(bytes * 8) / 1_000_000.0
            self.transferStats.rate = String(format: "%.1f Mbps", mbps)
        }
    }

    private func receive(on connection: NWConnection, connectionId: UUID) {
        let pipelineConnectionType = pipelines[connectionId]?.settings.connectionType ?? "TCP"
        let useTCP = (pipelines[connectionId]?.forceTCP == true)
            || pipelineConnectionType != "UDP"
        if useTCP {
             receiveTCP(on: connection, connectionId: connectionId)
         } else {
             receiveUDP(on: connection, connectionId: connectionId)
         }
    }

    private func receiveTCP(on connection: NWConnection, connectionId: UUID) {
        // Don't schedule receives on dead connections
        guard pipelines[connectionId] != nil else { return }

        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] content, contentContext, isComplete, error in
            if let error = error {
                // Fatal errors: connection is truly dead
                if case let NWError.posix(code) = error,
                   (code == .ECONNRESET || code == .ENOTCONN || code == .ECANCELED) {
                    LogManager.shared.log("Sender: Receive error (fatal): \(error)")
                    return
                }
                // Non-fatal (e.g. ENODATA/96): keep receiving, don't spam logs
                self?.receiveTCP(on: connection, connectionId: connectionId)
                return
            }

            if let content = content, content.count == 4 {
                let length = content.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
                let bodyLength = Int(length)

                connection.receive(minimumIncompleteLength: bodyLength, maximumLength: bodyLength) { body, bodyContext, isComplete, error in
                    // All pipelines access must happen on main thread to avoid dictionary races
                    DispatchQueue.main.async {
                        // Update heartbeat
                        self?.pipelines[connectionId]?.lastHeartbeat = Date()

                        if let body = body {
                            if let event = try? JSONDecoder().decode(InputEvent.self, from: body) {
                                if event.type == .command && event.keyCode == 888 {
                                    // Heartbeat - ignore
                                } else if event.type == .command && event.keyCode == 999 {
                                    self?.pipelines[connectionId]?.videoEncoder?.forceKeyframe()
                                } else if event.type == .command && event.keyCode == 777 {
                                    // Screen info from receiver: deltaX=width, deltaY=height (pixels)
                                    self?.handleScreenInfo(for: connectionId, width: Int(event.deltaX), height: Int(event.deltaY))
                                } else if self?.isDuplicateEvent(event.eventId) == false {
                                    InputHandler.shared.handle(event: event, for: connectionId)
                                }
                            }
                        }
                    }
                    self?.receiveTCP(on: connection, connectionId: connectionId)
                }
            } else {
                self?.receiveTCP(on: connection, connectionId: connectionId)
            }
        }
    }

    private func receiveUDP(on connection: NWConnection, connectionId: UUID) {
        connection.receiveMessage { [weak self] content, contentContext, isComplete, error in
            if let error = error {
                LogManager.shared.log("Sender: Receive UDP error \(error)")

                if case let NWError.posix(code) = error, code == .ECONNREFUSED {
                    DispatchQueue.main.async { [weak self] in
                        self?.connectionRefusedCount += 1
                        if (self?.connectionRefusedCount ?? 0) > 5 {
                            LogManager.shared.log("Sender: CRITICAL - Receiver is refusing connection (Firewall?). Stopping.")
                            self?.removeConnection(connectionId)
                        }
                    }
                }
                return
            }

            // All pipelines access must happen on main thread to avoid dictionary races
            DispatchQueue.main.async {
                self?.pipelines[connectionId]?.lastHeartbeat = Date()

                if let content = content {
                    if content.count > 4 {
                        let body = content.subdata(in: 4..<content.count)
                        if let event = try? JSONDecoder().decode(InputEvent.self, from: body) {
                            if event.type == .command && event.keyCode == 888 {
                                // Heartbeat - ignore
                            } else if event.type == .command && event.keyCode == 999 {
                                self?.pipelines[connectionId]?.videoEncoder?.forceKeyframe()
                            } else if event.type == .command && event.keyCode == 777 {
                                self?.handleScreenInfo(for: connectionId, width: Int(event.deltaX), height: Int(event.deltaY))
                            } else if self?.isDuplicateEvent(event.eventId) == false {
                                InputHandler.shared.handle(event: event, for: connectionId)
                            }
                        }
                    }
                }
            }
            self?.receiveUDP(on: connection, connectionId: connectionId)
        }
    }

    // Handle screen info from iOS receiver (command 777)
    // Receiver reports its native screen dimensions so we can match the aspect ratio
    private func handleScreenInfo(for connectionId: UUID, width: Int, height: Int) {
        guard width > 0 && height > 0 else { return }
        guard let pipeline = pipelines[connectionId] else { return }

        let serviceName = pipeline.service.name

        // Command 777 is sent by iOS/Mac Swift receivers to report screen dimensions.
        // These receivers now support type-byte framing (auto-detect), so keep supportsTypeByte = true.
        LogManager.shared.log("Sender: Screen info (command 777) from \(serviceName)")

        let oldW = pipeline.reportedScreenWidth
        let oldH = pipeline.reportedScreenHeight

        // Skip if dimensions haven't changed
        if oldW == width && oldH == height { return }

        pipelines[connectionId]?.reportedScreenWidth = width
        pipelines[connectionId]?.reportedScreenHeight = height
        LogManager.shared.log("Sender: Screen info from \(serviceName): \(width)x\(height)")

        // Restart pipeline with new dimensions
        stopPipeline(for: connectionId)
        startPipeline(for: connectionId)
    }

    private func stopPipeline(for connectionId: UUID) {
        pipelines[connectionId]?.screenRecorder?.stopCapture()
        pipelines[connectionId]?.screenRecorder = nil
        pipelines[connectionId]?.videoEncoder = nil
        pipelines[connectionId]?.audioEncoder = nil
        if let dm = pipelines[connectionId]?.virtualDisplayManager {
            dm.destroyDisplay()
            pipelines[connectionId]?.virtualDisplayManager = nil
        }
    }

    private func virtualDisplayResolution(for connectionId: UUID) -> VirtualDisplayManager.Resolution {
        let pipeline = pipelines[connectionId]
        let settings = pipeline?.settings ?? currentReceiverSettings()
        let serviceName = pipeline?.service.name ?? "unknown"
        let width = pipeline?.reportedScreenWidth.flatMap { $0 > 0 ? $0 : nil } ?? settings.resolutionWidth
        let height = pipeline?.reportedScreenHeight.flatMap { $0 > 0 ? $0 : nil } ?? settings.resolutionHeight
        // High physical PPI can make macOS retain a 2x backing scale even when
        // CGVirtualDisplaySettings.hiDPI is disabled. Advertise standard DPI for
        // non-Retina modes so the requested 1x logical mode is selected.
        let descriptorPPI = settings.retinaEnabled
            ? settings.resolutionPPI
            : min(settings.resolutionPPI, 110)

        return VirtualDisplayManager.Resolution(
            width: width,
            height: height,
            ppi: descriptorPPI,
            hiDPI: settings.retinaEnabled,
            name: "ExtendCast Display (\(serviceName))"
        )
    }

    func startPipeline(for connectionId: UUID) {
        guard let pipelineSettings = pipelines[connectionId]?.settings else { return }

        let serviceName = pipelines[connectionId]?.service.name ?? "unknown"
        LogManager.shared.log("Sender: Starting pipeline for \(serviceName)...")

        var targetDisplayID: CGDirectDisplayID? = nil

        // Create virtual display if enabled
        if pipelineSettings.useVirtualDisplay {
            let resolution = virtualDisplayResolution(for: connectionId)

            if let displayManager = pipelines[connectionId]?.virtualDisplayManager,
               let displayID = displayManager.displayID {
                targetDisplayID = displayID
                LogManager.shared.log("Sender: Reusing virtual display for \(serviceName) with ID \(displayID)")
            } else {
                LogManager.shared.log("Sender: Creating virtual display for \(serviceName)...")
                // Keep one stable macOS display identity per density mode.
                // This prevents macOS from restoring a cached 1x/2x mode from
                // the other setting while preserving layout within each mode.
                let densityIdentity = resolution.hiDPI ? "retina" : "standard"
                let receiverIdentity = pipelines[connectionId]
                    .map { receiverProfileKey(for: $0.service) }
                    ?? "name:unknown"
                let displayManager = VirtualDisplayManager(
                    identity: "\(receiverIdentity)|\(densityIdentity)"
                )
                if let displayID = displayManager.createDisplay(
                    resolution: resolution,
                    refreshRate: pipelineSettings.fps
                ) {
                    targetDisplayID = displayID
                    pipelines[connectionId]?.virtualDisplayManager = displayManager
                    LogManager.shared.log("Sender: Virtual display created for \(serviceName) with ID \(displayID)")
                    LogManager.shared.log("Sender: Go to System Settings > Displays to arrange it")
                } else {
                    LogManager.shared.log(
                        "Sender: Failed to create virtual display for \(serviceName); " +
                        "pipeline stopped to avoid streaming the main screen"
                    )
                    status = "Virtual display unavailable for \(serviceName)"
                    return
                }
            }

            // Update InputHandler with this connection's display bounds.
            if let displayID = targetDisplayID {
                func pollDisplayBounds(attempt: Int) {
                    let bounds = CGDisplayBounds(displayID)
                    if bounds.width > 0 && bounds.height > 0 {
                        let displayManager = self.pipelines[connectionId]?.virtualDisplayManager
                        displayManager?.selectRequestedMode()
                        let selectedBounds = CGDisplayBounds(displayID)
                        InputHandler.shared.updateDisplayBounds(bounds: selectedBounds, for: connectionId)
                        LogManager.shared.log("Sender: Virtual display for \(serviceName) bounds: \(selectedBounds) (attempt \(attempt))")
                        displayManager?.logCurrentMode()
                        self.updateConnectedDisplays()
                    } else if attempt < 10 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + Double(attempt) * 0.5) {
                            pollDisplayBounds(attempt: attempt + 1)
                        }
                    } else {
                        let fallbackBounds = CGRect(
                            x: 0,
                            y: 0,
                            width: resolution.width,
                            height: resolution.height
                        )
                        InputHandler.shared.updateDisplayBounds(bounds: fallbackBounds, for: connectionId)
                        LogManager.shared.log("Sender: Virtual display bounds unavailable after retries, using fallback: \(fallbackBounds)")
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    pollDisplayBounds(attempt: 1)
                }
            }
        } else {
            LogManager.shared.log("Sender: Using main screen (mirroring mode) for \(serviceName)")
        }

        // Calculate Physical Capture Resolution
        // Use reported screen dimensions if available (already in pixels)
        let captureWidth: Int
        let captureHeight: Int
        if let rw = pipelines[connectionId]?.reportedScreenWidth,
           let rh = pipelines[connectionId]?.reportedScreenHeight, rw > 0 && rh > 0 {
            captureWidth = rw
            captureHeight = rh
        } else {
            captureWidth = pipelineSettings.resolutionWidth
            captureHeight = pipelineSettings.resolutionHeight
        }

        // Adaptive quality: P2P gets full, loopback (ADB) gets medium-high, infrastructure gets capped
        let isP2P = pipelines[connectionId]?.isP2P ?? false
        let isLoopback = pipelines[connectionId]?.isLoopback ?? false
        var fps: Int
        let bitrate: Int
        let keyframeInterval: Double
        if isP2P {
            fps = 60  // AWDL can't sustain 120fps at typical bitrates; 60fps = 2x bits per frame
            bitrate = pipelineSettings.qualityRawValue
            keyframeInterval = 10.0 // P2P is reliable, long interval is fine
        } else if isLoopback {
            let isWiFiADB = pipelines[connectionId]?.isWiFiADB ?? false
            if isWiFiADB {
                // WiFi ADB — receiver queues all frames (no drops), so 60fps is safe.
                // Bitrate capped to fit WiFi bandwidth; shorter KF interval for faster recovery.
                fps = 60
                bitrate = min(pipelineSettings.qualityRawValue, 10_000_000) // Cap at 10 Mbps
                keyframeInterval = 3.0
                LogManager.shared.log("Sender: WiFi ADB mode — \(fps) FPS / \(bitrate / 1_000_000) Mbps / KF every 3s for \(serviceName)")
            } else {
                // USB ADB — ~280Mbps, plenty of headroom
                fps = 60
                bitrate = pipelineSettings.qualityRawValue
                keyframeInterval = 10.0
                LogManager.shared.log("Sender: USB ADB mode — \(fps) FPS / \(bitrate / 1_000_000) Mbps / KF every 10s for \(serviceName)")
            }
        } else {
            // Infrastructure (WiFi router, Windows/Linux receivers)
            // 30 FPS matches actual WiFi throughput — avoids frame drops that cause glitching.
            // Each frame gets 2x bit budget vs 60 FPS = sharper motion.
            fps = 30
            bitrate = pipelineSettings.qualityRawValue  // Use full user-selected bitrate
            keyframeInterval = 2.0  // Short interval for fast error recovery over WiFi
            LogManager.shared.log("Sender: Infrastructure mode — \(fps) FPS / \(bitrate / 1_000_000) Mbps / KF every 2s for \(serviceName)")
        }

        fps = pipelineSettings.fps
        LogManager.shared.log("Sender: Frame rate override \(fps) FPS (user setting)")

        let hasReportedDims = pipelines[connectionId]?.reportedScreenWidth != nil
        let qualityName = StreamQuality(rawValue: pipelineSettings.qualityRawValue)?.name
            ?? "\(pipelineSettings.qualityRawValue / 1_000_000) Mbps"
        LogManager.shared.log("Sender: Pipeline \(serviceName): \(captureWidth)x\(captureHeight)\(hasReportedDims ? " (device)" : "") @ \(qualityName) [\(fps) FPS, P2P: \(isP2P)]")

        // P2P: tight 0.1s rate limit window prevents AWDL buffer bloat
        // Infrastructure: loose 1.0s window lets the encoder handle burst scenes naturally
        let rateLimitWindow: Double = isP2P ? 0.1 : 1.0
        let encoder = VideoEncoder(connectionId: connectionId, width: captureWidth, height: captureHeight, bitrate: bitrate, expectedFPS: fps, keyframeIntervalSeconds: keyframeInterval, rateLimitWindow: rateLimitWindow)
        encoder.delegate = self
        pipelines[connectionId]?.videoEncoder = encoder

        // Audio encoder (if audio streaming enabled for this connection)
        let audioEnabled = connectedDisplays.first(where: { $0.id == connectionId })?.audioEnabled
            ?? pipelineSettings.audioStreamingEnabled
        var audioEnc: AudioEncoder? = nil
        if audioEnabled {
            let ae = AudioEncoder(connectionId: connectionId)
            ae.delegate = self
            pipelines[connectionId]?.audioEncoder = ae
            audioEnc = ae
            LogManager.shared.log("Sender: Audio encoder created for \(serviceName)")
        }

        let recorder = ScreenRecorder(
            videoEncoder: encoder,
            targetDisplayID: targetDisplayID,
            width: captureWidth,
            height: captureHeight,
            captureFPS: Int32(fps)
        )
        recorder.captureAudio = audioEnabled
        recorder.audioEncoder = audioEnc
        pipelines[connectionId]?.screenRecorder = recorder

        Task {
            await recorder.startCapture()
        }
    }

    // VideoEncoderDelegate - Send to the specific connection that owns this encoder
    private var encodedFrameCount: Int = 0

    private func sendIdentityIfSupported(for connectionId: UUID) {
        guard let pipeline = pipelines[connectionId],
              pipeline.supportsTypeByte else {
            return
        }
        let connectionType = pipeline.settings.connectionType ?? "TCP"
        guard pipeline.forceTCP || connectionType != "UDP" else {
            return
        }

        do {
            let identity = SenderIdentity.load()
            let packet = try SenderIdentity.framedPacket(identity)
            pipeline.connection.send(
                content: packet,
                completion: .contentProcessed { error in
                    if let error {
                        LogManager.shared.log(
                            "Sender: Identity handshake failed for " +
                            "\(pipeline.service.name): \(error)"
                        )
                    }
                }
            )
            LogManager.shared.log(
                "Sender: Sent identity \(identity.deviceName) " +
                "(\(identity.deviceId)) to \(pipeline.service.name)"
            )
        } catch {
            LogManager.shared.log(
                "Sender: Failed to encode identity for " +
                "\(pipeline.service.name): \(error)"
            )
        }
    }

    func videoEncoder(_ encoder: VideoEncoder, didEncode data: Data, for connectionId: UUID, isKeyframe: Bool) {
        guard let pipeline = pipelines[connectionId] else { return }

        encodedFrameCount += 1
        if encodedFrameCount <= 3 || encodedFrameCount % 300 == 0 {
            LogManager.shared.log("Sender: Sending frame #\(encodedFrameCount) (\(data.count) bytes, KF: \(isKeyframe)) to \(pipeline.service.name)")
        }

        // Determine if this connection uses TCP framing (ADB/localhost always TCP, else follow global)
        let pipelineConnectionType = pipeline.settings.connectionType ?? "TCP"
        let useTCP = pipeline.forceTCP || pipelineConnectionType != "UDP"

        if !useTCP {
            let mtu = 1000
            let headerSize = 8
            let maxPayload = mtu - headerSize

            udpFrameId &+= 1
            let thisFrameId = udpFrameId

            let totalData = data
            let totalCount = totalData.count

            bytesSentWindow += totalCount

            let totalChunks = UInt16((totalCount + maxPayload - 1) / maxPayload)

            for chunkIndex in 0..<totalChunks {
                let start = Int(chunkIndex) * maxPayload
                let end = min(start + maxPayload, totalCount)
                let chunkData = totalData.subdata(in: start..<end)

                var header = Data()
                var fid = thisFrameId.bigEndian
                var cid = chunkIndex.bigEndian
                var tot = totalChunks.bigEndian

                header.append(Data(bytes: &fid, count: 4))
                header.append(Data(bytes: &cid, count: 2))
                header.append(Data(bytes: &tot, count: 2))

                var finalPacket = header
                finalPacket.append(chunkData)

                let isLargeFrame = totalChunks > 10
                let pacingMicroseconds: useconds_t = 120

                pipeline.connection.send(content: finalPacket, completion: .contentProcessed { [weak self] error in
                    if let error = error {
                        if case let NWError.posix(code) = error {
                            switch code {
                            case .ECANCELED:
                                LogManager.shared.log("Sender: Connection to \(pipeline.service.name) canceled (Device disconnected)")
                                DispatchQueue.main.async {
                                    self?.removeConnection(connectionId)
                                }
                                return
                            case .ECONNREFUSED:
                                LogManager.shared.log("Sender: Connection refused by \(pipeline.service.name)")
                                return
                            default:
                                break
                            }
                        }
                        LogManager.shared.log("Sender: UDP Chunk Error to \(pipeline.service.name): \(error)")
                    }
                })

                if isLargeFrame && chunkIndex < totalChunks - 1 {
                    usleep(pacingMicroseconds)
                }
            }
        } else {
            // TCP: Length-prefixed framing - Send to this connection only
            var packet = Data()
            if pipeline.supportsTypeByte {
                // Format: [4-byte length][1-byte type: 0x01=video][payload]
                var typedPayload = Data([0x01])
                typedPayload.append(data)
                var lengthPrefix = UInt32(typedPayload.count).bigEndian
                packet.append(Data(bytes: &lengthPrefix, count: 4))
                packet.append(typedPayload)
            } else {
                // Legacy format: [4-byte length][payload] (iOS/Mac Swift receivers)
                var lengthPrefix = UInt32(data.count).bigEndian
                packet.append(Data(bytes: &lengthPrefix, count: 4))
                packet.append(data)
            }

            bytesSentWindow += packet.count

            // Preserve every encoded TCP frame. Dropping a P-frame here would break
            // the H.264 reference chain and cause decoder concealment/ghosting.
            pipeline.connection.send(content: packet, completion: .contentProcessed { error in
                if let error = error {
                    LogManager.shared.log("Sender: TCP Send Error to \(pipeline.service.name): \(error)")
                }
            })
        }
    }

    // AudioEncoderDelegate - Send AAC audio to the specific connection
    func audioEncoder(_ encoder: AudioEncoder, didEncode data: Data, for connectionId: UUID) {
        guard let pipeline = pipelines[connectionId] else { return }

        // Legacy receivers (iOS/Mac Swift) don't support audio — skip
        guard pipeline.supportsTypeByte else { return }

        // Audio always uses TCP framing
        // Format: [4-byte length][1-byte type: 0x02=audio][AAC data]
        var typedPayload = Data([0x02]) // Audio packet type
        typedPayload.append(data)
        var lengthPrefix = UInt32(typedPayload.count).bigEndian
        var packet = Data(bytes: &lengthPrefix, count: 4)
        packet.append(typedPayload)

        bytesSentWindow += packet.count

        pipeline.connection.send(content: packet, completion: .contentProcessed { error in
            if let error = error {
                LogManager.shared.log("Sender: Audio send error to \(pipeline.service.name): \(error)")
            }
        })
    }
}
