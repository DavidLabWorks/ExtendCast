import Foundation
import CoreGraphics
import VirtualDisplayLib

/// Swift wrapper for the Objective-C VirtualDisplay functionality
/// Uses private CoreGraphics APIs to create virtual displays
class VirtualDisplayManager {
    
    struct Resolution: Codable, Hashable {
        let width: Int
        let height: Int
        let ppi: Int
        let hiDPI: Bool
        let name: String
    }
    
    static let defaultResolutions: [Resolution] = [
        Resolution(width: 1280, height: 720, ppi: 92, hiDPI: false, name: "1280 x 720 (HD)"),
        Resolution(width: 1920, height: 1080, ppi: 102, hiDPI: false, name: "1920 x 1080 (FHD)"),
        Resolution(width: 1920, height: 1200, ppi: 113, hiDPI: false, name: "1920 x 1200 (16:10)"),
        Resolution(width: 2560, height: 1440, ppi: 109, hiDPI: false, name: "2560 x 1440 (2K)"),
        Resolution(width: 2560, height: 1600, ppi: 227, hiDPI: true, name: "2560 x 1600 (16:10)"),
        Resolution(width: 3840, height: 2160, ppi: 163, hiDPI: false, name: "3840 x 2160 (4K)"),
        Resolution(width: 1440, height: 900, ppi: 127, hiDPI: false, name: "1440 x 900 (16:10)"),
    ]
    
    private static let serialNumbersDefaultsKey = "virtualDisplaySerialNumbers"

    private var activeDisplay: Any?
    private(set) var displayID: CGDirectDisplayID?
    private(set) var activeResolution: Resolution?
    private(set) var activeRefreshRate: Int?
    private let serialNum: UInt32
    private var didSelectRequestedMode = false
    private var colorSyncWorkaroundTask: DispatchWorkItem?
    private var isUsingColorSyncWorkaround = false

    init(identity: String) {
        self.serialNum = Self.persistentSerialNumber(for: identity)
    }

    private func scheduleColorSyncWorkaround() {
        colorSyncWorkaroundTask?.cancel()

        let task = DispatchWorkItem { [weak self] in
            guard let self, self.activeDisplay != nil, self.displayID != nil else { return }
            ColorSyncWorkaround.shared.acquire()
            self.isUsingColorSyncWorkaround = true
        }
        colorSyncWorkaroundTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: task)
    }

    private func releaseColorSyncWorkaround() {
        colorSyncWorkaroundTask?.cancel()
        colorSyncWorkaroundTask = nil

        guard isUsingColorSyncWorkaround else { return }
        isUsingColorSyncWorkaround = false
        ColorSyncWorkaround.shared.release()
    }

    private static func persistentSerialNumber(for identity: String) -> UInt32 {
        let normalizedIdentity = identity
            .replacingOccurrences(of: #" \(\d+\)$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let defaults = UserDefaults.standard
        let storedValues = defaults.dictionary(forKey: serialNumbersDefaultsKey) ?? [:]

        if let storedNumber = storedValues[normalizedIdentity] as? NSNumber {
            return storedNumber.uint32Value
        }

        let usedSerialNumbers = Set(storedValues.values.compactMap { ($0 as? NSNumber)?.uint32Value })
        var serialNumber: UInt32 = 1
        while usedSerialNumbers.contains(serialNumber) {
            serialNumber += 1
        }

        var updatedValues = storedValues
        updatedValues[normalizedIdentity] = NSNumber(value: serialNumber)
        defaults.set(updatedValues, forKey: serialNumbersDefaultsKey)
        return serialNumber
    }
    
    /// Creates a virtual display with the specified resolution
    /// - Returns: The CGDirectDisplayID of the created virtual display, or nil if creation failed
    func createDisplay(resolution: Resolution, refreshRate: Int) -> CGDirectDisplayID? {
        return createDisplay(
            width: resolution.width,
            height: resolution.height,
            ppi: resolution.ppi,
            hiDPI: resolution.hiDPI,
            name: resolution.name,
            refreshRate: refreshRate
        )
    }
    
    /// Creates a virtual display with custom parameters
    func createDisplay(width: Int, height: Int, ppi: Int, hiDPI: Bool, name: String, refreshRate: Int) -> CGDirectDisplayID? {
        LogManager.shared.log(
            "VirtualDisplayManager: Requesting \(width)x\(height) @ \(refreshRate)Hz, HiDPI=\(hiDPI), descriptorPPI=\(ppi)"
        )

        // Call the Objective-C function
        guard let display = createVirtualDisplay(
            Int32(width),
            Int32(height),
            Int32(ppi),
            hiDPI,
            name,
            serialNum,
            Double(refreshRate)
        ) else {
            LogManager.shared.log("VirtualDisplayManager: Failed to create virtual display")
            return nil
        }
        
        activeDisplay = display
        activeResolution = Resolution(width: width, height: height, ppi: ppi, hiDPI: hiDPI, name: name)
        activeRefreshRate = refreshRate
        didSelectRequestedMode = false
        
        // Get the display ID from the created virtual display
        // The CGVirtualDisplay object has a displayID property
        if let displayIDValue = (display as AnyObject).value(forKey: "displayID") as? UInt32 {
            self.displayID = displayIDValue
            scheduleColorSyncWorkaround()
            LogManager.shared.log("VirtualDisplayManager: Created virtual display with ID \(displayIDValue)")
            return displayIDValue
        }
        
        LogManager.shared.log("VirtualDisplayManager: Created display but couldn't get ID")
        return nil
    }

    /// Selects the exact logical/backing-pixel pair requested by the user.
    ///
    /// macOS can restore a cached low-resolution mode after a virtual display
    /// is registered, even when `applySettings` received a larger mode. Looking
    /// at width alone is insufficient because 1440x960 can exist as both a
    /// low-resolution mode and a 2x 2880x1920 HiDPI mode.
    @discardableResult
    func selectRequestedMode() -> Bool {
        guard !didSelectRequestedMode else { return true }
        guard let displayID, let resolution = activeResolution else { return false }
        didSelectRequestedMode = true

        guard let modes = CGDisplayCopyAllDisplayModes(displayID, nil) as? [CGDisplayMode] else {
            LogManager.shared.log("VirtualDisplayManager: Unable to enumerate display modes")
            return false
        }

        let logicalWidth = resolution.hiDPI ? resolution.width / 2 : resolution.width
        let logicalHeight = resolution.hiDPI ? resolution.height / 2 : resolution.height
        let requestedMode = modes.first {
            $0.width == logicalWidth &&
            $0.height == logicalHeight &&
            $0.pixelWidth == resolution.width &&
            $0.pixelHeight == resolution.height
        }

        guard let requestedMode else {
            let availableModes = modes
                .map { "\($0.width)x\($0.height)@\($0.pixelWidth)x\($0.pixelHeight)" }
                .uniqued()
                .joined(separator: ", ")
            LogManager.shared.log(
                "VirtualDisplayManager: Exact requested mode unavailable " +
                "(logical \(logicalWidth)x\(logicalHeight), pixels \(resolution.width)x\(resolution.height)); " +
                "available: \(availableModes) ⚠️"
            )
            return false
        }

        let result = CGDisplaySetDisplayMode(displayID, requestedMode, nil)
        if result == .success {
            LogManager.shared.log(
                "VirtualDisplayManager: Selected requested mode logical=" +
                "\(requestedMode.width)x\(requestedMode.height), pixels=" +
                "\(requestedMode.pixelWidth)x\(requestedMode.pixelHeight)"
            )
            return true
        }

        LogManager.shared.log("VirtualDisplayManager: Failed to select requested mode (CGError \(result.rawValue))")
        return false
    }

    /// Logs the mode macOS actually selected, including the effective backing scale.
    func logCurrentMode() {
        guard let displayID,
              let mode = CGDisplayCopyDisplayMode(displayID) else {
            LogManager.shared.log("VirtualDisplayManager: Current display mode unavailable")
            return
        }

        let logicalWidth = mode.width
        let logicalHeight = mode.height
        let pixelWidth = mode.pixelWidth
        let pixelHeight = mode.pixelHeight
        let scale = logicalWidth > 0 ? Double(pixelWidth) / Double(logicalWidth) : 0
        let requestedHiDPI = activeResolution?.hiDPI ?? false
        let expectedScale = requestedHiDPI ? 2.0 : 1.0

        LogManager.shared.log(
            String(
                format: "VirtualDisplayManager: Active mode logical=%zux%zu, pixels=%zux%zu, refresh=%.0fHz, scale=%.1fx, requestedHiDPI=%@",
                logicalWidth,
                logicalHeight,
                pixelWidth,
                pixelHeight,
                mode.refreshRate,
                scale,
                requestedHiDPI ? "true" : "false"
            )
        )

        if abs(scale - expectedScale) > 0.1 {
            LogManager.shared.log(
                String(
                    format: "VirtualDisplayManager: Mode mismatch — expected %.1fx but macOS selected %.1fx ⚠️",
                    expectedScale,
                    scale
                )
            )
        }
    }

    /// Applies a new mode to the existing virtual display without changing its identity.
    func updateDisplay(resolution: Resolution, refreshRate: Int) -> Bool {
        guard let activeDisplay else {
            LogManager.shared.log("VirtualDisplayManager: Cannot update missing virtual display")
            return false
        }

        if activeResolution == resolution, activeRefreshRate == refreshRate {
            LogManager.shared.log("VirtualDisplayManager: Display settings unchanged; keeping display ID \(displayID ?? 0)")
            return true
        }

        // CGVirtualDisplay.applySettings may report success while silently ignoring
        // a HiDPI transition. Recreate the display with the same persisted identity
        // instead so macOS applies the new pixel-density mode reliably.
        if activeResolution?.hiDPI != resolution.hiDPI {
            LogManager.shared.log("VirtualDisplayManager: HiDPI mode changed; virtual display recreation required")
            return false
        }

        guard updateVirtualDisplay(
            activeDisplay,
            Int32(resolution.width),
            Int32(resolution.height),
            resolution.hiDPI,
            Double(refreshRate)
        ) else {
            LogManager.shared.log("VirtualDisplayManager: Failed to update virtual display in place")
            return false
        }

        activeResolution = resolution
        activeRefreshRate = refreshRate
        didSelectRequestedMode = false
        LogManager.shared.log("VirtualDisplayManager: Updated virtual display ID \(displayID ?? 0) in place at \(refreshRate)Hz")
        return true
    }
    
    /// Destroys the currently active virtual display
    func destroyDisplay() {
        releaseColorSyncWorkaround()
        activeDisplay = nil
        displayID = nil
        activeResolution = nil
        activeRefreshRate = nil
        didSelectRequestedMode = false
        LogManager.shared.log("VirtualDisplayManager: Destroyed virtual display")
    }
    
    deinit {
        destroyDisplay()
    }
}

private extension Sequence where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
