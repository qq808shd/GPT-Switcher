import AppKit
import Combine
import GPTSwitcherCore
import ServiceManagement
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var config: SwitcherConfig
    @Published private(set) var installation: ChatGPTInstallation?
    @Published var statusMessage: String?
    @Published var isSwitching = false
    @Published var pendingForceProfileID: ProfileID?
    @Published var pendingLoginProfileID: ProfileID?
    @Published private(set) var usageByProfile: [ProfileID: AccountUsageSnapshot] = [:]
    @Published private(set) var usageErrors: [ProfileID: String] = [:]
    @Published private(set) var isRefreshingUsage = false
    @Published private(set) var lastUsageRefresh: Date?

    let paths: GPTSwitcherPaths
    private let store: ConfigStore
    private let controller: ChatGPTController
    private let profiles: ProfileManager
    private let logger: SafeLogger
    private let usageService: AccountUsageService

    init(paths: GPTSwitcherPaths = .live) {
        self.paths = paths
        self.store = ConfigStore(paths: paths)
        self.logger = SafeLogger(paths: paths)
        self.controller = ChatGPTController(paths: paths, logger: logger)
        self.profiles = ProfileManager(paths: paths)
        self.usageService = AccountUsageService()
        do {
            self.config = try store.load()
        } catch {
            self.config = SwitcherConfig()
            self.statusMessage = error.localizedDescription
        }
        refreshInstallation()
    }

    var configuredAccounts: [AccountProfile] {
        config.accounts.filter { $0.isConfigured && hasCredential($0.id) }
    }

    var isChatGPTRunning: Bool { controller.isRunning }

    var activeAccount: AccountProfile? {
        guard let id = config.activeProfileID,
              config.accounts.contains(where: { $0.id == id }) else { return nil }
        return config.account(id)
    }

    func account(_ id: ProfileID) -> AccountProfile { config.account(id) }

    func hasCredential(_ id: ProfileID) -> Bool {
        controller.authStore.hasCredential(for: id)
    }

    func usageError(_ id: ProfileID) -> String? { usageErrors[id] }

    func refreshUsageIfNeeded(force: Bool = false) {
        guard !isRefreshingUsage, let installation else { return }
        if !force, let lastUsageRefresh, Date().timeIntervalSince(lastUsageRefresh) < 300 {
            return
        }
        let accounts = configuredAccounts
        guard !accounts.isEmpty else { return }
        isRefreshingUsage = true

        Task {
            for account in accounts {
                do {
                    let snapshot = try await usageService.fetch(
                        profilePaths: paths.profile(account.id),
                        installation: installation
                    )
                    usageByProfile[account.id] = snapshot
                    usageErrors[account.id] = nil
                } catch {
                    usageErrors[account.id] = error.localizedDescription
                    logger.log("Usage refresh failed for \(account.id.rawValue): \(type(of: error))")
                }
            }
            lastUsageRefresh = Date()
            isRefreshingUsage = false
        }
    }

    func refreshInstallation() {
        do {
            installation = try controller.installation(preferredPath: config.preferredChatGPTPath)
        } catch {
            installation = nil
            statusMessage = error.localizedDescription
        }
    }

    func switchTo(_ id: ProfileID, force: Bool = false) {
        guard !isSwitching else { return }
        let target = config.account(id)
        guard target.isConfigured, hasCredential(id) else {
            beginLoginSetup(id, force: force)
            return
        }

        isSwitching = true
        statusMessage = force ? "正在强制退出并切换…" : "正在切换到 \(target.displayName)…"

        Task {
            do {
                let result = try await controller.switchProfile(
                    to: target,
                    currentProfileID: config.activeProfileID,
                    preferredPath: config.preferredChatGPTPath,
                    launchAfterSwitch: config.automaticallyLaunchChatGPT,
                    force: force
                )
                config.activeProfileID = id
                try save()
                pendingForceProfileID = nil
                switch result {
                case .alreadyActive:
                    statusMessage = "\(target.displayName) 已在运行"
                case .launched:
                    statusMessage = "已切换到 \(target.displayName)，本地项目与历史保持不变"
                case .stopped:
                    statusMessage = "已选择 \(target.displayName)，未自动打开 ChatGPT"
                }
                refreshUsageIfNeeded(force: true)
            } catch ChatGPTControllerError.quitTimedOut {
                pendingForceProfileID = id
                statusMessage = ChatGPTControllerError.quitTimedOut.localizedDescription
            } catch {
                statusMessage = error.localizedDescription
                logger.log("Switch failed for \(id.rawValue): \(type(of: error))")
            }
            isSwitching = false
        }
    }

    func beginLoginSetup(_ id: ProfileID, force: Bool = false) {
        guard !isSwitching else { return }
        let target = config.account(id)
        isSwitching = true
        statusMessage = "正在打开 \(target.displayName) 的官方登录窗口…"

        Task {
            do {
                try await controller.beginLoginSetup(
                    for: target,
                    preferredPath: config.preferredChatGPTPath,
                    force: force
                )
                pendingLoginProfileID = id
                statusMessage = "请在 ChatGPT 中完成 \(target.displayName) 登录，然后点击“完成登录”"
            } catch {
                statusMessage = error.localizedDescription
                logger.log("Login setup failed for \(id.rawValue): \(type(of: error))")
            }
            isSwitching = false
        }
    }

    func completeLoginSetup(_ id: ProfileID, force: Bool = false) {
        guard !isSwitching else { return }
        let target = config.account(id)
        isSwitching = true
        statusMessage = "正在保存 \(target.displayName) 登录并返回共享工作区…"

        Task {
            do {
                _ = try await controller.completeLoginSetup(
                    for: target,
                    preferredPath: config.preferredChatGPTPath,
                    force: force
                )
                var configured = target
                configured.isConfigured = true
                config.updateAccount(configured)
                config.activeProfileID = id
                pendingLoginProfileID = nil
                pendingForceProfileID = nil
                try save()
                registerHotKeys()
                statusMessage = "\(target.displayName) 已保存；所有账号共享同一套本地项目与历史"
                refreshUsageIfNeeded(force: true)
            } catch {
                statusMessage = error.localizedDescription
                logger.log("Completing login failed for \(id.rawValue): \(type(of: error))")
            }
            isSwitching = false
        }
    }

    func addAccount() {
        let (id, displayName) = nextAccountIdentity()
        config.updateAccount(AccountProfile(id: id, displayName: displayName))
        if let key = nextShortcutKey() {
            config.shortcuts[id] = HotKeyConfiguration(key: key)
        }
        trySave()
        registerHotKeys()
        beginLoginSetup(id)
    }

    func openChatGPT() {
        if let active = config.activeProfileID,
           config.account(active).isConfigured,
           hasCredential(active) {
            switchTo(active)
        } else if let first = configuredAccounts.first {
            switchTo(first.id)
        } else {
            statusMessage = "请先添加并登录一个账号"
        }
    }

    func rename(_ id: ProfileID, to rawName: String) {
        var account = config.account(id)
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        account.displayName = String(trimmed.prefix(40))
        if account.displayName.isEmpty { account.displayName = id.defaultDisplayName }
        config.updateAccount(account)
        trySave()
    }

    func updateShortcut(_ id: ProfileID, _ shortcut: HotKeyConfiguration) {
        config.shortcuts[id] = shortcut
        trySave()
        registerHotKeys()
    }

    func setAutomaticallyLaunch(_ enabled: Bool) {
        config.automaticallyLaunchChatGPT = enabled
        trySave()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            config.launchAtLogin = enabled
            try save()
        } catch {
            config.launchAtLogin = SMAppService.mainApp.status == .enabled
            statusMessage = "无法更新登录启动设置：\(error.localizedDescription)"
        }
    }

    func deleteProfile(_ id: ProfileID) {
        do {
            try profiles.delete(
                id,
                activeProfileID: config.activeProfileID,
                chatGPTIsRunning: controller.isRunning
            )
            controller.authStore.removeMarkerIfActive(id)
            let name = config.account(id).displayName
            config.removeAccount(id)
            usageByProfile[id] = nil
            usageErrors[id] = nil
            if pendingLoginProfileID == id { pendingLoginProfileID = nil }
            try save()
            registerHotKeys()
            logger.log("Deleted GPT Switcher account slot \(id.rawValue)")
            statusMessage = "已删除 \(name) 的账号登录快照；共享项目和历史未删除"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func openProfileFolder(_ id: ProfileID) {
        do {
            let path = try profiles.prepare(id).root
            NSWorkspace.shared.activateFileViewerSelecting([path])
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func openSharedWorkspaceFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([paths.sharedCodexHome])
    }

    func openLogsFolder() {
        do {
            try paths.createSupportDirectories()
            NSWorkspace.shared.open(paths.logsRoot)
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func registerHotKeys() {
        let accountIDs = config.accounts.filter(\.isConfigured).map(\.id)
        HotKeyManager.shared.register(shortcuts: config.shortcuts, accountOrder: accountIDs) { [weak self] id in
            guard let self else { return }
            guard self.account(id).isConfigured, self.hasCredential(id) else {
                self.statusMessage = "请先完成 \(self.account(id).displayName) 登录"
                return
            }
            self.switchTo(id)
        }
    }

    private func nextAccountIdentity() -> (ProfileID, String) {
        let used = Set(config.accounts.map(\.id))
        for scalar in UnicodeScalar("A").value...UnicodeScalar("Z").value {
            guard let letter = UnicodeScalar(scalar).map({ String(Character($0)) }) else { continue }
            let raw = "account-\(letter.lowercased())"
            if let id = ProfileID(rawValue: raw), !used.contains(id) {
                return (id, "Account \(letter)")
            }
        }
        let raw = "account-\(UUID().uuidString.lowercased())"
        return (ProfileID(rawValue: raw)!, "新账号")
    }

    private func nextShortcutKey() -> String? {
        let used = Set(config.shortcuts.values.map { $0.key.uppercased() })
        return (1...9).map(String.init).first { !used.contains($0) }
    }

    private func save() throws { try store.save(config) }

    private func trySave() {
        do { try save() }
        catch { statusMessage = error.localizedDescription }
    }
}
