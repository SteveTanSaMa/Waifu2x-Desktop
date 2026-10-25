import Foundation
import XCTest
@testable import Waifu2x

@MainActor
final class AppUpdateCheckerTests: XCTestCase {
    func testSemanticVersionPrecedenceAndMalformedVersions() throws {
        let ordered = ["1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta", "1.0.0-beta.2",
                       "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0", "1.0.9", "1.0.10", "1.1.0", "2.0.0",
                       "999999999999999999999999999999.0.0"]
        let versions = try ordered.map { try XCTUnwrap(ReleaseVersion($0)) }
        for index in 1..<versions.count { XCTAssertLessThan(versions[index - 1], versions[index]) }
        XCTAssertEqual(ReleaseVersion("v1.0.1+build.42"), ReleaseVersion("1.0.1+other"))
        for invalid in ["", "1", "1.0", "1.0.0.0", "01.0.0", "1.-1.0", "1.0.0-", "1.0.0-01", "1.0.0+", "1.0.0+bad!", " 1.0.0", "release-1.0.0"] {
            XCTAssertNil(ReleaseVersion(invalid), invalid)
        }
    }

    func testChecksOnlyPublicMetadataAndReturnsAnOfficialReleasePage() async throws {
        try await withDefaults { defaults in
            let requests = UpdateRequestRecorder()
            let payload = try releaseData(tag: "v1.0.10")
            let checker = AppUpdateChecker(currentVersion: "1.0.9", defaults: defaults, transport: { request in
                await requests.record(request)
                return (payload, self.httpResponse())
            })
            checker.check()
            XCTAssertEqual(checker.status, .checking)
            try await wait { checker.status != .checking }
            XCTAssertEqual(checker.status, .available)
            XCTAssertEqual(checker.availableRelease?.version, "1.0.10")
            XCTAssertEqual(checker.availableRelease?.url.absoluteString,
                           "https://github.com/SteveTanSaMa/Waifu2x-Desktop/releases/tag/v1.0.10")
            let recorded = await requests.requests
            let request = try XCTUnwrap(recorded.first)
            XCTAssertEqual(recorded.count, 1)
            XCTAssertEqual(request.url, AppInformation.latestReleaseAPI)
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-GitHub-Api-Version"), "2026-03-10")
            XCTAssertEqual(request.timeoutInterval, 20)
            XCTAssertNotNil(checker.lastChecked)
            XCTAssertNil(checker.errorMessage)
        }
    }

    func testEqualOlderAndBuildOnlyVersionsDoNotOfferUpdates() async throws {
        try await withDefaults { defaults in
            for tag in ["v1.0.10", "1.0.9", "v1.0.10+metadata"] {
                let checker = AppUpdateChecker(currentVersion: "1.0.10", defaults: defaults,
                                               transport: transport(data: try releaseData(tag: tag)))
                checker.check()
                try await wait { checker.status != .checking }
                XCTAssertEqual(checker.status, .upToDate, tag)
                XCTAssertNil(checker.availableRelease)
            }
        }
    }

    func testInAppDownloadsAreOfferedOnlyForAnOfficialCatalogAsset() async throws {
        try await withDefaults { defaults in
            let official = "https://github.com/SteveTanSaMa/Waifu2x-Desktop/releases/download/v2.0.0/Waifu2x-update.json"
            for value in [official, "https://example.invalid/Waifu2x-update.json"] {
                var body = try JSONSerialization.jsonObject(with: releaseData()) as! [String: Any]
                body["assets"] = [["name": "Waifu2x-update.json", "browser_download_url": value]]
                let checker = AppUpdateChecker(currentVersion: "1.0.1", defaults: defaults,
                                               transport: transport(data: try JSONSerialization.data(withJSONObject: body)))
                checker.check()
                try await wait { checker.status != .checking }
                XCTAssertEqual(checker.status, .available)
                XCTAssertEqual(checker.availableRelease?.hasUpdateCatalog, value == official)
            }
        }
    }

    func testRejectsUntrustedDraftPrereleaseAndMalformedMetadata() async throws {
        try await withDefaults { defaults in
            let invalid = [
                Data("not json".utf8), Data("{}".utf8),
                try releaseData(draft: true), try releaseData(prerelease: true),
                try releaseData(tag: "v2.0.0-rc.1"), try releaseData(tag: "release-2"),
                try releaseData(url: "http://github.com/SteveTanSaMa/Waifu2x-Desktop/releases/tag/v2.0.0"),
                try releaseData(url: "https://github.com.evil.invalid/SteveTanSaMa/Waifu2x-Desktop/releases/tag/v2.0.0"),
                try releaseData(url: "https://github.com/other/Waifu2x-Desktop/releases/tag/v2.0.0"),
                try releaseData(url: "https://github.com/SteveTanSaMa/Waifu2x-Desktop/releases/tag/v9.0.0"),
                try releaseData(url: "https://github.com/SteveTanSaMa/Waifu2x-Desktop/releases/download/v2.0.0/update.dmg"),
                try releaseData(url: "https://user@github.com/SteveTanSaMa/Waifu2x-Desktop/releases/tag/v2.0.0"),
                try releaseData(url: "https://github.com/SteveTanSaMa/Waifu2x-Desktop/releases/tag/v2.0.0?next=external")
            ]
            for payload in invalid {
                let checker = AppUpdateChecker(currentVersion: "1.0.1", defaults: defaults, transport: transport(data: payload))
                checker.check()
                try await wait { checker.status != .checking }
                XCTAssertEqual(checker.status, .failed)
                XCTAssertNil(checker.availableRelease)
                XCTAssertEqual(checker.errorMessage, L("更新服务器返回的版本信息无效，请稍后再试"))
            }
        }
    }

    func testHTTPRateLimitTimeoutAndNetworkFailuresHaveUsefulMessages() async throws {
        try await withDefaults { defaults in
            let rateMessage = L("GitHub 请求次数已达上限，请稍后再检查更新")
            let cases: [(AppUpdateTransport, String)] = [
                (transport(data: Data(), status: 429), rateMessage),
                (transport(data: Data(), status: 403, headers: ["X-RateLimit-Remaining": "0"]), rateMessage),
                (transport(data: Data("{\"message\":\"API rate limit exceeded\"}".utf8), status: 403), rateMessage),
                (transport(data: Data(), status: 503), L("更新服务器返回错误（HTTP %d），请稍后再试", 503)),
                (transport(data: Data(), status: 404), L("暂时没有可用的正式版本，请稍后再试")),
                ({ @Sendable _ in throw URLError(.timedOut) }, L("检查更新超时，请检查网络连接后重试")),
                ({ @Sendable _ in throw URLError(.notConnectedToInternet) }, L("无法连接更新服务器，请检查网络连接后重试")),
                ({ @Sendable request in (Data(), URLResponse(url: request.url!, mimeType: nil, expectedContentLength: 0, textEncodingName: nil)) },
                 L("更新服务器返回的版本信息无效，请稍后再试"))
            ]
            for (transport, expected) in cases {
                let checker = AppUpdateChecker(currentVersion: "1.0.1", defaults: defaults, transport: transport)
                checker.check()
                try await wait { checker.status != .checking }
                XCTAssertEqual(checker.status, .failed)
                XCTAssertEqual(checker.errorMessage, expected)
                XCTAssertNil(checker.availableRelease)
            }
        }
    }

    func testRateLimitedAPIFallsBackToOfficialLatestHEADAndComparesVersions() async throws {
        try await withDefaults { defaults in
            let cases: [(Int, String, String, AppUpdateStatus)] = [
                (403, "v1.0.10", "1.0.9", .available),
                (429, "v1.0.1", "1.0.1", .upToDate),
                (429, "v1.0.0", "1.0.1", .upToDate)
            ]
            for (status, tag, installed, expected) in cases {
                let requests = UpdateRequestRecorder()
                let page = AppInformation.releasesURL.appendingPathComponent("latest")
                let finalURL = AppInformation.releasesURL.appendingPathComponent("tag").appendingPathComponent(tag)
                let limited = httpResponse(status: status, headers: ["X-RateLimit-Remaining": "0"])
                let resolved = httpResponse(url: finalURL)
                let checker = AppUpdateChecker(currentVersion: installed, defaults: defaults, transport: { request in
                    await requests.record(request)
                    if request.url == AppInformation.latestReleaseAPI, request.httpMethod == "GET" { return (Data(), limited) }
                    if request.url == page, request.httpMethod == "HEAD" { return (Data(), resolved) }
                    throw URLError(.badURL)
                })
                checker.check()
                try await wait { checker.status != .checking }
                XCTAssertEqual(checker.status, expected)
                XCTAssertNil(checker.errorMessage)
                if expected == .available {
                    XCTAssertEqual(checker.availableRelease?.version, "1.0.10")
                    XCTAssertEqual(checker.availableRelease?.url, finalURL)
                } else { XCTAssertNil(checker.availableRelease) }
                let recorded = await requests.requests
                XCTAssertEqual(recorded.count, 2)
                let head = try XCTUnwrap(recorded.last)
                XCTAssertEqual(head.httpMethod, "HEAD")
                XCTAssertEqual(head.url, page)
                XCTAssertNil(head.httpBody)
                XCTAssertNil(head.value(forHTTPHeaderField: "Authorization"))
                XCTAssertEqual(head.timeoutInterval, 20)
            }
        }
    }

    func testRateLimitFallbackRejectsUntrustedAndUnresolvedReleaseURLs() async throws {
        try await withDefaults { defaults in
            let invalidURLs = [
                "http://github.com/SteveTanSaMa/Waifu2x-Desktop/releases/tag/v2.0.0",
                "https://github.com.evil.invalid/SteveTanSaMa/Waifu2x-Desktop/releases/tag/v2.0.0",
                "https://github.com/other/Waifu2x-Desktop/releases/tag/v2.0.0",
                "https://github.com/SteveTanSaMa/other/releases/tag/v2.0.0",
                "https://github.com/SteveTanSaMa/Waifu2x-Desktop/releases/download/v2.0.0/update.dmg",
                "https://github.com/SteveTanSaMa/Waifu2x-Desktop/releases/latest",
                "https://github.com/login",
                "https://github.com/SteveTanSaMa/Waifu2x-Desktop/releases/tag/release-2",
                "https://github.com/SteveTanSaMa/Waifu2x-Desktop/releases/tag/v2.0.0-rc.1",
                "https://user@github.com/SteveTanSaMa/Waifu2x-Desktop/releases/tag/v2.0.0",
                "https://github.com:443/SteveTanSaMa/Waifu2x-Desktop/releases/tag/v2.0.0",
                "https://github.com/SteveTanSaMa/Waifu2x-Desktop/releases/tag/v2.0.0?next=external",
                "https://github.com/SteveTanSaMa/Waifu2x-Desktop/releases/tag/v2.0.0#fragment"
            ]
            for value in invalidURLs {
                let requests = UpdateRequestRecorder()
                let limited = httpResponse(status: 429)
                let resolved = httpResponse(url: try XCTUnwrap(URL(string: value)))
                let checker = AppUpdateChecker(currentVersion: "1.0.1", defaults: defaults, transport: { request in
                    await requests.record(request)
                    if request.url == AppInformation.latestReleaseAPI, request.httpMethod == "GET" { return (Data(), limited) }
                    if request.url == AppInformation.releasesURL.appendingPathComponent("latest"), request.httpMethod == "HEAD" {
                        return (Data(), resolved)
                    }
                    throw URLError(.badURL)
                })
                checker.check()
                try await wait { checker.status != .checking }
                XCTAssertEqual(checker.status, .failed, value)
                XCTAssertNil(checker.availableRelease, value)
                XCTAssertEqual(checker.errorMessage, L("GitHub 请求次数已达上限，请稍后再检查更新"))
                let count = await requests.requests.count
                XCTAssertEqual(count, 2)
            }
        }
    }

    func testRateLimitFallbackNetworkAndHTTPFailuresPreserveUsefulFailure() async throws {
        try await withDefaults { defaults in
            let finalURL = AppInformation.releasesURL.appendingPathComponent("tag/v2.0.0")
            let failedHeadResponses: [AppUpdateTransport] = [
                { @Sendable _ in throw URLError(.timedOut) },
                { @Sendable _ in throw URLError(.notConnectedToInternet) },
                { @Sendable _ in (Data(), URLResponse(url: finalURL, mimeType: nil, expectedContentLength: 0, textEncodingName: nil)) },
                transport(data: Data(), status: 302, headers: ["Location": finalURL.absoluteString]),
                transport(data: Data(), status: 404), transport(data: Data(), status: 429), transport(data: Data(), status: 503)
            ]
            for failedHead in failedHeadResponses {
                let requests = UpdateRequestRecorder()
                let limited = httpResponse(status: 403, headers: ["Retry-After": "60"])
                let checker = AppUpdateChecker(currentVersion: "1.0.1", defaults: defaults, transport: { request in
                    await requests.record(request)
                    if request.url == AppInformation.latestReleaseAPI, request.httpMethod == "GET" { return (Data(), limited) }
                    if request.url == AppInformation.releasesURL.appendingPathComponent("latest"), request.httpMethod == "HEAD" {
                        return try await failedHead(request)
                    }
                    throw URLError(.badURL)
                })
                checker.check()
                try await wait { checker.status != .checking }
                XCTAssertEqual(checker.status, .failed)
                XCTAssertNil(checker.availableRelease)
                XCTAssertEqual(checker.errorMessage, L("GitHub 请求次数已达上限，请稍后再检查更新"))
                let count = await requests.requests.count
                XCTAssertEqual(count, 2)
            }
        }
    }

    func testOtherAPIFailuresNeverTriggerLatestPageFallback() async throws {
        try await withDefaults { defaults in
            for status in [200, 400, 403, 404, 503] {
                let requests = UpdateRequestRecorder()
                let response = httpResponse(status: status)
                let checker = AppUpdateChecker(currentVersion: "1.0.1", defaults: defaults, transport: { request in
                    await requests.record(request)
                    return (Data(), response)
                })
                checker.check()
                try await wait { checker.status != .checking }
                XCTAssertEqual(checker.status, .failed)
                XCTAssertNil(checker.availableRelease)
                let count = await requests.requests.count
                XCTAssertEqual(count, 1, "Only a confirmed API rate limit may use HEAD fallback")
            }
        }
    }

    func testAutomaticChecksRespectPreferenceAndPersistedDayWhileManualChecksBypassIt() async throws {
        try await withDefaults { defaults in
            let requests = UpdateRequestRecorder()
            let payload = try releaseData(tag: "v1.0.1")
            let response = httpResponse()
            let transport: AppUpdateTransport = { request in
                await requests.record(request)
                return (payload, response)
            }
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            let checker = AppUpdateChecker(currentVersion: "1.0.1", defaults: defaults, transport: transport, now: { now })
            checker.checkAutomaticallyIfNeeded(enabled: false)
            XCTAssertEqual(checker.status, .idle)
            checker.checkAutomaticallyIfNeeded(enabled: true)
            checker.checkAutomaticallyIfNeeded(enabled: true)
            try await wait { checker.status != .checking }
            XCTAssertEqual(checker.status, .upToDate)
            XCTAssertEqual(defaults.object(forKey: AppUpdateChecker.lastCheckedKey) as? Date, now)
            let recreated = AppUpdateChecker(currentVersion: "1.0.1", defaults: defaults, transport: transport, now: { now })
            recreated.checkAutomaticallyIfNeeded(enabled: true)
            XCTAssertEqual(recreated.status, .idle)
            var count = await requests.requests.count
            XCTAssertEqual(count, 1)
            recreated.check()
            try await wait { recreated.status != .checking }
            count = await requests.requests.count
            XCTAssertEqual(count, 2)
            let tomorrow = now.addingTimeInterval(24 * 60 * 60)
            let expired = AppUpdateChecker(currentVersion: "1.0.1", defaults: defaults, transport: transport, now: { tomorrow })
            expired.checkAutomaticallyIfNeeded(enabled: true)
            try await wait { expired.status != .checking }
            count = await requests.requests.count
            XCTAssertEqual(count, 3)
        }
    }

    private func withDefaults(_ action: (UserDefaults) async throws -> Void) async throws {
        let name = "Waifu2x.UpdateTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try await action(defaults)
    }

    private func releaseData(tag: String = "v2.0.0", url: String? = nil, draft: Bool = false, prerelease: Bool = false) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "tag_name": tag,
            "html_url": url ?? "https://github.com/SteveTanSaMa/Waifu2x-Desktop/releases/tag/\(tag)",
            "draft": draft, "prerelease": prerelease
        ])
    }

    nonisolated private func httpResponse(status: Int = 200, headers: [String: String] = [:], url: URL? = nil) -> HTTPURLResponse {
        HTTPURLResponse(url: url ?? URL(string: "https://api.github.com/repos/SteveTanSaMa/Waifu2x-Desktop/releases/latest")!,
                        statusCode: status, httpVersion: "HTTP/2", headerFields: headers)!
    }

    private func transport(data: Data, status: Int = 200, headers: [String: String] = [:]) -> AppUpdateTransport {
        let response = httpResponse(status: status, headers: headers)
        return { _ in (data, response) }
    }

    private func wait(until predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(predicate(), "Update check did not finish")
    }
}

private actor UpdateRequestRecorder {
    private(set) var requests = [URLRequest]()
    func record(_ request: URLRequest) { requests.append(request) }
}
