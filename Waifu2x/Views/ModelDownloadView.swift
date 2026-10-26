import SwiftUI
import Foundation

/// A snapshot from the download owner. Views never decide model readiness or
/// advance to the tutorial; a complete byte count still requires verification.
enum ModelDownloadStatus: Equatable {
    case checking, downloading, paused, verifying, failed
}

struct ModelDownloadPresentation: Equatable {
    let progress: Double
    let downloadedBytes: Int64
    let totalBytes: Int64?
    let completedFiles: Int
    let totalFiles: Int
    let currentName: String
    let status: ModelDownloadStatus
    let errorMessage: String?
    /// Enables pause/resume/retry, never permission to enter the workspace.
    let canStart: Bool
    let isIncrementalRepair: Bool

    init(progress: Double = 0, downloadedBytes: Int64 = 0, totalBytes: Int64? = nil,
         completedFiles: Int = 0, totalFiles: Int = 0, currentName: String = "",
         status: ModelDownloadStatus = .checking, errorMessage: String? = nil,
         canStart: Bool = true, isIncrementalRepair: Bool = false) {
        self.progress = progress
        self.downloadedBytes = downloadedBytes
        self.totalBytes = totalBytes
        self.completedFiles = completedFiles
        self.totalFiles = totalFiles
        self.currentName = currentName
        self.status = status
        self.errorMessage = errorMessage
        self.canStart = canStart
        self.isIncrementalRepair = isIncrementalRepair
    }

    var fraction: Double { progress.isFinite ? min(1, max(0, progress)) : 0 }
}

struct ModelDownloadView: View {
    @Environment(\.locale) private var locale
    let presentation: ModelDownloadPresentation
    let onRetry: () -> Void
    let onPauseResume: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let _ = locale
        GeometryReader { geometry in
            let inset: CGFloat = geometry.size.width >= 1500 ? 56 : 40
            VStack(spacing: 0) {
                header(inset: inset).frame(height: 68)
                GeometryReader { content in
                    let width = min(1440, max(1, content.size.width - inset * 2))
                    let textWidth = min(440, max(350, width * 0.31))
                    let gap = min(72, max(44, width * 0.05))
                    let artWidth = max(1, width - textWidth - gap)
                    HStack(alignment: .center, spacing: gap) {
                        artwork
                            .frame(width: artWidth)
                        ScrollView {
                            downloadContent
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .frame(minHeight: max(1, content.size.height - 56), alignment: .center)
                        }
                        .scrollIndicators(.hidden)
                        .frame(width: textWidth, height: max(1, content.size.height - 32))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                footer(inset: inset).frame(height: 68)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityIdentifier("modelDownload")
    }

    private func header(inset: CGFloat) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "mountain.2")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Color(nsColor: ThemeColors.textAccent))
            Text(verbatim: "Waifu2x").font(.system(size: 16, weight: .semibold))
            Spacer(minLength: 16)
            Text(L("模型准备")).font(.system(size: 13)).foregroundStyle(.secondary)
        }
        .padding(.leading, 116).padding(.trailing, inset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            WorkspaceWindowDragRegion()
        }
    }

    private var artwork: some View {
        VStack(alignment: .leading, spacing: 18) {
            StartupLandscapeView(progress: presentation.fraction,
                                 animates: !reduceMotion && presentation.status == .downloading)
                .aspectRatio(1.5, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 24).stroke(.primary.opacity(0.07), lineWidth: 1) }
                .shadow(color: .black.opacity(0.05), radius: 28, y: 14)
                .accessibilityHidden(true)
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(L("清晰，随进度慢慢成形"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color(nsColor: ThemeColors.textAccent))
                Spacer(minLength: 0)
                Text(artworkCaption)
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 28)
    }

    private var downloadContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L("模型准备"))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(Color(nsColor: ThemeColors.textAccent))
                .padding(.bottom, 18)
            Text(presentation.isIncrementalRepair ? L("正在补全缺失的模型") : L("为清晰，备好画笔"))
                .font(.system(size: 32, weight: .semibold)).tracking(-0.6)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 16)
            Text(presentation.isIncrementalRepair ? L("只补全缺失或受损的模型，已验证的文件会保留") : L("先下载增强模型，之后即可在本机处理图片"))
                .font(.system(size: 14)).lineSpacing(5).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 30)
            progressDetails
                .padding(.bottom, 22)
            stateDetails
                .padding(.bottom, 24)
            action.frame(minHeight: 44, alignment: .leading)
            Text(presentation.isIncrementalRepair ? L("相同内容只下载一次，完成后会再次校验所有模型") : L("下载后的模型会保存在本机供后续使用"))
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 16)
        }
        .padding(.vertical, 20)
    }

    private var progressDetails: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(statusTitle).font(.system(size: 12, weight: .medium))
                Spacer(minLength: 0)
                // These are extracted model files, not separate archive downloads.
                if presentation.status == .verifying, presentation.totalFiles > 0 {
                    Text(L("%d / %d 个文件", presentation.completedFiles, presentation.totalFiles))
                        .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            Text(presentation.currentName.isEmpty ? L("正在准备模型清单") : presentation.currentName)
                .font(.system(size: 14, weight: .medium))
                .lineLimit(2).truncationMode(.middle)
                .help(presentation.currentName)
                .frame(minHeight: 34, alignment: .topLeading)
            ProgressView(value: presentation.fraction)
                .tint(Color.accentColor)
                .accessibilityLabel(L("模型下载进度"))
                .accessibilityValue(percentText)
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(byteProgress)
                    .font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Text(percentText)
                    .font(.system(size: 24, weight: .medium, design: .rounded)).monospacedDigit()
                    .foregroundStyle(Color(nsColor: ThemeColors.textAccent))
            }
        }
    }

    @ViewBuilder private var stateDetails: some View {
        if presentation.status == .failed {
            VStack(alignment: .leading, spacing: 7) {
                Label(L("下载暂时中断"), systemImage: "exclamationmark.circle")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.orange)
                Text(presentation.errorMessage ?? L("请检查网络连接后重试，已下载的内容会保留"))
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        } else {
            HStack(alignment: .top, spacing: 9) {
                if presentation.status == .checking || presentation.status == .verifying {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: presentation.status == .paused ? "pause.circle" : "arrow.down.circle")
                        .font(.system(size: 14)).foregroundStyle(Color(nsColor: ThemeColors.textAccent))
                }
                Text(statusDetail)
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var action: some View {
        switch presentation.status {
        case .failed:
            downloadButton(L("重试下载"), symbol: "arrow.clockwise", prominent: true, action: onRetry)
        case .paused:
            downloadButton(L("继续下载"), symbol: "arrow.down", prominent: true, action: onPauseResume)
        case .downloading:
            downloadButton(L("暂停下载"), symbol: "pause", prominent: false, action: onPauseResume)
        case .checking, .verifying:
            EmptyView()
        }
    }

    private func downloadButton(_ title: String, symbol: String, prominent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(prominent ? Color(nsColor: ToolbarActionPalette.prominentInk) : .primary)
                .padding(.horizontal, 24).padding(.vertical, 13)
                .background(prominent ? Color.accentColor : Color.primary.opacity(0.06), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!presentation.canStart)
        .opacity(presentation.canStart ? 1 : 0.55)
        .accessibilityIdentifier("modelDownloadAction")
    }

    private func footer(inset: CGFloat) -> some View {
        Label(L("模型保存在本机，图片不会上传"), systemImage: "lock.shield")
            .font(.system(size: 12)).foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, inset)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .top) { Divider().opacity(0.5) }
    }

    private var percentText: String { L("%d%%", Int((presentation.fraction * 100).rounded(.down))) }
    private var byteProgress: String {
        let downloaded = ByteCountFormatter.string(fromByteCount: max(0, presentation.downloadedBytes), countStyle: .file)
        guard let total = presentation.totalBytes, total > 0 else {
            return L("已下载 %@，总大小待确认", downloaded)
        }
        return L("%@ / %@", downloaded, ByteCountFormatter.string(fromByteCount: total, countStyle: .file))
    }
    private var statusTitle: String {
        switch presentation.status {
        case .checking: L("检查模型")
        case .downloading: L("正在下载")
        case .paused: L("已暂停")
        case .verifying: L("正在校验")
        case .failed: L("等待重试")
        }
    }
    private var statusDetail: String {
        switch presentation.status {
        case .checking: L("正在检查本机模型与可用下载")
        case .downloading: L("下载完成并校验后，将自动继续")
        case .paused: L("下载已暂停，准备好后可继续")
        case .verifying: L("正在核对模型完整性，完成后将自动继续")
        case .failed: L("请检查网络连接后重试，已下载的内容会保留")
        }
    }
    private var artworkCaption: String {
        if presentation.status == .paused { return L("稍作停留，清晰仍在途中") }
        if presentation.status == .failed { return L("画面停在这里，等待下一笔") }
        switch presentation.fraction {
        case ..<0.18: return L("先勾勒轮廓")
        case ..<0.48: return L("让山色渐次铺开")
        case ..<0.78: return L("把细节交还给山脊")
        case ..<1: return L("在水光里，收拢最后一笔")
        default: return L("山海已就位，正在准备启程")
        }
    }
}

/// Every painted layer is a deterministic function of downloaded fraction.
/// Time can only move a tiny water glimmer, never reveal another stroke or fill.
private struct StartupLandscapeView: View {
    @Environment(\.locale) private var locale
    let progress: Double
    let animates: Bool

    var body: some View {
        let _ = locale
        TimelineView(.animation(minimumInterval: 1 / 24, paused: !animates)) { timeline in
            Canvas { context, size in
                draw(in: context, size: size, shimmer: animates ? timeline.date.timeIntervalSinceReferenceDate : 0)
            }
        }
        .transaction { $0.animation = nil }
    }

    private func draw(in context: GraphicsContext, size: CGSize, shimmer: Double) {
        var canvas = context
        let scale = min(size.width / 720, size.height / 480)
        canvas.translateBy(x: (size.width - 720 * scale) / 2, y: (size.height - 480 * scale) / 2)
        canvas.scaleBy(x: scale, y: scale)
        canvas.clip(to: Path(CGRect(x: 0, y: 0, width: 720, height: 480)))
        let fraction = progress.isFinite ? min(1, max(0, progress)) : 0
        func stage(_ start: Double, _ end: Double) -> Double {
            let value = min(1, max(0, (fraction - start) / (end - start)))
            return value * value * (3 - 2 * value)
        }
        func color(_ hex: UInt32) -> Color {
            Color(red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255)
        }
        func polygon(_ points: [CGPoint]) -> Path {
            Path { path in
                path.addLines(points)
                path.closeSubpath()
            }
        }
        func paint(_ shape: Path, _ hex: UInt32, _ opacity: Double) {
            canvas.fill(shape, with: .color(color(hex).opacity(opacity)))
        }
        func line(_ a: CGPoint, _ b: CGPoint, _ hex: UInt32, _ opacity: Double, width: CGFloat = 1) {
            let shape = Path { path in path.move(to: a); path.addLine(to: b) }
            canvas.stroke(shape, with: .color(color(hex).opacity(opacity)), style: StrokeStyle(lineWidth: width, lineCap: .round))
        }
        let paper = Path(CGRect(x: 0, y: 0, width: 720, height: 480))
        canvas.fill(paper, with: .color(color(0xF6F5EB)))
        var sky = canvas
        sky.opacity = stage(0.04, 0.35)
        sky.fill(paper, with: .linearGradient(Gradient(colors: [color(0xFAF8EC), color(0xE2F0E1)]), startPoint: .zero, endPoint: CGPoint(x: 0, y: 350)))

        let sun = Path(ellipseIn: CGRect(x: 488, y: 48, width: 130, height: 130))
        canvas.stroke(sun, with: .color(color(0x8BB8A0).opacity(0.13)), lineWidth: 1)
        paint(sun, 0xA3E3CF, stage(0.12, 0.38))

        var distant = Path()
        distant.move(to: CGPoint(x: -20, y: 260))
        distant.addCurve(to: CGPoint(x: 141, y: 192), control1: CGPoint(x: 49, y: 257), control2: CGPoint(x: 97, y: 197))
        distant.addCurve(to: CGPoint(x: 280, y: 239), control1: CGPoint(x: 183, y: 178), control2: CGPoint(x: 233, y: 236))
        distant.addCurve(to: CGPoint(x: 430, y: 168), control1: CGPoint(x: 327, y: 242), control2: CGPoint(x: 382, y: 173))
        distant.addCurve(to: CGPoint(x: 586, y: 236), control1: CGPoint(x: 470, y: 153), control2: CGPoint(x: 546, y: 229))
        distant.addCurve(to: CGPoint(x: 740, y: 194), control1: CGPoint(x: 644, y: 246), control2: CGPoint(x: 696, y: 190))
        distant.addLine(to: CGPoint(x: 740, y: 350))
        distant.addLine(to: CGPoint(x: -20, y: 350))
        distant.closeSubpath()
        paint(distant, 0xBEDCCA, stage(0.17, 0.48))

        let ridgePoints = [CGPoint(x: 26, y: 328), CGPoint(x: 158, y: 225), CGPoint(x: 214, y: 173), CGPoint(x: 276, y: 112), CGPoint(x: 292, y: 116), CGPoint(x: 343, y: 182), CGPoint(x: 404, y: 242), CGPoint(x: 503, y: 319)]
        let mountain = polygon(ridgePoints)
        let ridge = Path { path in path.addLines(ridgePoints) }
        canvas.stroke(ridge, with: .color(color(0x4B7A67).opacity(0.15)), style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
        canvas.stroke(ridge.trimmedPath(from: 0, to: stage(0, 0.25)), with: .color(color(0x477F6C).opacity(0.65 * (1 - stage(0.5, 0.9)))), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        paint(mountain, 0x72AC96, stage(0.28, 0.63))
        paint(polygon([CGPoint(x: 285, y: 119), CGPoint(x: 279, y: 187), CGPoint(x: 322, y: 233), CGPoint(x: 337, y: 286), CGPoint(x: 503, y: 319), CGPoint(x: 404, y: 242), CGPoint(x: 343, y: 182)]), 0x4E8F7E, stage(0.37, 0.72))
        paint(polygon([CGPoint(x: 214, y: 173), CGPoint(x: 276, y: 112), CGPoint(x: 292, y: 116), CGPoint(x: 343, y: 182), CGPoint(x: 311, y: 164), CGPoint(x: 299, y: 171), CGPoint(x: 281, y: 147), CGPoint(x: 265, y: 168), CGPoint(x: 252, y: 159)]), 0xEDF2DD, stage(0.48, 0.77))

        var contours = canvas
        contours.clip(to: mountain)
        for index in 0..<14 {
            let y = CGFloat(179 + index * 9)
            var contour = Path()
            contour.move(to: CGPoint(x: 41, y: y + 70))
            contour.addCurve(to: CGPoint(x: 273, y: y), control1: CGPoint(x: 132, y: y + 55), control2: CGPoint(x: 204, y: y + 20))
            contour.addCurve(to: CGPoint(x: 410, y: y + 42), control1: CGPoint(x: 322, y: y + 8), control2: CGPoint(x: 326, y: y + 34))
            contours.stroke(contour.trimmedPath(from: 0, to: stage(0.69 + Double(index) * 0.009, 0.86 + Double(index) * 0.009)), with: .color(color(0xD5E9CE).opacity(0.55)), lineWidth: 0.8)
        }

        var foothills = Path()
        foothills.move(to: CGPoint(x: -20, y: 296))
        foothills.addCurve(to: CGPoint(x: 172, y: 266), control1: CGPoint(x: 56, y: 295), control2: CGPoint(x: 104, y: 247))
        foothills.addCurve(to: CGPoint(x: 339, y: 299), control1: CGPoint(x: 234, y: 282), control2: CGPoint(x: 272, y: 310))
        foothills.addCurve(to: CGPoint(x: 530, y: 263), control1: CGPoint(x: 407, y: 293), control2: CGPoint(x: 465, y: 252))
        foothills.addCurve(to: CGPoint(x: 740, y: 281), control1: CGPoint(x: 608, y: 276), control2: CGPoint(x: 664, y: 257))
        foothills.addLine(to: CGPoint(x: 740, y: 357))
        foothills.addLine(to: CGPoint(x: -20, y: 357))
        foothills.closeSubpath()
        paint(foothills, 0x2D7869, stage(0.42, 0.72))

        var lake = Path()
        lake.move(to: CGPoint(x: -20, y: 329))
        lake.addCurve(to: CGPoint(x: 244, y: 334), control1: CGPoint(x: 82, y: 312), control2: CGPoint(x: 154, y: 342))
        lake.addCurve(to: CGPoint(x: 740, y: 306), control1: CGPoint(x: 413, y: 319), control2: CGPoint(x: 594, y: 304))
        lake.addLine(to: CGPoint(x: 740, y: 500))
        lake.addLine(to: CGPoint(x: -20, y: 500))
        lake.closeSubpath()
        var water = canvas
        water.clip(to: lake)
        water.opacity = stage(0.5, 0.82)
        water.fill(paper, with: .linearGradient(Gradient(colors: [color(0xA6DDC8), color(0x53C9BD), color(0x62BAAD)]), startPoint: CGPoint(x: 0, y: 302), endPoint: CGPoint(x: 0, y: 480)))
        canvas.stroke(lake.trimmedPath(from: 0, to: stage(0.06, 0.3)), with: .color(color(0x70A78E).opacity(0.25 * (1 - stage(0.6, 0.85)))), lineWidth: 0.9)
        for index in 0..<42 {
            let row = CGFloat(index)
            let reveal = stage(0.73 + Double(index) * 0.004, 0.82 + Double(index) * 0.004)
            let y = 318 + row * 3.8
            let center = 546 + sin(row * 0.79) * 10
            let halfWidth = (21 + row * 1.4) * CGFloat(reveal)
            line(CGPoint(x: center - halfWidth, y: y), CGPoint(x: center + halfWidth, y: y), 0xEFF3D9, (0.55 - Double(index) * 0.005) * reveal, width: 1)
        }
        for index in 0..<42 {
            let x = CGFloat((index * 113 + 17) % 720)
            let y = CGFloat(337 + (index * 41) % 140)
            let length = CGFloat(10 + (index * 7) % 49) * CGFloat(stage(0.77, 1))
            line(CGPoint(x: x, y: y), CGPoint(x: x + length, y: y), index % 3 == 0 ? 0xE5F3DA : 0x257F73, 0.28 * stage(0.77, 1), width: 0.7)
        }

        var shore = Path()
        shore.move(to: CGPoint(x: -20, y: 336))
        shore.addCurve(to: CGPoint(x: 117, y: 360), control1: CGPoint(x: 35, y: 327), control2: CGPoint(x: 71, y: 347))
        shore.addCurve(to: CGPoint(x: 239, y: 411), control1: CGPoint(x: 179, y: 377), control2: CGPoint(x: 156, y: 402))
        shore.addCurve(to: CGPoint(x: 405, y: 492), control1: CGPoint(x: 341, y: 423), control2: CGPoint(x: 300, y: 477))
        shore.addLine(to: CGPoint(x: -20, y: 500)); shore.closeSubpath()
        paint(shore, 0x194F45, stage(0.56, 0.88))
        func pine(x: CGFloat, base: CGFloat, height: CGFloat, reveal: Double) {
            let top = base - height
            line(CGPoint(x: x, y: base), CGPoint(x: x, y: base - height * CGFloat(reveal)), 0x123F37, reveal, width: max(1, height * 0.022))
            for tier in 0..<7 {
                let t = CGFloat(tier)
                let y = top + height * (0.08 + t * 0.105)
                let spread = height * (0.045 + t * 0.021)
                let branch = polygon([CGPoint(x: x, y: y - height * 0.08), CGPoint(x: x - spread, y: y + height * 0.13), CGPoint(x: x, y: y + height * 0.1), CGPoint(x: x + spread, y: y + height * 0.13)])
                paint(branch, 0x123F37, reveal)
            }
        }
        for index in 0..<18 {
            pine(x: CGFloat(16 + index * 41), base: 310 + sin(CGFloat(index) * 0.8) * 7, height: CGFloat(14 + (index * 7) % 17), reveal: stage(0.59, 0.87))
        }
        pine(x: 41, base: 375, height: 173, reveal: stage(0.65, 0.9))
        pine(x: 99, base: 388, height: 133, reveal: stage(0.7, 0.94))
        pine(x: 163, base: 414, height: 78, reveal: stage(0.76, 0.98))

        // The final accent is still tied to actual bytes, including at 99%.
        let canoe = polygon([CGPoint(x: 421, y: 379), CGPoint(x: 464, y: 379), CGPoint(x: 451, y: 385), CGPoint(x: 433, y: 385)])
        paint(canoe, 0x205F52, stage(0.92, 1))
        line(CGPoint(x: 427, y: 379), CGPoint(x: 459, y: 379), 0xF4EED3, stage(0.92, 1), width: 1)

        // This separate 21-point glint is the only time-dependent paint.
        // It cannot change the landscape geometry, stage, or reveal amount.
        if shimmer != 0 {
            let opacity = stage(0.78, 1) * (0.08 + 0.04 * sin(shimmer * 0.55))
            line(CGPoint(x: 538, y: 359), CGPoint(x: 559, y: 359), 0xFAFFED, opacity, width: 1.4)
        }
    }
}
