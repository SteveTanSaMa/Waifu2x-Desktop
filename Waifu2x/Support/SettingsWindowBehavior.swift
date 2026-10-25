import AppKit
import SwiftUI

/// Settings is transient, while its preferences and background work stay app-owned.
struct SettingsWindowBehavior: NSViewRepresentable {
    let navigation: SettingsNavigation
    func makeNSView(context: Context) -> SettingsWindowFocusView { SettingsWindowFocusView() }
    func updateNSView(_ view: SettingsWindowFocusView, context: Context) {
        view.navigation = navigation
        if let window = view.window { navigation.registerSettingsWindow(window) }
    }
}

final class SettingsWindowFocusView: NSView {
    weak var navigation: SettingsNavigation?
    private var observers: [NSObjectProtocol] = []
    private var dismissal: Task<Void, Never>?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        dismissal?.cancel()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        guard let window else { return }
        navigation?.registerSettingsWindow(window)
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.didResignKeyNotification,
                                            object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleClose() }
        })
        observers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification,
                                            object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismissal?.cancel() }
        })
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification,
                                            object: NSApplication.shared, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleClose(applicationDeactivated: true) }
        })
    }

    deinit {
        dismissal?.cancel()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    private func scheduleClose(applicationDeactivated: Bool = false) {
        dismissal?.cancel()
        guard let window else { return }
        dismissal = Task { @MainActor [weak self, weak window] in
            // Let AppKit finish handing focus to a menu, child window or sheet.
            await Task.yield()
            guard !Task.isCancelled, let self, let window, self.window === window,
                  window.isVisible else { return }
            guard self.navigation?.preventsFocusDismissal() != true else { return }
            if !applicationDeactivated {
                guard !window.isKeyWindow, window.attachedSheet == nil else { return }
                if window.childWindows?.contains(where: { $0.isKeyWindow }) == true { return }
                if let key = NSApplication.shared.keyWindow,
                   key.parent === window || window.childWindows?.contains(where: { $0 === key }) == true {
                    return
                }
            }
            window.close()
        }
    }
}
