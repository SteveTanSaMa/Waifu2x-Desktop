import AppKit

@MainActor
extension Workspace {
    func writeExport(_ result: ProcessingResult, to url: URL) throws {
        try Data(contentsOf: result.asset.url).write(to: url, options: .atomic)
    }
    func exportName(_ result: ProcessingResult) -> String {
        "\((result.asset.name as NSString).deletingPathExtension)_waifu2x_\(result.options.scale)x.png"
    }
    func export() {
        guard let result else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = exportName(result)
        panel.message = L("导出无损 PNG · %@ · sRGB", result.asset.dimensions)
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try self?.writeExport(result, to: url)
                Task { @MainActor in self?.notice = L("已导出 %@", url.lastPathComponent) }
            } catch { Task { @MainActor in self?.errorMessage = error.localizedDescription } }
        }
    }
    func exportAll() {
        guard !busy, !completedImages.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = L("导出结果")
        panel.message = L("将 %d 张结果保存为 PNG；同名文件会自动编号。", completedImages.count)
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            Task { @MainActor in
                let results = self.completedImages.compactMap(\.result)
                self.isExporting = true
                let scoped = url.startAccessingSecurityScopedResource()
                let report = await Task.detached(priority: .userInitiated) { BatchExporter.write(results, to: url) }.value
                if scoped { url.stopAccessingSecurityScopedResource() }
                self.isExporting = false
                self.notice = L("已导出 %d 张图片", report.urls.count)
                if !report.failures.isEmpty { self.errorMessage = report.failures.joined(separator: "\n") }
            }
        }
    }
}
