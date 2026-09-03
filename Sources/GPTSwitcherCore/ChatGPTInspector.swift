import AppKit
import Foundation

public struct ChatGPTInstallation: Equatable, Sendable {
    public let appURL: URL
    public let bundleIdentifier: String
    public let version: String
    public let build: String
    public let chromiumVersion: String?
    public let supportsExplicitUserDataPath: Bool
    public let supportsCodexHome: Bool

    public var isSupported: Bool {
        bundleIdentifier == ChatGPTInspector.expectedBundleIdentifier
            && supportsExplicitUserDataPath
            && supportsCodexHome
    }
}

public enum ChatGPTInspectionError: LocalizedError {
    case notFound
    case invalidBundle(URL)

    public var errorDescription: String? {
        switch self {
        case .notFound:
            return "未找到新版 ChatGPT.app。请将它安装到 /Applications。"
        case .invalidBundle(let url):
            return "无法读取 ChatGPT 应用信息：\(url.path)"
        }
    }
}

public struct ChatGPTInspector {
    public static let expectedBundleIdentifier = "com.openai.codex"
    public static let explicitUserDataEnvironment = "CODEX_ELECTRON_USER_DATA_PATH"

    public init() {}

    public func inspect(preferredPath: String? = nil) throws -> ChatGPTInstallation {
        guard let appURL = locate(preferredPath: preferredPath) else {
            throw ChatGPTInspectionError.notFound
        }
        guard let bundle = Bundle(url: appURL), let info = bundle.infoDictionary else {
            throw ChatGPTInspectionError.invalidBundle(appURL)
        }

        let resources = appURL.appendingPathComponent("Contents/Resources", isDirectory: true)
        let asar = resources.appendingPathComponent("app.asar")
        let codex = resources.appendingPathComponent("codex")
        let hasUserDataEnvironment = fileContainsASCII(
            asar,
            needle: Self.explicitUserDataEnvironment
        )
        let hasCodexHome = fileContainsASCII(codex, needle: "CODEX_HOME")

        return ChatGPTInstallation(
            appURL: appURL,
            bundleIdentifier: info["CFBundleIdentifier"] as? String ?? "",
            version: info["CFBundleShortVersionString"] as? String ?? "未知",
            build: info["CFBundleVersion"] as? String ?? "未知",
            chromiumVersion: info["ChromiumBaseVersion"] as? String,
            supportsExplicitUserDataPath: hasUserDataEnvironment,
            supportsCodexHome: hasCodexHome
        )
    }

    private func locate(preferredPath: String?) -> URL? {
        let fileManager = FileManager.default
        if let preferredPath, !preferredPath.isEmpty,
           fileManager.fileExists(atPath: preferredPath) {
            return URL(fileURLWithPath: preferredPath).standardizedFileURL
        }
        let standard = URL(fileURLWithPath: "/Applications/ChatGPT.app", isDirectory: true)
        if fileManager.fileExists(atPath: standard.path) { return standard }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.expectedBundleIdentifier)
    }

    private func fileContainsASCII(_ url: URL, needle: String) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let target = Data(needle.utf8)
        var carry = Data()
        while let chunk = try? handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            var searchable = carry
            searchable.append(chunk)
            if searchable.range(of: target) != nil { return true }
            carry = searchable.suffix(max(0, target.count - 1))
        }
        return false
    }
}
