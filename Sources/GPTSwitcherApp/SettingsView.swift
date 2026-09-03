import GPTSwitcherCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        TabView {
            AccountsSettingsView(model: model)
                .tabItem { Label("账号", systemImage: "person.2") }
            ShortcutSettingsView(model: model)
                .tabItem { Label("快捷键", systemImage: "keyboard") }
            GeneralSettingsView(model: model)
                .tabItem { Label("通用", systemImage: "gearshape") }
            AdvancedSettingsView(model: model)
                .tabItem { Label("高级", systemImage: "wrench.and.screwdriver") }
        }
        .frame(width: 660, height: 500)
    }
}

private struct AccountsSettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section {
                Text("账号只切换模型登录身份；所有账号始终使用系统默认的同一套本地项目、对话和历史任务。")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.config.accounts) { account in
                AccountSection(model: model, id: account.id)
            }
            Section {
                Button(action: model.addAccount) {
                    Label("添加账号", systemImage: "person.badge.plus")
                }
                .disabled(model.isSwitching)
            }
        }
        .formStyle(.grouped)
    }
}

private struct AccountSection: View {
    @ObservedObject var model: AppModel
    let id: ProfileID
    @State private var showingDeleteConfirmation = false

    var account: AccountProfile { model.account(id) }

    var body: some View {
        Section(account.displayName) {
            TextField("显示名称", text: Binding(
                get: { account.displayName },
                set: { model.rename(id, to: $0) }
            ))
            LabeledContent("登录快照") {
                Text(model.paths.profile(id).authSnapshot.path)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(2)
            }
            HStack {
                if model.pendingLoginProfileID == id {
                    Button("完成登录并保存") { model.completeLoginSetup(id) }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button(model.hasCredential(id) ? "重新登录" : "登录账号") {
                        model.beginLoginSetup(id)
                    }
                }
                Button("在 Finder 中显示") { model.openProfileFolder(id) }
                Spacer()
                Button("删除账号", role: .destructive) {
                    showingDeleteConfirmation = true
                }
            }
            .disabled(model.isSwitching)
        }
        .confirmationDialog(
            "删除 \(account.displayName)？",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("删除账号登录快照", role: .destructive) { model.deleteProfile(id) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只删除 GPT Switcher 保存的这个账号登录快照；共享的本地项目、对话、任务和 ChatGPT 云端数据均不会删除。")
        }
    }
}

private struct ShortcutSettingsView: View {
    @ObservedObject var model: AppModel
    private let keys = (0...9).map(String.init) + (65...90).compactMap { UnicodeScalar($0).map(String.init) }

    var body: some View {
        Form {
            Section {
                ForEach(model.config.accounts) { account in
                    ShortcutRow(
                        name: account.displayName,
                        value: model.config.shortcuts[account.id] ?? HotKeyConfiguration(key: ""),
                        keys: keys,
                        onChange: { model.updateShortcut(account.id, $0) }
                    )
                }
            } header: {
                Text("全局快捷键")
            } footer: {
                Text("快捷键在 GPT Switcher 运行期间生效。新增账号会依次使用 ⌥⌘3、⌥⌘4 等可用组合。")
            }
        }
        .formStyle(.grouped)
    }
}

private struct ShortcutRow: View {
    let name: String
    let value: HotKeyConfiguration
    let keys: [String]
    let onChange: (HotKeyConfiguration) -> Void

    var body: some View {
        LabeledContent(name) {
            HStack {
                Toggle("⌃", isOn: binding(\.control)).toggleStyle(.button)
                Toggle("⌥", isOn: binding(\.option)).toggleStyle(.button)
                Toggle("⇧", isOn: binding(\.shift)).toggleStyle(.button)
                Toggle("⌘", isOn: binding(\.command)).toggleStyle(.button)
                Picker("按键", selection: Binding(
                    get: { value.key },
                    set: { var copy = value; copy.key = $0; onChange(copy) }
                )) {
                    Text("无").tag("")
                    ForEach(keys, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .frame(width: 70)
                Text(value.key.isEmpty ? "未设置" : value.displayText).font(.body.monospaced())
            }
        }
    }

    private func binding(_ keyPath: WritableKeyPath<HotKeyConfiguration, Bool>) -> Binding<Bool> {
        Binding(
            get: { value[keyPath: keyPath] },
            set: { newValue in
                var copy = value
                copy[keyPath: keyPath] = newValue
                onChange(copy)
            }
        )
    }
}

private struct GeneralSettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section("启动") {
                Toggle("登录 Mac 后自动启动 GPT Switcher", isOn: Binding(
                    get: { model.config.launchAtLogin },
                    set: model.setLaunchAtLogin
                ))
                Toggle("切换后自动打开 ChatGPT", isOn: Binding(
                    get: { model.config.automaticallyLaunchChatGPT },
                    set: model.setAutomaticallyLaunch
                ))
            }
            if let message = model.statusMessage {
                Section("状态") { Text(message).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
    }
}

private struct AdvancedSettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section("ChatGPT 兼容性") {
                if let app = model.installation {
                    LabeledContent("安装路径", value: app.appURL.path)
                    LabeledContent("Bundle ID", value: app.bundleIdentifier)
                    LabeledContent("版本", value: "\(app.version) (\(app.build))")
                    LabeledContent("Chromium", value: app.chromiumVersion ?? "未知")
                    LabeledContent("账号切换") {
                        Label(app.isSupported ? "已验证" : "不兼容", systemImage: app.isSupported ? "checkmark.shield" : "xmark.shield")
                            .foregroundStyle(app.isSupported ? .green : .red)
                    }
                } else {
                    Text("未找到兼容的 ChatGPT.app").foregroundStyle(.red)
                }
                Button("重新检查") { model.refreshInstallation() }
            }
            Section("共享本地数据") {
                LabeledContent("Codex 工作区") {
                    Text(model.paths.sharedCodexHome.path)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                LabeledContent("ChatGPT 数据") {
                    Text(model.paths.sharedChatGPTData.path)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                Button("打开共享 Codex 工作区") { model.openSharedWorkspaceFolder() }
                Button("打开 GPT Switcher 日志") { model.openLogsFolder() }
            }
            Section("账号登录快照") {
                ForEach(model.config.accounts) { account in
                    Button("打开 \(account.displayName) 登录快照文件夹") {
                        model.openProfileFolder(account.id)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
