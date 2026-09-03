import Foundation

public struct ProfileID: Codable, Hashable, Identifiable, Sendable {
    public let rawValue: String

    public var id: String { rawValue }

    public init?(rawValue: String) {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        guard !rawValue.isEmpty,
              rawValue.count <= 64,
              rawValue.unicodeScalars.allSatisfy(allowed.contains),
              !rawValue.hasPrefix("-"),
              !rawValue.hasSuffix("-") else {
            return nil
        }
        self.rawValue = rawValue
    }

    public static let accountA = ProfileID(rawValue: "account-a")!
    public static let accountB = ProfileID(rawValue: "account-b")!
    public static let legacyAccounts: [ProfileID] = [.accountA, .accountB]

    public var defaultDisplayName: String {
        if rawValue.hasPrefix("account-"),
           let suffix = rawValue.split(separator: "-").last,
           suffix.count == 1 {
            return "Account \(suffix.uppercased())"
        }
        return "Account"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let id = ProfileID(rawValue: value) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid GPT Switcher profile ID"
            )
        }
        self = id
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct AccountProfile: Codable, Hashable, Identifiable, Sendable {
    public var id: ProfileID
    public var displayName: String
    public var isConfigured: Bool

    public init(id: ProfileID, displayName: String? = nil, isConfigured: Bool = false) {
        self.id = id
        self.displayName = displayName ?? id.defaultDisplayName
        self.isConfigured = isConfigured
    }
}

public struct HotKeyConfiguration: Codable, Equatable, Sendable {
    public var key: String
    public var command: Bool
    public var option: Bool
    public var control: Bool
    public var shift: Bool

    public init(
        key: String,
        command: Bool = true,
        option: Bool = true,
        control: Bool = false,
        shift: Bool = false
    ) {
        self.key = key
        self.command = command
        self.option = option
        self.control = control
        self.shift = shift
    }

    public var displayText: String {
        let modifiers = (control ? "⌃" : "") + (option ? "⌥" : "")
            + (shift ? "⇧" : "") + (command ? "⌘" : "")
        return modifiers + key.uppercased()
    }
}

public struct SwitcherConfig: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 2

    public var schemaVersion: Int
    public var accounts: [AccountProfile]
    public var activeProfileID: ProfileID?
    public var shortcuts: [ProfileID: HotKeyConfiguration]
    public var launchAtLogin: Bool
    public var automaticallyLaunchChatGPT: Bool
    public var preferredChatGPTPath: String?

    public init(
        schemaVersion: Int = SwitcherConfig.currentSchemaVersion,
        accounts: [AccountProfile] = ProfileID.legacyAccounts.map { AccountProfile(id: $0) },
        activeProfileID: ProfileID? = nil,
        shortcuts: [ProfileID: HotKeyConfiguration] = [
            .accountA: HotKeyConfiguration(key: "1"),
            .accountB: HotKeyConfiguration(key: "2"),
        ],
        launchAtLogin: Bool = false,
        automaticallyLaunchChatGPT: Bool = true,
        preferredChatGPTPath: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.accounts = accounts
        self.activeProfileID = activeProfileID
        self.shortcuts = shortcuts
        self.launchAtLogin = launchAtLogin
        self.automaticallyLaunchChatGPT = automaticallyLaunchChatGPT
        self.preferredChatGPTPath = preferredChatGPTPath
    }

    public func account(_ id: ProfileID) -> AccountProfile {
        accounts.first(where: { $0.id == id }) ?? AccountProfile(id: id)
    }

    public mutating func updateAccount(_ account: AccountProfile) {
        if let index = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[index] = account
        } else {
            accounts.append(account)
        }
    }

    public mutating func removeAccount(_ id: ProfileID) {
        accounts.removeAll { $0.id == id }
        shortcuts[id] = nil
        if activeProfileID == id { activeProfileID = nil }
    }
}

public struct ProfilePaths: Equatable, Sendable {
    public let root: URL
    public let chatGPT: URL
    public let codex: URL

    public var authSnapshot: URL {
        codex.appendingPathComponent("auth.json")
    }
}
