import Foundation

struct BatchExportReport {
    var urls: [URL] = []
    var failures: [String] = []
}

enum BatchExporter {
    /// Each file is created exclusively, including on case-insensitive volumes.
    /// Existing user files and earlier results with the same name are preserved.
    static func write(_ results: [ProcessingResult], to directory: URL) -> BatchExportReport {
        var report = BatchExportReport()
        for result in results {
            let stem = "\((result.asset.name as NSString).deletingPathExtension)_waifu2x_\(result.options.scale)x"
            do {
                let data = try Data(contentsOf: result.asset.url)
                var suffix = 1
                while true {
                    let name = suffix == 1 ? "\(stem).png" : "\(stem) (\(suffix)).png"
                    let url = directory.appendingPathComponent(name)
                    do {
                        try data.write(to: url, options: .withoutOverwriting)
                        report.urls.append(url)
                        break
                    } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError {
                        suffix += 1
                    }
                }
            } catch { report.failures.append(L("%@：%@", result.asset.name, error.localizedDescription)) }
        }
        return report
    }
}
