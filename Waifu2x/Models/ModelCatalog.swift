import Foundation
import CryptoKit

enum ModelPreparationStatus: Equatable, Sendable {
    case checking, downloading, paused, verifying, failed, ready
}

struct ModelCatalog: Codable, Sendable {
    struct File: Codable, Hashable, Sendable {
        let path: String
        let bytes: Int64
        let sha256: String
        let sourceURL: URL
    }
    let schemaVersion: Int
    let catalogVersion: String
    let files: [File]
    let archive: File?
    let repairManifestURL: URL?

    init(schemaVersion: Int, catalogVersion: String, files: [File], archive: File? = nil,
         repairManifestURL: URL? = nil) {
        self.schemaVersion = schemaVersion
        self.catalogVersion = catalogVersion
        self.files = files
        self.archive = archive
        self.repairManifestURL = repairManifestURL
    }

    var totalModelBytes: Int64 { files.reduce(0) { $0 + $1.bytes } }

    /// Changes to a source, digest, size or destination invalidate opaque resume data.
    var identity: String {
        let entries = files + (archive.map { [$0] } ?? [])
        let fields = [String(schemaVersion), catalogVersion, repairManifestURL?.absoluteString ?? ""] + entries.flatMap {
            [$0.path, String($0.bytes), $0.sha256, $0.sourceURL.absoluteString]
        }
        return SHA256.hash(data: Data(fields.joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func load(bundle: Bundle = .main) throws -> ModelCatalog {
        guard let url = bundle.url(forResource: "ModelCatalog", withExtension: "json") else {
            throw ModelDownloadFailure.message(L("应用缺少模型清单，请重新安装完整应用"))
        }
        do { return try JSONDecoder().decode(ModelCatalog.self, from: Data(contentsOf: url)) }
        catch { throw ModelDownloadFailure.message(L("无法读取模型清单：%@", error.localizedDescription)) }
    }

    func validate() throws {
        guard (schemaVersion == 2 || schemaVersion == 3), catalogVersion == ModelPaths.catalogVersion,
              !files.isEmpty, files.count <= 512,
              Set(files.map(\.path)).count == files.count else {
            throw ModelDownloadFailure.message(L("模型清单无效，请重新安装完整应用"))
        }
        if schemaVersion == 3 && archive == nil {
            throw ModelDownloadFailure.message(L("模型清单无效，请重新安装完整应用"))
        }
        if let repairManifestURL {
            guard archive != nil,
                  Self.isOfficialRepairURL(repairManifestURL, filename: "Waifu2x-\(catalogVersion)-repair.json", allowsLatest: true) else {
                throw ModelDownloadFailure.message(L("模型清单无效，请重新安装完整应用"))
            }
        }
        if let archive {
            guard archive.path.hasSuffix(".tar.xz"), !archive.path.contains("/"),
                  !files.contains(where: { $0.path == archive.path }) else {
                throw ModelDownloadFailure.message(L("模型清单无效，请重新安装完整应用"))
            }
        }
        for file in files + (archive.map { [$0] } ?? []) {
            try Self.validateRelativePath(file.path)
            guard file.bytes > 0, file.bytes <= 2_000_000_000, Self.isSHA256(file.sha256) else {
                throw ModelDownloadFailure.message(L("模型清单无效，请重新安装完整应用"))
            }
            guard file.sourceURL.scheme?.lowercased() == "https", file.sourceURL.host?.isEmpty == false,
                  file.sourceURL.user == nil, file.sourceURL.password == nil, file.sourceURL.fragment == nil else {
                throw ModelDownloadFailure.message(L("模型下载地址必须是有效的 HTTPS 地址"))
            }
        }
    }

    static func validateRelativePath(_ path: String) throws {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains(":"),
              !path.utf8.contains(0), !path.contains("\n"), !path.contains("\r"),
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw ModelDownloadFailure.message(L("模型文件路径无效"))
        }
    }
    static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    /// Repair assets stay in the official repository. A later release may host
    /// identical payloads, but every raw file still has to match this catalog.
    static func isOfficialRepairURL(_ url: URL, filename: String, allowsLatest: Bool = false) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "https", components.host == "github.com", components.port == nil,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.percentEncodedPath == components.path else { return false }
        let prefix = "/SteveTanSaMa/Waifu2x-Desktop/releases/"
        if allowsLatest && components.path == prefix + "latest/download/" + filename { return true }
        guard components.path.hasPrefix(prefix + "download/") else { return false }
        let suffix = String(components.path.dropFirst((prefix + "download/").count))
        let parts = suffix.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 2 && String(parts[1]) == filename
            && String(parts[0]).range(of: #"^v[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil
    }
}

enum ModelDownloadFailure: LocalizedError, Sendable {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { value } else { nil } }
}
