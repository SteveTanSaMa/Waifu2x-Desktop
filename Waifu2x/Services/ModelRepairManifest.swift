import Foundation

typealias ModelRepairManifestLoader = @Sendable (URL) async throws -> Data

/// Metadata can choose a compressed transport, never the expected model bytes.
/// The installed application's catalog remains the authority for every payload.
struct ModelRepairManifest: Codable, Sendable {
    struct Entry: Codable, Sendable {
        let path: String
        let bytes: Int64
        let sha256: String
        let archive: ModelCatalog.File
    }

    struct Repair: Sendable {
        let archive: ModelCatalog.File
        let files: [ModelCatalog.File]
    }

    static let maximumBytes = 512 * 1024
    let schemaVersion: Int
    let catalogVersion: String
    let files: [Entry]

    static func load(from url: URL) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (stream, response) = try await URLSession.shared.bytes(for: request)
        defer { stream.task.cancel() }
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.url?.scheme == "https", response.expectedContentLength <= Int64(maximumBytes) else {
            throw URLError(.badServerResponse)
        }
        var data = Data()
        for try await byte in stream {
            try Task.checkCancellation()
            guard data.count < maximumBytes else { throw invalid() }
            data.append(byte)
        }
        return data
    }

    static func decode(_ data: Data, catalog: ModelCatalog, verified: Set<String>) throws -> [Repair] {
        guard data.count <= maximumBytes else { throw invalid() }
        let manifest = try JSONDecoder().decode(Self.self, from: data)
        guard manifest.schemaVersion == 1, manifest.catalogVersion == catalog.catalogVersion,
              manifest.files.count == catalog.files.count,
              Set(manifest.files.map(\.path)).count == manifest.files.count else { throw invalid() }
        let expected = Dictionary(uniqueKeysWithValues: catalog.files.map { ($0.path, $0) })
        var archives: [String: ModelCatalog.File] = [:]
        for entry in manifest.files {
            guard let file = expected[entry.path], entry.bytes == file.bytes, entry.sha256 == file.sha256,
                  entry.archive.path == "Waifu2x-model-\(file.sha256).tar.xz",
                  entry.archive.bytes > 0, entry.archive.bytes <= file.bytes + 1024 * 1024,
                  ModelCatalog.isSHA256(entry.archive.sha256),
                  ModelCatalog.isOfficialRepairURL(entry.archive.sourceURL, filename: entry.archive.path) else {
                throw invalid()
            }
            if let existing = archives[file.sha256], existing != entry.archive { throw invalid() }
            archives[file.sha256] = entry.archive
        }
        var grouped: [String: [ModelCatalog.File]] = [:]
        var order: [String] = []
        for file in catalog.files where !verified.contains(file.path) {
            if grouped[file.sha256] == nil { order.append(file.sha256) }
            grouped[file.sha256, default: []].append(file)
        }
        return try order.map { digest in
            guard let archive = archives[digest], let files = grouped[digest] else { throw invalid() }
            return Repair(archive: archive, files: files)
        }
    }

    private static func invalid() -> ModelDownloadFailure {
        .message(L("模型压缩包内容与清单不符"))
    }
}
