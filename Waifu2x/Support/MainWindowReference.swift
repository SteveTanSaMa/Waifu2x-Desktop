import AppKit
import SwiftUI

/// Captures the primary scene explicitly, without relying on localized titles.
struct MainWindowReference: NSViewRepresentable {
    let navigation: SettingsNavigation
    func makeNSView(context: Context) -> MainWindowReferenceView { MainWindowReferenceView() }
    func updateNSView(_ view: MainWindowReferenceView, context: Context) {
        view.navigation = navigation
        if let window = view.window { navigation.mainWindow = window }
    }
}

final class MainWindowReferenceView: NSView {
    weak var navigation: SettingsNavigation?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window { navigation?.mainWindow = window }
    }
}
