import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(\.locale) private var locale
    @ObservedObject var workspace: Workspace
    var configuresWindow = true
    @State private var isDropTarget = false
    @State private var canvasPresentation = CanvasPresentation()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let _ = locale
        ZStack {
            // Tint only the viewing surface; image pixels retain their original colors.
            Color(nsColor: .underPageBackgroundColor)
                .overlay { Color(nsColor: ThemeColors.canvasTint) }
            if workspace.input != nil {
                ImageCanvas(workspace: workspace, presentation: canvasPresentation)
            } else {
                EmptyCanvas(workspace: workspace)
            }
            if workspace.isLoading || workspace.isExporting { ProgressView(workspace.isExporting ? L("正在导出图片…") : L("正在打开图片…")).padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous)) }
            if isDropTarget {
                Color.accentColor.opacity(0.08).allowsHitTesting(false)
                Label(L("松开以打开图片"), systemImage: "photo.badge.plus")
                    .padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous)).allowsHitTesting(false)
            }
        }
        .ignoresSafeArea()
        .overlay(alignment: .top) {
            // Only this clear strip moves the window; the image keeps its pan gesture.
            WorkspaceWindowDragRegion().frame(height: 46)
        }
        .overlay { CanvasPanels(workspace: workspace).ignoresSafeArea() }
        .overlay(alignment: .bottom) {
            if workspace.input != nil { CanvasControlOverlay(workspace: workspace, presentation: canvasPresentation, processing: workspace.isProcessing) }
        }
        .overlay(alignment: .topLeading) {
            if let notice = workspace.notice, workspace.activePanels.isEmpty {
                Text(notice).font(.system(size: 11)).foregroundStyle(.secondary)
                    .padding(.horizontal, 14).padding(.vertical, 9).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .padding(.top, 62).padding(.leading, 20).allowsHitTesting(false)
            }
        }
        .overlay { WorkspaceToolbar(workspace: workspace).ignoresSafeArea() }
        .overlay(alignment: .bottomTrailing) {
            EnhanceButton(workspace: workspace)
                .padding(CanvasPanelLayout.inset + 16)
        }
        .background {
            if configuresWindow {
                WindowConfiguration(onEscape: {
                    guard !workspace.activePanels.isEmpty || workspace.isProcessing else { return false }
                    workspace.dismissPanelOrCancel()
                    return true
                })
            }
        }
        .frame(minWidth: CanvasPanelLayout.minimumWindowSize.width, minHeight: CanvasPanelLayout.minimumWindowSize.height)
        .font(.system(size: 14))
        .modifier(WorkspaceWindowChrome())
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTarget) { providers in
            guard !workspace.busy, !providers.isEmpty else { return false }
            Task {
                var urls: [URL] = []
                for provider in providers {
                    let url: URL? = await withCheckedContinuation { continuation in
                        _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
                    }
                    if let url { urls.append(url) }
                }
                workspace.load(urls)
            }
            return true
        }
        .alert(L("未能完成操作"), isPresented: Binding(get: { workspace.errorMessage != nil }, set: { if !$0 { workspace.errorMessage = nil } })) {
            Button(L("好"), role: .cancel) { workspace.errorMessage = nil }
        } message: { Text(workspace.errorMessage ?? "") }
        .task(id: workspace.notice) {
            guard workspace.notice != nil else { return }
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { workspace.notice = nil }
        }
        .onExitCommand(perform: workspace.dismissPanelOrCancel)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: workspace.isProcessing)
    }

}
