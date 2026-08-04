import Foundation
import Network

final class ConnectionDiagnosticsFile {
    private let directoryURL: URL
    private let currentFileURL: URL
    private let previousFileURL: URL
    private let maximumFileSize: Int
    private let lock = NSLock()

    init(directoryURL: URL, maximumFileSize: Int) {
        self.directoryURL = directoryURL
        self.maximumFileSize = maximumFileSize
        currentFileURL = directoryURL.appendingPathComponent("connection.log")
        previousFileURL = directoryURL.appendingPathComponent("connection.previous.log")
    }

    func append(_ entry: String) {
        lock.lock()
        defer { lock.unlock() }

        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
            let data = Data((entry + "\n").utf8)
            let currentSize = currentFileSize()
            if currentSize > 0 && currentSize + data.count > maximumFileSize {
                try rotateFiles()
            }

            if !FileManager.default.fileExists(atPath: currentFileURL.path) {
                FileManager.default.createFile(
                    atPath: currentFileURL.path,
                    contents: nil
                )
            }
            let handle = try FileHandle(forWritingTo: currentFileURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            // Diagnostics must never interfere with connecting.
        }
    }

    func contents() throws -> String {
        lock.lock()
        defer { lock.unlock() }

        return try [previousFileURL, currentFileURL]
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .map { try String(contentsOf: $0, encoding: .utf8) }
            .joined()
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }

        try? FileManager.default.removeItem(at: previousFileURL)
        try? FileManager.default.removeItem(at: currentFileURL)
    }

    var fileURL: URL { currentFileURL }

    private func currentFileSize() -> Int {
        let attributes = try? FileManager.default.attributesOfItem(
            atPath: currentFileURL.path
        )
        return attributes?[.size] as? Int ?? 0
    }

    private func rotateFiles() throws {
        if FileManager.default.fileExists(atPath: previousFileURL.path) {
            try FileManager.default.removeItem(at: previousFileURL)
        }
        try FileManager.default.moveItem(
            at: currentFileURL,
            to: previousFileURL
        )
    }
}

enum ConnectDiagnostics {
    static let tag = "[CONNECT]"

    private static let isRunningTests =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        || Bundle.allBundles.contains { $0.bundleURL.pathExtension == "xctest" }
    private static let sessionID = String(UUID().uuidString.prefix(8))
    private static let sessionStartedAt = ProcessInfo.processInfo.systemUptime
    private static let file = ConnectionDiagnosticsFile(
        directoryURL: FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        .appendingPathComponent("ExtendCast", isDirectory: true)
        .appendingPathComponent("Diagnostics", isDirectory: true),
        maximumFileSize: 512 * 1_024
    )

    static var persistedContents: String {
        (try? file.contents()) ?? "Connection diagnostics are unavailable."
    }

    static var fileURL: URL { file.fileURL }

    static func clearPersistedLog() {
        file.clear()
    }

    static func log(_ message: String) {
        guard !isRunningTests else { return }
        let timestamp = ISO8601DateFormatter.string(
            from: Date(),
            timeZone: .current,
            formatOptions: [
                .withInternetDateTime,
                .withFractionalSeconds,
            ]
        )
        let elapsed = ProcessInfo.processInfo.systemUptime - sessionStartedAt
        let line = String(
            format: "%@ session=%@ +%.3fs %@",
            timestamp,
            sessionID,
            elapsed,
            message
        )
        file.append(line)
        LogManager.shared.log("\(tag) \(message)")
    }

    static func stateSummary(_ state: NWConnection.State) -> String {
        switch state {
        case .setup:
            return "setup"
        case .preparing:
            return "preparing"
        case .ready:
            return "ready"
        case .waiting(let error):
            return "waiting error=\(error)"
        case .failed(let error):
            return "failed error=\(error)"
        case .cancelled:
            return "cancelled"
        @unknown default:
            return "unknown"
        }
    }

    static func pathSummary(_ path: NWPath?) -> String {
        guard let path else { return "path=nil" }
        let interfaces = path.availableInterfaces.map {
            "\($0.name):\($0.type)"
        }.joined(separator: ",")
        return [
            "status=\(path.status)",
            "local=\(String(describing: path.localEndpoint))",
            "remote=\(String(describing: path.remoteEndpoint))",
            "interfaces=[\(interfaces)]",
            "usesWiFi=\(path.usesInterfaceType(.wifi))",
            "usesWired=\(path.usesInterfaceType(.wiredEthernet))",
            "usesOther=\(path.usesInterfaceType(.other))",
            "ipv4=\(path.supportsIPv4)",
            "ipv6=\(path.supportsIPv6)",
            "dns=\(path.supportsDNS)",
            "expensive=\(path.isExpensive)",
            "constrained=\(path.isConstrained)",
        ].joined(separator: " ")
    }
}
