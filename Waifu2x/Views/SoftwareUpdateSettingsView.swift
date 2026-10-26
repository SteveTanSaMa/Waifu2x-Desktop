import AppKit
import SwiftUI

struct SoftwareUpdateSettingsView: View {
    @Environment(\.locale) private var locale
    @ObservedObject var preferences: AppPreferences
    @ObservedObject var checker: AppUpdateChecker
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let _ = locale
        Form {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 14) {
                        Image(systemName: PlatformSymbols.name(symbol, fallback: "exclamationmark.circle"))
                            .font(.system(size: 26, weight: .light))
                            .foregroundStyle(Color(nsColor: ThemeColors.textAccent))
                            .modifier(UpdateSymbolMotion(isActive: checker.status == .checking && !reduceMotion))
                            .frame(width: 40, height: 42)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(title).font(.body.weight(.semibold))
                            Text(L("当前版本 %@", AppInformation.version))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if checker.status == .failed, let message = checker.errorMessage {
                        Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    HStack(spacing: 12) {
                        Button(L("检查更新"), action: checker.check)
                            .disabled(checker.status == .checking || checker.downloader.isBusy)
                            .accessibilityIdentifier("checkForUpdates")
                            .background(HeaderGeometryReader(identifier: "checkForUpdates"))
                        if checker.status == .available, let release = checker.availableRelease {
                            if release.hasUpdateCatalog, !checker.downloader.isBusy,
                               checker.downloader.status == .idle || checker.downloader.targetVersion != release.version {
                                Button(L("下载更新"), action: checker.downloadAvailableUpdate)
                                    .buttonStyle(.borderedProminent)
                            }
                            Link(destination: release.url) {
                                Label(L("查看新版本"), systemImage: "arrow.up.right")
                            }
                            .buttonStyle(.bordered)
                        }
                        if checker.status == .checking { ProgressView().controlSize(.small) }
                    }
                    if let date = checker.lastChecked {
                        Text(L("上次检查：%@", date.formatted(.dateTime.year().month().day().hour().minute().locale(preferences.locale))))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
            if checker.downloader.status != .idle {
                Section {
                    AppUpdateDownloadView(downloader: checker.downloader, onRetry: checker.downloadAvailableUpdate)
                }
            }
            Section {
                Toggle(L("启动时检查更新"), isOn: $preferences.automaticallyCheckUpdates)
            } footer: {
                Text(L("每天检查一次正式版本，有更新时可前往 GitHub 下载"))
                    .font(.caption)
            }
            Section {
                Link(destination: AppInformation.releasesURL) {
                    Label(L("浏览所有版本"), systemImage: "arrow.up.right.square")
                }
            }
        }
        .formStyle(.grouped)
        .font(.body)
        .controlSize(.regular)
        .scrollContentBackground(.hidden)
        .accessibilityIdentifier("settingsUpdates")
        .background(HeaderGeometryReader(identifier: "settingsUpdates"))
    }

    private var symbol: String {
        switch checker.status {
        case .upToDate: "checkmark.circle"
        case .available: "arrow.down.circle"
        case .failed: "exclamationmark.arrow.triangle.2.circlepath"
        default: "arrow.triangle.2.circlepath"
        }
    }

    private var title: String {
        switch checker.status {
        case .idle: L("让清晰，常有新意")
        case .checking: L("正在检查更新")
        case .upToDate: L("已是最新版本")
        case .available: L("发现新版本 %@", checker.availableRelease?.version ?? "")
        case .failed: L("暂时无法检查更新")
        }
    }
}

private struct AppUpdateDownloadView: View {
    @Environment(\.locale) private var locale
    @ObservedObject var downloader: AppUpdateDownloader
    let onRetry: () -> Void

    var body: some View {
        let _ = locale
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.body.weight(.semibold))
            if let version = downloader.targetVersion {
                Text(L("版本 %@ · 构建 %@", version, downloader.targetBuild ?? "—"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if downloader.isBusy {
                if downloader.status == .downloading {
                    ProgressView(value: downloader.progress)
                    HStack {
                        Text(L("%@ / %@", bytes(downloader.downloadedBytes), bytes(downloader.totalBytes)))
                        Spacer()
                        Text(L("%d%%", Int((downloader.progress * 100).rounded(.down))))
                    }
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
                Button(L("取消下载"), action: downloader.cancel)
            }
            if downloader.fellBackToFull {
                Text(L("增量更新未能完成，已自动改用完整更新包"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = downloader.errorMessage {
                Text(error).font(.caption).foregroundStyle(.secondary)
            }
            if downloader.status == .cancelled || downloader.status == .failed {
                Button(L("重试下载"), action: onRetry).disabled(!downloader.canStart)
            }
            if let app = downloader.stagedApplication, downloader.status == .ready {
                Text(L("在 Finder 中将新版应用拖入「应用程序」文件夹，替换旧版后重新打开"))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(L("在 Finder 中查看更新")) {
                    NSWorkspace.shared.activateFileViewerSelecting([app])
                }
                .buttonStyle(.borderedProminent)
            } else {
                Text(L("优先下载变化的应用文件，验证完成后再由你替换安装"))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }

    private var title: String {
        switch downloader.status {
        case .preparing: L("正在比对已安装的应用")
        case .downloading: downloader.usesDelta ? L("正在下载增量更新") : L("正在下载完整更新包")
        case .verifying: L("正在验证并准备新版应用")
        case .ready: L("新版应用已准备好")
        case .cancelled: L("更新下载已取消")
        case .failed: L("更新准备未完成")
        case .idle: L("下载更新")
        }
    }

    private func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}
