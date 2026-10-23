import SwiftUI
import AppKit

/// Measures rendered control geometry without taking over window chrome or input.
struct HeaderGeometryReader: NSViewRepresentable {
    var identifier: String? = nil
    var onChange: ((CGRect, CGFloat) -> Void)? = nil
    func makeNSView(context: Context) -> HeaderGeometryView { HeaderGeometryView() }
    func updateNSView(_ view: HeaderGeometryView, context: Context) {
        view.identifier = identifier.map { NSUserInterfaceItemIdentifier($0) }
        view.onChange = onChange
        view.needsLayout = true
    }
}

final class HeaderGeometryView: NSView {
    var onChange: ((CGRect, CGFloat) -> Void)?
    private var previous: CGRect = .zero
    private var previousWidth: CGFloat = 0
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); needsLayout = true }
    override func layout() {
        super.layout()
        guard let window, bounds.width > 0 else { return }
        let native = convert(bounds, to: nil)
        // Report window coordinates from the top, matching CanvasPanelLayout.
        let rect = CGRect(x: native.minX, y: window.frame.height - native.maxY,
                          width: native.width, height: native.height)
        let width = window.frame.width
        guard rect != previous || width != previousWidth else { return }
        previous = rect
        previousWidth = width
        DispatchQueue.main.async { [weak self] in self?.onChange?(rect, width) }
    }
}
