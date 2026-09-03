import Foundation

public final class SafeLogger {
    private let paths: GPTSwitcherPaths
    private let queue = DispatchQueue(label: "com.gptswitcher.logger")

    public init(paths: GPTSwitcherPaths = .live) {
        self.paths = paths
    }

    public func log(_ message: String) {
        let safeMessage = sanitize(message)
        queue.async { [paths] in
            do {
                try paths.createSupportDirectories()
                let day = Self.dayFormatter.string(from: Date())
                let timestamp = Self.timestampFormatter.string(from: Date())
                let url = paths.logsRoot.appendingPathComponent("\(day).log")
                let line = "\(timestamp)  \(safeMessage)\n"
                let data = Data(line.utf8)
                if FileManager.default.fileExists(atPath: url.path) {
                    let handle = try FileHandle(forWritingTo: url)
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                    try handle.close()
                } else {
                    try data.write(to: url, options: .atomic)
                    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                }
            } catch {
                // Logging must never block switching or expose user data elsewhere.
            }
        }
    }

    private func sanitize(_ input: String) -> String {
        var output = input.replacingOccurrences(
            of: "(?i)(token|cookie|password|authorization)\\s*[:=]\\s*\\S+",
            with: "$1=<redacted>",
            options: .regularExpression
        )
        if output.count > 500 { output = String(output.prefix(500)) }
        return output.replacingOccurrences(of: "\n", with: " ")
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()
}
