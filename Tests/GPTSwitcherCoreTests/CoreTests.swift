import Foundation
import Testing
@testable import GPTSwitcherCore

@Suite("GPT Switcher Core")
struct CoreTests {
    private func temporaryPaths() throws -> GPTSwitcherPaths {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GPTSwitcherTests-\(UUID().uuidString)", isDirectory: true)
        return GPTSwitcherPaths(
            applicationSupportRoot: root.appendingPathComponent("support", isDirectory: true),
            logsRoot: root.appendingPathComponent("logs", isDirectory: true),
            sharedCodexHome: root.appendingPathComponent("shared-codex", isDirectory: true),
            sharedChatGPTData: root.appendingPathComponent("shared-chatgpt", isDirectory: true)
        )
    }

    @Test("Default configuration contains A and B and supports more accounts")
    func defaultConfig() {
        let config = SwitcherConfig()
        #expect(config.schemaVersion == 2)
        #expect(config.accounts.count == 2)
        #expect(config.account(.accountA).displayName == "Account A")
        #expect(config.account(.accountB).displayName == "Account B")
        #expect(config.activeProfileID == nil)
        #expect(config.shortcuts[.accountA]?.displayText == "⌥⌘1")
        #expect(ProfileID(rawValue: "account-c") != nil)
        #expect(ProfileID(rawValue: "../unsafe") == nil)
    }

    @Test("Configuration round trips dynamic accounts without credentials")
    func configurationRoundTrip() throws {
        let paths = try temporaryPaths()
        let store = ConfigStore(paths: paths)
        var config = SwitcherConfig()
        let accountC = ProfileID(rawValue: "account-c")!
        config.updateAccount(AccountProfile(id: accountC, displayName: "第三个账号", isConfigured: true))
        config.shortcuts[accountC] = HotKeyConfiguration(key: "3")
        config.activeProfileID = accountC
        try store.save(config)

        let loaded = try store.load()
        #expect(loaded == config)
        let text = try String(contentsOf: paths.configURL, encoding: .utf8)
        #expect(!text.lowercased().contains("token"))
        #expect(!text.lowercased().contains("cookie"))
        #expect(!text.lowercased().contains("password"))
    }

    @Test("Schema 1 configuration migrates to shared-workspace schema")
    func schemaMigration() throws {
        let paths = try temporaryPaths()
        try paths.createSupportDirectories()
        let old = SwitcherConfig(schemaVersion: 1)
        let data = try JSONEncoder().encode(old)
        try data.write(to: paths.configURL)

        let loaded = try ConfigStore(paths: paths).load()
        #expect(loaded.schemaVersion == 2)
        #expect(loaded.accounts.map(\.id) == [.accountA, .accountB])
    }

    @Test("Profile creation keeps isolated login enrollment slots")
    func separateLoginDirectories() throws {
        let paths = try temporaryPaths()
        let profileA = try paths.createProfileDirectories(for: .accountA)
        let profileB = try paths.createProfileDirectories(for: .accountB)

        #expect(profileA.chatGPT != profileA.codex)
        #expect(profileA.root != profileB.root)
        #expect(FileManager.default.fileExists(atPath: profileA.chatGPT.path))
        #expect(FileManager.default.fileExists(atPath: profileA.codex.path))
        #expect(paths.sharedCodexHome != profileA.codex)
    }

    @Test("Opaque credential activation preserves the shared workspace")
    func credentialActivation() throws {
        let paths = try temporaryPaths()
        let profileA = try paths.createProfileDirectories(for: .accountA)
        let profileB = try paths.createProfileDirectories(for: .accountB)
        try FileManager.default.createDirectory(at: paths.sharedCodexHome, withIntermediateDirectories: true)
        let workspaceMarker = paths.sharedCodexHome.appendingPathComponent("local-project-history.sqlite")
        try Data("workspace".utf8).write(to: workspaceMarker)
        try Data("original".utf8).write(to: paths.sharedAuthURL)
        try Data("account-a-secret".utf8).write(to: profileA.authSnapshot)
        try Data("account-b-secret".utf8).write(to: profileB.authSnapshot)

        let store = AccountAuthStore(paths: paths)
        try store.activate(.accountA)
        #expect(store.activeProfileID() == .accountA)
        #expect(try Data(contentsOf: paths.sharedAuthURL) == Data("account-a-secret".utf8))
        #expect(try Data(contentsOf: workspaceMarker) == Data("workspace".utf8))
        #expect(try Data(contentsOf: paths.originalSharedAuthBackupURL) == Data("original".utf8))

        try Data("account-a-refreshed".utf8).write(to: paths.sharedAuthURL)
        try store.preserveCurrentCredentialIfManaged()
        try store.activate(.accountB)
        #expect(store.activeProfileID() == .accountB)
        #expect(try Data(contentsOf: profileA.authSnapshot) == Data("account-a-refreshed".utf8))
        #expect(try Data(contentsOf: paths.sharedAuthURL) == Data("account-b-secret".utf8))
        #expect(try Data(contentsOf: workspaceMarker) == Data("workspace".utf8))
    }

    @Test("Missing credentials fail before switching")
    func missingCredential() throws {
        let paths = try temporaryPaths()
        let store = AccountAuthStore(paths: paths)
        #expect(!store.hasCredential(for: .accountA))
        #expect(throws: AccountAuthStoreError.self) {
            try store.activate(.accountA)
        }
    }

    @Test("Profile manager only removes its exact managed account slot")
    func safeDelete() throws {
        let paths = try temporaryPaths()
        let manager = ProfileManager(paths: paths)
        let accountC = ProfileID(rawValue: "account-c")!
        let profile = try manager.prepare(accountC)
        let marker = profile.chatGPT.appendingPathComponent("marker")
        try Data("test".utf8).write(to: marker)

        try manager.delete(accountC, activeProfileID: .accountB, chatGPTIsRunning: true)
        #expect(!FileManager.default.fileExists(atPath: profile.root.path))
        #expect(FileManager.default.fileExists(atPath: paths.sharedCodexHome.path) == false)
    }

    @Test("Active running account cannot be deleted")
    func activeDeleteRejected() throws {
        let paths = try temporaryPaths()
        let manager = ProfileManager(paths: paths)
        _ = try manager.prepare(.accountA)
        #expect(throws: ProfileManagerError.self) {
            try manager.delete(.accountA, activeProfileID: .accountA, chatGPTIsRunning: true)
        }
    }

    @Test("Symlinked profiles root is rejected")
    func symlinkRootRejected() throws {
        let paths = try temporaryPaths()
        try FileManager.default.createDirectory(
            at: paths.applicationSupportRoot,
            withIntermediateDirectories: true
        )
        let external = paths.applicationSupportRoot
            .deletingLastPathComponent()
            .appendingPathComponent("external", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: paths.profilesRoot, withDestinationURL: external)
        try FileManager.default.createDirectory(
            at: external.appendingPathComponent("account-a", isDirectory: true),
            withIntermediateDirectories: true
        )

        let manager = ProfileManager(paths: paths)
        #expect(throws: ProfileManagerError.self) {
            try manager.delete(.accountA, activeProfileID: nil, chatGPTIsRunning: false)
        }
        #expect(FileManager.default.fileExists(atPath: external.path))
    }

    @Test("Daily launch uses shared defaults and enrollment remains isolated")
    @MainActor
    func launchArguments() throws {
        let paths = try temporaryPaths()
        let profile = paths.profile(.accountA)
        let installation = ChatGPTInstallation(
            appURL: URL(fileURLWithPath: "/Applications/ChatGPT.app"),
            bundleIdentifier: "com.openai.codex",
            version: "test",
            build: "test",
            chromiumVersion: "test",
            supportsExplicitUserDataPath: true,
            supportsCodexHome: true
        )
        let controller = ChatGPTController(paths: paths)
        let shared = controller.sharedLaunchArguments(installation: installation)
        let enrollment = controller.isolatedLoginArguments(installation: installation, profile: profile)

        #expect(shared.contains("CODEX_HOME=\(paths.sharedCodexHome.path)"))
        #expect(shared.contains("CODEX_ELECTRON_USER_DATA_PATH=\(paths.sharedChatGPTData.path)"))
        #expect(shared.contains("--user-data-dir=\(paths.sharedChatGPTData.path)"))
        #expect(!shared.contains(where: { $0.contains(profile.root.path) }))
        #expect(enrollment.contains("CODEX_HOME=\(profile.codex.path)"))
        #expect(enrollment.contains("CODEX_ELECTRON_USER_DATA_PATH=\(profile.chatGPT.path)"))
        #expect(enrollment.contains("--user-data-dir=\(profile.chatGPT.path)"))
    }

    @Test("Usage response reports actual windows without plan assumptions")
    func usageResponse() throws {
        let response = Data(#"{"id":2,"result":{"rateLimits":{"limitId":"codex","limitName":null,"primary":{"usedPercent":63,"windowDurationMins":300,"resetsAt":1788431766},"secondary":{"usedPercent":10,"windowDurationMins":10080,"resetsAt":1789018566},"planType":"plus"},"rateLimitsByLimitId":{"codex":{"limitId":"codex","limitName":null,"primary":{"usedPercent":63,"windowDurationMins":300,"resetsAt":1788431766},"secondary":{"usedPercent":10,"windowDurationMins":10080,"resetsAt":1789018566},"planType":"plus"}},"accountId":"must-not-be-stored"}}"#.utf8)

        let decoded = try AccountUsageService.decodeRateLimitResponse(response)
        let usage = try #require(decoded)
        #expect(usage.planDisplayName == "Plus")
        #expect(usage.buckets.count == 1)
        #expect(usage.allWindows.count == 2)
        #expect(usage.allWindows[0].windowDurationMinutes == 300)
        #expect(usage.allWindows[0].usedPercent == 63)
        #expect(usage.allWindows[0].remainingPercent == 37)
        #expect(usage.allWindows[1].windowDurationMinutes == 10_080)
        #expect(usage.allWindows[1].remainingPercent == 90)
        let encoded = try String(data: JSONEncoder().encode(usage), encoding: .utf8)
        #expect(encoded?.contains("must-not-be-stored") == false)
    }

    @Test("Usage parser ignores app-server notifications")
    func usageNotificationIgnored() throws {
        let notification = Data(#"{"method":"remoteControl/status/changed","params":{"status":"disabled"}}"#.utf8)
        #expect(try AccountUsageService.decodeRateLimitResponse(notification) == nil)
    }
}
