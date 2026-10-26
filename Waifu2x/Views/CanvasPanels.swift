import SwiftUI

struct CanvasPanels: View {
    @ObservedObject var workspace: Workspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Only the panels receive input. The uncovered canvas must keep
                // receiving mouse, scroll and magnify events while panels are open.
                ForEach(CanvasPanel.allCases, id: \.self) { panel in
                    let frame = CanvasPanelLayout(size: geometry.size).frame(for: panel, openPanels: workspace.activePanels)
                    Group {
                        switch panel {
                        case .images: ImageQueuePanel(workspace: workspace)
                        case .options: ProcessingOptionsPanel(workspace: workspace)
                        }
                    }
                    // The surface extends under the real traffic lights and toolbar;
                    // only its contents start below the native titlebar controls.
                    .padding(.top, CanvasPanelLayout.titlebarClearance)
                    .frame(width: frame.width, height: frame.height)
                    .background(HeaderGeometryReader(identifier: panel == .images ? "imagesPanelBounds" : "optionsPanelBounds"))
                    .modifier(CanvasPanelSurface())
                    .shadow(color: .black.opacity(0.12), radius: 20, x: 0, y: 8)
                    .overlay(alignment: .top) {
                        WorkspaceWindowDragRegion().frame(height: CanvasPanelLayout.titlebarClearance)
                            .accessibilityHidden(true)
                    }
                    .position(x: frame.midX, y: frame.midY)
                    .offset(x: workspace.activePanels.contains(panel) ? 0 : (panel == .images ? -frame.width - CanvasPanelLayout.inset : frame.width + CanvasPanelLayout.inset))
                    .opacity(workspace.activePanels.contains(panel) ? 1 : 0)
                    .allowsHitTesting(workspace.activePanels.contains(panel))
                    .accessibilityHidden(!workspace.activePanels.contains(panel))
                }
            }
        }
        .animation(reduceMotion ? nil : PanelMotion.animation, value: workspace.activePanels)
        .allowsHitTesting(!workspace.activePanels.isEmpty)
    }
}

private struct CanvasPanelSurface: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            let shape = ConcentricRectangle(corners: .concentric(minimum: .fixed(8)), isUniform: true)
            content.background {
                shape.fill(.regularMaterial)
                    .overlay { shape.fill(Color(nsColor: ThemeColors.panel)) }
            }
            .clipShape(shape)
        } else {
            let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
            content.background {
                shape.fill(.regularMaterial)
                    .overlay { shape.fill(Color(nsColor: ThemeColors.panel)) }
            }
            .clipShape(shape)
        }
    }
}
