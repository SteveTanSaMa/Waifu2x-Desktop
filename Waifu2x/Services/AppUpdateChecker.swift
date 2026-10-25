import Foundation
import Observation

enum AppUpdateStatus: Equatable, Sendable {
    case idle, checking, upToDate, available, failed
}

typealias AppUpdateTransport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

/// Reads public release metadata. Installing an update remains an explicit user action.
@MainActor @Observable
final class AppUpdateChecker {
    struct AvailableRelease: Equatable, Sendable {
        let version: String
        let url: URL
        var hasUpdateCatalog = false
    }

    let downloader: AppUpdateDownloader

    static let lastCheckedKey = "appUpdate.lastChecked"
    static let automaticCheckInterval: TimeInterval = 24 * 60 * 60

    private(set) var status: AppUpdateStatus = .idle
    private(set) var availableRelease: AvailableRelease?
    private(set) var lastChecked: Date?
    private(set) var errorMessage: String?
    @ObservationIgnored private let currentVersion: String
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let transport: AppUpdateTransport
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var work: Task<Void, Never>?

    init(currentVersion: String = AppInformation.version, defaults: UserDefaults = .standard,
         session: URLSession = .shared, transport: AppUpdateTransport? = nil,
         now: @escaping @Sendable () -> Date = { Date() }, downloader: AppUpdateDownloader? = nil) {
        self.currentVersion = currentVersion
        self.defaults = defaults
        let resolvedTransport = transport ?? { try await session.data(for: $0) }
        self.transport = resolvedTransport
        self.downloader = downloader ?? AppUpdateDownloader(currentVersion: currentVersion, transport: transport)
        self.now = now
        lastChecked = defaults.object(forKey: Self.lastCheckedKey) as? Date
    }

    func checkAutomaticallyIfNeeded(enabled: Bool) {
        guard enabled, work == nil else { return }
        // Treat a future timestamp as stale after a clock change.
        if let lastChecked {
            let elapsed = now().timeIntervalSince(lastChecked)
            if elapsed >= 0, elapsed < Self.automaticCheckInterval { return }
        }
        check()
    }

    func check() {
        guard work == nil, !downloader.isBusy else { return }
        status = .checking
        availableRelease = nil
        errorMessage = nil
        work = Task { [weak self] in
            guard let self else { return }
            defer {
                let checked = now()
                lastChecked = checked
                defaults.set(checked, forKey: Self.lastCheckedKey)
                work = nil
            }
            do {
                guard let installed = ReleaseVersion(currentVersion) else {
                    throw UpdateFailure.message(L("无法识别当前应用版本，请打开官方发布页面查看更新"))
                }
                var request = URLRequest(url: AppInformation.latestReleaseAPI,
                                         cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
                request.setValue("Waifu2x-Desktop/\(currentVersion)", forHTTPHeaderField: "User-Agent")
                let (data, response) = try await transport(request)
                guard let response = response as? HTTPURLResponse else { throw UpdateFailure.invalidResponse }
                if response.statusCode == 429 || (response.statusCode == 403 &&
                    (response.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0" ||
                     response.value(forHTTPHeaderField: "Retry-After") != nil ||
                     Self.isRateLimitResponse(data))) {
                    // GitHub's public latest-release link is independent of the REST
                    // quota. HEAD follows its redirect without downloading page HTML.
                    if let release = await latestReleaseFromPage() {
                        finish(version: release.version, url: release.url, installed: installed)
                        return
                    }
                    throw UpdateFailure.message(L("GitHub 请求次数已达上限，请稍后再检查更新"))
                }
                guard response.statusCode == 200 else {
                    if response.statusCode == 404 {
                        throw UpdateFailure.message(L("暂时没有可用的正式版本，请稍后再试"))
                    }
                    throw UpdateFailure.message(L("更新服务器返回错误（HTTP %d），请稍后再试", response.statusCode))
                }
                guard data.count <= 2 * 1024 * 1024,
                      let release = try? JSONDecoder().decode(Release.self, from: data),
                      !release.draft, !release.prerelease,
                      let version = ReleaseVersion(release.tagName), version.prerelease.isEmpty,
                      let url = Self.officialReleaseURL(release.htmlURL, tag: release.tagName) else {
                    throw UpdateFailure.invalidResponse
                }
                let offered = AvailableRelease(version: version.description, url: url)
                let catalogURL = try? AppUpdateCatalog.assetURL(AppUpdateCatalog.filename, release: offered)
                let hasCatalog = release.assets?.contains {
                    $0.name == AppUpdateCatalog.filename && URL(string: $0.browserDownloadURL) == catalogURL
                } == true
                finish(version: version, url: url, installed: installed, hasUpdateCatalog: hasCatalog)
            } catch {
                status = .failed
                if let failure = error as? UpdateFailure { errorMessage = failure.localizedDescription }
                else if (error as? URLError)?.code == .timedOut {
                    errorMessage = L("检查更新超时，请检查网络连接后重试")
                } else {
                    errorMessage = L("无法连接更新服务器，请检查网络连接后重试")
                }
            }
        }
    }

    func downloadAvailableUpdate() {
        guard let release = availableRelease, release.hasUpdateCatalog else { return }
        downloader.start(release)
    }

    private func finish(version: ReleaseVersion, url: URL, installed: ReleaseVersion, hasUpdateCatalog: Bool = false) {
        if version > installed {
            availableRelease = AvailableRelease(version: version.description, url: url, hasUpdateCatalog: hasUpdateCatalog)
            status = .available
        } else {
            status = .upToDate
        }
    }

    private func latestReleaseFromPage() async -> (version: ReleaseVersion, url: URL)? {
        var request = URLRequest(url: AppInformation.releasesURL.appendingPathComponent("latest"),
                                 cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "HEAD"
        request.setValue("Waifu2x-Desktop/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        guard let (_, response) = try? await transport(request),
              let response = response as? HTTPURLResponse, response.statusCode == 200,
              let finalURL = response.url,
              let version = ReleaseVersion(finalURL.lastPathComponent), version.prerelease.isEmpty,
              let url = Self.officialReleaseURL(finalURL.absoluteString, tag: finalURL.lastPathComponent) else { return nil }
        return (version, url)
    }

    private static func officialReleaseURL(_ value: String, tag: String) -> URL? {
        guard let url = URL(string: value), url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "github.com", url.port == nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return nil }
        let expected = AppInformation.repositoryURL.pathComponents + ["releases", "tag", tag]
        guard url.pathComponents.count == expected.count,
              zip(url.pathComponents.dropLast(), expected.dropLast()).allSatisfy({ $0.lowercased() == $1.lowercased() }),
              url.lastPathComponent == tag else { return nil }
        return url
    }

    private static func isRateLimitResponse(_ data: Data) -> Bool {
        guard let body = try? JSONDecoder().decode(ServerMessage.self, from: data) else { return false }
        return body.message.lowercased().contains("rate limit")
    }

    private struct Release: Decodable {
        let tagName: String
        let htmlURL: String
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]?
        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name", htmlURL = "html_url", draft, prerelease, assets
        }
    }
    private struct Asset: Decodable {
        let name: String
        let browserDownloadURL: String
        enum CodingKeys: String, CodingKey { case name, browserDownloadURL = "browser_download_url" }
    }
    private struct ServerMessage: Decodable { let message: String }
    private enum UpdateFailure: LocalizedError {
        case invalidResponse, message(String)
        var errorDescription: String? {
            switch self {
            case .invalidResponse: L("更新服务器返回的版本信息无效，请稍后再试")
            case .message(let text): text
            }
        }
    }
}

/// Semantic Versioning precedence, with optional GitHub `v` tag prefix.
/// Numeric components stay strings so even very large version numbers compare correctly.
struct ReleaseVersion: Comparable, Sendable {
    let description: String
    let numbers: [String]
    let prerelease: [String]

    init?(_ value: String) {
        guard !value.isEmpty, value.utf8.count <= 128 else { return nil }
        let version = value.hasPrefix("v") || value.hasPrefix("V") ? String(value.dropFirst()) : value
        let metadata = version.split(separator: "+", omittingEmptySubsequences: false)
        guard metadata.count <= 2,
              metadata.count == 1 || Self.validIdentifiers(String(metadata[1]), numericLeadingZeros: true) else { return nil }
        let parts = metadata[0].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let numbers = parts[0].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard numbers.count == 3, numbers.allSatisfy(Self.isNumber),
              numbers.allSatisfy({ $0.count == 1 || !$0.hasPrefix("0") }) else { return nil }
        let prerelease = parts.count == 2 ? String(parts[1]) : ""
        guard parts.count == 1 || Self.validIdentifiers(prerelease, numericLeadingZeros: false) else { return nil }
        self.description = version
        self.numbers = numbers
        self.prerelease = prerelease.isEmpty ? [] : prerelease.split(separator: ".").map(String.init)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.numbers == rhs.numbers && lhs.prerelease == rhs.prerelease
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        for (left, right) in zip(lhs.numbers, rhs.numbers) where left != right {
            return numericLess(left, right)
        }
        if lhs.prerelease.isEmpty || rhs.prerelease.isEmpty {
            return !lhs.prerelease.isEmpty && rhs.prerelease.isEmpty
        }
        for (left, right) in zip(lhs.prerelease, rhs.prerelease) where left != right {
            let leftNumeric = isNumber(left), rightNumeric = isNumber(right)
            if leftNumeric && rightNumeric { return numericLess(left, right) }
            if leftNumeric != rightNumeric { return leftNumeric }
            return left < right
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }

    private static func numericLess(_ lhs: String, _ rhs: String) -> Bool {
        lhs.count == rhs.count ? lhs < rhs : lhs.count < rhs.count
    }
    private static func isNumber(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { (48...57).contains($0) }
    }
    private static func validIdentifiers(_ value: String, numericLeadingZeros: Bool) -> Bool {
        value.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { part in
            !part.isEmpty && part.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45
            } && (numericLeadingZeros || !isNumber(String(part)) || part.count == 1 || !part.hasPrefix("0"))
        }
    }
}
