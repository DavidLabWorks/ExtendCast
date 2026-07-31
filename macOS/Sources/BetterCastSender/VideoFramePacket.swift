import Foundation

struct VideoTimestampNormalizer {
    private let nominalFrameDurationNanoseconds: UInt64
    private var anchorRawNanoseconds: Int64?
    private var anchorOutputNanoseconds: UInt64 = 0
    private var lastRawNanoseconds: Int64?
    private var lastOutputNanoseconds: UInt64?
    private var shouldReanchorNextRawTimestamp = false

    init(expectedFPS: Int) {
        let framesPerSecond = max(expectedFPS, 1)
        nominalFrameDurationNanoseconds = UInt64(
            (1_000_000_000 + framesPerSecond / 2) / framesPerSecond
        )
    }

    mutating func normalize(rawNanoseconds: Int64?) -> UInt64 {
        guard let rawNanoseconds, rawNanoseconds >= 0 else {
            return advanceByOneFrame()
        }

        guard let previousOutput = lastOutputNanoseconds else {
            anchorRawNanoseconds = rawNanoseconds
            lastRawNanoseconds = rawNanoseconds
            lastOutputNanoseconds = 0
            shouldReanchorNextRawTimestamp = false
            return 0
        }

        if shouldReanchorNextRawTimestamp
            || lastRawNanoseconds.map({ rawNanoseconds < $0 }) == true {
            anchorRawNanoseconds = rawNanoseconds
            anchorOutputNanoseconds = addingWithoutOverflow(
                previousOutput,
                nominalFrameDurationNanoseconds
            )
            shouldReanchorNextRawTimestamp = false
        }

        let rawDelta = rawNanoseconds - (anchorRawNanoseconds ?? rawNanoseconds)
        var output = addingWithoutOverflow(
            anchorOutputNanoseconds,
            UInt64(max(rawDelta, 0))
        )
        if output <= previousOutput {
            output = addingWithoutOverflow(previousOutput, 1)
        }

        lastRawNanoseconds = rawNanoseconds
        lastOutputNanoseconds = output
        return output
    }

    private mutating func advanceByOneFrame() -> UInt64 {
        guard let previousOutput = lastOutputNanoseconds else {
            lastOutputNanoseconds = 0
            shouldReanchorNextRawTimestamp = true
            return 0
        }
        let output = addingWithoutOverflow(
            previousOutput,
            nominalFrameDurationNanoseconds
        )
        lastOutputNanoseconds = output
        shouldReanchorNextRawTimestamp = true
        return output
    }

    private func addingWithoutOverflow(
        _ lhs: UInt64,
        _ rhs: UInt64
    ) -> UInt64 {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? UInt64.max : value
    }
}

struct VideoFramePacketHeader {
    let streamID: UInt64
    let sequence: UInt64
    let presentationTimestampNanoseconds: UInt64
    let isKeyframe: Bool

    static func decode(from payload: Data) -> Self? {
        guard payload.count >= EncodedVideoFrame.headerSize else {
            return nil
        }

        func readUInt64(at offset: Int) -> UInt64 {
            payload[offset..<(offset + 8)].reduce(0) {
                ($0 << 8) | UInt64($1)
            }
        }

        return Self(
            streamID: readUInt64(at: 0),
            sequence: readUInt64(at: 8),
            presentationTimestampNanoseconds: readUInt64(at: 16),
            isKeyframe:
                payload[24] & EncodedVideoFrame.keyframeFlag != 0
        )
    }
}

struct EncodedVideoFrame {
    static let headerSize = 25
    static let keyframeFlag: UInt8 = 0x01

    let streamID: UInt64
    let sequence: UInt64
    let presentationTimestampNanoseconds: UInt64
    let isKeyframe: Bool
    let avccData: Data

    var wirePayload: Data {
        var payload = Data(capacity: Self.headerSize + avccData.count)
        var streamID = streamID.bigEndian
        var sequence = sequence.bigEndian
        var timestamp = presentationTimestampNanoseconds.bigEndian
        payload.append(Data(bytes: &streamID, count: MemoryLayout.size(ofValue: streamID)))
        payload.append(Data(bytes: &sequence, count: MemoryLayout.size(ofValue: sequence)))
        payload.append(Data(bytes: &timestamp, count: MemoryLayout.size(ofValue: timestamp)))
        payload.append(isKeyframe ? Self.keyframeFlag : 0)
        payload.append(avccData)
        return payload
    }
}
