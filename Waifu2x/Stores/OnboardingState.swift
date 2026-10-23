import Foundation
import Observation

enum OnboardingStep: Int, CaseIterable, Identifiable {
    case addImages, enhance, compareAndExport

    var id: Int { rawValue }
    var label: String {
        switch self {
        case .addImages: L("导入图片")
        case .enhance: L("增强细节")
        case .compareAndExport: L("对比与导出")
        }
    }
    var symbol: String {
        switch self {
        case .addImages: "photo.badge.plus"
        case .enhance: "sparkles"
        case .compareAndExport: "square.and.arrow.up"
        }
    }
    var title: String {
        switch self {
        case .addImages: L("从一幅画面开始")
        case .enhance: L("让细节，徐徐浮现")
        case .compareAndExport: L("把这一刻，清晰留存")
        }
    }
    var detail: String {
        switch self {
        case .addImages: L("将图片轻轻拖入画布，或点左下角 ＋ 添加。\n它会出现在左侧队列，等待焕然一新。")
        case .enhance: L("在右侧选择恰当的放大倍率与降噪强度。\n轻点右下角「增强」，让清晰慢慢显影。")
        case .compareAndExport: L("点开底部「比较」，拖动分界线细看变化。\n满意后，从右上角导出，将作品存为 PNG。")
        }
    }
    var hint: String {
        switch self {
        case .addImages: L("⌘O 打开图片   ·   ⌘V 粘贴")
        case .enhance: L("⌘↩ 增强当前图片   ·   支持多图处理")
        case .compareAndExport: L("⇧⌘S 导出当前结果   ·   支持批量导出")
        }
    }
}

/// Completion is saved only after an explicit skip or finish.
/// QA launches can show the tutorial without changing the real first-run flag.
@MainActor @Observable
final class OnboardingState {
    static let completionKey = "onboarding.completedVersion"
    static let currentVersion = 1

    var isPresented = false
    private(set) var step: OnboardingStep = .addImages
    private let defaults: UserDefaults
    private var hasCheckedLaunch = false
    private var persistsCompletion = true

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func presentIfNeeded(arguments: [String], isTesting: Bool = false) {
        guard !hasCheckedLaunch else { return }
        hasCheckedLaunch = true
        persistsCompletion = !arguments.contains("--isolated-session") && !isTesting
        if arguments.contains("--show-onboarding") {
            show()
        } else if persistsCompletion && !arguments.contains("--sample") && defaults.integer(forKey: Self.completionKey) < Self.currentVersion {
            show()
        }
    }

    func show() {
        step = .addImages
        isPresented = true
    }

    func select(_ step: OnboardingStep) { self.step = step }
    func advance() { step = OnboardingStep(rawValue: step.rawValue + 1) ?? step }
    func back() { step = OnboardingStep(rawValue: step.rawValue - 1) ?? step }

    func complete() {
        if persistsCompletion { defaults.set(Self.currentVersion, forKey: Self.completionKey) }
        isPresented = false
    }
}
