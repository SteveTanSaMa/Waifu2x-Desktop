import SwiftUI

/// A deliberately simplified workspace, drawn in the real window's coordinate space.
/// The surrounding tutorial owns the camera, pointer, and control highlights.
struct OnboardingWorkspaceDiagram: View {
    let frame: OnboardingDemoFrame
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Canvas { context, _ in
            var drawing = WorkspaceDiagramDrawing(context: context, dark: colorScheme == .dark)
            drawing.draw(frame)
        }
        .frame(width: OnboardingDemoLayout.size.width, height: OnboardingDemoLayout.size.height)
        .accessibilityHidden(true)
    }
}

private struct WorkspaceDiagramDrawing {
    var context: GraphicsContext
    let dark: Bool
    private var accent: Color { Color(red: 0.325, green: 0.788, blue: 0.741) }
    private var ink: Color { dark ? Color(white: 0.87) : Color(white: 0.24) }
    private var muted: Color { ink.opacity(0.34) }
    private var hairline: Color { ink.opacity(0.10) }
    private var placeholder: Color { ink.opacity(0.16) }
    private var surface: Color { dark ? Color(red: 0.145, green: 0.17, blue: 0.16) : Color(red: 0.97, green: 0.985, blue: 0.97) }
    private var canvas: Color { dark ? Color(red: 0.085, green: 0.105, blue: 0.10) : Color(red: 0.91, green: 0.945, blue: 0.92) }
    private var control: Color { ink.opacity(dark ? 0.07 : 0.045) }
    private var accentInk: Color { Color(red: 0.065, green: 0.23, blue: 0.20) }

    mutating func draw(_ frame: OnboardingDemoFrame) {
        let window = CGRect(origin: .zero, size: OnboardingDemoLayout.size)
        rounded(window, radius: 20, fill: canvas)
        context.clip(to: Path(roundedRect: window, cornerRadius: 20))
        emptyCanvas(opacity: 1 - frame.imageOpacity)
        if frame.imageOpacity > 0 {
            var image = self
            image.context.opacity *= frame.imageOpacity
            image.artwork(in: OnboardingDemoLayout.imageRect,
                          detail: frame.enhancementProgress, comparison: frame.showsComparison, split: frame.split)
            image.bottomControls(frame)
        }
        panel(CGRect(x: 8, y: 8, width: 280, height: 752))
        panel(CGRect(x: 892, y: 8, width: 380, height: 752))
        trafficLights()
        toolbar(exportEnabled: frame.enhancementProgress >= 1)
        queue(frame)
        options(frame)
        enhanceButton(enabled: frame.imageOpacity >= 0.99)
        if frame.draggedImageOpacity > 0 {
            var dragged = self
            dragged.context.opacity *= frame.draggedImageOpacity
            let card = CGRect(x: frame.cursor.x - 60, y: frame.cursor.y - 56, width: 116, height: 88)
            dragged.rounded(card.insetBy(dx: -5, dy: -5), radius: 12, fill: surface, shadow: true)
            dragged.artwork(in: card, detail: 0, comparison: false, split: 0.5)
            dragged.symbol("plus.circle.fill", at: CGPoint(x: card.maxX - 1, y: card.maxY - 1), size: 24, color: accent)
        }
        if frame.exportSheetOpacity > 0 {
            var sheet = self
            sheet.context.opacity *= frame.exportSheetOpacity
            sheet.saveSheet(exported: frame.exported)
        }
        if frame.exported && frame.exportSheetOpacity <= 0.001 {
            exportNotice()
        }
        context.stroke(Path(roundedRect: window.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 20),
                       with: .color(ink.opacity(0.15)), lineWidth: 1)
    }

    private mutating func panel(_ rect: CGRect) {
        rounded(rect, radius: 13, fill: surface, border: hairline, shadow: true)
    }

    private mutating func trafficLights() {
        for (index, color) in [Color(red: 1, green: 0.37, blue: 0.34),
                                Color(red: 1, green: 0.74, blue: 0.23),
                                Color(red: 0.17, green: 0.79, blue: 0.26)].enumerated() {
            let rect = CGRect(x: 20 + index * 20, y: 20, width: 12, height: 12)
            context.fill(Path(ellipseIn: rect), with: .color(color))
            context.stroke(Path(ellipseIn: rect), with: .color(.black.opacity(0.10)), lineWidth: 0.6)
        }
    }

    private mutating func toolbar(exportEnabled: Bool) {
        rounded(CGRect(x: 234, y: 18, width: 44, height: 32), radius: 16, fill: accent.opacity(0.22))
        symbol("photo.on.rectangle.angled", at: CGPoint(x: 256, y: 34), size: 16, color: dark ? accent : accentInk)
        rounded(CGRect(x: 902, y: 18, width: 44, height: 32), radius: 16, fill: accent.opacity(0.22))
        symbol("slider.horizontal.3", at: CGPoint(x: 924, y: 34), size: 16, color: dark ? accent : accentInk)
        rounded(OnboardingDemoLayout.exportRect, radius: 16, fill: control, border: hairline)
        symbol("square.and.arrow.up", at: CGPoint(x: 1240, y: 33), size: 16, color: exportEnabled ? ink : placeholder)
    }

    private mutating func queue(_ frame: OnboardingDemoFrame) {
        bar(x: 32, y: 88, width: 46, height: 8, color: muted)
        bar(x: 220, y: 89, width: 34, height: 6)
        if frame.imageOpacity > 0 {
            var row = self
            row.context.opacity *= frame.imageOpacity
            row.rounded(OnboardingDemoLayout.queueRect, radius: 10, fill: accent.opacity(0.15))
            row.artwork(in: CGRect(x: 28, y: 120, width: 56, height: 56), detail: frame.enhancementProgress,
                        comparison: false, split: 0.5)
            row.bar(x: 96, y: 133, width: 119, height: 7, color: ink.opacity(0.38))
            row.bar(x: 96, y: 151, width: 74, height: 5)
            if frame.enhancementProgress >= 1 {
                row.symbol("checkmark.circle.fill", at: CGPoint(x: 102, y: 169), size: 11, color: accent)
                row.bar(x: 114, y: 167, width: 52, height: 4)
            }
            row.symbol("xmark", at: CGPoint(x: 261, y: 148), size: 8, color: muted)
        }
        rounded(CGRect(x: 240, y: 712, width: 36, height: 36), radius: 18, fill: accent.opacity(0.22), border: accent.opacity(0.25))
        symbol("plus", at: CGPoint(x: 258, y: 730), size: 16, color: dark ? accent : accentInk)
    }

    private mutating func options(_ frame: OnboardingDemoFrame) {
        bar(x: 916, y: 88, width: 98, height: 9, color: muted)
        symbol("arrow.up.left.and.arrow.down.right", at: CGPoint(x: 925, y: 140), size: 14, color: accent)
        text(L("放大倍率"), at: CGPoint(x: 945, y: 140), size: 14, weight: .semibold, anchor: .leading, maxWidth: 298)
        for (index, scale) in [1, 2, 4].enumerated() {
            let x = CGFloat(917 + index * 113)
            let selected = frame.scaleIsSelected ? scale == 2 : scale == 1
            let rect = CGRect(x: x, y: 164, width: 105, height: 82)
            rounded(rect, radius: 12, fill: selected ? accent.opacity(0.19) : control,
                    border: selected ? accent.opacity(0.58) : .clear)
            text(L("%d×", scale), at: CGPoint(x: rect.midX, y: 193), size: 25, weight: .medium, rounded: true)
            bar(x: rect.midX - 17, y: 220, width: 34, height: 5, color: selected ? accent.opacity(0.75) : placeholder)
            if selected { symbol("checkmark", at: CGPoint(x: rect.maxX - 11, y: rect.minY + 12), size: 8, color: accent) }
        }
        bar(x: 917, y: 261, width: 124, height: 5)
        symbol("sparkle", at: CGPoint(x: 925, y: 286), size: 14, color: accent)
        text(L("降噪"), at: CGPoint(x: 945, y: 286), size: 14, weight: .semibold, anchor: .leading, maxWidth: 298)
        for index in 0..<5 {
            let rect = CGRect(x: 916 + index * 67, y: 306, width: 60, height: 70)
            let selected = frame.noiseIsSelected ? index == 2 : index == 0
            rounded(rect, radius: 10, fill: selected ? accent.opacity(0.19) : control,
                    border: selected ? accent.opacity(0.58) : .clear)
            for level in 0..<4 {
                let height = CGFloat(7 + level * 4)
                let active = level < index
                rounded(CGRect(x: rect.midX - 12 + CGFloat(level) * 7, y: 342 - height, width: 4, height: height),
                        radius: 2, fill: active ? (selected ? accent : ink.opacity(0.48)) : placeholder)
            }
            bar(x: rect.midX - 11, y: 357, width: 22, height: 4, color: selected ? accent.opacity(0.8) : placeholder)
            if selected { symbol("checkmark", at: CGPoint(x: rect.maxX - 8, y: rect.minY + 9), size: 7, color: accent) }
        }
        bar(x: 917, y: 392, width: 158, height: 5)
        line(from: CGPoint(x: 916, y: 429), to: CGPoint(x: 1248, y: 429), color: hairline)
        bar(x: 917, y: 451, width: 68, height: 7, color: muted)
        for index in 0..<4 {
            let y = CGFloat(487 + index * 45)
            symbol(["square.stack", "cpu", "square.stack.3d.up", "square.grid.2x2"][index],
                   at: CGPoint(x: 926, y: y), size: 13, color: muted)
            bar(x: 946, y: y - 3, width: CGFloat(76 + index % 2 * 21), height: 5)
            rounded(CGRect(x: 1171, y: y - 10, width: 77, height: 21), radius: 6, fill: control)
            bar(x: 1182, y: y - 2, width: 37, height: 4)
            symbol("chevron.down", at: CGPoint(x: 1236, y: y), size: 7, color: muted)
        }
    }

    private mutating func enhanceButton(enabled: Bool) {
        let rect = OnboardingDemoLayout.enhanceRect
        rounded(rect, radius: 22, fill: enabled ? accent : accent.opacity(0.18), border: .white.opacity(0.16), shadow: true)
        symbol("sparkles", at: CGPoint(x: 1170, y: 722), size: 15, color: enabled ? accentInk : muted)
        text(L("增强"), at: CGPoint(x: 1212, y: 722), size: 16, weight: .semibold, color: enabled ? accentInk : muted, maxWidth: 68)
    }

    private mutating func emptyCanvas(opacity: Double) {
        guard opacity > 0 else { return }
        var empty = self
        empty.context.opacity *= opacity
        let rect = OnboardingDemoLayout.dropRect
        empty.context.stroke(Path(roundedRect: rect, cornerRadius: 22),
                             with: .color(accent.opacity(0.22)), style: StrokeStyle(lineWidth: 1.5, dash: [7, 7]))
        empty.symbol("photo.on.rectangle.angled", at: CGPoint(x: 590, y: 320), size: 52, color: accent.opacity(0.75))
        empty.bar(x: 514, y: 371, width: 152, height: 11, color: muted)
        empty.bar(x: 479, y: 399, width: 222, height: 6)
        empty.rounded(CGRect(x: 528, y: 437, width: 124, height: 36), radius: 18, fill: accent)
        empty.symbol("plus", at: CGPoint(x: 553, y: 455), size: 12, color: accentInk)
        empty.bar(x: 570, y: 452, width: 58, height: 6, color: accentInk.opacity(0.7))
    }

    private mutating func bottomControls(_ frame: OnboardingDemoFrame) {
        let controls = CGRect(x: 310, y: 700, width: 560, height: 52)
        rounded(controls, radius: 18, fill: surface, border: hairline, shadow: true)
        if frame.enhancementProgress > 0 && frame.enhancementProgress < 1 {
            symbol("sparkles", at: CGPoint(x: 341, y: 726), size: 15, color: accent)
            bar(x: 364, y: 714, width: 88, height: 6, color: muted)
            rounded(CGRect(x: 364, y: 733, width: 280, height: 4), radius: 2, fill: placeholder)
            rounded(CGRect(x: 364, y: 733, width: max(4, 280 * frame.enhancementProgress), height: 4), radius: 2, fill: accent)
        } else {
            rounded(CGRect(x: 342, y: 710, width: 192, height: 32), radius: 8, fill: control)
            let selected = frame.showsComparison ? 2 : (frame.enhancementProgress >= 1 ? 1 : 0)
            rounded(CGRect(x: 342 + selected * 64, y: 711, width: 64, height: 30), radius: 7,
                    fill: dark ? Color(white: 0.33) : .white, shadow: true)
            for (index, title) in [L("原图"), L("结果"), L("比较")].enumerated() {
                text(title, at: CGPoint(x: 374 + index * 64, y: 726), size: 14,
                     color: index == selected ? ink : muted, maxWidth: 54)
            }
            bar(x: 557, y: 723, width: 106, height: 5)
        }
        symbol("minus.magnifyingglass", at: CGPoint(x: 715, y: 726), size: 14, color: muted)
        bar(x: 754, y: 723, width: 30, height: 5)
        symbol("chevron.down", at: CGPoint(x: 799, y: 726), size: 7, color: muted)
        symbol("plus.magnifyingglass", at: CGPoint(x: 836, y: 726), size: 14, color: muted)
    }

    private mutating func artwork(in rect: CGRect, detail: Double, comparison: Bool, split: CGFloat) {
        var art = self
        art.context.clip(to: Path(roundedRect: rect, cornerRadius: min(12, rect.width * 0.08)))
        art.context.translateBy(x: rect.minX, y: rect.minY)
        art.context.scaleBy(x: rect.width / 548, y: rect.height / 365)
        art.landscape(detail: detail >= 1 ? 1 : 0)
        if detail > 0 && detail < 1 {
            let edge = 548 * detail
            var enhanced = art
            enhanced.context.clip(to: Path(CGRect(x: 0, y: 0, width: edge, height: 365)))
            enhanced.landscape(detail: 1)
            art.line(from: CGPoint(x: edge, y: 0), to: CGPoint(x: edge, y: 365), color: accent.opacity(0.8), width: 1.5)
        }
        if comparison {
            let x = min(0.98, max(0.02, split)) * 548
            // Fewer contours on the original side convey the comparison without invented image content.
            var original = art
            original.context.clip(to: Path(CGRect(x: 0, y: 0, width: x, height: 365)))
            original.landscape(detail: 0)
            art.line(from: CGPoint(x: x, y: 0), to: CGPoint(x: x, y: 365), color: .white.opacity(0.9), width: 1.5)
            art.rounded(CGRect(x: x - 14, y: 168.5, width: 28, height: 28), radius: 14, fill: .black.opacity(0.45))
            art.symbol("arrow.left.and.right", at: CGPoint(x: x, y: 182.5), size: 12, color: .white)
        }
        context.stroke(Path(roundedRect: rect, cornerRadius: min(12, rect.width * 0.08)), with: .color(hairline), lineWidth: 1)
    }

    private mutating func landscape(detail: Double) {
        let bounds = CGRect(x: 0, y: 0, width: 548, height: 365)
        context.fill(Path(bounds), with: .color(dark ? Color(red: 0.12, green: 0.28, blue: 0.25) : Color(red: 0.87, green: 0.95, blue: 0.88)))
        context.fill(Path(ellipseIn: CGRect(x: 375, y: 34, width: 98, height: 98)), with: .color(accent.opacity(dark ? 0.7 : 0.5)))
        let back = path { p in
            p.move(to: CGPoint(x: 0, y: 199))
            p.addCurve(to: CGPoint(x: 284, y: 178), control1: CGPoint(x: 158, y: 72), control2: CGPoint(x: 183, y: 266))
            p.addCurve(to: CGPoint(x: 548, y: 159), control1: CGPoint(x: 416, y: 74), control2: CGPoint(x: 416, y: 213))
            p.addLine(to: CGPoint(x: 548, y: 365)); p.addLine(to: CGPoint(x: 0, y: 365)); p.closeSubpath()
        }
        context.fill(back, with: .color(accent.opacity(0.27)))
        let mountain = path { p in
            p.move(to: CGPoint(x: 27, y: 260)); p.addLine(to: CGPoint(x: 211, y: 89))
            p.addLine(to: CGPoint(x: 223, y: 92)); p.addLine(to: CGPoint(x: 388, y: 261)); p.closeSubpath()
        }
        context.fill(mountain, with: .color(dark ? Color(red: 0.24, green: 0.51, blue: 0.43) : Color(red: 0.39, green: 0.66, blue: 0.55)))
        context.fill(path { p in
            p.move(to: CGPoint(x: 165, y: 132)); p.addLine(to: CGPoint(x: 211, y: 89)); p.addLine(to: CGPoint(x: 223, y: 92))
            p.addLine(to: CGPoint(x: 270, y: 140)); p.addLine(to: CGPoint(x: 238, y: 129)); p.addLine(to: CGPoint(x: 218, y: 114))
            p.addLine(to: CGPoint(x: 201, y: 135)); p.addLine(to: CGPoint(x: 191, y: 125)); p.closeSubpath()
        }, with: .color(dark ? Color(red: 0.69, green: 0.83, blue: 0.70) : Color(red: 0.95, green: 0.97, blue: 0.86)))
        var contours = self
        contours.context.clip(to: mountain)
        for index in 0..<(detail >= 1 ? 17 : 8) {
            let y = CGFloat(140 + index * (detail >= 1 ? 7 : 15))
            let ridge = path { p in
                p.move(to: CGPoint(x: 25, y: y + 75)); p.addLine(to: CGPoint(x: 214, y: y))
                p.addQuadCurve(to: CGPoint(x: 390, y: y + 83), control: CGPoint(x: 267, y: y + 51))
            }
            contours.context.stroke(ridge, with: .color(Color(red: 0.79, green: 0.94, blue: 0.81).opacity(0.55)), lineWidth: detail >= 1 ? 0.9 : 1.7)
        }
        context.fill(path { p in
            p.move(to: CGPoint(x: 0, y: 242))
            p.addCurve(to: CGPoint(x: 289, y: 253), control1: CGPoint(x: 134, y: 187), control2: CGPoint(x: 160, y: 298))
            p.addCurve(to: CGPoint(x: 548, y: 226), control1: CGPoint(x: 410, y: 215), control2: CGPoint(x: 452, y: 247))
            p.addLine(to: CGPoint(x: 548, y: 365)); p.addLine(to: CGPoint(x: 0, y: 365)); p.closeSubpath()
        }, with: .color(Color(red: 0.11, green: 0.39, blue: 0.32)))
        let lake = path { p in
            p.move(to: CGPoint(x: 0, y: 272)); p.addQuadCurve(to: CGPoint(x: 548, y: 255), control: CGPoint(x: 270, y: 288))
            p.addLine(to: CGPoint(x: 548, y: 365)); p.addLine(to: CGPoint(x: 0, y: 365)); p.closeSubpath()
        }
        context.fill(lake, with: .color(accent.opacity(dark ? 0.65 : 0.9)))
        var water = self
        water.context.clip(to: lake)
        for index in 0..<(detail >= 1 ? 24 : 12) {
            let y = CGFloat(267 + index * (detail >= 1 ? 4 : 8))
            let center = 422 + sin(CGFloat(index) * 0.8) * 5
            water.line(from: CGPoint(x: center - CGFloat(13 + index), y: y),
                       to: CGPoint(x: center + CGFloat(13 + index), y: y), color: Color(red: 0.87, green: 0.97, blue: 0.81).opacity(0.65), width: 1)
        }
        context.fill(path { p in
            p.move(to: CGPoint(x: 0, y: 277)); p.addQuadCurve(to: CGPoint(x: 208, y: 365), control: CGPoint(x: 135, y: 297))
            p.addLine(to: CGPoint(x: 0, y: 365)); p.closeSubpath()
        }, with: .color(Color(red: 0.07, green: 0.26, blue: 0.21)))
        for (x, base, height) in [(29.0, 300.0, 117.0), (68.0, 316.0, 89.0), (111.0, 337.0, 59.0)] {
            line(from: CGPoint(x: x, y: base), to: CGPoint(x: x, y: base - height), color: Color(red: 0.06, green: 0.24, blue: 0.20), width: 2)
            for tier in 0..<5 {
                let y = base - height + Double(tier) * height * 0.15
                let spread = 6 + Double(tier) * height * 0.025
                context.fill(path { p in
                    p.move(to: CGPoint(x: x, y: y)); p.addLine(to: CGPoint(x: x - spread, y: y + height * 0.26))
                    p.addLine(to: CGPoint(x: x + spread, y: y + height * 0.26)); p.closeSubpath()
                }, with: .color(Color(red: 0.06, green: 0.24, blue: 0.20)))
            }
        }
    }

    private mutating func saveSheet(exported: Bool) {
        context.fill(Path(CGRect(x: 0, y: 0, width: 1280, height: 768)), with: .color(.black.opacity(dark ? 0.28 : 0.12)))
        let rect = OnboardingDemoLayout.savePanelRect
        rounded(rect, radius: 16, fill: surface, border: ink.opacity(0.15), shadow: true)
        symbol(exported ? "checkmark.circle.fill" : "square.and.arrow.up", at: CGPoint(x: 383, y: 264),
               size: exported ? 24 : 21, color: accent)
        bar(x: 408, y: 259, width: exported ? 104 : 142, height: 9, color: muted)
        bar(x: 373, y: 309, width: 57, height: 6)
        rounded(CGRect(x: 447, y: 296, width: 461, height: 32), radius: 6, fill: control, border: accent.opacity(0.65))
        bar(x: 459, y: 309, width: 136, height: 6, color: muted)
        text(".png", at: CGPoint(x: 621, y: 312), size: 13, color: muted)
        bar(x: 373, y: 357, width: 45, height: 6)
        rounded(CGRect(x: 447, y: 344, width: 461, height: 32), radius: 6, fill: control, border: hairline)
        symbol("folder", at: CGPoint(x: 465, y: 360), size: 13, color: accent)
        bar(x: 484, y: 358, width: 65, height: 5)
        symbol("chevron.down", at: CGPoint(x: 891, y: 360), size: 8, color: muted)
        line(from: CGPoint(x: 340, y: 439), to: CGPoint(x: 940, y: 439), color: hairline)
        rounded(CGRect(x: 704, y: 466, width: 96, height: 32), radius: 8, fill: control, border: hairline)
        bar(x: 736, y: 479, width: 32, height: 5, color: muted)
        rounded(OnboardingDemoLayout.saveRect, radius: 8, fill: accent)
        if exported {
            symbol("checkmark", at: CGPoint(x: 860, y: 482), size: 14, color: accentInk)
        } else {
            text(L("存储"), at: CGPoint(x: 860, y: 482), size: 13, weight: .semibold, color: accentInk, maxWidth: 80)
        }
    }

    private mutating func exportNotice() {
        rounded(CGRect(x: 330, y: 70, width: 236, height: 38), radius: 18,
                fill: surface, border: hairline, shadow: true)
        symbol("checkmark.circle.fill", at: CGPoint(x: 351, y: 89), size: 14, color: accent)
        bar(x: 369, y: 86, width: 58, height: 6, color: muted)
        bar(x: 435, y: 86, width: 108, height: 6)
    }

    private mutating func rounded(_ rect: CGRect, radius: CGFloat, fill: Color,
                                  border: Color = .clear, shadow: Bool = false) {
        let shape = Path(roundedRect: rect, cornerRadius: radius)
        if shadow {
            var shaded = context
            shaded.addFilter(.shadow(color: .black.opacity(dark ? 0.20 : 0.08), radius: 9, x: 0, y: 4))
            shaded.fill(shape, with: .color(fill))
        } else {
            context.fill(shape, with: .color(fill))
        }
        context.stroke(shape, with: .color(border), lineWidth: 1)
    }

    private mutating func bar(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, color: Color? = nil) {
        rounded(CGRect(x: x, y: y, width: width, height: height), radius: height / 2, fill: color ?? placeholder)
    }

    private mutating func line(from start: CGPoint, to end: CGPoint, color: Color, width: CGFloat = 1) {
        context.stroke(path { p in p.move(to: start); p.addLine(to: end) }, with: .color(color), lineWidth: width)
    }

    private mutating func text(_ string: String, at point: CGPoint, size: CGFloat, weight: Font.Weight = .regular,
                               color: Color? = nil, anchor: UnitPoint = .center, rounded: Bool = false, maxWidth: CGFloat? = nil) {
        let text = Text(string).font(.system(size: size, weight: weight, design: rounded ? .rounded : .default))
        var resolved = context.resolve(text)
        resolved.shading = .color(color ?? ink)
        let measured = resolved.measure(in: CGSize(width: 10_000, height: 10_000))
        if let maxWidth, measured.width > maxWidth {
            var fitted = context
            fitted.translateBy(x: point.x, y: point.y)
            let scale = maxWidth / measured.width
            fitted.scaleBy(x: scale, y: scale)
            fitted.draw(resolved, at: .zero, anchor: anchor)
        } else {
            context.draw(resolved, at: point, anchor: anchor)
        }
    }

    private mutating func symbol(_ name: String, at point: CGPoint, size: CGFloat, color: Color) {
        var resolved = context.resolve(Text(Image(systemName: name)).font(.system(size: size, weight: .medium)))
        resolved.shading = .color(color)
        context.draw(resolved, at: point)
    }

    private func path(_ draw: (inout Path) -> Void) -> Path {
        var result = Path()
        draw(&result)
        return result
    }
}
