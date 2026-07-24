import Darwin
import Foundation

/// Prevents a macOS 26 ColorSync file-notification loop while virtual displays are online.
///
/// The user agent is paused only after the display profile has been created. A detached
/// watchdog resumes it if BetterCast exits unexpectedly.
final class ColorSyncWorkaround {
    static let shared = ColorSyncWorkaround()

    private var holdCount = 0
    private var pausedProcessID: pid_t?
    private var watchdog: Process?

    private init() {}

    func acquire() {
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 else { return }

        holdCount += 1
        guard holdCount == 1 else { return }
        guard let processID = findUserAgentProcessID() else {
            holdCount = 0
            LogManager.shared.log("ColorSync workaround: user agent not found")
            return
        }
        guard Darwin.kill(processID, SIGSTOP) == 0 else {
            holdCount = 0
            LogManager.shared.log("ColorSync workaround: unable to pause user agent")
            return
        }
        guard let watchdog = startWatchdog(for: processID) else {
            holdCount = 0
            return
        }

        pausedProcessID = processID
        self.watchdog = watchdog
        LogManager.shared.log("ColorSync workaround: paused profile watcher while virtual display is active")
    }

    func release() {
        guard holdCount > 0 else { return }

        holdCount -= 1
        guard holdCount == 0, let processID = pausedProcessID else { return }

        _ = Darwin.kill(processID, SIGCONT)
        watchdog?.terminate()
        watchdog = nil
        pausedProcessID = nil
        LogManager.shared.log("ColorSync workaround: resumed profile watcher")
    }

    private func findUserAgentProcessID() -> pid_t? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-u", String(getuid()), "-x", "colorsync.useragent"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8),
              let firstLine = text.split(whereSeparator: \.isNewline).first,
              let processID = pid_t(firstLine) else {
            return nil
        }
        return processID
    }

    private func startWatchdog(for processID: pid_t) -> Process? {
        let parentProcessID = getpid()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            "while kill -0 \(parentProcessID) 2>/dev/null; do sleep 1; done; kill -CONT \(processID) 2>/dev/null"
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            return process
        } catch {
            _ = Darwin.kill(processID, SIGCONT)
            LogManager.shared.log("ColorSync workaround: watchdog failed; user agent restored")
            return nil
        }
    }
}
