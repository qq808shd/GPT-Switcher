import Foundation

public enum ConfigStoreError: LocalizedError {
    case unsupportedSchema(Int)

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version):
            return "配置文件版本 \(version) 暂不受支持。"
        }
    }
}

public final class ConfigStore {
    public let paths: GPTSwitcherPaths

    public init(paths: GPTSwitcherPaths = .live) {
        self.paths = paths
    }

    public func load() throws -> SwitcherConfig {
        guard FileManager.default.fileExists(atPath: paths.configURL.path) else {
            return SwitcherConfig()
        }
        let data = try Data(contentsOf: paths.configURL)
        var config = try JSONDecoder().decode(SwitcherConfig.self, from: data)
        guard (1...SwitcherConfig.currentSchemaVersion).contains(config.schemaVersion) else {
            throw ConfigStoreError.unsupportedSchema(config.schemaVersion)
        }
        if config.schemaVersion == 1 {
            for id in ProfileID.legacyAccounts where !config.accounts.contains(where: { $0.id == id }) {
                config.accounts.append(AccountProfile(id: id))
            }
            config.schemaVersion = SwitcherConfig.currentSchemaVersion
        }
        return normalized(config)
    }

    public func save(_ config: SwitcherConfig) throws {
        try paths.createSupportDirectories()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(normalized(config))
        try data.write(to: paths.configURL, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: paths.configURL.path
        )
    }

    private func normalized(_ input: SwitcherConfig) -> SwitcherConfig {
        var config = input
        config.schemaVersion = SwitcherConfig.currentSchemaVersion
        var seen = Set<ProfileID>()
        config.accounts = config.accounts.filter { seen.insert($0.id).inserted }
        if let active = config.activeProfileID,
           !config.accounts.contains(where: { $0.id == active }) {
            config.activeProfileID = nil
        }
        return config
    }
}
