import Foundation

struct VideoFramePacketHeader {
    static let size = 25

    let streamID: UInt64
    let presentationTimestampNanoseconds: UInt64

    static func decode(from payload: Data) -> Self? {
        guard payload.count >= size else { return nil }

        func readUInt64(at offset: Int) -> UInt64 {
            payload[offset..<(offset + 8)].reduce(0) {
                ($0 << 8) | UInt64($1)
            }
        }

        return Self(
            streamID: readUInt64(at: 0),
            presentationTimestampNanoseconds: readUInt64(at: 16)
        )
    }
}
