import Foundation
import CryptoKit
import Darwin

/// Existing caches stay usable until a complete, verified model set can replace them.
struct ModelStore: Sendable {
    let catalog: ModelCatalog
    let paths: ModelPaths
    var resumeURL: URL { paths.downloadDirectory.appendingPathComponent("download.resume.json") }

    func pendingURL(for file: ModelCatalog.File) -> URL {
        let digest = SHA256.hash(data: Data(file.path.utf8)).map { String(format: "%02x", $0) }.joined()
        return paths.downloadDirectory.appendingPathComponent("\(digest).downloaded")
    }

    func validatedFiles(progress: @Sendable (Int, Int64, String) -> Void = { _, _, _ in }) throws -> Set<String> {
        try catalog.validate()
        var valid = Set<String>(), bytes: Int64 = 0
        for file in catalog.files {
            try Task.checkCancellation()
            if try matches(file) { valid.insert(file.path); bytes += file.bytes }
            progress(valid.count, bytes, file.path)
        }
        return valid
    }

    func install(_ file: ModelCatalog.File, from downloaded: URL) throws {
        try Task.checkCancellation()
        guard catalog.files.contains(file), try Self.isRegularFile(downloaded, bytes: file.bytes),
              try Self.sha256(of: downloaded) == file.sha256 else {
            throw ModelDownloadFailure.message(L("模型文件校验失败：%@", file.path))
        }
        let manager = FileManager.default
        let destination = paths.root.appendingPathComponent(file.path)
        try ensureDirectory(destination.deletingLastPathComponent())
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".model-\(UUID().uuidString).staging")
        defer { try? manager.removeItem(at: staging) }
        try manager.copyItem(at: downloaded, to: staging)
        try Task.checkCancellation()
        // Staging and destination share a filesystem; rename replaces a corrupt file atomically.
        guard rename(staging.path, destination.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    func archiveMatches(_ url: URL) throws -> Bool {
        guard let archive = catalog.archive, try Self.isRegularFile(url, bytes: archive.bytes) else { return false }
        return try Self.sha256(of: url) == archive.sha256
    }

    func installArchive(from downloaded: URL, progress: @Sendable (Int, String) -> Void = { _, _ in }) throws {
        try catalog.validate()
        guard try archiveMatches(downloaded) else {
            throw ModelDownloadFailure.message(L("模型压缩包校验失败，请重试"))
        }
        try Task.checkCancellation()
        guard (try? paths.root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
            throw ModelDownloadFailure.message(L("模型缓存目录无效，请移除符号链接后重试"))
        }
        let manager = FileManager.default
        let parent = paths.root.deletingLastPathComponent()
        try manager.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(".models-\(UUID().uuidString).staging", isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: staging) }
        try ModelArchiveExtractor.extract(downloaded, to: staging, catalog: catalog, progress: progress)
        try Task.checkCancellation()
        if manager.fileExists(atPath: paths.root.path) {
            // Both directories share a filesystem. Swap them without exposing a partial cache.
            guard renamex_np(staging.path, paths.root.path, UInt32(RENAME_SWAP)) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
        } else if rename(staging.path, paths.root.path) != 0 {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    private func matches(_ file: ModelCatalog.File) throws -> Bool {
        let url = paths.root.appendingPathComponent(file.path)
        guard safeParents(of: url), try Self.isRegularFile(url, bytes: file.bytes) else { return false }
        return try Self.sha256(of: url) == file.sha256
    }

    private func safeParents(of url: URL) -> Bool {
        var parent = url.deletingLastPathComponent()
        while parent.path.count >= paths.root.path.count {
            if (try? parent.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { return false }
            if parent.path == paths.root.path { return true }
            parent.deleteLastPathComponent()
        }
        return false
    }

    private func ensureDirectory(_ directory: URL) throws {
        guard safeParents(of: directory.appendingPathComponent("placeholder")) else {
            throw ModelDownloadFailure.message(L("模型缓存目录无效，请移除符号链接后重试"))
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard safeParents(of: directory.appendingPathComponent("placeholder")) else {
            throw ModelDownloadFailure.message(L("模型缓存目录无效，请移除符号链接后重试"))
        }
    }

    private static func isRegularFile(_ url: URL, bytes: Int64) throws -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) else { return false }
        return values.isRegularFile == true && values.isSymbolicLink != true && Int64(values.fileSize ?? -1) == bytes
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 4 * 1024 * 1024), !data.isEmpty {
            try Task.checkCancellation()
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
