import GPTSwitcherCore
import SwiftUI

struct MenuContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if model.configuredAccounts.isEmpty {
                Text("所有账号共享同一套本地项目、对话和任务。第一次添加账号时，登录仍在官方 ChatGPT 窗口中完成。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            accounts

            if let message = model.statusMessage {
                Label(message, systemImage: model.pendingForceProfileID == nil ? "info.circle" : "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundColor(model.pendingForceProfileID == nil ? .secondary : .orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("状态：\(message)")
            }

            if let pending = model.pendingForceProfileID {
                Button(role: .destructive) {
                    model.switchTo(pending, force: true)
                } label: {
                    Label("强制退出并继续切换", systemImage: "exclamationmark.octagon")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isSwitching)
            }

            Divider()

            VStack(spacing: 6) {
                Button(action: model.addAccount) {
                    Label("添加账号", systemImage: "person.badge.plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .disabled(model.isSwitching)

                Button {
                    model.refreshUsageIfNeeded(force: true)
                } label: {
                    HStack {
                        Label("刷新账号额度", systemImage: "arrow.clockwise")
                        Spacer()
                        if model.isRefreshingUsage { ProgressView().controlSize(.small) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .disabled(model.configuredAccounts.isEmpty || model.isRefreshingUsage)
                .accessibilityHint("读取所有已登录账号的最新额度和重置时间")

                Button(action: model.openChatGPT) {
                    Label("打开 ChatGPT", systemImage: "arrow.up.forward.app")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .disabled(model.configuredAccounts.isEmpty || model.isSwitching)

                SettingsLink {
                    Label("账号管理与设置", systemImage: "gearshape")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)

                Button(role: .destructive) { NSApplication.shared.terminate(nil) } label: {
                    Label("退出 GPT Switcher", systemImage: "power")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
            .labelStyle(.titleAndIcon)
        }
        .padding(16)
        .frame(width: 390)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("GPT Switcher").font(.headline)
                Text(currentStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.isSwitching { ProgressView().controlSize(.small) }
        }
    }

    private var currentStatus: String {
        if let active = model.activeAccount {
            return "当前：\(active.displayName)" + (model.isChatGPTRunning ? "" : "（未运行）")
        }
        return "尚未选择账号"
    }

    private var accounts: some View {
        VStack(spacing: 8) {
            ForEach(model.config.accounts) { account in
                if model.pendingLoginProfileID == account.id {
                    Button {
                        model.completeLoginSetup(account.id)
                    } label: {
                        Label("完成 \(account.displayName) 登录", systemImage: "checkmark.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isSwitching)
                } else if account.isConfigured && model.hasCredential(account.id) {
                    Button {
                        model.switchTo(account.id)
                    } label: {
                        HStack {
                            Image(systemName: model.config.activeProfileID == account.id ? "checkmark.circle.fill" : "circle")
                                .foregroundColor(model.config.activeProfileID == account.id ? .accentColor : .secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(account.displayName)
                                    if let plan = model.usageByProfile[account.id]?.planDisplayName {
                                        Text(plan)
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                AccountUsageCompactView(
                                    snapshot: model.usageByProfile[account.id],
                                    error: model.usageError(account.id),
                                    isLoading: model.isRefreshingUsage
                                )
                            }
                            Spacer()
                            Text(model.config.shortcuts[account.id]?.displayText ?? "")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 5)
                    .disabled(model.isSwitching)
                    .accessibilityLabel("切换到 \(account.displayName)")
                    .accessibilityValue(usageAccessibilityValue(account.id))
                    .accessibilityHint("切换模型账号，本地项目和历史保持不变")
                } else {
                    Button {
                        model.beginLoginSetup(account.id)
                    } label: {
                        Label("登录 \(account.displayName)", systemImage: "plus.circle")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .disabled(model.isSwitching)
                }
            }
        }
    }

    private func usageAccessibilityValue(_ id: ProfileID) -> String {
        if let snapshot = model.usageByProfile[id] {
            let plan = snapshot.planDisplayName.map { "\($0) 套餐。" } ?? ""
            let windows = snapshot.buckets.flatMap(\.windows).map { window in
                "\(UsageText.duration(window.windowDurationMinutes))额度剩余 \(window.remainingPercent)%，\(UsageText.reset(window.resetsAt))"
            }
            return plan + windows.joined(separator: "。")
        }
        if model.isRefreshingUsage { return "正在获取额度" }
        if model.usageError(id) != nil { return "额度暂不可用" }
        return "尚未获取额度"
    }
}

private struct AccountUsageCompactView: View {
    let snapshot: AccountUsageSnapshot?
    let error: String?
    let isLoading: Bool

    var body: some View {
        if let snapshot, !rows(snapshot).isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(rows(snapshot)) { row in
                    HStack(spacing: 4) {
                        Text("\(row.label)剩余 \(row.window.remainingPercent)%")
                            .foregroundStyle(color(for: row.window.remainingPercent))
                        Text("·")
                        Text(UsageText.reset(row.window.resetsAt))
                    }
                    .font(.caption)
                    .monospacedDigit()
                }
            }
        } else if isLoading {
            Text("正在获取额度…")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if error != nil {
            Text("额度暂不可用")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Text("点击“刷新账号额度”获取")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private func rows(_ snapshot: AccountUsageSnapshot) -> [UsageRow] {
        let multipleBuckets = snapshot.buckets.count > 1
        return snapshot.buckets.flatMap { bucket in
            bucket.windows.enumerated().map { index, window in
                let bucketPrefix = multipleBuckets ? "\(bucket.name ?? bucket.id) · " : ""
                return UsageRow(
                    id: "\(bucket.id)-\(index)",
                    label: bucketPrefix + UsageText.duration(window.windowDurationMinutes) + " ",
                    window: window
                )
            }
        }
    }

    private func color(for remaining: Int) -> Color {
        if remaining <= 10 { return .red }
        if remaining <= 30 { return .orange }
        return .secondary
    }

    private struct UsageRow: Identifiable {
        let id: String
        let label: String
        let window: UsageLimitWindow
    }
}

private enum UsageText {
    static func duration(_ minutes: Int?) -> String {
        guard let minutes, minutes > 0 else { return "当前窗口" }
        if minutes % 10_080 == 0 { return "\(minutes / 10_080) 周" }
        if minutes % 1_440 == 0 { return "\(minutes / 1_440) 天" }
        if minutes % 60 == 0 { return "\(minutes / 60) 小时" }
        return "\(minutes) 分钟"
    }

    static func reset(_ date: Date?) -> String {
        guard let date else { return "重置时间未知" }
        if Calendar.current.isDateInToday(date) {
            return date.formatted(.dateTime.hour().minute()) + " 重置"
        }
        return date.formatted(.dateTime.month().day().hour().minute()) + " 重置"
    }
}
