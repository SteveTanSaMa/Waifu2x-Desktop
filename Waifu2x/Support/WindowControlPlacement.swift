import AppKit

/// CSS reference: panel inset 8 + frame inset 10 + group padding 1 + radius 7.
/// This fixed anchor never depends on panel visibility or a SwiftUI transaction.
@MainActor
final class WindowControlPlacement {
    static let closeCenter = CGPoint(x: 26, y: 26)
    private weak var window: NSWindow?
    private var enteringFullScreen = false
    private var observers: [NSObjectProtocol] = []
    private let nativeCenters: [(kind: NSWindow.ButtonType, center: CGPoint)]

    init(window: NSWindow) {
        self.window = window
        nativeCenters = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { kind in
            guard let button = window.standardWindowButton(kind) else { return nil }
            let rect = button.convert(button.bounds, to: nil)
            return (kind, CGPoint(x: rect.midX, y: window.frame.height - rect.midY))
        }
        let notifications = NotificationCenter.default
        for name in [NSWindow.didResizeNotification, NSWindow.didUpdateNotification] {
            observers.append(notifications.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.place() }
            })
        }
        observers.append(notifications.addObserver(forName: NSWindow.willEnterFullScreenNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.enteringFullScreen = true
                self.apply(self.nativeCenters)
            }
        })
        observers.append(notifications.addObserver(forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.enteringFullScreen = false; self?.place() }
        })
    }
    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

    func place() {
        guard let window, !enteringFullScreen, !window.styleMask.contains(.fullScreen),
              let close = nativeCenters.first(where: { $0.kind == .closeButton }) else { return }
        apply(nativeCenters.map { ($0.kind, CGPoint(x: Self.closeCenter.x + $0.center.x - close.center.x,
                                                   y: Self.closeCenter.y)) })
    }
    private func apply(_ centers: [(kind: NSWindow.ButtonType, center: CGPoint)]) {
        guard let window else { return }
        for (kind, center) in centers {
            guard let button = window.standardWindowButton(kind), let parent = button.superview else { continue }
            let target = parent.convert(CGPoint(x: center.x, y: window.frame.height - center.y), from: nil)
            let origin = CGPoint(x: target.x - button.frame.width / 2, y: target.y - button.frame.height / 2)
            if abs(button.frame.minX - origin.x) > 0.1 || abs(button.frame.minY - origin.y) > 0.1 {
                button.setFrameOrigin(origin)
            }
        }
    }
}
