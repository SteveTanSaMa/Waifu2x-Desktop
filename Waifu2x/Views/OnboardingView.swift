import SwiftUI

struct OnboardingView: View {
    @Bindable var onboarding: OnboardingState
    var animates = true
    let onFinish: (_ opensSample: Bool) -> Void
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    private var reduceMotion: Bool { systemReduceMotion || !animates }
    private var motion: Animation? { reduceMotion ? nil : .smooth(duration: 0.4) }

    var body: some View {
        GeometryReader { geometry in
            let inset: CGFloat = geometry.size.width >= 1500 ? 56 : 40
            VStack(spacing: 0) {
                header(inset: inset)
                    .frame(height: 64)
                    .background(HeaderGeometryReader(identifier: "onboardingHeaderBounds"))
                GeometryReader { content in
                    let width = min(1440, max(1, content.size.width - inset * 2))
                    let textWidth = min(420, max(320, width * 0.30))
                    let gap = min(64, max(40, width * 0.045))
                    let animationWidth = max(1, width - textWidth - gap)
                    HStack(alignment: .center, spacing: gap) {
                        OnboardingIllustration(step: onboarding.step, animates: animates)
                            .frame(width: animationWidth,
                                   height: min(max(1, content.size.height - 56), animationWidth / 1.5))
                            .background(HeaderGeometryReader(identifier: "onboardingAnimationBounds"))
                        instructions
                            .frame(width: textWidth, alignment: .leading)
                            .background(HeaderGeometryReader(identifier: "onboardingInstructionsBounds"))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                footer(inset: inset)
                    .frame(height: 80)
                    .overlay(alignment: .top) { Divider().opacity(0.65) }
                    .background(HeaderGeometryReader(identifier: "onboardingFooterBounds"))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onExitCommand { onFinish(false) }
    }

    private func header(inset: CGFloat) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles.rectangle.stack")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Color(nsColor: ThemeColors.textAccent))
                Text("Waifu2x").font(.system(size: 16, weight: .semibold))
                Text(L("快速入门")).font(.system(size: 13)).foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.leading, 3)
            }
            .fixedSize(horizontal: true, vertical: false)
            .background(HeaderGeometryReader(identifier: "onboardingBrandBounds"))
            Spacer()
            Button(L("跳过教程")) { onFinish(false) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .font(.system(size: 13))
                .lineLimit(1).fixedSize()
                .accessibilityIdentifier("skipOnboarding")
        }
        // Keep the native traffic lights in their usual location.
        .padding(.leading, 116).padding(.trailing, inset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            Color.clear.contentShape(Rectangle())
                .gesture(WindowDragGesture()).allowsWindowActivationEvents(true)
        }
    }

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L("%02d / %02d  ·  %@", onboarding.step.rawValue + 1, OnboardingStep.allCases.count, onboarding.step.label))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(Color(nsColor: ThemeColors.textAccent))
                .padding(.bottom, 20)
            Text(onboarding.step.title)
                .font(.system(size: 30, weight: .semibold)).tracking(-0.6)
                .lineSpacing(3)
                .padding(.bottom, 18)
            Text(onboarding.step.detail)
                .font(.system(size: 14)).lineSpacing(7)
                .foregroundStyle(.secondary)
                .padding(.bottom, 24)
            Label(onboarding.step.hint, systemImage: "keyboard")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .id(onboarding.step)
        .transition(.opacity.combined(with: .offset(y: reduceMotion ? 0 : 9)))
        .accessibilityElement(children: .contain)
    }

    private func footer(inset: CGFloat) -> some View {
        HStack(spacing: 16) {
            Button {
                withAnimation(motion) { onboarding.back() }
            } label: {
                Label(L("上一步"), systemImage: "arrow.left")
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .opacity(onboarding.step == .addImages ? 0 : 1)
            .disabled(onboarding.step == .addImages)
            .accessibilityHidden(onboarding.step == .addImages)
            .fixedSize()
            Spacer(minLength: 8)
            ViewThatFits(in: .horizontal) {
                stepNavigation(showsLabels: true)
                stepNavigation(showsLabels: false)
            }
            .layoutPriority(-1)
            Spacer(minLength: 8)
            HStack(spacing: 16) {
                if onboarding.step == .compareAndExport {
                    Button(L("进入工作区")) { onFinish(false) }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
                Button {
                    if onboarding.step == .compareAndExport {
                        onFinish(true)
                    } else {
                        withAnimation(motion) { onboarding.advance() }
                    }
                } label: {
                    HStack(spacing: 10) {
                        Text(onboarding.step == .compareAndExport ? L("试用示例图片") : L("下一步"))
                        Image(systemName: "arrow.right").font(.system(size: 11, weight: .semibold))
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color(nsColor: ToolbarActionPalette.prominentInk))
                    .padding(.horizontal, 24).frame(height: 42)
                    .background(Color.accentColor, in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("onboardingNext")
            }
            .fixedSize()
        }
        .font(.system(size: 13))
        .padding(.horizontal, inset)
    }

    /// Longer translations can keep the navigation readable by showing only
    /// step numbers; every step retains its full accessible label and tooltip.
    private func stepNavigation(showsLabels: Bool) -> some View {
        HStack(spacing: showsLabels ? 20 : 8) {
            ForEach(OnboardingStep.allCases) { step in
                Button {
                    withAnimation(motion) { onboarding.select(step) }
                } label: {
                    HStack(spacing: 7) {
                        Text(L("%02d", step.rawValue + 1))
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                        if showsLabels {
                            Text(step.label).font(.system(size: 12, weight: .medium))
                        }
                    }
                    .foregroundStyle(step == onboarding.step ? Color(nsColor: ThemeColors.textAccent) : .secondary)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(step == onboarding.step ? Color.accentColor.opacity(0.12) : .clear, in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("第 %d 步：%@", step.rawValue + 1, step.label))
                .accessibilityAddTraits(step == onboarding.step ? .isSelected : [])
                .help(step.label)
            }
        }
        .fixedSize()
    }
}
