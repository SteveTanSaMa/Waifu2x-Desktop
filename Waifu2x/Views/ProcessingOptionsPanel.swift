import SwiftUI

struct ProcessingOptionsPanel: View {
    @Bindable var workspace: Workspace
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(L("图像增强")).font(.system(size: 18, weight: .semibold))
                    Text(workspace.images.count > 1
                         ? (workspace.isMultiSelecting ? L("为所选 %d 张图片调整", workspace.processingImages.count) : L("为当前图片调整"))
                         : L("在清晰与质感之间，找到恰好的分寸"))
                        .font(.system(size: 12)).foregroundStyle(OptionsPalette.supportingText)
                }
                Spacer(minLength: 0)
            }.padding(24)
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    enhancementSection(L("放大倍率"), symbol: "arrow.up.left.and.arrow.down.right") {
                        HStack(spacing: 8) {
                            ForEach([1, 2, 4], id: \.self) { scale in
                                ScaleChoice(scale: scale, selected: workspace.options.scale == scale) { workspace.options.scale = scale }
                            }
                        }
                        HStack(spacing: 6) {
                            Text(workspace.options.upscaleEnabled ? L("输出尺寸") : L("保留原尺寸"))
                            if let input = workspace.input {
                                Text(L("%d × %d px", input.image.width * workspace.options.scale, input.image.height * workspace.options.scale)).monospacedDigit()
                            }
                            Spacer(minLength: 8)
                            if workspace.options.repeatsScale2 {
                                Text(L("两步放大"))
                                    .fixedSize()
                                    .help(L("分两次 2× 放大至 4×，降噪只在第一步进行"))
                            }
                        }.font(.system(size: 12)).foregroundStyle(OptionsPalette.supportingText)
                    }
                    enhancementSection(L("降噪"), symbol: "sparkle") {
                        HStack(spacing: 5) {
                            ForEach(-1...3, id: \.self) { level in
                                NoiseChoice(level: level, selected: workspace.options.noise == level) { workspace.options.noise = level }
                            }
                        }
                        Text(workspace.options.noiseHint)
                            .font(.system(size: 12)).foregroundStyle(OptionsPalette.supportingText)
                    }
                    if let message = workspace.options.validationMessage {
                        Label(message, systemImage: "info.circle").font(.system(size: 14)).foregroundStyle(.orange)
                    }
                    AdvancedProcessingOptions(workspace: workspace)
                }.padding(.horizontal, 24).padding(.bottom, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.bottom, CanvasPanelLayout.bottomClearance)
        }
    }
    private func enhancementSection<Content: View>(_ title: String, symbol: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 14)).frame(width: 18).foregroundStyle(Color.accentColor)
                Text(title).font(.system(size: 14, weight: .semibold))
                Spacer()
            }
            content()
        }
    }
}

private struct ScaleChoice: View {
    let scale: Int
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Text(L("%d×", scale)).font(.system(size: 25, weight: .medium, design: .rounded))
                Text(scale == 1 ? L("原尺寸") : (scale == 2 ? L("两倍") : L("四倍")))
                    .font(.system(size: 14)).foregroundStyle(OptionsPalette.supportingText)
                    .lineLimit(2).minimumScaleFactor(0.85).multilineTextAlignment(.center)
            }
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(selected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.045), in: .rect(cornerRadius: 12))
            .overlay(alignment: .topTrailing) {
                if selected { Image(systemName: "checkmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(Color.accentColor).padding(8) }
            }
            .foregroundStyle(.primary)
            .contentShape(.rect(cornerRadius: 12))
        }.buttonStyle(ParameterButtonStyle()).accessibilityLabel(scale == 1 ? L("原尺寸，不放大") : L("放大 %d 倍", scale))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct NoiseChoice: View {
    let level: Int
    let selected: Bool
    let action: () -> Void
    private var title: String { level == -1 ? L("关闭") : [L("轻度"), L("适中"), L("较强"), L("强力")][level] }
    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(0..<4, id: \.self) { index in
                        Capsule().fill(index <= level ? (selected ? Color.accentColor : Color.primary.opacity(0.5)) : Color.primary.opacity(0.14))
                            .frame(width: 4, height: CGFloat(7 + index * 4))
                    }
                }.frame(height: 20)
                Text(title).font(.system(size: 14, weight: selected ? .semibold : .regular))
                    .lineLimit(2).minimumScaleFactor(0.85).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 12)
            .background(selected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.045), in: .rect(cornerRadius: 10))
            .overlay(alignment: .topTrailing) {
                if selected { Image(systemName: "checkmark").font(.system(size: 8, weight: .semibold)).foregroundStyle(Color.accentColor).padding(5) }
            }
            .foregroundStyle(.primary)
            .contentShape(.rect(cornerRadius: 10))
        }.buttonStyle(ParameterButtonStyle()).accessibilityLabel(level == -1 ? L("不降噪") : L("降噪%@，级别 %d", title, level))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct ParameterButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.65 : 1)
    }
}

enum OptionsPalette {
    // The standard secondary label falls below 4.5:1 on the light window background.
    // Deriving this from the semantic primary label keeps both appearances readable.
    static let supportingText = Color(nsColor: .labelColor).opacity(0.72)
}
