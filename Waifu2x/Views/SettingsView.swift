import AppKit
import SwiftUI

struct SettingsView: View {
    @Environment(\.locale) private var locale
    @ObservedObject var preferences: AppPreferences
    @ObservedObject var navigation: SettingsNavigation
    @ObservedObject var updates: AppUpdateChecker
    @ObservedObject var integrity: FileIntegrityChecker
    let modelsAreReady: Bool
    let canShowTutorial: Bool
    let onShowTutorial: () -> Void
    @OptionalObservedObject var workflow: ProcessingWorkflow? = nil
    @OptionalObservedObject var maintenance: ModelMaintenance? = nil
    @Environment(\.openWindow) private var openWindow
    @State private var sidebarSelection = DeferredSettingsSelection()

    var body: some View {
        let _ = locale
        HStack(spacing: 0) {
            List(SettingsSection.allCases, selection: Binding(get: { navigation.selection }, set: {
                sidebarSelection.request($0, navigation: navigation)
            })) { section in
                Label {
                    Text(section.title)
                        .font(.body)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: section.symbol)
                        .font(.body)
                }
                .tag(section)
                .padding(.vertical, 3)
            }
            .listStyle(.sidebar)
            .font(.body)
            .scrollContentBackground(.hidden)
            .padding(.top, 8)
            .frame(width: 180)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                Text((navigation.selection ?? .general).title)
                    .font(.system(size: 18, weight: .semibold))
                    .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 2)
                detail
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: 720, height: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .background(HeaderGeometryReader(identifier: "settingsBounds"))
        .background(SettingsWindowBehavior(navigation: navigation))
        .font(.body)
        .tint(.accentColor)
        .accessibilityIdentifier("appSettings")
        .onExitCommand { _ = navigation.closeIfVisible() }
    }

    @ViewBuilder private var detail: some View {
        switch navigation.selection ?? .general {
        case .general:
            GeneralSettingsView(preferences: preferences, workflow: workflow, canShowTutorial: canShowTutorial) {
                _ = navigation.closeIfVisible()
                onShowTutorial()
                openWindow(id: "main")
            }
        case .models:
            ModelIntegritySettingsView(checker: integrity, modelsAreReady: modelsAreReady, maintenance: maintenance)
        case .updates:
            SoftwareUpdateSettingsView(preferences: preferences, checker: updates)
        case .about:
            AboutSettingsView(maintenance: maintenance)
        }
    }
}

private struct GeneralSettingsView: View {
    @Environment(\.locale) private var locale
    @ObservedObject var preferences: AppPreferences
    @OptionalObservedObject var workflow: ProcessingWorkflow?
    let canShowTutorial: Bool
    let onShowTutorial: () -> Void

    var body: some View {
        let _ = locale
        Form {
            Section {
                Picker(L("语言"), selection: $preferences.languageCode) {
                    ForEach(AppPreferences.languageCodes, id: \.self) { code in
                        Text(verbatim: languageName(code)).tag(code)
                    }
                }
                .accessibilityIdentifier("settingsLanguage")
                .background(HeaderGeometryReader(identifier: "settingsLanguage"))
                Picker(L("外观"), selection: $preferences.appearance) {
                    Text(L("跟随系统")).tag("system")
                    Text(L("浅色")).tag("light")
                    Text(L("深色")).tag("dark")
                }
                .accessibilityIdentifier("settingsAppearance")
                .background(HeaderGeometryReader(identifier: "settingsAppearance"))
            } footer: {
                Text(L("更改后立即生效，跟随系统时优先使用系统首选语言"))
                    .font(.caption)
            }
            if let workflow {
                Section {
                    Toggle(isOn: Binding(get: { preferences.notifiesOnCompletion },
                                         set: workflow.setNotifiesOnCompletion)) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(L("完成后发送通知"))
                            Text(L("在后台完成批量增强时通知"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .disabled(workflow.isRequestingNotificationPermission)
                    .accessibilityIdentifier("settingsCompletionNotification")
                    .background(HeaderGeometryReader(identifier: "settingsCompletionNotification"))
                    Toggle(isOn: Binding(get: { preferences.preventsSleepWhileProcessing },
                                         set: workflow.setPreventsSleepWhileProcessing)) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(L("处理期间防止睡眠"))
                            Text(L("仅在增强运行时保持 Mac 唤醒"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("settingsPreventsSleep")
                    .background(HeaderGeometryReader(identifier: "settingsPreventsSleep"))
                } header: {
                    Text(L("处理任务"))
                } footer: {
                    if let status = workflow.notificationStatus {
                        Text(status).font(.caption)
                    }
                }
            }
            Section {
                LabeledContent {
                    Button(L("查看教程"), action: onShowTutorial)
                        .disabled(!canShowTutorial)
                        .accessibilityIdentifier("settingsTutorial")
                        .background(HeaderGeometryReader(identifier: "settingsTutorial"))
                } label: {
                    Label(L("快速入门"), systemImage: "play.rectangle")
                }
            } footer: {
                Text(L("在主窗口重新回顾导入、增强与导出"))
                    .font(.caption)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .font(.body)
        .controlSize(.regular)
    }

    private func languageName(_ code: String) -> String {
        switch code {
        case "system": L("跟随系统")
        case "zh-Hans": "简体中文"
        case "zh-Hant": "繁體中文"
        case "ja": "日本語"
        case "fr": "Français"
        case "ko": "한국어"
        case "ru": "Русский"
        default: "English"
        }
    }
}

private struct AboutSettingsView: View {
    @Environment(\.locale) private var locale
    @OptionalObservedObject var maintenance: ModelMaintenance?
    @State private var copiedDiagnostics = false

    private var diagnosticStatus: DiagnosticModelStatus {
        switch maintenance?.diagnosticStatus {
        case .checking: .checking
        case .ready: .ready
        case .issues: .needsRepair
        case .repairing: .repairing
        case .unknown, nil: .unverified
        }
    }

    var body: some View {
        let _ = locale
        ScrollView {
            VStack(spacing: 12) {
                VStack(spacing: 10) {
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable().interpolation(.high)
                        .frame(width: 64, height: 64)
                        .accessibilityHidden(true)
                    Text(verbatim: "Waifu2x Desktop").font(.system(size: 22, weight: .semibold))
                    Text(L("让画面，回到清晰之中"))
                        .font(.body).foregroundStyle(.secondary)
                        .background(HeaderGeometryReader(identifier: "settingsAboutTagline"))
                    Text(L("版本 %@ · 构建 %@", AppInformation.version, AppInformation.build))
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        .textSelection(.enabled)
                }
                Divider().frame(maxWidth: 300)
                VStack(spacing: 12) {
                    Text(verbatim: "Copyright © 2026 Steve Tan")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(L("模型保存在本机，图片不会上传"))
                        .font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 22) {
                        Link(destination: AppInformation.repositoryURL) {
                            Label(L("访问 GitHub"), systemImage: "arrow.up.right.square")
                        }
                        Link(L("反馈问题"), destination: AppInformation.issuesURL)
                    }
                    .font(.body)
                    Button {
                        copiedDiagnostics = AppDiagnostics.copy(modelStatus: diagnosticStatus)
                    } label: {
                        Label(copiedDiagnostics ? L("诊断信息已复制") : L("复制诊断信息"),
                              systemImage: copiedDiagnostics ? "checkmark" : "doc.on.doc")
                    }
                    .accessibilityIdentifier("settingsCopyDiagnostics")
                    .background(HeaderGeometryReader(identifier: "settingsCopyDiagnostics"))
                }
                VStack(spacing: 6) {
                    Text(L("开源组件"))
                        .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    Text(verbatim: "ONNX Runtime · waifu2x-ncnn-vulkan · nunif")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 20).padding(.vertical, 16)
            .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
        .accessibilityIdentifier("settingsAbout")
        .background(HeaderGeometryReader(identifier: "settingsAbout"))
    }
}

/// NSTableView can write its selection while SwiftUI is reconciling rows.
/// Deliver only the latest user choice after that view update has completed.
@MainActor
private final class DeferredSettingsSelection {
    private var operation = UUID()

    func request(_ selection: SettingsSection?, navigation: SettingsNavigation) {
        guard navigation.selection != selection else { return }
        let previous = navigation.selection
        let id = UUID()
        operation = id
        DispatchQueue.main.async { [weak self, weak navigation] in
            guard let self, let navigation, self.operation == id,
                  navigation.selection == previous else { return }
            navigation.selection = selection
        }
    }
}
