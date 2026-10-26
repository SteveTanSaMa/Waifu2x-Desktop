import SwiftUI

struct PreferencesCommands: Commands {
    @ObservedObject var navigation: SettingsNavigation
    @ObservedObject var updates: AppUpdateChecker
    @ObservedObject var integrity: FileIntegrityChecker
    @ObservedObject private var preferences = AppPreferences.shared
    let modelsAreReady: Bool
    let canShowTutorial: Bool
    let onShowTutorial: () -> Void
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        if #available(macOS 14.0, *) {
            ModernSettingsCommands(commands: self)
        } else {
            content {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
        }
    }

    @CommandsBuilder fileprivate func content(openSettings: @escaping () -> Void) -> some Commands {
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
                presentSettings(.updates, openSettings: openSettings)
                updates.check()
            }
            .disabled(updates.status == .checking)
        }
        CommandGroup(replacing: .appInfo) {
            Button(L("关于 Waifu2x")) {
                presentSettings(.about, openSettings: openSettings)
            }
        }
        CommandGroup(replacing: .help) {
            Button(L("快速入门…")) {
                onShowTutorial()
                openWindow(id: "main")
            }
            .disabled(!canShowTutorial)
            Button(L("检查文件完整性…")) {
                presentSettings(.models, openSettings: openSettings)
                integrity.check()
            }
            .disabled(!modelsAreReady || !integrity.canStart)
            Divider()
            Link(L("访问 GitHub"), destination: AppInformation.repositoryURL)
        }
    }

    private func presentSettings(_ section: SettingsSection, openSettings: () -> Void) {
        navigation.selection = section
        navigation.prepareForPresentation()
        openSettings()
    }
}

@available(macOS 14.0, *)
private struct ModernSettingsCommands: Commands {
    let commands: PreferencesCommands
    @ObservedObject private var navigation: SettingsNavigation
    @ObservedObject private var updates: AppUpdateChecker
    @ObservedObject private var integrity: FileIntegrityChecker
    @ObservedObject private var preferences = AppPreferences.shared
    @Environment(\.openSettings) private var openSettings

    init(commands: PreferencesCommands) {
        self.commands = commands
        _navigation = ObservedObject(wrappedValue: commands.navigation)
        _updates = ObservedObject(wrappedValue: commands.updates)
        _integrity = ObservedObject(wrappedValue: commands.integrity)
    }

    var body: some Commands {
        commands.content(openSettings: { openSettings() })
    }
}
