import AppKit
import SwiftUI

/// Newer toolbar APIs have the same native background treatment on Ventura.
struct WorkspaceWindowChrome: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.toolbar(removing: .title)
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        } else {
            content.toolbarBackground(.hidden, for: .windowToolbar)
        }
    }
}

/// Keeps the drag target narrow so image panning and floating controls continue
/// to own their events on every supported system.
struct WorkspaceWindowDragRegion: View {
    @ViewBuilder var body: some View {
        if #available(macOS 15, *) {
            Color.clear.contentShape(Rectangle())
                .gesture(WindowDragGesture()).allowsWindowActivationEvents(true)
        } else {
            NativeWindowDragRegion()
        }
    }
}

private struct NativeWindowDragRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowDragView { WindowDragView() }
    func updateNSView(_ view: WindowDragView, context: Context) {}
}

final class WindowDragView: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
}

enum PlatformSymbols {
    static func name(_ preferred: String, fallback: String) -> String {
        NSImage(systemSymbolName: preferred, accessibilityDescription: nil) == nil ? fallback : preferred
    }
}

struct IntegritySymbolMotion: ViewModifier {
    let isActive: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 14, *) {
            content.symbolEffect(.pulse, isActive: isActive)
        } else {
            content
        }
    }
}

struct UpdateSymbolMotion: ViewModifier {
    let isActive: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.symbolEffect(.rotate, isActive: isActive)
        } else if #available(macOS 14, *) {
            content.symbolEffect(.pulse, isActive: isActive)
        } else {
            content
        }
    }
}
