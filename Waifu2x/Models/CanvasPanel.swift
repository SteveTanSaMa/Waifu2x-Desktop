import CoreGraphics

enum CanvasPanel: CaseIterable, Hashable { case images, options }

/// The surface starts behind the native titlebar, not below it. Its 8-point
/// inset follows the supplied reference; panel corners adapt concentrically to the window.
struct CanvasPanelLayout {
    // 280 + 380 pt panels, a 560 pt controls host, outer insets and gaps.
    static let minimumWindowSize = CGSize(width: 1280, height: 768)
    static let inset: CGFloat = 8
    static let titlebarClearance: CGFloat = 64
    static let controlInset: CGFloat = 12
    static let headerControlInset: CGFloat = 10
    static let toolbarHeight: CGFloat = 56
    static let toolbarControlHeight: CGFloat = 32
    // Glass Button renders four points beyond its trailing layout boundary.
    static let trailingButtonOutset: CGFloat = 4
    static var toolbarCenterY: CGFloat { inset + headerControlInset + toolbarControlHeight / 2 }
    static let toolbarLabelHeight: CGFloat = 24
    static let bottomClearance: CGFloat = 80
    static let controlsWidth: CGFloat = CanvasControlLayout.width
    let size: CGSize
    func frame(for panel: CanvasPanel, openPanels: Set<CanvasPanel> = []) -> CGRect {
        let inset = Self.inset
        let queueWidth = max(1, min(280, size.width - 380 - inset * 3))
        let width = min(panel == .images ? queueWidth : 380, max(1, size.width - inset * 2))
        return CGRect(x: panel == .images ? inset : size.width - inset - width,
                      y: inset, width: width, height: max(1, size.height - inset * 2))
    }

    /// The image moves horizontally into the exposed region; its fit and Y remain unchanged.
    func exposedRange(for panels: Set<CanvasPanel>) -> ClosedRange<CGFloat> {
        let left = panels.contains(.images) ? frame(for: .images, openPanels: panels).maxX : 0
        let right = panels.contains(.options) ? frame(for: .options, openPanels: panels).minX : size.width
        // AppKit can lay out a representable at zero width while attaching it.
        let width = max(0, size.width)
        let start = min(width, max(0, left))
        return start...min(width, max(start, right))
    }

    func centerX(for panels: Set<CanvasPanel>) -> CGFloat {
        let range = exposedRange(for: panels)
        return (range.lowerBound + range.upperBound) / 2
    }

    /// Image and controls use one bounded anchor even when the exposed region
    /// is narrower than the controls. Keep the complete control surface visible.
    func presentationCenterX(for panels: Set<CanvasPanel>, controlsWidth: CGFloat = CanvasPanelLayout.controlsWidth) -> CGFloat {
        let halfWidth = min(max(0, size.width) / 2, controlsWidth / 2)
        return min(max(centerX(for: panels), halfWidth), max(halfWidth, size.width - halfWidth))
    }

}

/// Shared SwiftUI-content and native-host geometry.
enum CanvasControlLayout {
    static let width: CGFloat = 560
    static let idleHeight: CGFloat = 32
    static let processingHeight: CGFloat = 76
    static let verticalPadding: CGFloat = 10
    static let bottomPadding: CGFloat = 18
    static func height(processing: Bool) -> CGFloat {
        (processing ? processingHeight : idleHeight) + verticalPadding * 2 + bottomPadding
    }
}
