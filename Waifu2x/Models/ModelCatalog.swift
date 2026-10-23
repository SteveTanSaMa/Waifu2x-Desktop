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

    var totalModelBytes: Int64 { files.reduce(0) { $0 + $1.bytes } }

    /// Changes to a source, digest, size or destination invalidate opaque resume data.
    var identity: String {
        let fields = [String(schemaVersion), catalogVersion] + files.flatMap {
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
        guard schemaVersion == 2, catalogVersion == ModelPaths.catalogVersion,
              !files.isEmpty, files.count <= 512,
              Set(files.map(\.path)).count == files.count else {
            throw ModelDownloadFailure.message(L("模型清单无效，请重新安装完整应用"))
        }
        for file in files {
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
    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

enum ModelDownloadFailure: LocalizedError, Sendable {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { value } else { nil } }
}
