import Foundation
import CryptoKit
import Darwin

extension ModelStore {
    struct IntegrityFinding: Equatable, Sendable {
        enum Reason: Equatable, Sendable {
            case missing, symbolicLink, notRegularFile, sizeMismatch, hashMismatch, unreadable

            var localizedDescription: String {
                switch self {
                case .missing: L("模型文件缺失")
                case .symbolicLink: L("模型路径包含符号链接")
                case .notRegularFile: L("模型路径不是普通文件")
                case .sizeMismatch: L("模型文件大小不匹配")
                case .hashMismatch: L("模型文件 SHA-256 校验不匹配")
                case .unreadable: L("无法读取模型文件")
                }
            }
        }
        let path: String
        let reason: Reason
    }

    /// A read-only scan. Every completed file advances progress, including damaged files.
    /// No resume data, downloaded archive, or cache entry is created or changed.
    func integrityReport(progress: @Sendable (Int, String, IntegrityFinding?) -> Void = { _, _, _ in }) throws -> [IntegrityFinding] {
        try catalog.validate()
        var findings = [IntegrityFinding]()
        for (index, file) in catalog.files.enumerated() {
            try Task.checkCancellation()
            progress(index, file.path, nil)
            let finding = try integrityFinding(for: file)
            if let finding { findings.append(finding) }
            progress(index + 1, file.path, finding)
        }
        return findings
    }

    private func integrityFinding(for file: ModelCatalog.File) throws -> IntegrityFinding? {
        func finding(_ reason: IntegrityFinding.Reason) -> IntegrityFinding { .init(path: file.path, reason: reason) }
        let root = paths.root.standardizedFileURL
        let url = root.appendingPathComponent(file.path)
        var parent = url.deletingLastPathComponent()
        while parent.path.count >= root.path.count {
            var information = stat()
            guard lstat(parent.path, &information) == 0 else {
                return finding(errno == ENOENT ? .missing : .unreadable)
            }
            let type = information.st_mode & mode_t(S_IFMT)
            if type == mode_t(S_IFLNK) { return finding(.symbolicLink) }
            guard type == mode_t(S_IFDIR) else { return finding(.notRegularFile) }
            if parent.path == root.path { break }
            parent.deleteLastPathComponent()
        }

        var information = stat()
        guard lstat(url.path, &information) == 0 else { return finding(errno == ENOENT ? .missing : .unreadable) }
        let type = information.st_mode & mode_t(S_IFMT)
        if type == mode_t(S_IFLNK) { return finding(.symbolicLink) }
        guard type == mode_t(S_IFREG) else { return finding(.notRegularFile) }
        guard information.st_size == file.bytes else { return finding(.sizeMismatch) }

        // Refuse a final path swapped to a symlink between lstat and open; nonblocking
        // open also prevents a substituted FIFO from blocking the utility worker.
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { return finding(errno == ELOOP ? .symbolicLink : .unreadable) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        guard fstat(descriptor, &information) == 0 else { return finding(.unreadable) }
        guard information.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { return finding(.notRegularFile) }
        guard information.st_size == file.bytes else { return finding(.sizeMismatch) }
        do {
            var hash = SHA256()
            while let data = try handle.read(upToCount: 4 * 1024 * 1024), !data.isEmpty {
                try Task.checkCancellation()
                hash.update(data: data)
            }
            try Task.checkCancellation()
            let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
            return digest == file.sha256 ? nil : finding(.hashMismatch)
        } catch is CancellationError { throw CancellationError() }
        catch { return finding(.unreadable) }
    }
}
