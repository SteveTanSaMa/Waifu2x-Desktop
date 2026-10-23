import SwiftUI

struct EmptyCanvas: View {
    let workspace: Workspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        GeometryReader { geometry in
            let layout = CanvasPanelLayout(size: geometry.size)
            let range = layout.exposedRange(for: workspace.activePanels)
            let contentWidth = max(160, range.upperBound - range.lowerBound - 32)
            VStack(spacing: 0) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 60, weight: .light)).foregroundStyle(Color.accentColor)
                    .padding(.bottom, 24)
                Text(L("为图片增添细节"))
                    .font(.system(size: 26, weight: .medium)).tracking(-0.6)
                    .padding(.bottom, 10)
                Text(L("拖入图片，放大尺寸或减少噪点"))
                    .font(.system(size: 14)).foregroundStyle(.secondary)
                    .padding(.bottom, 26)
                Button(action: workspace.chooseImage) {
                    Text(L("打开图片…")).foregroundStyle(Color(nsColor: ToolbarActionPalette.prominentInk))
                }
                    .font(.system(size: 14)).buttonStyle(ToolbarActionButtonStyle(expanded: true, prominent: true)).controlSize(.large)
                    .keyboardShortcut("o", modifiers: .command)
                Button(L("试用示例图片"), action: workspace.openSample)
                    .buttonStyle(.plain).font(.system(size: 14)).foregroundStyle(.secondary)
                    .padding(.top, 16)
            }
            .multilineTextAlignment(.center)
            .frame(width: contentWidth)
            .position(x: layout.centerX(for: workspace.activePanels), y: geometry.size.height / 2)
            Text(L("PNG、JPEG、HEIC、TIFF、WebP · 支持 ⌘V 粘贴"))
                .font(.system(size: 11)).foregroundStyle(.tertiary)
                .multilineTextAlignment(.center).frame(width: contentWidth)
                .position(x: layout.centerX(for: workspace.activePanels), y: max(0, geometry.size.height - 36))
        }
        .animation(reduceMotion ? nil : PanelMotion.animation, value: workspace.activePanels)
    }
}
