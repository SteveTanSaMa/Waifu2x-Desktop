import AppKit
import Combine

enum SettingsSection: String, CaseIterable, Identifiable {
    case general, models, updates, about
    var id: Self { self }
    var title: String {
        switch self {
        case .general: L("通用")
        case .models: L("模型与文件")
        case .updates: L("软件更新")
        case .about: L("关于")
        }
    }
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .models: "checkmark.shield"
        case .updates: "arrow.triangle.2.circlepath"
        case .about: "info.circle"
        }
    }
}

@MainActor
final class SettingsNavigation: ObservableObject {
    @Published var selection: SettingsSection? = .general
    weak var mainWindow: NSWindow?
    private(set) weak var settingsWindow: NSWindow?
    private var placement: Task<Void, Never>?
    var preventsFocusDismissal: @MainActor () -> Bool = { false }

    func closeIfVisible() -> Bool {
        guard let window = settingsWindow, window.isVisible else { return false }
        placement?.cancel()
        window.close()
        return true
    }

    func prepareForPresentation() {
        placement?.cancel()
        centerOverMainWindow()
        placement = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled else { return }
            self?.centerOverMainWindow()
        }
    }

    func registerSettingsWindow(_ window: NSWindow) {
        guard settingsWindow !== window else { return }
        settingsWindow = window
        prepareForPresentation()
    }

    private func centerOverMainWindow() {
        guard let window = settingsWindow, let main = mainWindow, main !== window else { return }
        let screen = main.screen ?? NSScreen.screens.max {
            Self.intersectionArea(main.frame, $0.frame) < Self.intersectionArea(main.frame, $1.frame)
        }.flatMap { main.frame.intersects($0.frame) ? $0 : nil } ?? NSScreen.main
        let frame = Self.centeredFrame(size: window.frame.size, over: main.frame,
                                       visibleFrame: screen?.visibleFrame)
        window.setFrameOrigin(frame.origin)
    }

    static func centeredFrame(size: CGSize, over main: CGRect, visibleFrame: CGRect?) -> CGRect {
        var origin = CGPoint(x: main.midX - size.width / 2, y: main.midY - size.height / 2)
        if let visible = visibleFrame {
            origin.x = min(max(origin.x, visible.minX), max(visible.minX, visible.maxX - size.width))
            origin.y = min(max(origin.y, visible.minY), max(visible.minY, visible.maxY - size.height))
        }
        return CGRect(origin: origin, size: size)
    }

    private static func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }
}
