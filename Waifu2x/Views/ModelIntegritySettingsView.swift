import AppKit
import SwiftUI

struct ModelIntegritySettingsView: View {
    @Bindable var checker: FileIntegrityChecker
    let modelsAreReady: Bool
    var maintenance: ModelMaintenance? = nil
    private var isChecking: Bool { checker.status == .checking }
    private var isRepairing: Bool { maintenance?.isRepairing == true }
    private var isActive: Bool { isChecking || isRepairing }
    private var progress: Double { isRepairing ? (maintenance?.progress ?? 0) : checker.progress }

    var body: some View {
        Form {
            Section {
                LabeledContent(L("模型状态"), value: modelStatus)
                    .accessibilityIdentifier("modelStatus")
                    .background(HeaderGeometryReader(identifier: "modelStatus"))
                LabeledContent(L("占用空间"), value: installedSize)
                    .accessibilityIdentifier("modelStorageSize")
                    .background(HeaderGeometryReader(identifier: "modelStorageSize"))
            }
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .center, spacing: 14) {
                        IntegrityScanView(progress: progress, isChecking: isActive,
                                          isValid: checker.status == .valid && !isRepairing,
                                          hasIssues: !isActive && (checker.status == .issues || checker.status == .failed))
                            .frame(width: 80, height: 80)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(title).font(.body.weight(.semibold))
                            Text(detail).font(.body).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if isActive {
                        VStack(alignment: .leading, spacing: 9) {
                            ProgressView(value: progress).tint(.accentColor)
                                .accessibilityLabel(isRepairing ? L("模型修复进度") : L("文件检查进度"))
                            HStack(alignment: .firstTextBaseline) {
                                Text(progressDescription)
                                Spacer()
                                Text(L("%d%%", Int((progress * 100).rounded(.down))))
                            }
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                    actionButtons
                    if !modelsAreReady && !isRepairing {
                        Text(L("模型准备完成后，即可检查文件完整性"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if !isActive, let maintenance, maintenance.hasModelIssues {
                        if maintenance.repairOutcome == .failed {
                            Text(L("暂时无法完成修复，请稍后重试"))
                                .foregroundStyle(.secondary)
                        } else if maintenance.repairOutcome == .cancelled {
                            Text(L("修复已取消，可稍后继续"))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            if !isActive && !checker.issues.isEmpty {
                Section {
                    if checker.issues.contains(where: { $0.kind == .application }) {
                        Text(L("应用文件异常，请从 GitHub 重新下载安装"))
                            .font(.body).foregroundStyle(.secondary)
                    }
                    if checker.issues.contains(where: { $0.kind == .model }) {
                        Text(L("修复缺失或受损的模型，即可继续处理图片"))
                            .font(.body).foregroundStyle(.secondary)
                    }
                } header: {
                    Text(L("检查结果")).font(.caption.weight(.medium))
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .font(.body)
        .controlSize(.regular)
        .accessibilityIdentifier("settingsIntegrity")
        .background(HeaderGeometryReader(identifier: "settingsIntegrity"))
        .task { await maintenance?.refreshStorage() }
    }

    private var actionButtons: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                primaryActions
                revealButton
            }
            .fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: 10) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { primaryActions }
                        .fixedSize(horizontal: true, vertical: false)
                    VStack(alignment: .leading, spacing: 10) { primaryActions }
                }
                revealButton
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var primaryActions: some View {
        if isRepairing, let maintenance {
            Button(L("取消修复"), action: maintenance.cancelRepair)
                .disabled(!maintenance.canCancelRepair)
        } else if isChecking {
            Button(L("取消检查"), action: checker.cancel)
        } else {
            Button(L("检查文件完整性"), action: checker.check)
                .disabled(!modelsAreReady || !checker.canStart || isRepairing)
                .accessibilityIdentifier("checkFileIntegrity")
                .background(HeaderGeometryReader(identifier: "checkFileIntegrity"))
            if let maintenance, maintenance.hasModelIssues {
                Button(L("修复模型"), action: maintenance.startRepair)
                    .disabled(!maintenance.canStartRepair)
                    .accessibilityIdentifier("repairModels")
                    .background(HeaderGeometryReader(identifier: "repairModels"))
            }
        }
    }

    private var revealButton: some View {
        Button(L("在 Finder 中查看"), action: revealModels)
            .disabled(!FileManager.default.fileExists(atPath: ModelPaths.current.root.deletingLastPathComponent().path))
            .accessibilityIdentifier("revealModels")
            .background(HeaderGeometryReader(identifier: "revealModels"))
    }

    private var modelStatus: String {
        let state = maintenance?.diagnosticStatus ?? {
            if isChecking { return .checking }
            switch checker.modelVerification {
            case .unknown: return .unknown
            case .valid: return .ready
            case .issues: return .issues
            }
        }()
        return switch state {
        case .unknown: L("尚未检查模型")
        case .checking: L("正在检查")
        case .ready: L("模型可正常使用")
        case .issues: L("部分模型需要修复")
        case .repairing: L("正在修复模型")
        }
    }

    private var installedSize: String {
        guard let maintenance else { return "—" }
        guard let bytes = maintenance.installedBytes else {
            return maintenance.isReadingStorage ? L("正在读取") : L("暂时无法读取")
        }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private var progressDescription: String {
        guard isRepairing, let maintenance else {
            return L("已检查 %d / %d 个文件", checker.checkedFiles, checker.totalFiles)
        }
        if maintenance.isVerifyingRepair { return L("正在核对修复结果") }
        guard let downloader = maintenance.downloader else { return L("正在准备修复") }
        if downloader.status == .downloading, let total = downloader.totalBytes {
            return ByteCountFormatter.string(fromByteCount: downloader.downloadedBytes, countStyle: .file)
                + " / " + ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
        }
        return downloader.status == .checking ? L("正在准备修复") : L("正在补全模型")
    }

    private var title: String {
        if isRepairing { return L("正在修复模型") }
        return switch checker.status {
        case .idle: L("为清晰，核对每一处细节")
        case .checking: L("正在核对文件")
        case .valid: L("所有文件完整")
        case .issues: L("发现需要关注的文件")
        case .cancelled: L("检查已取消")
        case .failed: L("检查未完成")
        }
    }

    private var detail: String {
        if isRepairing { return L("补回缺失的细节，让清晰继续") }
        return switch checker.status {
        case .valid: L("应用与模型均已通过验证")
        case .checking: L("沿着每一处细节，确认文件完整")
        case .issues: L("请查看下方的检查结果")
        default: L("检查模型文件是否缺失或受损，图片不会被修改")
        }
    }

    private func revealModels() {
        let root = ModelPaths.current.root
        let target = FileManager.default.fileExists(atPath: root.path) ? root : root.deletingLastPathComponent()
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }
}

private struct IntegrityScanView: View {
    let progress: Double
    let isChecking: Bool
    let isValid: Bool
    let hasIssues: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var fraction: Double { min(1, max(0, progress)) }
    private var color: Color { hasIssues ? .orange : Color(nsColor: ThemeColors.textAccent) }

    var body: some View {
        ZStack {
            Circle().fill(color.opacity(0.07))
            Circle().stroke(color.opacity(0.14), lineWidth: 1)
            Circle().trim(from: 0, to: fraction)
                .stroke(color.opacity(0.8), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if isValid || hasIssues {
                Image(systemName: isValid ? "checkmark.shield" : "exclamationmark.shield")
                    .font(.system(size: 34, weight: .light))
                    .transition(.opacity)
            } else {
                Image(systemName: "mountain.2")
                    .font(.system(size: 37, weight: .ultraLight))
                    .opacity(isChecking ? 0.65 : 0.9)
                    .symbolEffect(.pulse, isActive: isChecking && !reduceMotion)
                if isChecking && !reduceMotion {
                    Rectangle()
                        .fill(LinearGradient(colors: [.clear, color, .clear], startPoint: .leading, endPoint: .trailing))
                        .frame(width: 76, height: 1)
                        .shadow(color: color.opacity(0.6), radius: 5)
                        .offset(y: 34 - 68 * fraction)
                }
            }
        }
        .foregroundStyle(color)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: fraction)
        .animation(.easeInOut(duration: reduceMotion ? 0.12 : 0.3), value: isValid)
        .animation(.easeInOut(duration: reduceMotion ? 0.12 : 0.3), value: hasIssues)
        .accessibilityHidden(true)
    }
}
