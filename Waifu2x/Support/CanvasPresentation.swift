import SwiftUI
import AppKit

/// The canvas animation is the only presentation clock. Every tick positions
/// the native controls host synchronously before either view is displayed.
final class CanvasPresentation {
    private(set) weak var canvas: CanvasView?
    weak var controls: CanvasControlsHostView?

    func connect(_ view: CanvasView) {
        guard canvas !== view else { return }
        canvas = view
        view.onPresentationChange = { [weak self] in self?.updateControls() }
        updateControls()
    }

    func updateControls() {
        guard let canvas, let controls, canvas.window != nil, canvas.window === controls.window else { return }
        let center = canvas.convert(CGPoint(x: canvas.imageCenterX, y: 0), to: controls).x
        controls.position(at: center)
    }
}

final class CanvasControlsHostView: NSView {
    let host: NSHostingView<CanvasControls>
    weak var presentation: CanvasPresentation?
    var processing = false
    override var isFlipped: Bool { true }

    init(workspace: Workspace) {
        host = NSHostingView(rootView: CanvasControls(workspace: workspace))
        super.init(frame: .zero)
        host.sizingOptions = [.intrinsicContentSize]
        addSubview(host)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        presentation?.updateControls()
    }

    func position(at center: CGFloat) {
        let size = CGSize(width: CanvasControlLayout.width, height: CanvasControlLayout.height(processing: processing))
        let bottomLift: CGFloat = bounds.width < 800 ? 64 : 0
        // Direct frame assignment intentionally avoids a second animation clock.
        host.frame = CGRect(x: center - size.width / 2,
                            y: bounds.height - size.height - bottomLift,
                            width: size.width, height: size.height)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard host.frame.contains(convert(point, from: superview)) else { return nil }
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}
