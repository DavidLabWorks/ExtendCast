import Foundation
import CoreGraphics
import ColorSync

/// Captures and restores display layout around virtual-display hotplug.
///
/// Toggling Retina destroys and recreates the ExtendCast display. WindowServer
/// often reshuffles every online display — physical modes (e.g. Redmi 27NU)
/// and the virtual display's arrangement origin. This puts both back.
enum PhysicalDisplayModePreserver {
    struct ModeKey: Equatable {
        let width: Int
        let height: Int
        let pixelWidth: Int
        let pixelHeight: Int
        let refreshRate: Double

        init(mode: CGDisplayMode) {
            width = mode.width
            height = mode.height
            pixelWidth = mode.pixelWidth
            pixelHeight = mode.pixelHeight
            refreshRate = mode.refreshRate
        }

        init(width: Int, height: Int, pixelWidth: Int, pixelHeight: Int, refreshRate: Double) {
            self.width = width
            self.height = height
            self.pixelWidth = pixelWidth
            self.pixelHeight = pixelHeight
            self.refreshRate = refreshRate
        }

        func matches(_ other: ModeKey, refreshTolerance: Double = 0.5) -> Bool {
            width == other.width
                && height == other.height
                && pixelWidth == other.pixelWidth
                && pixelHeight == other.pixelHeight
                && abs(refreshRate - other.refreshRate) <= refreshTolerance
        }

        var description: String {
            String(
                format: "%dx%d@%dx%d %.0fHz",
                width,
                height,
                pixelWidth,
                pixelHeight,
                refreshRate
            )
        }
    }

    struct Entry: Equatable {
        let uuid: String?
        let displayID: CGDirectDisplayID
        let mode: ModeKey
        let originX: CGFloat
        let originY: CGFloat

        var originDescription: String {
            String(format: "(%.0f, %.0f)", originX, originY)
        }
    }

    struct Snapshot: Equatable {
        let entries: [Entry]
        var isEmpty: Bool { entries.isEmpty }
    }

    /// ExtendCast virtual displays advertise vendorID = 1 (see VirtualDisplay.m).
    private static let extendCastVendorID: UInt32 = 1

    static func capture(excluding excludedIDs: Set<CGDirectDisplayID>) -> Snapshot {
        var entries: [Entry] = []
        for displayID in onlineDisplayIDs() {
            if excludedIDs.contains(displayID) { continue }
            if CGDisplayVendorNumber(displayID) == extendCastVendorID { continue }
            guard let mode = CGDisplayCopyDisplayMode(displayID) else { continue }
            let bounds = CGDisplayBounds(displayID)
            entries.append(
                Entry(
                    uuid: uuidString(for: displayID),
                    displayID: displayID,
                    mode: ModeKey(mode: mode),
                    originX: bounds.origin.x,
                    originY: bounds.origin.y
                )
            )
        }
        return Snapshot(entries: entries)
    }

    static func captureOrigin(of displayID: CGDirectDisplayID) -> CGPoint? {
        let bounds = CGDisplayBounds(displayID)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        return bounds.origin
    }

    /// Restores physical modes, then applies saved origins (physical + optional virtual)
    /// in one display-configuration transaction.
    @discardableResult
    static func restore(
        _ snapshot: Snapshot,
        excluding excludedIDs: Set<CGDirectDisplayID>,
        virtualDisplayID: CGDirectDisplayID?,
        virtualOrigin: CGPoint?
    ) -> Int {
        let online = onlineDisplayIDs()
        var changes = 0

        for entry in snapshot.entries {
            guard let displayID = resolveDisplayID(for: entry, online: online) else {
                LogManager.shared.log(
                    "PhysicalDisplayModePreserver: Display gone, skip restore " +
                    "id=\(entry.displayID) uuid=\(entry.uuid ?? "nil")"
                )
                continue
            }
            if excludedIDs.contains(displayID) { continue }
            if CGDisplayVendorNumber(displayID) == extendCastVendorID { continue }

            guard let current = CGDisplayCopyDisplayMode(displayID) else { continue }
            let currentKey = ModeKey(mode: current)
            if entry.mode.matches(currentKey) { continue }

            guard let targetMode = findMode(matching: entry.mode, on: displayID) else {
                LogManager.shared.log(
                    "PhysicalDisplayModePreserver: No matching mode for display \(displayID) " +
                    "wanted \(entry.mode.description); current \(currentKey.description) ⚠️"
                )
                continue
            }

            let error = CGDisplaySetDisplayMode(displayID, targetMode, nil)
            if error == .success {
                changes += 1
                LogManager.shared.log(
                    "PhysicalDisplayModePreserver: Restored mode display \(displayID) " +
                    "\(currentKey.description) → \(entry.mode.description)"
                )
            } else {
                LogManager.shared.log(
                    "PhysicalDisplayModePreserver: Failed to restore mode display \(displayID) " +
                    "(CGError \(error.rawValue))"
                )
            }
        }

        changes += restoreOrigins(
            snapshot: snapshot,
            online: online,
            excluding: excludedIDs,
            virtualDisplayID: virtualDisplayID,
            virtualOrigin: virtualOrigin
        )

        if changes == 0 {
            LogManager.shared.log("PhysicalDisplayModePreserver: Layout already intact")
        }
        return changes
    }

    static func findMode(matching key: ModeKey, on displayID: CGDirectDisplayID) -> CGDisplayMode? {
        guard let modes = CGDisplayCopyAllDisplayModes(displayID, nil) as? [CGDisplayMode] else {
            return nil
        }
        return modes.first { key.matches(ModeKey(mode: $0)) }
    }

    static func resolveDisplayID(for entry: Entry, online: [CGDirectDisplayID]) -> CGDirectDisplayID? {
        if let uuid = entry.uuid {
            for displayID in online {
                if uuidString(for: displayID) == uuid {
                    return displayID
                }
            }
        }
        if online.contains(entry.displayID) {
            return entry.displayID
        }
        return nil
    }

    static func originsMatch(_ a: CGPoint, _ b: CGPoint, tolerance: CGFloat = 1) -> Bool {
        abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance
    }

    private static func restoreOrigins(
        snapshot: Snapshot,
        online: [CGDirectDisplayID],
        excluding excludedIDs: Set<CGDirectDisplayID>,
        virtualDisplayID: CGDirectDisplayID?,
        virtualOrigin: CGPoint?
    ) -> Int {
        struct Move {
            let displayID: CGDirectDisplayID
            let origin: CGPoint
            let label: String
        }

        var moves: [Move] = []
        let mainID = CGMainDisplayID()

        for entry in snapshot.entries {
            guard let displayID = resolveDisplayID(for: entry, online: online) else { continue }
            if excludedIDs.contains(displayID) { continue }
            if CGDisplayVendorNumber(displayID) == extendCastVendorID { continue }
            if displayID == mainID { continue }

            let current = CGDisplayBounds(displayID).origin
            let wanted = CGPoint(x: entry.originX, y: entry.originY)
            if originsMatch(current, wanted) { continue }
            moves.append(Move(displayID: displayID, origin: wanted, label: "physical"))
        }

        if let virtualDisplayID,
           let virtualOrigin,
           online.contains(virtualDisplayID),
           virtualDisplayID != mainID {
            let current = CGDisplayBounds(virtualDisplayID).origin
            if !originsMatch(current, virtualOrigin) {
                moves.append(Move(displayID: virtualDisplayID, origin: virtualOrigin, label: "virtual"))
            }
        }

        guard !moves.isEmpty else { return 0 }

        var config: CGDisplayConfigRef?
        let beginError = CGBeginDisplayConfiguration(&config)
        guard beginError == .success, let config else {
            LogManager.shared.log(
                "PhysicalDisplayModePreserver: CGBeginDisplayConfiguration failed " +
                "(CGError \(beginError.rawValue))"
            )
            return 0
        }

        var configured = 0
        for move in moves {
            let error = CGConfigureDisplayOrigin(
                config,
                move.displayID,
                Int32(move.origin.x.rounded()),
                Int32(move.origin.y.rounded())
            )
            if error == .success {
                configured += 1
                LogManager.shared.log(
                    "PhysicalDisplayModePreserver: Queued \(move.label) origin " +
                    "display \(move.displayID) → \(String(format: "(%.0f, %.0f)", move.origin.x, move.origin.y))"
                )
            } else {
                LogManager.shared.log(
                    "PhysicalDisplayModePreserver: CGConfigureDisplayOrigin failed for " +
                    "\(move.label) display \(move.displayID) (CGError \(error.rawValue))"
                )
            }
        }

        let completeError = CGCompleteDisplayConfiguration(config, .permanently)
        if completeError != .success {
            LogManager.shared.log(
                "PhysicalDisplayModePreserver: CGCompleteDisplayConfiguration failed " +
                "(CGError \(completeError.rawValue))"
            )
            return 0
        }
        return configured
    }

    private static func onlineDisplayIDs() -> [CGDirectDisplayID] {
        var displayCount: UInt32 = 0
        var displays = [CGDirectDisplayID](repeating: 0, count: 16)
        let error = CGGetOnlineDisplayList(16, &displays, &displayCount)
        guard error == .success else { return [] }
        return Array(displays.prefix(Int(displayCount)))
    }

    private static func uuidString(for displayID: CGDirectDisplayID) -> String? {
        guard let unmanaged = CGDisplayCreateUUIDFromDisplayID(displayID) else { return nil }
        return CFUUIDCreateString(nil, unmanaged.takeRetainedValue()) as String?
    }
}

/// Coalesces capture/restore across destroy → recreate gaps on the main queue.
final class PhysicalDisplayModeSession {
    static let shared = PhysicalDisplayModeSession()

    private var snapshot: PhysicalDisplayModePreserver.Snapshot?
    private var virtualOrigin: CGPoint?
    private var restoreWorkItem: DispatchWorkItem?
    private let settleDelay: TimeInterval = 0.8

    private init() {}

    func captureBeforeMutation(excluding excludedIDs: Set<CGDirectDisplayID>) {
        if snapshot == nil {
            let captured = PhysicalDisplayModePreserver.capture(excluding: excludedIDs)
            snapshot = captured
            let summary = captured.entries
                .map { "\($0.displayID):\($0.mode.description)@\($0.originDescription)" }
                .joined(separator: ", ")
            LogManager.shared.log(
                "PhysicalDisplayModePreserver: Captured \(captured.entries.count) physical layout(s)" +
                (summary.isEmpty ? "" : " [\(summary)]")
            )
        }

        if virtualOrigin == nil {
            for displayID in excludedIDs {
                if let origin = PhysicalDisplayModePreserver.captureOrigin(of: displayID) {
                    virtualOrigin = origin
                    LogManager.shared.log(
                        String(
                            format: "PhysicalDisplayModePreserver: Saved virtual origin (%.0f, %.0f)",
                            origin.x,
                            origin.y
                        )
                    )
                    break
                }
            }
        }
    }

    /// Used after destroy when a recreate may or may not follow.
    func scheduleFallbackRestore() {
        scheduleRestore(excluding: [], virtualDisplayID: nil)
    }

    func cancelScheduledRestore() {
        restoreWorkItem?.cancel()
        restoreWorkItem = nil
    }

    /// Restores after WindowServer finishes reshuffling around virtual display changes.
    func scheduleRestore(
        excluding excludedIDs: Set<CGDirectDisplayID>,
        virtualDisplayID: CGDirectDisplayID?
    ) {
        restoreWorkItem?.cancel()
        guard snapshot != nil || virtualOrigin != nil else { return }
        let snap = snapshot ?? PhysicalDisplayModePreserver.Snapshot(entries: [])
        let savedVirtualOrigin = virtualOrigin
        let work = DispatchWorkItem { [weak self] in
            PhysicalDisplayModePreserver.restore(
                snap,
                excluding: excludedIDs,
                virtualDisplayID: virtualDisplayID,
                virtualOrigin: savedVirtualOrigin
            )
            self?.snapshot = nil
            self?.virtualOrigin = nil
            self?.restoreWorkItem = nil
        }
        restoreWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay, execute: work)
    }

    #if DEBUG
    var debugSnapshotEntryCount: Int { snapshot?.entries.count ?? 0 }
    var debugVirtualOrigin: CGPoint? { virtualOrigin }
    #endif
}
