import AppKit
import Foundation

public enum SwitchResult: Equatable, Sendable {
    case alreadyActive
    case launched
    case stopped
}

public enum ChatGPTControllerError: LocalizedError {
    case incompatibleInstallation
    case quitTimedOut
    case launchFailed(String)
    case launchTimedOut

    public var errorDescription: String? {
        switch self {
        case .incompatibleInstallation:
            return "当前 ChatGPT 版本可能不支持账号登录配置。为保护数据，已停止切换。"
        case .quitTimedOut:
            return "ChatGPT 仍在运行。你可以选择强制退出后再切换。"
        case .launchFailed(let message):
            return "ChatGPT 启动失败：\(message)"
        case .launchTimedOut:
            return "已发出启动请求，但未能在限定时间内确认 ChatGPT 正在运行。"
        }
    }
}

@MainActor
public final class ChatGPTController {
    public let paths: GPTSwitcherPaths
    public let logger: SafeLogger
    public let authStore: AccountAuthStore
    private let inspector: ChatGPTInspector

    public init(
        paths: GPTSwitcherPaths = .live,
        logger: SafeLogger? = nil,
        inspector: ChatGPTInspector = ChatGPTInspector(),
        authStore: AccountAuthStore? = nil
    ) {
        self.paths = paths
        self.logger = logger ?? SafeLogger(paths: paths)
        self.inspector = inspector
        self.authStore = authStore ?? AccountAuthStore(paths: paths)
    }

    public var isRunning: Bool {
        !NSRunningApplication.runningApplications(
            withBundleIdentifier: ChatGPTInspector.expectedBundleIdentifier
        ).filter { !$0.isTerminated }.isEmpty
    }

    public func installation(preferredPath: String? = nil) throws -> ChatGPTInstallation {
        try inspector.inspect(preferredPath: preferredPath)
    }

    /// Switches only the active account credential. The official default ChatGPT
    /// and CODEX_HOME directories remain shared, so local projects and threads do not move.
    public func switchProfile(
        to profile: AccountProfile,
        currentProfileID: ProfileID?,
        preferredPath: String? = nil,
        launchAfterSwitch: Bool = true,
        force: Bool = false
    ) async throws -> SwitchResult {
        let installation = try supportedInstallation(preferredPath: preferredPath)
        guard authStore.hasCredential(for: profile.id) else {
            throw AccountAuthStoreError.missingCredential(profile.id)
        }

        if authStore.activeProfileID() == profile.id && isRunning {
            return .alreadyActive
        }

        if isRunning {
            logger.log("Switch \(currentProfileID?.rawValue ?? "unknown") → \(profile.id.rawValue)")
            requestQuit(force: force)
            guard await waitUntilRunning(false, timeout: force ? 8 : 12) else {
                throw ChatGPTControllerError.quitTimedOut
            }
            logger.log("ChatGPT terminated")
        }

        try authStore.preserveCurrentCredentialIfManaged()
        try authStore.activate(profile.id)
        logger.log("Activated account credential \(profile.id.rawValue); shared workspace unchanged")

        guard launchAfterSwitch else {
            logger.log("Account selected without launch: \(profile.id.rawValue)")
            return .stopped
        }

        try launch(arguments: sharedLaunchArguments(installation: installation))
        guard await waitUntilRunning(true, timeout: 15) else {
            throw ChatGPTControllerError.launchTimedOut
        }
        logger.log("ChatGPT launched with \(profile.id.rawValue); shared workspace")
        return .launched
    }

    /// Starts a one-time isolated official login window. Once login finishes,
    /// completeLoginSetup moves only that opaque auth file into the shared workspace.
    public func beginLoginSetup(
        for profile: AccountProfile,
        preferredPath: String? = nil,
        force: Bool = false
    ) async throws {
        let installation = try supportedInstallation(preferredPath: preferredPath)
        if isRunning {
            requestQuit(force: force)
            guard await waitUntilRunning(false, timeout: force ? 8 : 12) else {
                throw ChatGPTControllerError.quitTimedOut
            }
        }
        try authStore.preserveCurrentCredentialIfManaged()
        let profilePaths = try paths.createProfileDirectories(for: profile.id)
        try launch(arguments: isolatedLoginArguments(installation: installation, profile: profilePaths))
        guard await waitUntilRunning(true, timeout: 15) else {
            throw ChatGPTControllerError.launchTimedOut
        }
        logger.log("Started official login setup for \(profile.id.rawValue)")
    }

    public func completeLoginSetup(
        for profile: AccountProfile,
        preferredPath: String? = nil,
        force: Bool = false
    ) async throws -> SwitchResult {
        let installation = try supportedInstallation(preferredPath: preferredPath)
        guard authStore.hasCredential(for: profile.id) else {
            throw AccountAuthStoreError.missingCredential(profile.id)
        }
        if isRunning {
            requestQuit(force: force)
            guard await waitUntilRunning(false, timeout: force ? 8 : 12) else {
                throw ChatGPTControllerError.quitTimedOut
            }
        }
        try authStore.activate(profile.id)
        try launch(arguments: sharedLaunchArguments(installation: installation))
        guard await waitUntilRunning(true, timeout: 15) else {
            throw ChatGPTControllerError.launchTimedOut
        }
        logger.log("Completed login setup for \(profile.id.rawValue); shared workspace")
        return .launched
    }

    public func openActiveProfile(
        _ profile: AccountProfile,
        preferredPath: String? = nil
    ) async throws -> SwitchResult {
        try await switchProfile(
            to: profile,
            currentProfileID: profile.id,
            preferredPath: preferredPath
        )
    }

    public func forceQuit() async -> Bool {
        requestQuit(force: true)
        return await waitUntilRunning(false, timeout: 8)
    }

    public func sharedLaunchArguments(installation: ChatGPTInstallation) -> [String] {
        [
            "-n",
            "--env", "CODEX_HOME=\(paths.sharedCodexHome.path)",
            "--env", "\(ChatGPTInspector.explicitUserDataEnvironment)=\(paths.sharedChatGPTData.path)",
            installation.appURL.path,
            "--args",
            "--user-data-dir=\(paths.sharedChatGPTData.path)",
        ]
    }

    public func isolatedLoginArguments(
        installation: ChatGPTInstallation,
        profile: ProfilePaths
    ) -> [String] {
        [
            "-n",
            "--env", "CODEX_HOME=\(profile.codex.path)",
            "--env", "\(ChatGPTInspector.explicitUserDataEnvironment)=\(profile.chatGPT.path)",
            installation.appURL.path,
            "--args",
            "--user-data-dir=\(profile.chatGPT.path)",
        ]
    }

    private func supportedInstallation(preferredPath: String?) throws -> ChatGPTInstallation {
        let installation = try inspector.inspect(preferredPath: preferredPath)
        guard installation.isSupported else {
            logger.log("Compatibility check failed for ChatGPT \(installation.version) (\(installation.build))")
            throw ChatGPTControllerError.incompatibleInstallation
        }
        return installation
    }

    private func launch(arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = arguments
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ChatGPTControllerError.launchFailed(message?.isEmpty == false ? message! : "open 返回错误")
        }
    }

    private func requestQuit(force: Bool) {
        let applications = NSRunningApplication.runningApplications(
            withBundleIdentifier: ChatGPTInspector.expectedBundleIdentifier
        )
        for application in applications where !application.isTerminated {
            if force { application.forceTerminate() } else { application.terminate() }
        }
    }

    private func waitUntilRunning(_ expected: Bool, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isRunning == expected { return true }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return isRunning == expected
    }
}
