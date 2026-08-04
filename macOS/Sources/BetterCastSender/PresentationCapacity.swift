import Foundation

/// Maps user capture intent onto what a receiver can actually present.
/// Desktop soft-decode receivers get a bounded pixel/fps stream envelope so the
/// sender never oversells decode capacity. Hardware-decode receivers keep full
/// capture dimensions. Virtual display size stays full either way; only
/// capture/encode dimensions are limited for soft decode.
enum PresentationCapacity {
    struct Envelope: Equatable {
        var width: Int
        var height: Int
        var fps: Int
        var retinaEnabled: Bool
        var appliedLimit: Bool
        var detail: String
    }

    /// Soft H.264 decode budget for Desktop receivers without hardware decode.
    private static let softDecodeMaxLongEdge = 1920
    private static let softDecodeMaxFPS = 30

    static func isDesktopSoftDecodeReceiver(_ serviceName: String) -> Bool {
        let name = serviceName.lowercased()
        return name.contains("(windows)") || name.contains("(linux)")
    }

    static func bind(
        width: Int,
        height: Int,
        fps: Int,
        retinaEnabled: Bool,
        serviceName: String,
        isP2P: Bool = false,
        isLoopback: Bool = false,
        hardwareDecode: Bool = false
    ) -> Envelope {
        let safeWidth = max(width, 2)
        let safeHeight = max(height, 2)
        let safeFPS = max(fps, 1)

        guard isDesktopSoftDecodeReceiver(serviceName),
              !isP2P,
              !isLoopback,
              !hardwareDecode else {
            return Envelope(
                width: safeWidth,
                height: safeHeight,
                fps: safeFPS,
                retinaEnabled: retinaEnabled,
                appliedLimit: false,
                detail: hardwareDecode ? "hardware-decode capacity" : "full capacity"
            )
        }

        var outWidth = safeWidth
        var outHeight = safeHeight
        // Soft decode cannot sustain HiDPI 2x pixel doubling on desktop receivers.
        let outRetina = false
        let outFPS = min(safeFPS, softDecodeMaxFPS)

        let longEdge = max(outWidth, outHeight)
        if longEdge > softDecodeMaxLongEdge {
            let scale = Double(softDecodeMaxLongEdge) / Double(longEdge)
            outWidth = evenPixel(Int((Double(outWidth) * scale).rounded()))
            outHeight = evenPixel(Int((Double(outHeight) * scale).rounded()))
        }

        let limited =
            outWidth != safeWidth
            || outHeight != safeHeight
            || outFPS != safeFPS
            || outRetina != retinaEnabled

        return Envelope(
            width: outWidth,
            height: outHeight,
            fps: outFPS,
            retinaEnabled: outRetina,
            appliedLimit: limited,
            detail: limited
                ? "soft-decode envelope \(outWidth)x\(outHeight) @ \(outFPS) FPS"
                : "soft-decode within budget"
        )
    }

    private static func evenPixel(_ value: Int) -> Int {
        let clamped = max(value, 2)
        return clamped - (clamped % 2)
    }
}
