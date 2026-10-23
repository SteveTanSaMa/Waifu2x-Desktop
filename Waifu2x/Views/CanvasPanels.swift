import SwiftUI

struct CanvasPanels: View {
    @Bindable var workspace: Workspace
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
                    .background {
                        let shape = ConcentricRectangle(corners: .concentric(minimum: .fixed(8)), isUniform: true)
                        shape.fill(.regularMaterial)
                            // A quiet semantic fill protects labels over bright artwork.
                            .overlay { shape.fill(Color(nsColor: ThemeColors.panel)) }
                    }
                    .clipShape(ConcentricRectangle(corners: .concentric(minimum: .fixed(8)), isUniform: true))
                    .shadow(color: .black.opacity(0.12), radius: 20, x: 0, y: 8)
                    .overlay(alignment: .top) {
                        Color.clear.frame(height: CanvasPanelLayout.titlebarClearance)
                            .contentShape(Rectangle()).gesture(WindowDragGesture())
                            .allowsWindowActivationEvents(true).accessibilityHidden(true)
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
