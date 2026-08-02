import XCTest
import UniformTypeIdentifiers
@testable import BetterCastSender

final class SetupPermissionStatusTests: XCTestCase {
    func testSetupIsCompleteOnlyWhenBothPermissionsAreGranted() {
        XCTAssertFalse(SetupPermissionStatus().isComplete)
        XCTAssertFalse(
            SetupPermissionStatus(
                screenRecordingGranted: true,
                accessibilityGranted: false
            ).isComplete
        )
        XCTAssertTrue(
            SetupPermissionStatus(
                screenRecordingGranted: true,
                accessibilityGranted: true
            ).isComplete
        )
    }

    func testCompletedCountMatchesVisibleProgress() {
        XCTAssertEqual(SetupPermissionStatus().completedCount, 0)
        XCTAssertEqual(
            SetupPermissionStatus(
                screenRecordingGranted: true,
                accessibilityGranted: false
            ).completedCount,
            1
        )
        XCTAssertEqual(
            SetupPermissionStatus(
                screenRecordingGranted: true,
                accessibilityGranted: true
            ).completedCount,
            2
        )
    }

    func testApplicationDragSourceProvidesAnAppFileURL() {
        let provider = SetupApplicationDragProvider.make(
            bundleURL: URL(fileURLWithPath: "/Applications/ExtendCast.app")
        )

        XCTAssertTrue(
            provider.hasItemConformingToTypeIdentifier(
                UTType.fileURL.identifier
            )
        )
    }

    func testPrivacyLinksTargetTheInstalledSystemSettingsExtension() {
        XCTAssertEqual(
            PrivacySettingsLink.url(
                for: .screenRecording,
                installedExtensionIdentifier:
                    "com.apple.settings.PrivacySecurity.extension"
            ).absoluteString,
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture"
        )
        XCTAssertEqual(
            PrivacySettingsLink.url(
                for: .accessibility,
                installedExtensionIdentifier:
                    "com.apple.settings.PrivacySecurity.extension"
            ).absoluteString,
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility"
        )
    }

    func testPrivacyLinksFallBackToLegacySystemPreferences() {
        XCTAssertEqual(
            PrivacySettingsLink.url(
                for: .screenRecording,
                installedExtensionIdentifier: nil
            ).absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        )
        XCTAssertEqual(
            PrivacySettingsLink.url(
                for: .accessibility,
                installedExtensionIdentifier: nil
            ).absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        )
    }
}
