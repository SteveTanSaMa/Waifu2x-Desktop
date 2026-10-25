import Foundation

enum AppInformation {
    static let repositoryURL = URL(string: "https://github.com/SteveTanSaMa/Waifu2x-Desktop")!
    static let releasesURL = repositoryURL.appendingPathComponent("releases")
    static let issuesURL = repositoryURL.appendingPathComponent("issues")
    static let latestReleaseAPI = URL(string: "https://api.github.com/repos/SteveTanSaMa/Waifu2x-Desktop/releases/latest")!

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }
    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }
}
