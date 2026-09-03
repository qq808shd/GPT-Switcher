import Foundation

public enum ProfileManagerError: LocalizedError {
    case unsafePath
    case activeProfileRunning

    public var errorDescription: String? {
        switch self {
        case .unsafePath:
            return "Profile 路径不属于 GPT Switcher，已拒绝删除。"
        case .activeProfileRunning:
            return "请先切换或退出当前 ChatGPT，再删除这个 Profile。"
        }
    }
}

public struct ProfileManager {
    public let paths: GPTSwitcherPaths

    public init(paths: GPTSwitcherPaths = .live) {
        self.paths = paths
    }

    public func prepare(_ id: ProfileID) throws -> ProfilePaths {
        try paths.createProfileDirectories(for: id)
    }

    public func delete(_ id: ProfileID, activeProfileID: ProfileID?, chatGPTIsRunning: Bool) throws {
        if activeProfileID == id && chatGPTIsRunning {
            throw ProfileManagerError.activeProfileRunning
        }
        let expected = paths.profilesRoot.appendingPathComponent(id.rawValue, isDirectory: true)
            .standardizedFileURL
        let actual = paths.profile(id).root.standardizedFileURL
        guard actual == expected,
              actual.deletingLastPathComponent() == paths.profilesRoot.standardizedFileURL else {
            throw ProfileManagerError.unsafePath
        }

        for protectedPath in [paths.applicationSupportRoot, paths.profilesRoot, actual] {
            if (try? protectedPath.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                throw ProfileManagerError.unsafePath
            }
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: actual.path, isDirectory: &isDirectory) else { return }
        guard isDirectory.boolValue else { throw ProfileManagerError.unsafePath }
        try FileManager.default.removeItem(at: actual)
    }
}
