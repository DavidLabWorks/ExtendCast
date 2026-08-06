import Foundation

/// Helpers for treating a receiver's native panel size as device info
/// (separate from the virtual-display Dimensions picker).
enum DeviceNativeResolution {
    static let fallbackPPI = 110

    /// Virtual displays require even pixel dimensions.
    static func normalizedPixelSize(width: Int, height: Int) -> (width: Int, height: Int)? {
        guard width > 0, height > 0 else { return nil }
        let evenWidth = width - (width % 2)
        let evenHeight = height - (height % 2)
        guard evenWidth >= 640, evenHeight >= 480 else { return nil }
        return (evenWidth, evenHeight)
    }

    /// Derive PPI from panel pixels + physical size in millimetres.
    /// Falls back to `fallbackPPI` when physical size is missing or implausible.
    static func suggestedPPI(
        pixelWidth: Int,
        pixelHeight: Int,
        physicalWidthMM: Double?,
        physicalHeightMM: Double?,
        fallback: Int = fallbackPPI
    ) -> Int {
        guard let physicalWidthMM,
              let physicalHeightMM,
              physicalWidthMM > 1,
              physicalHeightMM > 1,
              pixelWidth > 0,
              pixelHeight > 0 else {
            return clampedPPI(fallback)
        }

        let diagonalInches = hypot(physicalWidthMM, physicalHeightMM) / 25.4
        guard diagonalInches > 1 else { return clampedPPI(fallback) }

        let pixelDiagonal = hypot(Double(pixelWidth), Double(pixelHeight))
        let ppi = Int((pixelDiagonal / diagonalInches).rounded())
        return clampedPPI(ppi)
    }

    static func matchesAvailableResolution(
        width: Int,
        height: Int,
        available: [(width: Int, height: Int)]
    ) -> Bool {
        available.contains { $0.width == width && $0.height == height }
    }

    static func displayLabel(width: Int, height: Int) -> String {
        "\(width) × \(height)"
    }

    static func clampedPPI(_ ppi: Int) -> Int {
        min(500, max(72, ppi))
    }
}
