import SwiftUI

@main
struct Waifu2xApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var workspace = Workspace(persistOptions: !ProcessInfo.processInfo.arguments.contains("--isolated-session"))
    @State private var didConfigure = false
    @State private var onboarding = OnboardingState()
    @State private var startup = AppStartupState()
    private var blocksWorkspace: Bool { onboarding.isPresented || !startup.isReady }
    var body: some Scene {
        Window(Text(verbatim: "Waifu2x"), id: "main") {
            WorkspaceRootView(workspace: workspace, onboarding: onboarding, startup: startup)
                .tint(.accentColor)
                .onAppear {
                    guard !didConfigure else { return }
                    didConfigure = true
                    delegate.onTerminate = { workspace.shutdown(); startup.cancel() }
                    delegate.prepareForTermination = { await startup.models.pauseForTermination() }
                    delegate.connectOpenImages { workspace.load($0) }
                    if ProcessInfo.processInfo.arguments.contains("--sample") { workspace.openSample() }
                    let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
                    startup.begin(isTesting: isTesting) {
                        onboarding.presentIfNeeded(arguments: ProcessInfo.processInfo.arguments, isTesting: isTesting)
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: CanvasPanelLayout.minimumWindowSize.width, height: 760)
        .defaultLaunchBehavior(.presented)
        .commands {
            CommandGroup(replacing: .help) {
                Button(L("快速入门…")) { onboarding.show() }.disabled(workspace.busy || blocksWorkspace)
            }
            CommandGroup(replacing: .newItem) {
                Button(L("打开图片…"), action: workspace.chooseImage).keyboardShortcut("o").disabled(workspace.busy || blocksWorkspace)
                Button(L("打开示例图片"), action: workspace.openSample).disabled(workspace.busy || blocksWorkspace)
            }
            CommandGroup(after: .pasteboard) {
                Button(L("粘贴图片"), action: workspace.pasteImage).keyboardShortcut("v").disabled(workspace.busy || blocksWorkspace)
            }
            CommandGroup(replacing: .saveItem) {
                Button(L("导出 PNG…"), action: workspace.export).keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(workspace.result == nil || workspace.busy || blocksWorkspace)
                Button(L("导出全部结果…"), action: workspace.exportAll).keyboardShortcut("s", modifiers: [.command, .option, .shift])
                    .disabled(workspace.completedImages.isEmpty || workspace.busy || blocksWorkspace)
            }
            CommandMenu(L("图片")) {
                Button(workspace.isMultiSelecting ? L("增强所选图片") : L("增强当前图片"), action: workspace.process).keyboardShortcut(.return, modifiers: .command)
                    .disabled(!workspace.canProcessSelection || blocksWorkspace)
                Button(L("增强全部图片"), action: workspace.processAll).keyboardShortcut(.return, modifiers: [.command, .option])
                    .disabled(workspace.images.isEmpty || workspace.busy || !workspace.options.isValid || blocksWorkspace)
                Button(L("增强未完成或设置已变更的图片"), action: workspace.processPending)
                    .disabled(workspace.pendingImages.isEmpty || workspace.busy || !workspace.options.isValid || blocksWorkspace)
                Button(L("图片列表")) { workspace.showsImages.toggle() }.disabled(blocksWorkspace)
                Button(workspace.activePanels.isEmpty ? L("取消处理") : L("收起面板"), action: workspace.dismissPanelOrCancel)
                    .keyboardShortcut(.escape, modifiers: [])
                    .disabled(blocksWorkspace || (workspace.activePanels.isEmpty && !workspace.isProcessing))
                Button(L("增强选项…")) { workspace.showsOptions.toggle() }.keyboardShortcut(",", modifiers: [.command, .option])
                    .disabled(workspace.busy || blocksWorkspace)
                Divider()
                Button(L("适合窗口"), action: workspace.resetView).keyboardShortcut("0").disabled(blocksWorkspace)
                Button(L("实际像素")) { workspace.actualSizeRequested = true }.keyboardShortcut("1").disabled(blocksWorkspace)
                Button(L("放大")) { workspace.zoom = min(20, workspace.zoom * 1.25) }.keyboardShortcut("+").disabled(blocksWorkspace)
                Button(L("缩小")) { workspace.zoom = max(0.25, workspace.zoom / 1.25) }.keyboardShortcut("-").disabled(blocksWorkspace)
                Divider()
                ForEach(PreviewMode.allCases, id: \.self) { mode in
                    Button(L("显示%@", L(mode.rawValue))) { workspace.preview = mode }.disabled(workspace.result == nil || blocksWorkspace)
                }
            }
        }
    }

}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    var onTerminate: (() -> Void)?
    var prepareForTermination: (() async -> Void)?
    private var isPreparingTermination = false
    private var onOpenImages: (([URL]) -> Void)?
    private var pendingURLs: [URL] = []
    func connectOpenImages(_ handler: @escaping ([URL]) -> Void) {
        onOpenImages = handler
        if !pendingURLs.isEmpty { handler(pendingURLs); pendingURLs = [] }
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        if let onOpenImages { onOpenImages(urls) } else { pendingURLs.append(contentsOf: urls) }
    }
    func applicationWillTerminate(_ notification: Notification) { onTerminate?() }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let prepareForTermination else { return .terminateNow }
        guard !isPreparingTermination else { return .terminateLater }
        isPreparingTermination = true
        Task {
            await prepareForTermination()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Per-launch appearance overrides are for visual QA; no system or saved preference is changed.
        if ProcessInfo.processInfo.arguments.contains("--appearance=dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
        if ProcessInfo.processInfo.arguments.contains("--appearance=light") { NSApp.appearance = NSAppearance(named: .aqua) }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
