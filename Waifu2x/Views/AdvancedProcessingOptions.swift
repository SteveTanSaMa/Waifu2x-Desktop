import SwiftUI

struct AdvancedProcessingOptions: View {
    @Environment(\.locale) private var locale
    @ObservedObject var workspace: Workspace
    var body: some View {
        let _ = locale
        VStack(spacing: 22) {
            AdvancedOptionRow(L("增强模型"), symbol: "cube", detail: workspace.options.modelHint) {
                TrailingOptionPicker(title: L("增强模型"), selection: $workspace.options.model,
                                     choices: WaifuModel.allCases.map { ($0, $0.title) })
                    .help(L("依照画面类型选择模型，让插画与照片各得其所"))
            }
            AdvancedOptionRow(L("透明通道"), symbol: "square.on.square", detail: workspace.options.alphaHint) {
                TrailingOptionPicker(title: L("透明通道"), selection: $workspace.options.alpha,
                                     choices: AlphaMode.allCases.map { ($0, $0.title) })
                    .help(L("保留透明度时，Metal 使用插值放大透明通道，其他后端由模型处理透明通道；选择白色背景则将透明区域铺成白色"))
            }
            AdvancedOptionRow(L("推理增强"), symbol: "square.stack.3d.up", detail: workspace.options.tta == 0 ? L("以单一方向处理，减少额外等待") : L("多方向处理后融合，需要更长时间")) {
                TrailingOptionPicker(title: L("推理增强（TTA）"), selection: $workspace.options.tta,
                                     choices: [(0, L("关闭")), (2, L("%d 次", 2)), (4, L("%d 次", 4))])
                    .help(L("TTA 从多个方向处理同一画面，再取均值融合；次数越多，通常越耗时"))
            }
            AdvancedOptionRow(L("推理后端"), symbol: "cpu", detail: workspace.options.backendHint) {
                TrailingOptionPicker(title: L("推理后端"), selection: $workspace.options.backend,
                                     choices: InferenceBackend.allCases.map { ($0, $0.title) })
            }
            AdvancedOptionRow(L("分块大小"), symbol: "square.grid.2x2", detail: workspace.options.tileHint) {
                TrailingOptionPicker(title: L("分块大小"), selection: $workspace.options.tileSize,
                                     choices: [64, 256, 400, 640].map { ($0, L("%d px", $0)) })
            }
            AdvancedOptionRow(L("多线程"), symbol: "cpu.fill", detail: workspace.options.multithreading ? L("让最多 %d 个 CPU 线程一同参与处理", workspace.options.inferenceThreads) : L("以单个 CPU 线程处理，为其他任务留些余量")) {
                Toggle(L("多线程推理"), isOn: $workspace.options.multithreading)
                    .toggleStyle(.switch).controlSize(.mini)
                    .help(L("设置 CPU 的工作线程数量；GPU 的并行计算由所选后端管理"))
            }
            AdvancedOptionRow(L("分块顺序"), symbol: "shuffle", detail: workspace.options.shuffle ? L("打散处理顺序，完成后拼回原位") : L("按行依次处理各个分块")) {
                Toggle(L("随机排列分块顺序"), isOn: $workspace.options.shuffle)
                    .toggleStyle(.switch).controlSize(.mini)
            }
        }
    }
}

private struct AdvancedOptionRow<Control: View>: View {
    @Environment(\.locale) private var locale
    let title: String
    let symbol: String
    let detail: String
    @ViewBuilder let control: () -> Control

    init(_ title: String, symbol: String, detail: String, @ViewBuilder control: @escaping () -> Control) {
        self.title = title
        self.symbol = symbol
        self.detail = detail
        self.control = control
    }

    var body: some View {
        let _ = locale
        VStack(alignment: .leading, spacing: 9) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    heading
                    Spacer(minLength: 0)
                    optionControl
                }
                VStack(alignment: .leading, spacing: 7) {
                    heading
                    HStack {
                        Spacer(minLength: 0)
                        optionControl
                    }
                }
            }
            Text(detail).font(.system(size: 12)).foregroundStyle(OptionsPalette.supportingText)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var heading: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 14)).foregroundStyle(Color.accentColor).frame(width: 18)
            Text(title).font(.system(size: 14, weight: .semibold))
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var optionControl: some View {
        control().labelsHidden().controlSize(.regular)
            .font(.system(size: 12))
            .fixedSize(horizontal: true, vertical: false)
    }
}
