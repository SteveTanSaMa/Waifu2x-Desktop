import Darwin
import Foundation

/// Measures only installed catalog entries, without following links out of the cache.
enum ModelStorageFootprint {
    static func bytes(catalog: ModelCatalog, paths: ModelPaths) throws -> Int64 {
        try catalog.validate()
        let root = open(paths.root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else {
            if errno == ENOENT || errno == ENOTDIR || errno == ELOOP { return 0 }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { close(root) }
        var total: Int64 = 0
        for file in catalog.files {
            try Task.checkCancellation()
            let components = file.path.split(separator: "/").map(String.init)
            var directory = dup(root)
            guard directory >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            defer { close(directory) }
            var safe = true
            for component in components.dropLast() {
                let child = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if child < 0 {
                    if errno != ENOENT && errno != ENOTDIR && errno != ELOOP {
                        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                    }
                    safe = false
                    break
                }
                close(directory)
                directory = child
            }
            guard safe, let name = components.last else { continue }
            var information = stat()
            if fstatat(directory, name, &information, AT_SYMLINK_NOFOLLOW) != 0 {
                if errno == ENOENT || errno == ENOTDIR { continue }
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            guard information.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), information.st_size >= 0 else { continue }
            let addition = total.addingReportingOverflow(Int64(information.st_size))
            total = addition.overflow ? Int64.max : addition.partialValue
        }
        return total
    }
}
