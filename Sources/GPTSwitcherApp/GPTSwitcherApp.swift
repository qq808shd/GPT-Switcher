import SwiftUI

@main
struct GPTSwitcherApplication: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra("GPT Switcher", systemImage: "arrow.triangle.2.circlepath.circle.fill") {
            MenuContentView(model: model)
                .task {
                    model.registerHotKeys()
                    model.refreshUsageIfNeeded()
                }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model)
        }
    }
}
