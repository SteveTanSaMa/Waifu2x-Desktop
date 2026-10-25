import SwiftUI

struct PreferencesCommands: Commands {
    let navigation: SettingsNavigation
    let updates: AppUpdateChecker
    let integrity: FileIntegrityChecker
    let modelsAreReady: Bool
    let canShowTutorial: Bool
    let onShowTutorial: () -> Void
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button(L("设置…")) {
                guard !navigation.closeIfVisible() else { return }
                navigation.prepareForPresentation()
                openSettings()
            }
                .keyboardShortcut(",", modifiers: .command)
        }
        CommandGroup(after: .appSettings) {
            Button(L("检查更新…")) {
                presentSettings(.updates)
                updates.check()
            }
            .disabled(updates.status == .checking)
        }
        CommandGroup(replacing: .appInfo) {
            Button(L("关于 Waifu2x")) {
                presentSettings(.about)
            }
        }
        CommandGroup(replacing: .help) {
            Button(L("快速入门…")) {
                onShowTutorial()
                openWindow(id: "main")
            }
            .disabled(!canShowTutorial)
            Button(L("检查文件完整性…")) {
                presentSettings(.models)
                integrity.check()
            }
            .disabled(!modelsAreReady || !integrity.canStart)
            Divider()
            Link(L("访问 GitHub"), destination: AppInformation.repositoryURL)
        }
    }

    private func presentSettings(_ section: SettingsSection) {
        navigation.selection = section
        navigation.prepareForPresentation()
        openSettings()
    }
}
