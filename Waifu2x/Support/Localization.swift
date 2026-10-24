import Foundation

/// Uses the first supported system language, including per-app language choices
/// supplied by macOS. No language preference is stored by the application.
struct AppLocalization {
    static let supportedLanguages = ["en", "zh-Hans", "zh-Hant", "ja", "fr", "ko", "ru"]
    static let current = AppLocalization(preferredLanguages: Locale.preferredLanguages)

    let language: String
    let locale: Locale
    private let localizedBundle: Bundle
    private let englishBundle: Bundle

    init(preferredLanguages: [String], bundle: Bundle = .main) {
        language = Self.resolveLanguage(preferredLanguages)
        locale = Locale(identifier: language)
        let english = Self.resourceBundle("en", in: bundle) ?? bundle
        englishBundle = english
        localizedBundle = Self.resourceBundle(language, in: bundle) ?? english
    }

    static func resolveLanguage(_ preferences: [String]) -> String {
        let supportedCodes: Set<String> = ["en", "zh", "ja", "fr", "ko", "ru"]
        // Bundle returns an arbitrary available language if nothing matches.
        // Filter unsupported preferences first so that case always falls back to English.
        let candidates = preferences.filter {
            guard let code = Locale(identifier: $0).language.languageCode?.identifier else { return false }
            return supportedCodes.contains(code.lowercased())
        }
        guard !candidates.isEmpty else { return "en" }
        return Bundle.preferredLocalizations(from: supportedLanguages, forPreferences: candidates).first ?? "en"
    }

    func string(_ key: String, arguments: [CVarArg] = []) -> String {
        let english = englishBundle.localizedString(forKey: key, value: key, table: nil)
        let translated = localizedBundle.localizedString(forKey: key, value: english, table: nil)
        guard !arguments.isEmpty else { return translated }
        return String(format: translated, locale: locale, arguments: arguments)
    }

    private static func resourceBundle(_ language: String, in bundle: Bundle) -> Bundle? {
        bundle.url(forResource: language, withExtension: "lproj").flatMap(Bundle.init(url:))
    }
}

/// Resolves a manually maintained catalog key. Chinese lookup keys are stable
/// identifiers; the catalog's English source values provide the default copy.
func L(_ key: String, _ arguments: CVarArg...) -> String {
    AppLocalization.current.string(key, arguments: arguments)
}
