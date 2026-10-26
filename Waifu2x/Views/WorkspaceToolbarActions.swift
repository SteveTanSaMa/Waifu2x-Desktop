import SwiftUI

struct WorkspaceToolbarActions: View {
    @Environment(\.locale) private var locale
    @ObservedObject var workspace: Workspace
    private var exportInk: Color { Color(nsColor: workspace.showsOptions ? ToolbarActionPalette.prominentInk : ToolbarActionPalette.neutralInk) }
    var body: some View {
        let _ = locale
        HStack(spacing: 8) {
            if workspace.images.count > 1 {
                Menu {
                    Button(L("导出当前图片…"), action: workspace.export).disabled(workspace.result == nil)
                    Button(L("导出全部结果（%d 张）…", workspace.completedImages.count), action: workspace.exportAll).disabled(workspace.completedImages.isEmpty)
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .foregroundStyle(exportInk)
                        .frame(width: 20, height: CanvasPanelLayout.toolbarLabelHeight)
                }
                .modifier(ToolbarMenuSurface(expanded: workspace.showsOptions))
                .accessibilityLabel(L("导出 PNG")).accessibilityIdentifier("exportAction").disabled(workspace.busy).help(L("导出 PNG"))
            } else {
                Button(action: workspace.export) {
                    Image(systemName: "square.and.arrow.up")
                        .symbolRenderingMode(.monochrome).foregroundStyle(exportInk)
                        .frame(width: 20, height: CanvasPanelLayout.toolbarLabelHeight)
                }
                .accessibilityLabel(L("导出图片")).accessibilityIdentifier("exportAction").buttonStyle(ToolbarActionButtonStyle(expanded: workspace.showsOptions))
                .disabled(workspace.result == nil || workspace.busy).help(L("导出 PNG（⇧⌘S）"))
            }
        }
    }
}

private struct ToolbarMenuSurface: ViewModifier {
    let expanded: Bool
    private var ink: Color { Color(nsColor: expanded ? ToolbarActionPalette.prominentInk : ToolbarActionPalette.neutralInk) }
    func body(content: Content) -> some View {
        content.menuStyle(.borderlessButton).menuIndicator(.hidden).buttonStyle(.plain)
            .tint(ink)
            .symbolRenderingMode(.monochrome).foregroundStyle(ink)
            .frame(width: 44, height: CanvasPanelLayout.toolbarControlHeight)
            .modifier(ToolbarControlSurface(expanded: expanded))
    }
}

struct EnhanceButton: View {
    @Environment(\.locale) private var locale
    @ObservedObject var workspace: Workspace
    var body: some View {
        let _ = locale
        Button(action: workspace.process) {
            Label(L("增强"), systemImage: "sparkles")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(workspace.canProcessSelection ? Color(nsColor: ToolbarActionPalette.prominentInk) : Color.primary.opacity(0.55))
                .frame(width: 112, height: 44)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .modifier(ToolbarControlSurface(expanded: true, prominent: true))
        .disabled(!workspace.canProcessSelection)
        .accessibilityLabel(L("增强")).accessibilityIdentifier("enhanceAction")
        .background(HeaderGeometryReader(identifier: "enhanceBounds"))
        .help(workspace.isMultiSelecting ? L("增强所选图片（⌘↩）") : L("增强当前图片（⌘↩）"))
        .alert(L("是否需要重新开始图片增强？"), isPresented: $workspace.showsRestartConfirmation) {
            Button(L("重新开始"), action: workspace.confirmRestart)
            Button(L("继续当前任务"), role: .cancel, action: workspace.dismissRestartConfirmation)
        } message: {
            Text(L("将停止当前处理，并使用当前设置重新开始。"))
        }
    }
}
