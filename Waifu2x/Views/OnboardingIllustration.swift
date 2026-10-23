import SwiftUI

/// A camera moves over a simplified version of the actual workspace. Pointer
/// actions and the resulting UI share one timeline, including static previews.
struct OnboardingIllustration: View {
    let step: OnboardingStep
    var animates = true
    var previewTime: TimeInterval? = nil
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var startedAt = Date()
    @State private var pausedElapsed: TimeInterval?
    private var reduceMotion: Bool { systemReduceMotion || !animates }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || pausedElapsed != nil || previewTime != nil)) { timeline in
            let elapsed = previewTime ?? pausedElapsed ?? max(0, timeline.date.timeIntervalSince(startedAt))
            let frame = reduceMotion && previewTime == nil
                ? OnboardingDemoTimeline.stillFrame(step: step)
                : OnboardingDemoTimeline.frame(step: step, elapsed: elapsed)
            ZStack {
                RoundedRectangle(cornerRadius: 22).fill(.primary.opacity(0.035))
                viewport(frame)
                    .padding(.top, 40).padding(.bottom, 48)
                    .accessibilityHidden(true)
                VStack(spacing: 0) {
                    HStack(spacing: 7) {
                        Image(systemName: step.symbol)
                        Text(L("%@演示", step.label))
                            .lineLimit(1).minimumScaleFactor(0.85)
                        Spacer()
                        if !reduceMotion && previewTime == nil {
                            Button {
                                if let pausedElapsed {
                                    startedAt = .now.addingTimeInterval(-pausedElapsed)
                                    self.pausedElapsed = nil
                                } else {
                                    pausedElapsed = max(0, Date().timeIntervalSince(startedAt))
                                }
                            } label: {
                                Image(systemName: pausedElapsed == nil ? "pause.fill" : "play.fill")
                                    .frame(width: 25, height: 25).contentShape(Rectangle())
                            }
                            .accessibilityLabel(pausedElapsed == nil ? L("暂停演示") : L("继续演示"))
                            Button {
                                startedAt = .now
                                pausedElapsed = nil
                            } label: {
                                Image(systemName: "arrow.counterclockwise")
                                    .frame(width: 25, height: 25).contentShape(Rectangle())
                            }
                            .accessibilityLabel(L("重播本步演示"))
                        }
                    }
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    .buttonStyle(.plain)
                    .padding(.horizontal, 18).padding(.top, 9)
                    Spacer()
                    Text(frame.caption)
                        .font(.system(size: 13, weight: .medium))
                        .multilineTextAlignment(.center).lineSpacing(2)
                        .lineLimit(2).minimumScaleFactor(0.85)
                        .frame(minHeight: 36)
                        .foregroundStyle(Color(nsColor: ThemeColors.textAccent))
                        .padding(.horizontal, 20).padding(.bottom, 6)
                }
            }
        }
        .onChange(of: step) { _, _ in
            startedAt = .now
            pausedElapsed = nil
        }
    }

    private func viewport(_ frame: OnboardingDemoFrame) -> some View {
        GeometryReader { geometry in
            let fit = min((geometry.size.width - 36) / OnboardingDemoLayout.size.width,
                          geometry.size.height / OnboardingDemoLayout.size.height)
            let scale = fit * frame.camera.zoom
            ZStack(alignment: .topLeading) {
                OnboardingWorkspaceDiagram(frame: frame)
                    .overlay { annotations(frame, scale: scale) }
                    .frame(width: OnboardingDemoLayout.size.width, height: OnboardingDemoLayout.size.height)
                    .scaleEffect(scale, anchor: .topLeading)
                    .offset(x: geometry.size.width / 2 - frame.camera.center.x * scale,
                            y: geometry.size.height / 2 - frame.camera.center.y * scale)
                    .opacity(frame.opacity)
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .clipped()
            // Positions already contain the camera's eased motion. Applying a
            // second implicit animation here would detach clicks from controls.
            .transaction { $0.animation = nil }
        }
    }

    private func annotations(_ frame: OnboardingDemoFrame, scale: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                for (index, target) in frame.targets.enumerated() {
                    var rect = target.rect
                    if target == .split {
                        rect.origin.x = OnboardingDemoLayout.imageRect.minX + OnboardingDemoLayout.imageRect.width * frame.split - rect.width / 2
                        rect.origin.y = OnboardingDemoLayout.imageRect.midY - rect.height / 2
                    }
                    context.stroke(Path(roundedRect: rect.insetBy(dx: -5 / scale, dy: -5 / scale), cornerRadius: 12 / scale),
                                   with: .color(.accentColor.opacity(0.85)), lineWidth: 1.5 / scale)
                    if frame.targets.count > 1 {
                        let point = CGPoint(x: min(rect.minY < 60 ? rect.midX : rect.maxX + 5 / scale,
                                                   OnboardingDemoLayout.size.width - 10 / scale),
                                            y: rect.minY < 60 ? rect.maxY + 10 / scale : rect.minY - 4 / scale)
                        context.fill(Path(ellipseIn: CGRect(x: point.x - 9 / scale, y: point.y - 9 / scale,
                                                            width: 18 / scale, height: 18 / scale)), with: .color(.accentColor))
                        var number = context.resolve(Text(L("%d", index + 1)).font(.system(size: 11 / scale, weight: .semibold)))
                        number.shading = .color(Color(nsColor: ToolbarActionPalette.prominentInk))
                        context.draw(number, at: point)
                    }
                }
                if frame.click > 0 {
                    let radius = (12 + 18 * (1 - frame.click)) / scale
                    context.stroke(Path(ellipseIn: CGRect(x: frame.cursor.x - radius, y: frame.cursor.y - radius,
                                                         width: radius * 2, height: radius * 2)),
                                   with: .color(.accentColor.opacity(frame.click * 0.8)), lineWidth: 2 / scale)
                }
            }
            if frame.cursorOpacity > 0 {
                DemoPointer()
                    .fill(.black)
                    .overlay { DemoPointer().stroke(.white, lineWidth: 1.3 / scale) }
                    .frame(width: 19 / scale, height: 28 / scale)
                    .scaleEffect(1 - frame.click * 0.12, anchor: .topLeading)
                    .offset(x: frame.cursor.x, y: frame.cursor.y)
                    .opacity(frame.cursorOpacity)
            }
        }
        .allowsHitTesting(false)
    }
}

private struct DemoPointer: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let points: [CGPoint] = [CGPoint(x: 0.02, y: 0.02), CGPoint(x: 0.02, y: 0.79),
                                 CGPoint(x: 0.28, y: 0.60), CGPoint(x: 0.53, y: 0.98),
                                 CGPoint(x: 0.75, y: 0.88), CGPoint(x: 0.51, y: 0.52),
                                 CGPoint(x: 0.95, y: 0.52)]
        path.addLines(points.map { CGPoint(x: $0.x * rect.width, y: $0.y * rect.height) })
        path.closeSubpath()
        return path
    }
}
