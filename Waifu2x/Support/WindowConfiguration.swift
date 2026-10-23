import SwiftUI
import AppKit

struct WindowConfiguration: NSViewRepresentable {
    var onEscape: (() -> Bool)? = nil
    func makeNSView(context: Context) -> WindowProbe { WindowProbe() }
    func updateNSView(_ nsView: WindowProbe, context: Context) {
        nsView.onEscape = onEscape
    }
}

final class WindowProbe: NSView {
    var onEscape: (() -> Bool)?
    private var keyMonitor: Any?
    private var controlPlacement: WindowControlPlacement?
    deinit { if let keyMonitor { NSEvent.removeMonitor(keyMonitor) } }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        controlPlacement = nil
        guard let window else { return }
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = false
        let minimum = CanvasPanelLayout.minimumWindowSize
        window.contentMinSize = minimum
        let frameMinimum = window.minSize
        if window.frame.width < frameMinimum.width || window.frame.height < frameMinimum.height {
            var frame = window.frame
            let height = max(frame.height, frameMinimum.height)
            frame.origin.y -= height - frame.height
            frame.size = CGSize(width: max(frame.width, frameMinimum.width), height: height)
            window.setFrame(frame, display: true)
        }
        controlPlacement = WindowControlPlacement(window: window)
        controlPlacement?.place()
        // The AppKit image view can own keyboard focus. Scope Escape to this
        // window so floating SwiftUI panels still close without affecting file panels.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window, event.keyCode == 53,
                  event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
                  self.onEscape?() == true else { return event }
            return nil
        }
    }
}
