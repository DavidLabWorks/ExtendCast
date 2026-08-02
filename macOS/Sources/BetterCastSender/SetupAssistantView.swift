import AppKit
import ApplicationServices
import CoreGraphics
import SwiftUI

enum SetupApplicationDragProvider {
    static func make(
        bundleURL: URL = Bundle.main.bundleURL
    ) -> NSItemProvider {
        NSItemProvider(object: bundleURL as NSURL)
    }
}

struct SetupPermissionStatus: Equatable {
    var screenRecordingGranted = false
    var accessibilityGranted = false

    var completedCount: Int {
        [screenRecordingGranted, accessibilityGranted].filter { $0 }.count
    }

    var isComplete: Bool {
        screenRecordingGranted && accessibilityGranted
    }
}

struct SetupAssistantView: View {
    let onComplete: () -> Void

    @State private var status = SetupPermissionStatus()

    private let appIcon = NSWorkspace.shared.icon(
        forFile: Bundle.main.bundlePath
    )

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            VStack(spacing: 16) {
                GroupBox {
                    VStack(spacing: 0) {
                        SetupPermissionRow(
                            step: 1,
                            title: "Screen Recording",
                            detail: "Captures the display you choose and sends it to your receiver.",
                            isGranted: status.screenRecordingGranted,
                            action: openScreenRecordingSettings
                        )

                        Divider()
                            .padding(.leading, 54)

                        SetupPermissionRow(
                            step: 2,
                            title: "Accessibility",
                            detail: "Relays mouse and keyboard input from the receiver back to this Mac.",
                            isGranted: status.accessibilityGranted,
                            action: openAccessibilitySettings
                        )
                    }
                } label: {
                    Label("Permissions", systemImage: "hand.raised")
                }

                if status.isComplete {
                    Label(
                        "ExtendCast is ready to capture and receive input.",
                        systemImage: "checkmark.circle.fill"
                    )
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.green)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        Color.green.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 8)
                    )
                    .transition(.opacity.combined(with: .move(edge: .top)))
                } else {
                    SetupApplicationDragSource(appIcon: appIcon)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)

            Spacer(minLength: 0)

            Divider()
            footer
        }
        .frame(minWidth: 620, idealWidth: 660, minHeight: 480)
        .background(Color(nsColor: .windowBackgroundColor))
        .animation(.easeInOut(duration: 0.2), value: status)
        .task {
            refreshPermissionStatus()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 750_000_000)
                guard !Task.isCancelled else { return }
                refreshPermissionStatus()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: appIcon)
                .resizable()
                .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 4) {
                Text("Set Up ExtendCast")
                    .font(.title2.weight(.semibold))

                Text("Grant two permissions to enable display streaming and remote input.")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 24)

            VStack(alignment: .trailing, spacing: 7) {
                Text("\(status.completedCount) of 2 ready")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ProgressView(
                    value: Double(status.completedCount),
                    total: 2
                )
                .controlSize(.small)
                .frame(width: 112)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text("Permission changes are detected automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            if !status.isComplete {
                Button("Set Up Later") {
                    onComplete()
                }
                .keyboardShortcut(.cancelAction)

                Button("Check Again") {
                    refreshPermissionStatus()
                }
                .keyboardShortcut(.defaultAction)
            } else {
                Button("Continue") {
                    onComplete()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func refreshPermissionStatus() {
        status = SetupPermissionStatus(
            screenRecordingGranted: CGPreflightScreenCaptureAccess(),
            accessibilityGranted: AXIsProcessTrusted()
        )
    }

    private func openScreenRecordingSettings() {
        PrivacySettingsLink.open(.screenRecording)
    }

    private func openAccessibilitySettings() {
        PrivacySettingsLink.open(.accessibility)
    }
}

private struct SetupPermissionRow: View {
    let step: Int
    let title: String
    let detail: String
    let isGranted: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(
                        isGranted
                            ? Color.green
                            : Color.accentColor.opacity(0.12)
                    )

                if isGranted {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                } else {
                    Text("\(step)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tint)
                }
            }
            .frame(width: 26, height: 26)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body.weight(.medium))

                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 16)

            if isGranted {
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.green)
            } else {
                VStack(alignment: .trailing, spacing: 6) {
                    Label("Not Granted", systemImage: "exclamationmark.circle")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)

                    Button("Open Settings", action: action)
                        .controlSize(.regular)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}

private struct SetupApplicationDragSource: View {
    let appIcon: NSImage

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Add ExtendCast directly")
                    .font(.system(size: 13, weight: .medium))

                Text("Open a permission page, then drag ExtendCast into its app list.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Image(nsImage: appIcon)
                    .resizable()
                    .frame(width: 24, height: 24)

                Text("Drag ExtendCast to System Settings")
                    .font(.caption.weight(.medium))

                Spacer()

                Image(systemName: "arrow.up.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                Color.accentColor.opacity(0.07),
                in: RoundedRectangle(cornerRadius: 7)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .stroke(
                        Color.accentColor.opacity(0.55),
                        style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                    )
            }
            .contentShape(Rectangle())
            .onDrag {
                SetupApplicationDragProvider.make()
            }
            .help("Drag the ExtendCast app into the open privacy settings list.")
            .accessibilityLabel(
                "Drag the ExtendCast app into the open privacy settings list"
            )
        }
        .padding(14)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 8)
        )
    }
}
