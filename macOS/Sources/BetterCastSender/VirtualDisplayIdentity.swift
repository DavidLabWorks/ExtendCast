import Foundation

/// Produces a stable virtual-display identity and migrates legacy bundle-scoped
/// mappings into a dedicated suite that survives future application renames.
enum VirtualDisplayIdentity {
    private static let namespace = "extendcast-v1"
    private static let serialNumbersDefaultsKey = "virtualDisplaySerialNumbers"
    private static let canonicalSuiteName = "com.extendcast.virtual-display-identities"
    private static let legacyBundleIdentifiers = [
        "com.bettercast.sender",
        "com.extendcast.app",
    ]
    private static let migrationLock = NSLock()

    static func serialNumber(for identity: String) -> UInt32 {
        migrationLock.lock()
        defer { migrationLock.unlock() }

        var canonicalMapping = storedMapping(in: canonicalSuiteName)
        let serialNumber = serialNumber(
            for: identity,
            canonicalMapping: canonicalMapping,
            legacyMappings: storedLegacyMappings()
        )
        let normalizedIdentity = normalize(identity)

        if canonicalMapping[normalizedIdentity] != serialNumber {
            canonicalMapping[normalizedIdentity] = serialNumber
            storeCanonicalMapping(canonicalMapping)
        }

        return serialNumber
    }

    static func serialNumber(
        for identity: String,
        canonicalMapping: [String: UInt32] = [:],
        legacyMappings: [[String: UInt32]]
    ) -> UInt32 {
        let normalizedIdentity = normalize(identity)

        for mapping in [canonicalMapping] + legacyMappings {
            if let serialNumber = serialNumber(
                in: mapping,
                matching: normalizedIdentity
            ) {
                return serialNumber
            }
        }

        var hash: UInt32 = 2_166_136_261

        for byte in "\(namespace)|\(normalizedIdentity)".utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }

        // CoreGraphics expects a non-zero display serial number.
        return hash == 0 ? 1 : hash
    }

    private static func storedMapping(in suiteName: String) -> [String: UInt32] {
        guard let values = UserDefaults(suiteName: suiteName)?
            .dictionary(forKey: serialNumbersDefaultsKey) else {
            return [:]
        }

        return values.reduce(into: [String: UInt32]()) { result, entry in
            if let number = entry.value as? NSNumber {
                result[entry.key] = number.uint32Value
            }
        }
    }

    private static func storeCanonicalMapping(_ mapping: [String: UInt32]) {
        let storedValues = mapping.mapValues { NSNumber(value: $0) }
        UserDefaults(suiteName: canonicalSuiteName)?
            .set(storedValues, forKey: serialNumbersDefaultsKey)
    }

    private static func serialNumber(
        in mapping: [String: UInt32],
        matching normalizedIdentity: String
    ) -> UInt32? {
        mapping
            .filter { $0.value != 0 && normalize($0.key) == normalizedIdentity }
            .sorted {
                let left = discoveryPrefixPriority($0.key)
                let right = discoveryPrefixPriority($1.key)
                if left != right {
                    return left < right
                }
                return $0.key.localizedStandardCompare($1.key) == .orderedAscending
            }
            .first?
            .value
    }

    private static func discoveryPrefixPriority(_ identity: String) -> Int {
        let value = identity
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if value.hasPrefix("host:") { return 1 }
        if value.hasPrefix("service:") { return 2 }
        if value.hasPrefix("name:") { return 3 }
        return 0
    }

    private static func storedLegacyMappings() -> [[String: UInt32]] {
        legacyBundleIdentifiers.map(storedMapping(in:))
    }

    private static func normalize(_ identity: String) -> String {
        let normalized = identity
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let components = normalized.split(
            separator: "|",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )

        guard components.count == 2 else {
            return normalizeReceiverKey(normalized)
        }

        return "\(normalizeReceiverKey(String(components[0])))|\(components[1])"
    }

    private static func normalizeReceiverKey(_ value: String) -> String {
        let withoutDiscoveryPrefix = value.replacingOccurrences(
            of: #"^(host|service|name):"#,
            with: "",
            options: .regularExpression
        )
        return removingSystemDuplicateSuffix(from: withoutDiscoveryPrefix)
    }

    private static func removingSystemDuplicateSuffix(from value: String) -> String {
        value.replacingOccurrences(
            of: #" \(\d+\)$"#,
            with: "",
            options: .regularExpression
        )
    }
}
