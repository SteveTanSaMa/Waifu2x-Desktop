import CoreGraphics
import Foundation

/// Coordinates follow the real workspace so a demonstrated control stays in
/// the same place when the user leaves the tutorial.
enum OnboardingDemoLayout {
    static let size = CGSize(width: 1280, height: 768)
    static let imageRect = CGRect(x: 316, y: 196, width: 548, height: 365)
    static let queueRect = CGRect(x: 16, y: 108, width: 264, height: 80)
    static let dropRect = CGRect(x: 344, y: 234, width: 492, height: 300)
    static let scaleRect = CGRect(x: 1030, y: 164, width: 105, height: 82)
    static let noiseRect = CGRect(x: 1050, y: 306, width: 60, height: 70)
    static let enhanceRect = CGRect(x: 1144, y: 700, width: 112, height: 44)
    static let compareRect = CGRect(x: 470, y: 710, width: 64, height: 32)
    static let exportRect = CGRect(x: 1218, y: 18, width: 44, height: 32)
    static let savePanelRect = CGRect(x: 340, y: 224, width: 600, height: 300)
    static let saveRect = CGRect(x: 812, y: 466, width: 96, height: 32)
}

enum OnboardingDemoTarget {
    case drop, queue, scale, noise, enhance, compare, split, export, save

    var rect: CGRect {
        switch self {
        case .drop: OnboardingDemoLayout.dropRect
        case .queue: OnboardingDemoLayout.queueRect
        case .scale: OnboardingDemoLayout.scaleRect
        case .noise: OnboardingDemoLayout.noiseRect
        case .enhance: OnboardingDemoLayout.enhanceRect
        case .compare: OnboardingDemoLayout.compareRect
        case .split: CGRect(x: 568, y: 356, width: 44, height: 44)
        case .export: OnboardingDemoLayout.exportRect
        case .save: OnboardingDemoLayout.saveRect
        }
    }
}

struct OnboardingDemoCamera {
    var center = CGPoint(x: 640, y: 384)
    var zoom: CGFloat = 1
}

struct OnboardingDemoFrame {
    var camera = OnboardingDemoCamera()
    var cursor = CGPoint(x: 220, y: 520)
    var cursorOpacity = 0.0
    var click = 0.0
    var imageOpacity = 0.0
    var draggedImageOpacity = 0.0
    var scaleIsSelected = false
    var noiseIsSelected = false
    var enhancementProgress = 0.0
    var showsComparison = false
    var split: CGFloat = 0.5
    var exportSheetOpacity = 0.0
    var exported = false
    var targets: [OnboardingDemoTarget] = []
    var caption = ""
    var opacity = 1.0
}

/// Each loop has a deliberate order: establish the workspace, move the camera,
/// show the input, then hold the resulting state before returning to overview.
enum OnboardingDemoTimeline {
    /// Keep camera, pointer, captions, and holds on one clock when adjusting pace.
    static let playbackRate = 0.65

    static func duration(for step: OnboardingStep) -> TimeInterval {
        authoredDuration(for: step) / playbackRate
    }

    private static func authoredDuration(for step: OnboardingStep) -> TimeInterval {
        switch step {
        case .addImages: 11
        case .enhance: 13.5
        case .compareAndExport: 17
        }
    }

    static func frame(step: OnboardingStep, elapsed: TimeInterval) -> OnboardingDemoFrame {
        let duration = authoredDuration(for: step)
        let time = (max(0, elapsed) * playbackRate).truncatingRemainder(dividingBy: duration)
        var frame: OnboardingDemoFrame
        switch step {
        case .addImages: frame = importFrame(at: time)
        case .enhance: frame = enhancementFrame(at: time)
        case .compareAndExport: frame = comparisonFrame(at: time)
        }
        frame.opacity = min(ramp(time, 0, 0.25), 1 - ramp(time, duration - 0.35, duration))
        return frame
    }

    static func stillFrame(step: OnboardingStep) -> OnboardingDemoFrame {
        var frame = OnboardingDemoFrame()
        frame.imageOpacity = 1
        switch step {
        case .addImages:
            frame.targets = [.drop, .queue]
            frame.caption = L("拖入画布 → 在左侧队列查看")
        case .enhance:
            frame.scaleIsSelected = true
            frame.noiseIsSelected = true
            frame.targets = [.scale, .noise, .enhance]
            frame.caption = L("选择倍率和降噪 → 点击右下角「增强」")
        case .compareAndExport:
            frame.scaleIsSelected = true
            frame.noiseIsSelected = true
            frame.enhancementProgress = 1
            frame.showsComparison = true
            frame.targets = [.compare, .split, .export]
            frame.caption = L("点击「比较」→ 拖动分界线 → 导出并存储")
        }
        return frame
    }

    private static func importFrame(at t: Double) -> OnboardingDemoFrame {
        var frame = OnboardingDemoFrame()
        frame.camera = camera(t, [
            (0, 640, 384, 1), (1, 640, 384, 1),
            (2.2, 590, 384, 1.6), (4.6, 590, 384, 1.6),
            (5.8, 170, 190, 2.2), (7.6, 170, 190, 2.2),
            (9.2, 640, 384, 1), (11, 640, 384, 1)
        ])
        frame.cursor = cursor(t, [(0, -110, 500), (2.2, -110, 500), (3.8, 590, 380), (4.7, 590, 380), (6.1, 190, 155)])
        frame.cursorOpacity = ramp(t, 1.7, 2.1) * (1 - ramp(t, 6.7, 7.1))
        frame.draggedImageOpacity = ramp(t, 2, 2.3) * (1 - ramp(t, 3.8, 4))
        frame.imageOpacity = ramp(t, 3.8, 4.2)
        frame.click = tap(t, at: 3.85)
        if t < 1.5 { frame.caption = L("画面在中央，左侧收纳，右侧调节") }
        else if t < 5 { frame.caption = L("将图片轻轻拖入中间的画布"); frame.targets = [.drop] }
        else if t < 8.3 { frame.caption = L("导入后，图片出现在左侧队列"); frame.targets = [.queue] }
        else { frame.caption = L("画面已就位，让细节有新的可能") }
        return frame
    }

    private static func enhancementFrame(at t: Double) -> OnboardingDemoFrame {
        var frame = OnboardingDemoFrame()
        frame.imageOpacity = 1
        frame.camera = camera(t, [
            (0, 640, 384, 1), (0.8, 640, 384, 1),
            (2, 1082, 170, 2.2), (3.7, 1082, 170, 2.2),
            (4.7, 1080, 330, 2.2), (5.9, 1080, 330, 2.2),
            (7.1, 1150, 660, 2.2), (8.3, 1150, 660, 2.2),
            (9.5, 640, 384, 1), (13.5, 640, 384, 1)
        ])
        frame.cursor = cursor(t, [(0, 950, 400), (2, 1000, 250), (2.7, 1082, 205), (3.7, 1082, 205),
                                  (4.8, 1080, 341), (5.9, 1080, 341), (7.4, 1200, 722), (8.6, 1200, 722)])
        frame.cursorOpacity = ramp(t, 1.7, 2) * (1 - ramp(t, 8.6, 9))
        frame.click = max(tap(t, at: 2.8), tap(t, at: 5), tap(t, at: 7.7))
        frame.scaleIsSelected = t >= 2.8
        frame.noiseIsSelected = t >= 5
        frame.enhancementProgress = ramp(t, 7.85, 10.3)
        if t < 1.7 { frame.caption = L("从恰当的参数，唤醒画面里的细节") }
        else if t < 4.1 { frame.caption = L("在右侧选择恰当的放大倍率"); frame.targets = [.scale] }
        else if t < 6.3 { frame.caption = L("再选择合适的降噪强度"); frame.targets = [.noise] }
        else if t < 8.6 { frame.caption = L("轻点右下角「增强」，开始处理"); frame.targets = [.enhance] }
        else if t < 10.3 { frame.caption = L("留意底部进度，等清晰慢慢浮现") }
        else { frame.caption = L("细节已浮现，接下来细看变化") }
        return frame
    }

    private static func comparisonFrame(at t: Double) -> OnboardingDemoFrame {
        var frame = OnboardingDemoFrame()
        frame.imageOpacity = 1
        frame.scaleIsSelected = true
        frame.noiseIsSelected = true
        frame.enhancementProgress = 1
        frame.camera = camera(t, [
            (0, 640, 384, 1), (0.8, 640, 384, 1),
            (2, 550, 680, 2.4), (3.2, 550, 680, 2.4),
            (4.4, 590, 378, 2), (8.4, 590, 378, 2),
            (10, 1175, 100, 3), (11.1, 1175, 100, 3),
            (12.2, 640, 374, 2.1), (13.9, 640, 374, 2.1),
            (15.3, 640, 384, 1), (17, 640, 384, 1)
        ])
        frame.cursor = cursor(t, [(0, 700, 650), (2.3, 502, 726), (3.2, 502, 726), (4.7, 590, 378),
                                  (5.8, 453, 378), (6.1, 453, 378), (7.6, 754, 378), (8.3, 590, 378),
                                  (10.4, 1240, 34), (11.1, 1240, 34), (12.7, 860, 482), (13.8, 860, 482)])
        frame.cursorOpacity = ramp(t, 1.8, 2.1) * (1 - ramp(t, 14.1, 14.5))
        frame.click = max(tap(t, at: 2.5), tap(t, at: 4.8), tap(t, at: 10.6), tap(t, at: 13.4))
        frame.showsComparison = t >= 2.5
        frame.split = 0.5 - 0.25 * ramp(t, 4.8, 5.8) + 0.55 * ramp(t, 6.1, 7.6) - 0.30 * ramp(t, 7.6, 8.3)
        frame.exportSheetOpacity = ramp(t, 10.8, 11.2) * (1 - ramp(t, 13.6, 14.1))
        frame.exported = t >= 14.1
        if t < 1.7 { frame.caption = L("清晰之后，值得再细看一眼") }
        else if t < 3.8 { frame.caption = L("点击底部的「比较」"); frame.targets = [.compare] }
        else if t < 8.7 { frame.caption = L("抓住分界线，左右拖动查看细节"); frame.targets = [.split] }
        else if t < 11.3 { frame.caption = L("满意后，点击右上角导出图标"); frame.targets = [.export] }
        else if t < 14.1 { frame.caption = L("选择保存位置，再点「存储」"); frame.targets = [.save] }
        else { frame.caption = L("PNG 已存储，让下一幅画面继续焕新") }
        return frame
    }

    private static func ramp(_ value: Double, _ start: Double, _ end: Double) -> Double {
        let fraction = min(1, max(0, (value - start) / (end - start)))
        return fraction * fraction * (3 - 2 * fraction)
    }

    private static func tap(_ time: Double, at start: Double) -> Double {
        guard time >= start else { return 0 }
        return 1 - ramp(time, start, start + 0.5)
    }

    private static func camera(_ time: Double, _ keys: [(Double, CGFloat, CGFloat, CGFloat)]) -> OnboardingDemoCamera {
        let pair = interval(time, keys.map { $0.0 })
        let a = keys[pair.0], b = keys[pair.1]
        let t = CGFloat(pair.2)
        return OnboardingDemoCamera(center: CGPoint(x: a.1 + (b.1 - a.1) * t, y: a.2 + (b.2 - a.2) * t),
                                    zoom: a.3 + (b.3 - a.3) * t)
    }

    private static func cursor(_ time: Double, _ keys: [(Double, CGFloat, CGFloat)]) -> CGPoint {
        let pair = interval(time, keys.map { $0.0 })
        let a = keys[pair.0], b = keys[pair.1]
        let t = CGFloat(pair.2)
        return CGPoint(x: a.1 + (b.1 - a.1) * t, y: a.2 + (b.2 - a.2) * t)
    }

    private static func interval(_ time: Double, _ times: [Double]) -> (Int, Int, Double) {
        guard let next = times.firstIndex(where: { $0 > time }) else { return (times.count - 1, times.count - 1, 0) }
        guard next > 0 else { return (0, 0, 0) }
        return (next - 1, next, ramp(time, times[next - 1], times[next]))
    }
}
