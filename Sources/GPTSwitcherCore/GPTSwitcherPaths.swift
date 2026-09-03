import Foundation

public struct GPTSwitcherPaths: Sendable {
    public let applicationSupportRoot: URL
    public let logsRoot: URL
    private let sharedCodexHomeOverride: URL?
    private let sharedChatGPTDataOverride: URL?

    public init(
        applicationSupportRoot: URL,
        logsRoot: URL,
        sharedCodexHome: URL? = nil,
        sharedChatGPTData: URL? = nil
    ) {
        self.applicationSupportRoot = applicationSupportRoot.standardizedFileURL
        self.logsRoot = logsRoot.standardizedFileURL
        self.sharedCodexHomeOverride = sharedCodexHome?.standardizedFileURL
        self.sharedChatGPTDataOverride = sharedChatGPTData?.standardizedFileURL
    }

    public static var live: GPTSwitcherPaths {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return GPTSwitcherPaths(
            applicationSupportRoot: home
                .appendingPathComponent("Library/Application Support/GPT Switcher", isDirectory: true),
            logsRoot: home.appendingPathComponent("Library/Logs/GPT Switcher", isDirectory: true)
        )
    }

    public var profilesRoot: URL {
        applicationSupportRoot.appendingPathComponent("profiles", isDirectory: true)
    }

    public var configURL: URL {
        applicationSupportRoot.appendingPathComponent("config.json")
    }

    public var activeAuthMarkerURL: URL {
        applicationSupportRoot.appendingPathComponent("active-auth-profile.json")
    }

    public var migrationBackupRoot: URL {
        applicationSupportRoot.appendingPathComponent("migration-backup", isDirectory: true)
    }

    public var originalSharedAuthBackupURL: URL {
        migrationBackupRoot.appendingPathComponent("original-auth.json")
    }

    public var sharedCodexHome: URL {
        sharedCodexHomeOverride
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
    }

    public var sharedAuthURL: URL {
        sharedCodexHome.appendingPathComponent("auth.json")
    }

    public var sharedChatGPTData: URL {
        sharedChatGPTDataOverride
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Codex", isDirectory: true)
    }

    public func profile(_ id: ProfileID) -> ProfilePaths {
        let root = profilesRoot.appendingPathComponent(id.rawValue, isDirectory: true)
        return ProfilePaths(
            root: root,
            chatGPT: root.appendingPathComponent("chatgpt", isDirectory: true),
            codex: root.appendingPathComponent("codex", isDirectory: true)
        )
    }

    public func createProfileDirectories(for id: ProfileID) throws -> ProfilePaths {
        let profile = profile(id)
        try createPrivateDirectory(profile.chatGPT)
        try createPrivateDirectory(profile.codex)
        return profile
    }

    public func createSupportDirectories() throws {
        try createPrivateDirectory(applicationSupportRoot)
        try createPrivateDirectory(profilesRoot)
        try createPrivateDirectory(logsRoot)
        try createPrivateDirectory(migrationBackupRoot)
    }

    private func createPrivateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
}
