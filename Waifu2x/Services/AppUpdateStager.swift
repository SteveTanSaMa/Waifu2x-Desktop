import CryptoKit
import Darwin
import Foundation

/// Builds a candidate in a private staging folder. No update operation writes
/// into the running app, and archive entries never choose their own output path.
enum AppUpdateStager {
    static func matches(_ root: URL, files: [AppUpdateCatalog.File]) throws -> Bool {
        try Task.checkCancellation()
        let manager = FileManager.default
        guard let values = try? root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true, values.isSymbolicLink != true else { return false }
        let canonical = root.resolvingSymlinksInPath().standardizedFileURL
        guard let enumerator = manager.enumerator(at: canonical,
                                                  includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey],
                                                  errorHandler: { _, _ in false }) else { return false }
        let expected = Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0) })
        var seen = Set<String>()
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { return false }
            if values.isDirectory == true { continue }
            let normalizedPath = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard normalizedPath.hasPrefix(canonical.path + "/") else { return false }
            let path = String(normalizedPath.dropFirst(canonical.path.count + 1))
            guard values.isRegularFile == true, let file = expected[path],
                  try matchesFile(url, file: file) else { return false }
            seen.insert(path)
        }
        return seen == Set(expected.keys)
    }

    static func matchesFile(_ url: URL, file: AppUpdateCatalog.File) throws -> Bool {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              Int64(values.fileSize ?? -1) == file.bytes,
              let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber,
              mode.intValue & 0o777 == file.mode else { return false }
        return try ModelStore.sha256(of: url) == file.sha256
    }

    static func applyDelta(_ archive: URL, installed: URL, destination: URL,
                           catalog: AppUpdateCatalog, delta: AppUpdateCatalog.Delta) throws {
        guard try matches(installed, files: delta.baseFiles) else { throw AppUpdateFailure.invalidApplication }
        try Task.checkCancellation()
        try FileManager.default.copyItem(at: installed, to: destination)
        // Validate the copy too, before writing into any of its existing paths.
        guard try matches(destination, files: delta.baseFiles) else { throw AppUpdateFailure.invalidApplication }
        for path in delta.removedFiles {
            try Task.checkCancellation()
            try FileManager.default.removeItem(at: destination.appendingPathComponent(path))
        }
        // Remove obsolete empty directories so file↔directory changes remain safe.
        try removeEmptyDirectories(in: destination)
        let changed = Set(delta.changedFiles)
        let files = catalog.files.filter { changed.contains($0.path) }
        for file in files {
            let url = destination.appendingPathComponent(file.path)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
        try extract(archive, to: destination, files: files, wrapper: nil)
        guard try matches(destination, files: catalog.files) else { throw AppUpdateFailure.invalidApplication }
    }

    static func extractFull(_ archive: URL, destination: URL, catalog: AppUpdateCatalog) throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        try extract(archive, to: destination, files: catalog.files, wrapper: catalog.appBundleName)
        guard try matches(destination, files: catalog.files) else { throw AppUpdateFailure.invalidApplication }
    }

    static func validateApplication(_ root: URL, catalog: AppUpdateCatalog,
                                    signatureChecker: ApplicationSignatureChecking) throws {
        try Task.checkCancellation()
        let plistURL = root.appendingPathComponent("Contents/Info.plist")
        let data = try Data(contentsOf: plistURL)
        guard let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == "studio.stevetan.Waifu2x",
              let version = info["CFBundleShortVersionString"] as? String,
              ReleaseVersion(version) == ReleaseVersion(catalog.version),
              info["CFBundleVersion"] as? String == catalog.build,
              let executable = info["CFBundleExecutable"] as? String,
              !executable.contains("/"), !executable.isEmpty,
              catalog.files.contains(where: { $0.path == "Contents/MacOS/\(executable)" && $0.mode & 0o111 != 0 }),
              try signatureChecker(root) else { throw AppUpdateFailure.invalidApplication }
    }

    static func verifySignature(_ root: URL) throws -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--verify", "--deep", "--strict", root.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try Task.checkCancellation()
        try process.run()
        do {
            while process.isRunning {
                try Task.checkCancellation()
                Thread.sleep(forTimeInterval: 0.02)
            }
            try Task.checkCancellation()
            return process.terminationReason == .exit && process.terminationStatus == 0
        } catch {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            throw error
        }
    }

    private static func extract(_ archive: URL, to root: URL, files: [AppUpdateCatalog.File], wrapper: String?) throws {
        guard let reader = archive_read_new() else { throw AppUpdateFailure.invalidArchive }
        defer { archive_read_free(reader) }
        let configured: Bool
        if wrapper == nil {
            configured = archive_read_support_filter_xz(reader) == 0 && archive_read_support_format_tar(reader) == 0
        } else {
            configured = archive_read_support_format_zip(reader) == 0
        }
        guard configured, archive_read_open_filename(reader, archive.path, 1024 * 1024) == 0 else {
            throw AppUpdateFailure.invalidArchive
        }
        let expected = Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0) })
        let directories = Set(files.flatMap { file -> [String] in
            let parts = file.path.split(separator: "/")
            return (1..<parts.count).map { parts.prefix($0).joined(separator: "/") }
        })
        var seen = Set<String>(), written = Set<String>()
        var entry: OpaquePointer?
        while true {
            try Task.checkCancellation()
            let result = archive_read_next_header(reader, &entry)
            if result == 1 { break }
            guard result == 0, let entry, let raw = archive_entry_pathname(entry),
                  var path = String(validatingCString: raw),
                  archive_entry_symlink(entry) == nil, archive_entry_hardlink(entry) == nil else {
                throw AppUpdateFailure.invalidArchive
            }
            if path.hasSuffix("/") { path.removeLast() }
            try AppUpdateCatalog.validatePath(path)
            guard seen.insert(path).inserted else { throw AppUpdateFailure.invalidArchive }
            let kind = archive_entry_filetype(entry)
            guard kind == S_IFDIR || kind == S_IFREG else { throw AppUpdateFailure.invalidArchive }
            if let wrapper {
                // ditto's resource-fork sidecars are never written or executed.
                if path == "__MACOSX" || path.hasPrefix("__MACOSX/") { continue }
                if path == wrapper, kind == S_IFDIR { continue }
                guard path.hasPrefix(wrapper + "/") else { throw AppUpdateFailure.invalidArchive }
                path = String(path.dropFirst(wrapper.count + 1))
            }
            if kind == S_IFDIR {
                guard directories.contains(path) else { throw AppUpdateFailure.invalidArchive }
                continue
            }
            guard let file = expected[path], archive_entry_size(entry) == file.bytes else {
                throw AppUpdateFailure.invalidArchive
            }
            let destination = root.appendingPathComponent(file.path)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard !FileManager.default.fileExists(atPath: destination.path),
                  FileManager.default.createFile(atPath: destination.path, contents: nil,
                                                 attributes: [.posixPermissions: 0o600]) else { throw AppUpdateFailure.invalidArchive }
            let output = try FileHandle(forWritingTo: destination)
            defer { try? output.close() }
            var bytes: Int64 = 0, hash = SHA256()
            var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
            while true {
                try Task.checkCancellation()
                let count = buffer.withUnsafeMutableBytes { archive_read_data(reader, $0.baseAddress, $0.count) }
                guard count >= 0 else { throw AppUpdateFailure.invalidArchive }
                if count == 0 { break }
                bytes += Int64(count)
                guard bytes <= file.bytes else { throw AppUpdateFailure.invalidArchive }
                let chunk = Data(buffer.prefix(count))
                hash.update(data: chunk)
                try output.write(contentsOf: chunk)
            }
            guard bytes == file.bytes,
                  hash.finalize().map({ String(format: "%02x", $0) }).joined() == file.sha256 else {
                throw AppUpdateFailure.invalidArchive
            }
            try FileManager.default.setAttributes([.posixPermissions: file.mode], ofItemAtPath: destination.path)
            written.insert(path)
        }
        guard written == Set(expected.keys) else { throw AppUpdateFailure.invalidArchive }
    }

    private static func removeEmptyDirectories(in root: URL) throws {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else {
            throw AppUpdateFailure.invalidApplication
        }
        let directories = enumerator.compactMap { $0 as? URL }.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }.sorted { $0.path.count > $1.path.count }
        for directory in directories {
            try Task.checkCancellation()
            if try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty {
                try FileManager.default.removeItem(at: directory)
            }
        }
    }
}
