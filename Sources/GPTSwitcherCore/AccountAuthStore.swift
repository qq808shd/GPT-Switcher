import Foundation

public enum AccountAuthStoreError: LocalizedError {
    case missingCredential(ProfileID)
    case unsafeCredentialFile

    public var errorDescription: String? {
        switch self {
        case .missingCredential:
            return "这个账号还没有保存登录状态，请先完成账号登录。"
        case .unsafeCredentialFile:
            return "登录状态文件不安全或格式异常，已停止切换。"
        }
    }
}

private struct ActiveAuthMarker: Codable {
    let profileID: ProfileID
}

/// Moves opaque, official Codex auth files between private account slots.
/// The contents are never decoded, inspected, or logged by GPT Switcher.
public final class AccountAuthStore: @unchecked Sendable {
    public let paths: GPTSwitcherPaths
    private let fileManager: FileManager

    public init(paths: GPTSwitcherPaths = .live, fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
    }

    public func hasCredential(for id: ProfileID) -> Bool {
        isSafeCredentialFile(paths.profile(id).authSnapshot)
    }

    public func activeProfileID() -> ProfileID? {
        guard let data = try? Data(contentsOf: paths.activeAuthMarkerURL),
              let marker = try? JSONDecoder().decode(ActiveAuthMarker.self, from: data) else {
            return nil
        }
        return marker.profileID
    }

    public func preserveCurrentCredentialIfManaged() throws {
        guard let current = activeProfileID(), isSafeCredentialFile(paths.sharedAuthURL) else { return }
        _ = try paths.createProfileDirectories(for: current)
        try atomicOpaqueCopy(from: paths.sharedAuthURL, to: paths.profile(current).authSnapshot)
    }

    public func activate(_ id: ProfileID) throws {
        let source = paths.profile(id).authSnapshot
        guard isSafeCredentialFile(source) else {
            throw AccountAuthStoreError.missingCredential(id)
        }
        try paths.createSupportDirectories()
        try fileManager.createDirectory(
            at: paths.sharedCodexHome,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try backupOriginalSharedCredentialIfNeeded()
        try atomicOpaqueCopy(from: source, to: paths.sharedAuthURL)
        try saveMarker(id)
    }

    public func removeMarkerIfActive(_ id: ProfileID) {
        guard activeProfileID() == id else { return }
        try? fileManager.removeItem(at: paths.activeAuthMarkerURL)
    }

    private func backupOriginalSharedCredentialIfNeeded() throws {
        guard !fileManager.fileExists(atPath: paths.originalSharedAuthBackupURL.path),
              isSafeCredentialFile(paths.sharedAuthURL) else { return }
        try atomicOpaqueCopy(from: paths.sharedAuthURL, to: paths.originalSharedAuthBackupURL)
    }

    private func saveMarker(_ id: ProfileID) throws {
        let data = try JSONEncoder().encode(ActiveAuthMarker(profileID: id))
        try data.write(to: paths.activeAuthMarkerURL, options: .atomic)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.activeAuthMarkerURL.path)
    }

    private func isSafeCredentialFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
        ]) else { return false }
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let size = values.fileSize,
              size > 0,
              size <= 5_000_000 else { return false }
        return true
    }

    private func atomicOpaqueCopy(from source: URL, to destination: URL) throws {
        guard isSafeCredentialFile(source) else {
            throw AccountAuthStoreError.unsafeCredentialFile
        }
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".gpt-switcher-\(UUID().uuidString).tmp")
        defer { try? fileManager.removeItem(at: temporary) }
        try fileManager.copyItem(at: source, to: temporary)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: destination)
        }
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }
}
