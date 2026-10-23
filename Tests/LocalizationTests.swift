import XCTest
@testable import Waifu2x

final class LocalizationTests: XCTestCase {
    func testSystemPreferenceOrderAndEnglishFallback() {
        let cases: [([String], String)] = [
            ([], "en"), (["es-MX", "de-DE"], "en"),
            (["es-MX", "ja-JP", "fr-FR"], "ja"), (["fr-CA", "en-GB"], "fr"),
            (["en-AU", "ja-JP"], "en"), (["ko-KR"], "ko"), (["ru-RU"], "ru"),
            (["zh-TW"], "zh-Hant"), (["zh-HK"], "zh-Hant"), (["zh-MO"], "zh-Hant"),
            (["zh-CN"], "zh-Hans"), (["zh-SG"], "zh-Hans"),
            (["zh-Hant-CN"], "zh-Hant"), (["zh-Hans-HK"], "zh-Hans")
        ]
        for (preferences, expected) in cases {
            XCTAssertEqual(AppLocalization.resolveLanguage(preferences), expected, "\(preferences)")
        }
    }

    func testEveryCatalogEntryHasAllLanguagesAndMatchingFormatArguments() throws {
        let catalog = try loadCatalog()
        XCTAssertGreaterThan(catalog.count, 200)
        for (key, entry) in catalog {
            let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any], key)
            XCTAssertEqual(Set(localizations.keys), Set(AppLocalization.supportedLanguages), key)
            let english = try translation("en", in: localizations)
            XCTAssertFalse(english.isEmpty, key)
            XCTAssertEqual(formatArguments(english), formatArguments(key), key)
            XCTAssertEqual(english.components(separatedBy: "%%").count, key.components(separatedBy: "%%").count, key)
            for language in AppLocalization.supportedLanguages {
                let value = try translation(language, in: localizations)
                XCTAssertFalse(value.isEmpty, "\(language): \(key)")
                XCTAssertEqual(formatArguments(value), formatArguments(english), "\(language): \(key)")
                XCTAssertEqual(value.components(separatedBy: "%%").count, english.components(separatedBy: "%%").count, "\(language): \(key)")
            }
        }
    }

    func testAllLocalizedCallSitesAreInTheCatalogAndPanelCopyHasNoPeriods() throws {
        let catalog = try loadCatalog()
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = project.appendingPathComponent("Waifu2x")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: source, includingPropertiesForKeys: nil))
        let panelFiles: Set<String> = ["ProcessingOptionsPanel.swift", "AdvancedProcessingOptions.swift", "ProcessingOptionHints.swift", "ProcessingOptions.swift"]
        let expression = try NSRegularExpression(pattern: #"\bL\(\s*"((?:[^"\\]|\\.)*)""#)
        var panelKeys = Set<String>()
        for case let url as URL in files where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            for match in expression.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                let literal = String(text[Range(match.range(at: 1), in: text)!])
                XCTAssertFalse(literal.contains(#"\("#), "Localized keys must be stable: \(url.lastPathComponent)")
                let quoted = Data("\"\(literal)\"".utf8)
                let key = try XCTUnwrap(JSONSerialization.jsonObject(with: quoted, options: .fragmentsAllowed) as? String)
                XCTAssertNotNil(catalog[key], "Missing key in \(url.lastPathComponent): \(key)")
                if panelFiles.contains(url.lastPathComponent) { panelKeys.insert(key) }
            }
        }
        XCTAssertGreaterThan(panelKeys.count, 60)
        for key in panelKeys {
            let entry = try XCTUnwrap(catalog[key])
            let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any])
            for language in AppLocalization.supportedLanguages {
                let value = try translation(language, in: localizations)
                XCTAssertFalse(value.contains("。") || value.contains("．") || value.contains("."), "Sentence period in \(language): \(key)")
            }
        }
    }

    func testCompiledBundleResolvesTranslatedStringsAndFormatsCounts() throws {
        XCTAssertEqual(Set(Bundle.main.localizations).subtracting(["Base"]), Set(AppLocalization.supportedLanguages))
        let catalog = try loadCatalog()
        for language in AppLocalization.supportedLanguages {
            let localizer = AppLocalization(preferredLanguages: [language])
            XCTAssertEqual(localizer.language, language)
            for (key, entry) in catalog {
                let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any])
                XCTAssertEqual(localizer.string(key), try translation(language, in: localizations), "\(language): \(key)")
            }
            let count = localizer.string("为所选 %d 张图片调整", arguments: [12])
            XCTAssertTrue(count.contains("12"))
            XCTAssertFalse(count.contains("%d"))
        }
        let english = AppLocalization(preferredLanguages: ["de-DE", "es-ES"])
        XCTAssertEqual(english.string("图像增强"), "Image enhancement")
        let count = english.string("为所选 %d 张图片调整", arguments: [12])
        XCTAssertTrue(count.contains("12"))
        XCTAssertFalse(count.contains("%d"))
        XCTAssertFalse(count.contains("所选"))
    }

    func testMissingTranslationUsesEnglishInsteadOfAnotherLanguage() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        for language in ["en", "ja"] {
            try FileManager.default.createDirectory(at: directory.appendingPathComponent("\(language).lproj"), withIntermediateDirectories: true)
        }
        try #""key" = "English fallback";"#.write(to: directory.appendingPathComponent("en.lproj/Localizable.strings"), atomically: true, encoding: .utf8)
        try #""other" = "別の値";"#.write(to: directory.appendingPathComponent("ja.lproj/Localizable.strings"), atomically: true, encoding: .utf8)
        let bundle = try XCTUnwrap(Bundle(url: directory))
        XCTAssertEqual(AppLocalization(preferredLanguages: ["ja"], bundle: bundle).string("key"), "English fallback")
    }

    private func loadCatalog() throws -> [String: [String: Any]] {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: project.appendingPathComponent("Waifu2x/Resources/Localizable.xcstrings"))
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(document["sourceLanguage"] as? String, "en")
        return try XCTUnwrap(document["strings"] as? [String: [String: Any]])
    }

    private func translation(_ language: String, in localizations: [String: Any]) throws -> String {
        let item = try XCTUnwrap(localizations[language] as? [String: Any])
        let unit = try XCTUnwrap(item["stringUnit"] as? [String: String])
        return try XCTUnwrap(unit["value"])
    }

    private func formatArguments(_ text: String) -> [String] {
        let expression = try! NSRegularExpression(pattern: #"%(?:(\d+)\$)?([-+0 #]*(?:\d+)?(?:\.\d+)?(?:l[diu]|[@diufge]))"#)
        return expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).enumerated().map { index, match in
            let position = Range(match.range(at: 1), in: text).map { String(text[$0]) } ?? "\(index + 1)"
            let type = String(text[Range(match.range(at: 2), in: text)!])
            return "\(position):\(type)"
        }.sorted()
    }
}
