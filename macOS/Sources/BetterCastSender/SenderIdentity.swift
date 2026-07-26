import Foundation

enum SenderIdentity {
    static let packetType: UInt8 = 0x03
    private static let deviceIDDefaultsKey = "senderStableDeviceID"

    struct Payload: Codable, Equatable {
        let protocolVersion: Int
        let deviceId: String
        let deviceName: String
    }

    static func load(
        defaults: UserDefaults = .standard,
        deviceName: String = Host.current().localizedName
            ?? ProcessInfo.processInfo.hostName
    ) -> Payload {
        let deviceId: String
        if let saved = defaults.string(forKey: deviceIDDefaultsKey),
           UUID(uuidString: saved) != nil {
            deviceId = saved
        } else {
            deviceId = UUID().uuidString.lowercased()
            defaults.set(deviceId, forKey: deviceIDDefaultsKey)
        }

        return Payload(
            protocolVersion: 1,
            deviceId: deviceId,
            deviceName: deviceName
        )
    }

    static func framedPacket(_ payload: Payload) throws -> Data {
        let json = try JSONEncoder().encode(payload)
        var typedBody = Data([packetType])
        typedBody.append(json)

        var length = UInt32(typedBody.count).bigEndian
        var packet = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        packet.append(typedBody)
        return packet
    }
}
