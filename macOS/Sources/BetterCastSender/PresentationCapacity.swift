import Foundation

/// Maps user capture intent onto what a receiver can actually present.
/// Desktop soft-decode receivers get a bounded pixel/fps stream envelope so the
/// sender never oversells decode capacity. Hardware-decode receivers keep the
/// user's resolution / Retina / FPS — present-path headroom is the user's FPS
/// knob until zero-copy present ships. Virtual display size stays full either
/// way; only soft-decode capture/encode dimensions are limited.
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
        hardwareDecode: Bool = false,
        zeroCopyPresent: Bool = false
    ) -> Envelope {
        let safeWidth = max(width, 2)
        let safeHeight = max(height, 2)
        let safeFPS = max(fps, 1)

        guard isDesktopSoftDecodeReceiver(serviceName),
              !isP2P,
              !isLoopback else {
            return Envelope(
                width: safeWidth,
                height: safeHeight,
                fps: safeFPS,
                retinaEnabled: retinaEnabled,
                appliedLimit: false,
                detail: "full capacity"
            )
        }

        if hardwareDecode {
            // Keep user clarity (resolution / Retina) and FPS. Soft present may
            // stutter at high FPS — that is intentional: the user owns that knob.
            let detail = zeroCopyPresent
                ? "hardware-decode zero-copy capacity"
                : "hardware-decode software-present (user fps)"
            return Envelope(
                width: safeWidth,
                height: safeHeight,
                fps: safeFPS,
                retinaEnabled: retinaEnabled,
                appliedLimit: false,
                detail: detail
            )
        }

        return limitedEnvelope(
            width: safeWidth,
            height: safeHeight,
            fps: safeFPS,
            retinaEnabled: retinaEnabled,
            maxLongEdge: softDecodeMaxLongEdge,
            maxFPS: softDecodeMaxFPS,
            limitedDetailPrefix: "soft-decode envelope",
            withinBudgetDetail: "soft-decode within budget"
        )
    }

    private static func limitedEnvelope(
        width: Int,
        height: Int,
        fps: Int,
        retinaEnabled: Bool,
        maxLongEdge: Int,
        maxFPS: Int,
        limitedDetailPrefix: String,
        withinBudgetDetail: String
    ) -> Envelope {
        var outWidth = width
        var outHeight = height
        // Soft/present-bound paths cannot sustain HiDPI 2x pixel doubling.
        let outRetina = false
        let outFPS = min(fps, maxFPS)

        let longEdge = max(outWidth, outHeight)
        if longEdge > maxLongEdge {
            let scale = Double(maxLongEdge) / Double(longEdge)
            outWidth = evenPixel(Int((Double(outWidth) * scale).rounded()))
            outHeight = evenPixel(Int((Double(outHeight) * scale).rounded()))
        }

        let limited =
            outWidth != width
            || outHeight != height
            || outFPS != fps
            || outRetina != retinaEnabled

        return Envelope(
            width: outWidth,
            height: outHeight,
            fps: outFPS,
            retinaEnabled: outRetina,
            appliedLimit: limited,
            detail: limited
                ? "\(limitedDetailPrefix) \(outWidth)x\(outHeight) @ \(outFPS) FPS"
                : withinBudgetDetail
        )
    }

    private static func evenPixel(_ value: Int) -> Int {
        let clamped = max(value, 2)
        return clamped - (clamped % 2)
    }
}
