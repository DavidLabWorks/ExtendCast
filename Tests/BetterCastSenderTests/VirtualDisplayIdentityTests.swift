import XCTest
@testable import BetterCastSender

final class VirtualDisplayIdentityTests: XCTestCase {
    func testLegacyBundleIdentityWinsDuringMigration() {
        let legacyMappings: [[String: UInt32]] = [
            [
                "169.254.204.111:51820|standard": 4,
                "169.254.204.111:51820|retina": 3,
            ],
            [
                "169.254.204.111:51820|standard": 1,
                "169.254.204.111:51820|retina": 2,
            ],
        ]

        XCTAssertEqual(
            VirtualDisplayIdentity.serialNumber(
                for: "host:169.254.204.111:51820|standard",
                legacyMappings: legacyMappings
            ),
            4
        )
        XCTAssertEqual(
            VirtualDisplayIdentity.serialNumber(
                for: "service:169.254.204.111:51820|retina",
                legacyMappings: legacyMappings
            ),
            3
        )
    }

    func testSerialNumberIsStableForKnownReceiverIdentity() {
        XCTAssertEqual(
            VirtualDisplayIdentity.serialNumber(
                for: "169.254.204.111:51820|standard",
                legacyMappings: []
            ),
            1_224_158_631
        )
        XCTAssertEqual(
            VirtualDisplayIdentity.serialNumber(
                for: "169.254.204.111:51820|retina",
                legacyMappings: []
            ),
            2_192_175_573
        )
    }

    func testDensityModesHaveDifferentDisplayIdentities() {
        let standard = VirtualDisplayIdentity.serialNumber(
            for: "receiver.example|standard",
            legacyMappings: []
        )
        let retina = VirtualDisplayIdentity.serialNumber(
            for: "receiver.example|retina",
            legacyMappings: []
        )

        XCTAssertNotEqual(standard, retina)
    }

    func testDiscoveryPrefixesShareOneDisplayIdentity() {
        let identities = [
            "169.254.204.111:51820|standard",
            "host:169.254.204.111:51820|standard",
            "service:169.254.204.111:51820|standard",
            "name:169.254.204.111:51820|standard",
        ]

        XCTAssertEqual(
            Set(identities.map {
                VirtualDisplayIdentity.serialNumber(for: $0, legacyMappings: [])
            }).count,
            1
        )
    }

    func testCanonicalLegacyKeyWinsOverPrefixedAliases() {
        XCTAssertEqual(
            VirtualDisplayIdentity.serialNumber(
                for: "service:receiver.example|standard",
                legacyMappings: [[
                    "service:receiver.example|standard": 9,
                    "host:receiver.example|standard": 8,
                    "receiver.example|standard": 7,
                ]]
            ),
            7
        )
    }

    func testCanonicalMappingSurvivesLegacyPreferencesRemoval() {
        XCTAssertEqual(
            VirtualDisplayIdentity.serialNumber(
                for: "host:169.254.204.111:51820|standard",
                canonicalMapping: [
                    "169.254.204.111:51820|standard": 4,
                ],
                legacyMappings: []
            ),
            4
        )
    }

    func testSystemDuplicateSuffixDoesNotCreateAnotherIdentity() {
        let original = VirtualDisplayIdentity.serialNumber(
            for: "Receiver|standard",
            legacyMappings: []
        )
        let duplicate = VirtualDisplayIdentity.serialNumber(
            for: "Receiver (2)|standard",
            legacyMappings: []
        )

        XCTAssertEqual(original, duplicate)
    }
}
