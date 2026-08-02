import AppKit

enum PrivacySettingsPane: String {
    case screenRecording = "Privacy_ScreenCapture"
    case accessibility = "Privacy_Accessibility"
}

enum PrivacySettingsLink {
    private static let legacyPaneIdentifier = "com.apple.preference.security"
    private static let privacyExtensionURL = URL(
        fileURLWithPath:
            "/System/Library/ExtensionKit/Extensions/SecurityPrivacyExtension.appex"
    )

    private static var installedPrivacyExtensionIdentifier: String? {
        Bundle(url: privacyExtensionURL)?.bundleIdentifier
    }

    static func url(
        for pane: PrivacySettingsPane,
        installedExtensionIdentifier: String? = installedPrivacyExtensionIdentifier
    ) -> URL {
        let paneIdentifier = installedExtensionIdentifier
            ?? legacyPaneIdentifier
        return URL(
            string: "x-apple.systempreferences:\(paneIdentifier)?\(pane.rawValue)"
        )!
    }

    @discardableResult
    static func open(_ pane: PrivacySettingsPane) -> Bool {
        NSWorkspace.shared.open(url(for: pane))
    }
}
