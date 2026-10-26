import SwiftUI

/// One persistent content hierarchy owns the controls and their motion. Moving
/// a native toolbar item between hosts would discard its presentation position.
struct WorkspaceToolbar: View {
    @Environment(\.locale) private var locale
    @ObservedObject var workspace: Workspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var actionsWidth: CGFloat = 150
    var body: some View {
        let _ = locale
        GeometryReader { geometry in
            let layout = WorkspaceHeaderLayout(size: geometry.size, panels: workspace.activePanels, actionsWidth: actionsWidth)
            ZStack(alignment: .topLeading) {
                PanelToolbarToggle(isOn: $workspace.showsImages, symbol: "photo.on.rectangle.angled", title: L("图片队列"))
                    .frame(width: 44, height: 32)
                    .background(HeaderGeometryReader(identifier: "queueToggleBounds"))
                    .offset(x: layout.queueX, y: layout.centerY - 16)
                    .accessibilityIdentifier("queueToggle")
                PanelToolbarToggle(isOn: $workspace.showsOptions, symbol: "slider.horizontal.3", title: L("调节面板"))
                    .frame(width: 44, height: 32)
                    .background(HeaderGeometryReader(identifier: "optionsToggleBounds"))
                    .offset(x: layout.optionsX, y: CanvasPanelLayout.toolbarCenterY - 16)
                    .accessibilityIdentifier("optionsToggle")
                WorkspaceToolbarActions(workspace: workspace)
                    .fixedSize()
                    .background(HeaderGeometryReader(identifier: "actionsBounds", onChange: { rect, _ in
                        if actionsWidth != rect.width { actionsWidth = rect.width }
                    }))
                    .offset(x: layout.actionsX, y: CanvasPanelLayout.toolbarCenterY - 16)
            }
            .font(.system(size: 14, weight: .medium))
            .animation(reduceMotion ? nil : PanelMotion.animation, value: workspace.activePanels)
        }
    }
}

struct WorkspaceHeaderLayout {
    let size: CGSize
    let panels: Set<CanvasPanel>
    let actionsWidth: CGFloat
    var centerY: CGFloat { CanvasPanelLayout.toolbarCenterY }
    var queueX: CGFloat { panels.contains(.images) ? CanvasPanelLayout(size: size).frame(for: .images).maxX - CanvasPanelLayout.headerControlInset - 44 : 92 }
    // Actions retain the same horizontal anchor for every panel combination.
    var actionsX: CGFloat { size.width - CanvasPanelLayout.inset - CanvasPanelLayout.headerControlInset - actionsWidth }
    var optionsX: CGFloat { panels.contains(.options) ? CanvasPanelLayout(size: size).frame(for: .options).minX + CanvasPanelLayout.headerControlInset : actionsX - 8 - 44 }
}

struct PanelToolbarToggle: View {
    @Environment(\.locale) private var locale
    @Binding var isOn: Bool
    let symbol: String
    let title: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let _ = locale
        // Keep the glyph outside the native Button label host. That host can
        // commit its final frame before the SwiftUI surface finishes moving.
        Button { isOn.toggle() } label: {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .modifier(ToolbarControlSurface(expanded: isOn, appearanceAnimation: reduceMotion ? nil : .linear(duration: PanelMotion.duration)))
        .overlay {
            Image(systemName: symbol)
                .symbolRenderingMode(.monochrome)
                .modifier(ToolbarGlyphInk(expanded: isOn, animation: reduceMotion ? nil : .linear(duration: PanelMotion.duration)))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(HeaderGeometryReader(identifier: symbol == "slider.horizontal.3" ? "optionsSymbolBounds" : "queueSymbolBounds"))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        // One composited unit receives the outer animated transform, so the
        // symbol and capsule share the same presentation position every frame.
        .compositingGroup()
        .accessibilityLabel(title).accessibilityValue(isOn ? L("展开") : L("收起"))
        .help(isOn ? L("收起%@", title) : L("展开%@", title))
    }

}

private struct ToolbarGlyphInk: ViewModifier {
    let expanded: Bool
    let animation: Animation?
    private var color: Color { Color(nsColor: expanded ? ToolbarActionPalette.prominentInk : ToolbarActionPalette.neutralInk) }

    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 14, *) {
            content.animation(animation) { $0.foregroundStyle(color) }
        } else {
            content.foregroundStyle(color).animation(animation, value: expanded)
        }
    }
}

enum PanelMotion {
    static let duration: TimeInterval = 0.30
    static let animation = Animation.easeInOut(duration: duration)
}
