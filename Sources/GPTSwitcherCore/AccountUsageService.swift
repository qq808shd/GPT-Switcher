import Foundation

public struct UsageLimitWindow: Codable, Equatable, Sendable {
    public let usedPercent: Int
    public let windowDurationMinutes: Int?
    public let resetsAt: Date?

    public init(usedPercent: Int, windowDurationMinutes: Int?, resetsAt: Date?) {
        self.usedPercent = min(100, max(0, usedPercent))
        self.windowDurationMinutes = windowDurationMinutes
        self.resetsAt = resetsAt
    }

    public var remainingPercent: Int { 100 - usedPercent }
}

public struct UsageLimitBucket: Codable, Equatable, Sendable {
    public let id: String
    public let name: String?
    public let windows: [UsageLimitWindow]

    public init(id: String, name: String?, windows: [UsageLimitWindow]) {
        self.id = id
        self.name = name
        self.windows = windows
    }
}

public struct AccountUsageSnapshot: Codable, Equatable, Sendable {
    public let planType: String?
    public let buckets: [UsageLimitBucket]
    public let fetchedAt: Date

    public init(planType: String?, buckets: [UsageLimitBucket], fetchedAt: Date = Date()) {
        self.planType = planType
        self.buckets = buckets
        self.fetchedAt = fetchedAt
    }

    public var allWindows: [UsageLimitWindow] {
        buckets.flatMap(\.windows)
    }

    public var planDisplayName: String? {
        switch planType?.lowercased() {
        case "plus": return "Plus"
        case "pro": return "Pro"
        case "prolite": return "Pro 5x"
        case "free": return "Free"
        case "go": return "Go"
        case "team", "business", "self_serve_business_prolite", "self_serve_business_usage_based":
            return "Business"
        case "enterprise", "enterprise_cbp_automation", "enterprise_cbp_usage_based", "ent26":
            return "Enterprise"
        case "edu", "edu_plus", "edu_pro": return "Edu"
        case .some(let value) where !value.isEmpty && value != "unknown": return value
        default: return nil
        }
    }
}

public enum AccountUsageServiceError: LocalizedError {
    case missingCredential
    case missingCodexExecutable
    case launchFailed
    case requestTimedOut
    case serverError
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .missingCredential: return "账号登录状态不可用"
        case .missingCodexExecutable: return "当前 ChatGPT 安装中没有找到 Codex 用量查询组件"
        case .launchFailed: return "无法启动本地用量查询组件"
        case .requestTimedOut: return "额度查询超时"
        case .serverError: return "OpenAI 暂时无法返回这个账号的额度"
        case .invalidResponse: return "收到的额度数据格式暂不支持"
        }
    }
}

public actor AccountUsageService {
    private let timeout: TimeInterval

    public init(timeout: TimeInterval = 20) {
        self.timeout = timeout
    }

    public func fetch(
        profilePaths: ProfilePaths,
        installation: ChatGPTInstallation
    ) async throws -> AccountUsageSnapshot {
        let timeout = timeout
        return try await Task.detached(priority: .utility) {
            try Self.fetchBlocking(
                profilePaths: profilePaths,
                installation: installation,
                timeout: timeout
            )
        }.value
    }

    static func decodeRateLimitResponse(_ data: Data, fetchedAt: Date = Date()) throws -> AccountUsageSnapshot? {
        let envelope: RPCEnvelope
        do {
            envelope = try JSONDecoder().decode(RPCEnvelope.self, from: data)
        } catch {
            return nil
        }
        guard envelope.id == 2 else { return nil }
        if envelope.error != nil { throw AccountUsageServiceError.serverError }
        guard let response = envelope.result else { throw AccountUsageServiceError.invalidResponse }

        let snapshots: [(String, RateLimitSnapshotDTO)]
        if let byID = response.rateLimitsByLimitId, !byID.isEmpty {
            snapshots = byID.sorted { lhs, rhs in
                if lhs.key == "codex" { return true }
                if rhs.key == "codex" { return false }
                return lhs.key < rhs.key
            }
        } else {
            snapshots = [(response.rateLimits.limitId ?? "codex", response.rateLimits)]
        }

        let buckets = snapshots.compactMap { fallbackID, snapshot -> UsageLimitBucket? in
            let windows = [snapshot.primary, snapshot.secondary].compactMap { dto -> UsageLimitWindow? in
                guard let dto else { return nil }
                return UsageLimitWindow(
                    usedPercent: dto.usedPercent,
                    windowDurationMinutes: dto.windowDurationMins,
                    resetsAt: dto.resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
                )
            }
            guard !windows.isEmpty else { return nil }
            return UsageLimitBucket(
                id: snapshot.limitId ?? fallbackID,
                name: snapshot.limitName,
                windows: windows
            )
        }
        let preferredPlan = response.rateLimitsByLimitId?["codex"]?.planType
            ?? response.rateLimits.planType
            ?? snapshots.compactMap { $0.1.planType }.first
        return AccountUsageSnapshot(planType: preferredPlan, buckets: buckets, fetchedAt: fetchedAt)
    }

    private static func fetchBlocking(
        profilePaths: ProfilePaths,
        installation: ChatGPTInstallation,
        timeout: TimeInterval
    ) throws -> AccountUsageSnapshot {
        let fileManager = FileManager.default
        let sourceAuth = profilePaths.authSnapshot
        guard isSafeCredentialFile(sourceAuth) else {
            throw AccountUsageServiceError.missingCredential
        }
        let codexExecutable = installation.appURL.appendingPathComponent("Contents/Resources/codex")
        guard fileManager.isExecutableFile(atPath: codexExecutable.path) else {
            throw AccountUsageServiceError.missingCodexExecutable
        }

        let temporaryHome = fileManager.temporaryDirectory
            .appendingPathComponent("GPTSwitcherUsage-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(
            at: temporaryHome,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? fileManager.removeItem(at: temporaryHome) }
        let temporaryAuth = temporaryHome.appendingPathComponent("auth.json")
        try fileManager.copyItem(at: sourceAuth, to: temporaryAuth)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporaryAuth.path)

        let process = Process()
        process.executableURL = codexExecutable
        process.arguments = ["app-server", "--stdio", "--disable", "plugins"]
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = temporaryHome.path
        process.environment = environment

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice

        let stateQueue = DispatchQueue(label: "com.gptswitcher.usage-response")
        let completed = DispatchSemaphore(value: 0)
        var buffered = Data()
        var finalResult: Result<AccountUsageSnapshot, Error>?

        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            stateQueue.sync {
                guard finalResult == nil else { return }
                buffered.append(chunk)
                while let newline = buffered.firstIndex(of: 0x0A) {
                    let line = Data(buffered[..<newline])
                    buffered.removeSubrange(...newline)
                    do {
                        if let snapshot = try decodeRateLimitResponse(line) {
                            finalResult = .success(snapshot)
                            completed.signal()
                            return
                        }
                    } catch {
                        finalResult = .failure(error)
                        completed.signal()
                        return
                    }
                }
            }
        }

        do {
            try process.run()
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            throw AccountUsageServiceError.launchFailed
        }

        let requests = [
            #"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"gpt-switcher","title":"GPT Switcher","version":"1.2.0"},"capabilities":{"experimentalApi":true}}}"#,
            #"{"method":"initialized"}"#,
            #"{"id":2,"method":"account/rateLimits/read"}"#,
        ].joined(separator: "\n") + "\n"
        try inputPipe.fileHandleForWriting.write(contentsOf: Data(requests.utf8))

        let waitResult = completed.wait(timeout: .now() + timeout)
        outputPipe.fileHandleForReading.readabilityHandler = nil
        try? inputPipe.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        process.waitUntilExit()

        guard waitResult == .success else {
            throw AccountUsageServiceError.requestTimedOut
        }
        let result = stateQueue.sync { finalResult }
        guard let result else { throw AccountUsageServiceError.invalidResponse }
        let snapshot = try result.get()

        // The app server may transparently refresh the official OAuth file. Keep
        // that opaque refresh in the account slot without decoding its contents.
        if isSafeCredentialFile(temporaryAuth) {
            try atomicOpaqueCopy(from: temporaryAuth, to: sourceAuth)
        }
        return snapshot
    }

    private static func isSafeCredentialFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
        ]) else { return false }
        return values.isRegularFile == true
            && values.isSymbolicLink != true
            && (values.fileSize ?? 0) > 0
            && (values.fileSize ?? 0) <= 5_000_000
    }

    private static func atomicOpaqueCopy(from source: URL, to destination: URL) throws {
        guard isSafeCredentialFile(source) else { throw AccountUsageServiceError.missingCredential }
        let fileManager = FileManager.default
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".gpt-switcher-usage-\(UUID().uuidString).tmp")
        defer { try? fileManager.removeItem(at: temporary) }
        try fileManager.copyItem(at: source, to: temporary)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: destination)
        }
    }
}

private struct RPCEnvelope: Decodable {
    let id: Int?
    let result: GetAccountRateLimitsResponseDTO?
    let error: RPCErrorDTO?
}

private struct RPCErrorDTO: Decodable {
    let code: Int?
}

private struct GetAccountRateLimitsResponseDTO: Decodable {
    let rateLimits: RateLimitSnapshotDTO
    let rateLimitsByLimitId: [String: RateLimitSnapshotDTO]?
}

private struct RateLimitSnapshotDTO: Decodable {
    let limitId: String?
    let limitName: String?
    let planType: String?
    let primary: RateLimitWindowDTO?
    let secondary: RateLimitWindowDTO?
}

private struct RateLimitWindowDTO: Decodable {
    let usedPercent: Int
    let windowDurationMins: Int?
    let resetsAt: Int64?
}
