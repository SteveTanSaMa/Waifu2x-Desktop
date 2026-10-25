import Foundation

/// Release metadata binds every downloaded byte and every staged app file to a
/// single public release. Asset names are resolved against that release only.
struct AppUpdateCatalog: Codable, Sendable {
    struct Asset: Codable, Equatable, Sendable {
        let path: String
        let bytes: Int64
        let sha256: String
    }
    struct File: Codable, Equatable, Sendable {
        let path: String
        let bytes: Int64
        let sha256: String
        let mode: Int
    }
    struct Delta: Codable, Sendable {
        let fromVersion: String
        let fromBuild: String
        let baseFiles: [File]
        let archive: Asset
        let changedFiles: [String]
        let removedFiles: [String]
    }

    static let filename = "Waifu2x-update.json"
    let schemaVersion: Int
    let version: String
    let build: String
    let appBundleName: String
    let full: Asset
    let files: [File]
    let deltas: [Delta]

    func validate(for release: AppUpdateChecker.AvailableRelease) throws {
        guard schemaVersion == 1, ReleaseVersion(version) == ReleaseVersion(release.version),
              ReleaseVersion(version)?.prerelease.isEmpty == true,
              !build.isEmpty, build.utf8.count <= 128, appBundleName == "Waifu2x.app",
              full.path.hasSuffix(".zip"), deltas.count <= 32 else { throw AppUpdateFailure.invalidCatalog }
        try Self.validateAsset(full)
        try Self.validateFiles(files)
        let target = Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0) })
        for delta in deltas {
            guard let old = ReleaseVersion(delta.fromVersion), let new = ReleaseVersion(version), old < new,
                  !delta.fromBuild.isEmpty, delta.fromBuild.utf8.count <= 128,
                  delta.archive.path.hasSuffix(".tar.xz"), delta.archive.bytes < full.bytes else {
                throw AppUpdateFailure.invalidCatalog
            }
            try Self.validateAsset(delta.archive)
            try Self.validateFiles(delta.baseFiles)
            let base = Dictionary(uniqueKeysWithValues: delta.baseFiles.map { ($0.path, $0) })
            let changed = Set(delta.changedFiles), removed = Set(delta.removedFiles)
            guard changed.count == delta.changedFiles.count, removed.count == delta.removedFiles.count,
                  !changed.isEmpty || !removed.isEmpty,
                  changed.isDisjoint(with: removed),
                  changed == Set(files.filter { base[$0.path] != $0 }.map(\.path)),
                  removed == Set(base.keys).subtracting(target.keys) else { throw AppUpdateFailure.invalidCatalog }
        }
    }

    static func assetURL(_ asset: String, release: AppUpdateChecker.AvailableRelease) throws -> URL {
        try validatePath(asset)
        guard !asset.contains("/"), let page = URLComponents(url: release.url, resolvingAgainstBaseURL: false),
              page.scheme == "https", page.host?.lowercased() == "github.com", page.port == nil,
              page.user == nil, page.password == nil, page.query == nil, page.fragment == nil,
              release.url.pathComponents.dropLast().map({ $0.lowercased() }) ==
                (AppInformation.repositoryURL.pathComponents + ["releases", "tag"]).map({ $0.lowercased() }),
              ReleaseVersion(release.url.lastPathComponent) == ReleaseVersion(release.version) else {
            throw AppUpdateFailure.invalidCatalog
        }
        return AppInformation.releasesURL.appendingPathComponent("download")
            .appendingPathComponent(release.url.lastPathComponent).appendingPathComponent(asset)
    }

    static func validatePath(_ path: String) throws {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, path.utf8.count <= 1024, !path.contains("\\"), !path.contains(":"),
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw AppUpdateFailure.invalidCatalog
        }
    }

    private static func validateAsset(_ asset: Asset) throws {
        try validatePath(asset.path)
        guard !asset.path.contains("/"), asset.bytes > 0, asset.bytes <= 2 * 1024 * 1024 * 1024,
              validDigest(asset.sha256) else { throw AppUpdateFailure.invalidCatalog }
    }

    private static func validateFiles(_ files: [File]) throws {
        guard !files.isEmpty, files.count <= 10_000 else { throw AppUpdateFailure.invalidCatalog }
        var paths = Set<String>(), spelling = [String: String](), bytes: Int64 = 0
        for file in files {
            try validatePath(file.path)
            guard paths.insert(file.path).inserted, file.bytes >= 0, file.bytes <= 2 * 1024 * 1024 * 1024,
                  validDigest(file.sha256), (0...0o777).contains(file.mode) else { throw AppUpdateFailure.invalidCatalog }
            bytes += file.bytes
            guard bytes <= 8 * 1024 * 1024 * 1024 else { throw AppUpdateFailure.invalidCatalog }
            let parts = file.path.split(separator: "/")
            for count in 1...parts.count {
                let path = parts.prefix(count).joined(separator: "/")
                let key = path.decomposedStringWithCanonicalMapping.folding(options: .caseInsensitive,
                                                                            locale: Locale(identifier: "en_US_POSIX"))
                guard spelling[key] == nil || spelling[key] == path else { throw AppUpdateFailure.invalidCatalog }
                spelling[key] = path
            }
        }
        for path in paths {
            let parts = path.split(separator: "/")
            for count in 1..<parts.count where paths.contains(parts.prefix(count).joined(separator: "/")) {
                throw AppUpdateFailure.invalidCatalog
            }
        }
    }

    private static func validDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

enum AppUpdateFailure: LocalizedError {
    case invalidCatalog, unavailableCatalog, invalidArchive, invalidApplication, download
    var errorDescription: String? {
        switch self {
        case .invalidCatalog: L("更新清单无效，请前往 GitHub 下载完整版本")
        case .unavailableCatalog: L("此版本尚未提供应用内更新，请前往 GitHub 下载")
        case .invalidArchive: L("更新文件校验失败，请重试")
        case .invalidApplication: L("更新应用验证失败，原应用未被修改")
        case .download: L("更新下载失败，请检查网络连接后重试")
        }
    }
}
