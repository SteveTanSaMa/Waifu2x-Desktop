import SwiftUI

/// Ordinary frosted material, with a flat accent for active panel controls.
struct ToolbarControlSurface: ViewModifier {
    let expanded: Bool
    var prominent = false
    var appearanceAnimation: Animation? = nil
    @Environment(\.isEnabled) private var isEnabled
    func body(content: Content) -> some View {
        content.background {
            Capsule().fill(.regularMaterial)
                .overlay {
                    Capsule().fill(Color.accentColor)
                        .animation(appearanceAnimation) { fill in
                            fill.opacity(expanded || prominent ? (isEnabled ? 1 : 0.35) : 0)
                        }
                }
        }
    }
}

struct ToolbarActionButtonStyle: ButtonStyle {
    let expanded: Bool
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, prominent ? 10.5 : 12)
            .frame(height: CanvasPanelLayout.toolbarControlHeight)
            .contentShape(Capsule())
            .modifier(ToolbarControlSurface(expanded: expanded, prominent: prominent))
            .opacity(configuration.isPressed ? 0.72 : 1)
    }
}
