import SwiftUI

class LogManager: ObservableObject {
    static let shared = LogManager()
    private static let maximumLogCount = 200

    @Published var logs: [String] = []

    func log(_ message: String) {
        DispatchQueue.main.async {
            let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
            self.logs.append("[\(timestamp)] \(message)")
            if self.logs.count > Self.maximumLogCount {
                self.logs.removeFirst(self.logs.count - Self.maximumLogCount)
            }
            print(message)
        }
    }
}

// MARK: - Update Checker

class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    private static var isEnabled: Bool {
        Bundle.main.object(forInfoDictionaryKey: "ExtendCastEnableUpdates") as? Bool ?? true
    }

    /// Reads the complete user-facing version from Info.plist.
    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    static var displayVersion: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return displayVersion(shortVersion: short, build: build)
    }

    static func displayVersion(shortVersion: String, build: String) -> String {
        "\(shortVersion) (Build \(build))"
    }

    private static let repoOwner = "Ruobin521"
    private static let repoName = "ExtendCast"

    @Published var latestVersion: String?
    @Published var downloadURL: String?
    @Published var releaseNotes: String?
    @Published var updateAvailable = false
    @Published var checkedOnce = false
    @Published var isChecking = false

    /// Extracts numeric components from tags such as "v1.2.3" or "release-1.2".
    static func versionComponents(from value: String) -> [Int] {
        guard let start = value.firstIndex(where: \.isNumber) else { return [] }
        let numericVersion = value[start...].prefix { $0.isNumber || $0 == "." }
        return numericVersion
            .split(separator: ".", omittingEmptySubsequences: false)
            .map { Int($0) ?? 0 }
    }

    static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        let candidateComponents = versionComponents(from: candidate)
        let currentComponents = versionComponents(from: current)
        guard !candidateComponents.isEmpty, !currentComponents.isEmpty else { return false }

        let componentCount = max(candidateComponents.count, currentComponents.count)
        for index in 0..<componentCount {
            let candidateValue = index < candidateComponents.count ? candidateComponents[index] : 0
            let currentValue = index < currentComponents.count ? currentComponents[index] : 0
            if candidateValue != currentValue {
                return candidateValue > currentValue
            }
        }
        return false
    }

    func checkForUpdates() {
        guard Self.isEnabled, !isChecking else { return }
        isChecking = true

        let urlString = "https://api.github.com/repos/\(Self.repoOwner)/\(Self.repoName)/releases/latest"
        guard let url = URL(string: urlString) else {
            isChecking = false
            return
        }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("ExtendCast/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard
                let data,
                error == nil,
                let httpResponse = response as? HTTPURLResponse,
                (200..<300).contains(httpResponse.statusCode)
            else {
                DispatchQueue.main.async {
                    self?.isChecking = false
                }
                return
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                DispatchQueue.main.async {
                    self?.isChecking = false
                }
                return
            }

            let tagName = json["tag_name"] as? String ?? ""
            let htmlURL = json["html_url"] as? String ?? ""
            let body = json["body"] as? String ?? ""
            guard !tagName.isEmpty, !htmlURL.isEmpty else {
                DispatchQueue.main.async {
                    self?.isChecking = false
                }
                return
            }

            DispatchQueue.main.async {
                self?.isChecking = false
                self?.latestVersion = tagName
                self?.downloadURL = htmlURL
                self?.releaseNotes = body

                self?.updateAvailable = Self.isVersion(tagName, newerThan: Self.currentVersion)

                self?.checkedOnce = true
                if self?.updateAvailable == true {
                    LogManager.shared.log("Update: \(tagName) available (current: \(Self.currentVersion))")
                }
            }
        }.resume()
    }
}

// MARK: - Log View

struct LogView: View {
    @ObservedObject var logManager = LogManager.shared
    @ObservedObject var updateChecker = UpdateChecker.shared

    private static let repoOwner = "Ruobin521"
    private static let repoName = "ExtendCast"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Update banner
            if updateChecker.checkedOnce {
                if updateChecker.updateAvailable, let version = updateChecker.latestVersion {
                    HStack {
                        Image(systemName: "arrow.down.circle.fill")
                            .foregroundColor(.green)
                        Text("Update available: \(version)")
                            .font(.system(size: 13, weight: .medium))
                        Spacer()
                        Button("Download") {
                            if let urlStr = updateChecker.downloadURL, let url = URL(string: urlStr) {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.green.opacity(0.1))
                    )
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                } else {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("You're on the latest version (\(UpdateChecker.currentVersion))")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                }
            }

            // Action buttons
            HStack {
                Spacer()

                Button {
                    openReportIssue()
                } label: {
                    Label("Report Issue", systemImage: "exclamationmark.bubble")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    let text = logManager.logs.joined(separator: "\n")
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(text, forType: .string)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    logManager.logs.removeAll()
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 6)

            ScrollView {
                Text(logManager.logs.joined(separator: "\n"))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Logs")
    }

    private func openReportIssue() {
        let systemInfo = [
            "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "ExtendCast \(UpdateChecker.currentVersion)",
            "Chip: \(ProcessInfo.processInfo.processorCount) cores"
        ].joined(separator: ", ")

        let recentLogs = logManager.logs.suffix(30).joined(separator: "\n")

        let body = """
        **Describe the issue:**


        **Steps to reproduce:**
        1.

        **Expected behavior:**


        **System info:** \(systemInfo)

        <details><summary>Recent Logs</summary>

        ```
        \(recentLogs)
        ```

        </details>
        """

        let encodedTitle = "Bug: ".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let encodedBody = body.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let urlString = "https://github.com/\(Self.repoOwner)/\(Self.repoName)/issues/new?title=\(encodedTitle)&body=\(encodedBody)"

        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }
}
