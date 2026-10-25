import Foundation
import Observation

/// Shared preferences also serve localization calls made by background services.
/// All mutable storage, including the cached localizer and defaults, is protected
/// by `lock`; ObservationRegistrar supports concurrent access. Views perform their
/// preference mutations on the main actor, while reads can occur on any thread.
@Observable
final class AppPreferences: @unchecked Sendable {
    static let languageKey = "preferences.language"
    static let appearanceKey = "preferences.appearance"
    static let automaticallyCheckUpdatesKey = "preferences.automaticallyCheckUpdates"
    static let notifiesOnCompletionKey = "preferences.notifiesOnCompletion"
    static let preventsSleepWhileProcessingKey = "preferences.preventsSleepWhileProcessing"
    static let languageCodes = ["system"] + AppLocalization.supportedLanguages
    static let appearances = ["system", "light", "dark"]

    static let shared: AppPreferences = {
        let process = ProcessInfo.processInfo
        let isolated = process.arguments.contains("--isolated-session")
            || process.environment["XCTestConfigurationFilePath"] != nil
            || !(process.environment["WAIFU2X_TEST_MODE"] ?? "").isEmpty
            || NSClassFromString("XCTestCase") != nil
        return AppPreferences(defaults: isolated ? nil : .standard)
    }()

    @ObservationIgnored private let lock = NSLock()
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private let systemLanguages: [String]
    @ObservationIgnored private var storedLanguageCode: String
    @ObservationIgnored private var storedAppearance: String
    @ObservationIgnored private var storedAutomaticallyCheckUpdates: Bool
    @ObservationIgnored private var storedNotifiesOnCompletion: Bool
    @ObservationIgnored private var storedPreventsSleepWhileProcessing: Bool
    @ObservationIgnored private var cachedLocalizer: AppLocalization

    /// Pass a dedicated suite for persistence tests or nil for an in-memory
    /// session. Neither mode reads or writes the application's standard defaults.
    init(defaults: UserDefaults? = .standard, systemLanguages: [String] = Locale.preferredLanguages) {
        self.defaults = defaults
        self.systemLanguages = systemLanguages
        let language = Self.validLanguage(defaults?.string(forKey: Self.languageKey) ?? "system")
        storedLanguageCode = language
        storedAppearance = Self.validAppearance(defaults?.string(forKey: Self.appearanceKey) ?? "system")
        storedAutomaticallyCheckUpdates = defaults?.object(forKey: Self.automaticallyCheckUpdatesKey) as? Bool ?? true
        storedNotifiesOnCompletion = defaults?.object(forKey: Self.notifiesOnCompletionKey) as? Bool ?? false
        storedPreventsSleepWhileProcessing = defaults?.object(forKey: Self.preventsSleepWhileProcessingKey) as? Bool ?? true
        cachedLocalizer = AppLocalization(preferredLanguages: language == "system" ? systemLanguages : [language])
    }

    var languageCode: String {
        get {
            access(keyPath: \.languageCode)
            return lock.withLock { storedLanguageCode }
        }
        set {
            let language = Self.validLanguage(newValue)
            guard languageCode != language else { return }
            let localizer = AppLocalization(preferredLanguages: language == "system" ? systemLanguages : [language])
            withMutation(keyPath: \.languageCode) {
                lock.withLock {
                    storedLanguageCode = language
                    cachedLocalizer = localizer
                    defaults?.set(language, forKey: Self.languageKey)
                }
            }
        }
    }

    var appearance: String {
        get {
            access(keyPath: \.appearance)
            return lock.withLock { storedAppearance }
        }
        set {
            let appearance = Self.validAppearance(newValue)
            guard self.appearance != appearance else { return }
            withMutation(keyPath: \.appearance) {
                lock.withLock {
                    storedAppearance = appearance
                    defaults?.set(appearance, forKey: Self.appearanceKey)
                }
            }
        }
    }

    var automaticallyCheckUpdates: Bool {
        get {
            access(keyPath: \.automaticallyCheckUpdates)
            return lock.withLock { storedAutomaticallyCheckUpdates }
        }
        set {
            guard automaticallyCheckUpdates != newValue else { return }
            withMutation(keyPath: \.automaticallyCheckUpdates) {
                lock.withLock {
                    storedAutomaticallyCheckUpdates = newValue
                    defaults?.set(newValue, forKey: Self.automaticallyCheckUpdatesKey)
                }
            }
        }
    }

    var notifiesOnCompletion: Bool {
        get {
            access(keyPath: \.notifiesOnCompletion)
            return lock.withLock { storedNotifiesOnCompletion }
        }
        set {
            guard notifiesOnCompletion != newValue else { return }
            withMutation(keyPath: \.notifiesOnCompletion) {
                lock.withLock {
                    storedNotifiesOnCompletion = newValue
                    defaults?.set(newValue, forKey: Self.notifiesOnCompletionKey)
                }
            }
        }
    }

    var preventsSleepWhileProcessing: Bool {
        get {
            access(keyPath: \.preventsSleepWhileProcessing)
            return lock.withLock { storedPreventsSleepWhileProcessing }
        }
        set {
            guard preventsSleepWhileProcessing != newValue else { return }
            withMutation(keyPath: \.preventsSleepWhileProcessing) {
                lock.withLock {
                    storedPreventsSleepWhileProcessing = newValue
                    defaults?.set(newValue, forKey: Self.preventsSleepWhileProcessingKey)
                }
            }
        }
    }

    /// Reading L() within a view body registers this language dependency, so a
    /// language switch updates existing views without replacing workspace state.
    var localizer: AppLocalization {
        access(keyPath: \.languageCode)
        return lock.withLock { cachedLocalizer }
    }

    var locale: Locale { localizer.locale }

    private static func validLanguage(_ value: String) -> String {
        languageCodes.contains(value) ? value : "system"
    }

    private static func validAppearance(_ value: String) -> String {
        appearances.contains(value) ? value : "system"
    }
}
