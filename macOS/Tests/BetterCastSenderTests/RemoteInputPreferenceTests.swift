import XCTest
@testable import BetterCastSender

final class RemoteInputPreferenceTests: XCTestCase {
    func testMissingRemoteInputDefaultsToDisabled() throws {
        let json = """
        {
          "resolutionWidth": 1920,
          "resolutionHeight": 1080,
          "resolutionPPI": 110,
          "resolutionName": "1080p",
          "retinaEnabled": false,
          "qualityRawValue": 2,
          "fps": 60,
          "useVirtualDisplay": true,
          "audioStreamingEnabled": true
        }
        """.data(using: .utf8)!

        let settings = try JSONDecoder().decode(ReceiverSettings.self, from: json)
        XCTAssertNil(settings.remoteInputEnabled)
        XCTAssertFalse(settings.allowsRemoteInput)
    }

    func testExplicitRemoteInputEnabled() throws {
        let json = """
        {
          "resolutionWidth": 1920,
          "resolutionHeight": 1080,
          "resolutionPPI": 110,
          "resolutionName": "1080p",
          "retinaEnabled": false,
          "qualityRawValue": 2,
          "fps": 60,
          "useVirtualDisplay": true,
          "audioStreamingEnabled": true,
          "remoteInputEnabled": true
        }
        """.data(using: .utf8)!

        let settings = try JSONDecoder().decode(ReceiverSettings.self, from: json)
        XCTAssertEqual(settings.remoteInputEnabled, true)
        XCTAssertTrue(settings.allowsRemoteInput)
    }
}
