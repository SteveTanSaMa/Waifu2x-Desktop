import SwiftUI
import AppKit

/// The AppKit host is positioned by the canvas presentation callback, never by
/// an independent SwiftUI animation or a deferred observable-state update.
struct CanvasControlOverlay: NSViewRepresentable {
    let workspace: Workspace
    let presentation: CanvasPresentation
    let processing: Bool
    @Environment(\.isEnabled) private var isEnabled
    func makeNSView(context: Context) -> CanvasControlsHostView {
        let view = CanvasControlsHostView(workspace: workspace)
        presentation.controls = view
        view.presentation = presentation
        return view
    }
    func updateNSView(_ view: CanvasControlsHostView, context: Context) {
        view.processing = processing
        // The nested hosting view has its own environment, so forward disabling.
        view.host.rootView = CanvasControls(workspace: workspace, isEnabled: isEnabled)
        presentation.updateControls()
        view.needsLayout = true
    }
}

struct CanvasControls: View {
    @Bindable var workspace: Workspace
    var isEnabled = true
    var body: some View {
        HStack(spacing: 8) {
            Group {
                if workspace.isProcessing {
                    ProcessingStatus(workspace: workspace)
                        .frame(width: 356, alignment: .leading)
                } else {
                    HStack(spacing: 4) {
                        Picker(L("预览"), selection: Binding(get: { workspace.result == nil ? .original : workspace.preview }, set: { workspace.preview = $0 })) {
                            ForEach(PreviewMode.allCases, id: \.self) { mode in
                                Text(mode.compactLabel).tag(mode)
                                    .accessibilityLabel(L(mode.rawValue))
                                    .help(L(mode.rawValue))
                            }
                        }
                        .pickerStyle(.segmented).labelsHidden().controlSize(.regular)
                        .font(.system(size: 14)).fixedSize(horizontal: true, vertical: false).layoutPriority(1)
                        .disabled(workspace.result == nil)
                        if let asset = workspace.displayedAsset {
                            Text(L("%@ px", asset.dimensions))
                                .font(.system(size: 12)).monospacedDigit()
                                .foregroundStyle(.secondary).lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .accessibilityLabel(L("%@分辨率 %@ 像素", workspace.preview == .original || workspace.result == nil ? L("原图") : L("结果"), asset.dimensions))
                                .help(L("当前预览图片的像素尺寸"))
                        }
                    }.frame(width: 356)
                }
            }
            CanvasZoomControls(workspace: workspace).frame(width: 132)
        }
        .frame(height: workspace.isProcessing ? CanvasControlLayout.processingHeight : CanvasControlLayout.idleHeight)
        .padding(.horizontal, 16).padding(.vertical, CanvasControlLayout.verticalPadding)
        .background(.regularMaterial, in: .rect(cornerRadius: 18))
        .background(HeaderGeometryReader(identifier: "canvasControlsBounds"))
        .padding(.horizontal, 16).padding(.bottom, CanvasControlLayout.bottomPadding)
        .disabled(!isEnabled)
    }
}

private extension PreviewMode {
    var compactLabel: String {
        switch self {
        case .original: L("preview.original")
        case .result: L("preview.result")
        case .compare: L("preview.compare")
        }
    }
}

private struct CanvasZoomControls: View {
    @Bindable var workspace: Workspace
    var body: some View {
        HStack(spacing: 5) {
            Button(L("缩小"), systemImage: "minus.magnifyingglass") { workspace.zoom = max(0.25, workspace.zoom / 1.25) }
                .disabled(workspace.zoom <= 0.25).help(L("缩小（⌘−）"))
            Menu {
                Button(L("适合窗口（⌘0）"), action: workspace.resetView)
                Button(L("实际像素 · 100%（⌘1）")) { workspace.actualSizeRequested = true }
            } label: {
                Text(L("%d%%", Int((workspace.pixelScale * 100).rounded())))
                    .font(.system(size: 14)).monospacedDigit().frame(width: 64)
            }
            .menuStyle(.borderlessButton)
            .help(L("缩放 · 捏合缩放，拖动平移，双击适合窗口"))
            .accessibilityLabel(L("缩放 %d%%", Int((workspace.pixelScale * 100).rounded())))
            Button(L("放大"), systemImage: "plus.magnifyingglass") { workspace.zoom = min(20, workspace.zoom * 1.25) }
                .disabled(workspace.zoom >= 20).help(L("放大（⌘+）"))
        }
        .labelStyle(.iconOnly).buttonStyle(.borderless).controlSize(.regular).font(.system(size: 14))
        .fixedSize()
    }
}

private struct ProcessingStatus: View {
    let workspace: Workspace
    var body: some View {
        HStack(spacing: 12) {
            if let progress = workspace.tileProgress {
                ProgressView(value: progress.fraction).progressViewStyle(.circular).controlSize(.small)
            } else {
                ProgressView().controlSize(.small)
            }
            VStack(alignment: .leading, spacing: 3) {
                if workspace.batchCount > 1 {
                    Text(L("第 %d / %d 张 · %@", workspace.batchIndex, workspace.batchCount, workspace.activeName))
                        .font(.system(size: 11, weight: .medium)).lineLimit(1).truncationMode(.middle)
                }
                Text(workspace.stage).font(.system(size: 14, weight: .medium)).lineLimit(1)
                if let progress = workspace.tileProgress {
                    Text(L("已完成 %d / %d 块 · %d%%", progress.completed, progress.total, Int(progress.fraction * 100)))
                        .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                }
                TimelineView(.periodic(from: workspace.startedAt, by: 1)) { context in
                    Text(L("%@ · %d 秒", (workspace.activeOptions ?? workspace.options).summary, Int(context.date.timeIntervalSince(workspace.startedAt))))
                        .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                }
            }
            Button(L("取消"), action: workspace.cancel).buttonStyle(.borderless).help(L("取消处理（Esc）"))
        }.frame(maxWidth: 320)
    }
}
