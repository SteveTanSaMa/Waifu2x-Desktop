import Foundation
import CryptoKit
import Darwin

/// Reads only the catalog's regular files. The archive never chooses where to write.
enum ModelArchiveExtractor {
    static func extract(_ source: URL, to root: URL, catalog: ModelCatalog,
                        progress: @Sendable (Int, String) -> Void) throws {
        guard let reader = archive_read_new() else { throw unreadable() }
        defer { archive_read_free(reader) }
        guard archive_read_support_filter_xz(reader) == 0,
              archive_read_support_format_tar(reader) == 0,
              archive_read_open_filename(reader, source.path, 1024 * 1024) == 0 else {
            throw unreadable()
        }
        let expected = Dictionary(uniqueKeysWithValues: catalog.files.map { ($0.path, $0) })
        let directories = Set(catalog.files.flatMap { file -> [String] in
            let parts = file.path.split(separator: "/")
            return (1..<parts.count).map { parts.prefix($0).joined(separator: "/") }
        })
        var seen = Set<String>(), installed = Set<String>()
        var entry: OpaquePointer?
        while true {
            try Task.checkCancellation()
            let result = archive_read_next_header(reader, &entry)
            if result == 1 { break } // ARCHIVE_EOF
            guard result == 0, let entry, let raw = archive_entry_pathname(entry),
                  var name = String(validatingCString: raw),
                  archive_entry_symlink(entry) == nil, archive_entry_hardlink(entry) == nil else {
                throw unreadable()
            }
            if name.hasSuffix("/") { name.removeLast() }
            try ModelCatalog.validateRelativePath(name)
            guard seen.insert(name).inserted else { throw unexpected() }
            let kind = archive_entry_filetype(entry)
            if kind == S_IFDIR {
                guard directories.contains(name) else { throw unexpected() }
                continue
            }
            guard kind == S_IFREG, let file = expected[name], archive_entry_size(entry) == file.bytes else {
                throw unexpected()
            }
            let destination = root.appendingPathComponent(file.path)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw unreadable()
            }
            let output = try FileHandle(forWritingTo: destination)
            defer { try? output.close() }
            var hash = SHA256(), bytes: Int64 = 0
            var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
            while true {
                try Task.checkCancellation()
                let count = buffer.withUnsafeMutableBytes { archive_read_data(reader, $0.baseAddress, $0.count) }
                guard count >= 0 else { throw unreadable() }
                if count == 0 { break }
                bytes += Int64(count)
                guard bytes <= file.bytes else { throw unexpected() }
                let chunk = Data(buffer.prefix(count))
                hash.update(data: chunk)
                try output.write(contentsOf: chunk)
            }
            let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
            guard bytes == file.bytes, digest == file.sha256 else { throw unexpected() }
            installed.insert(name)
            progress(installed.count, name)
        }
        guard installed == Set(expected.keys) else { throw unexpected() }
    }

    private static func unreadable() -> ModelDownloadFailure {
        .message(L("模型压缩包无法解压，请重试"))
    }
    private static func unexpected() -> ModelDownloadFailure {
        .message(L("模型压缩包内容与清单不符"))
    }
}
