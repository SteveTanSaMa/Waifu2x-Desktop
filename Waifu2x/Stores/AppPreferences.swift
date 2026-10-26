import Combine
import Foundation

/// Preferences are shared with background localization readers. The lock protects
/// each stored value and its cached localizer; change events follow the committed
/// snapshot, so subscribers can safely read the new value without taking our lock.
final class AppPreferences: ObservableObject, @unchecked Sendable {
    enum Change: Equatable { case language, appearance, automaticallyCheckUpdates, notifiesOnCompletion, preventsSleepWhileProcessing }

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

    let objectWillChange = ObservableObjectPublisher()
    private let changeSubject = PassthroughSubject<Change, Never>()
    var changes: AnyPublisher<Change, Never> { changeSubject.eraseToAnyPublisher() }
    private let lock = NSLock()
    private let defaults: UserDefaults?
    private let systemLanguages: [String]
    private var storedLanguageCode: String
    private var storedAppearance: String
    private var storedAutomaticallyCheckUpdates: Bool
    private var storedNotifiesOnCompletion: Bool
    private var storedPreventsSleepWhileProcessing: Bool
    private var cachedLocalizer: AppLocalization

    /// A dedicated suite or nil keeps tests and isolated sessions separate from
    /// the user's actual application preferences.
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
        get { lock.withLock { storedLanguageCode } }
        set {
            let language = Self.validLanguage(newValue)
            let localizer = AppLocalization(preferredLanguages: language == "system" ? systemLanguages : [language])
            let changed = lock.withLock {
                guard storedLanguageCode != language else { return false }
                storedLanguageCode = language
                cachedLocalizer = localizer
                defaults?.set(language, forKey: Self.languageKey)
                return true
            }
            if changed { publish(.language) }
        }
    }

    var appearance: String {
        get { lock.withLock { storedAppearance } }
        set {
            let appearance = Self.validAppearance(newValue)
            let changed = lock.withLock {
                guard storedAppearance != appearance else { return false }
                storedAppearance = appearance
                defaults?.set(appearance, forKey: Self.appearanceKey)
                return true
            }
            if changed { publish(.appearance) }
        }
    }

    var automaticallyCheckUpdates: Bool {
        get { lock.withLock { storedAutomaticallyCheckUpdates } }
        set {
            let changed = lock.withLock {
                guard storedAutomaticallyCheckUpdates != newValue else { return false }
                storedAutomaticallyCheckUpdates = newValue
                defaults?.set(newValue, forKey: Self.automaticallyCheckUpdatesKey)
                return true
            }
            if changed { publish(.automaticallyCheckUpdates) }
        }
    }

    var notifiesOnCompletion: Bool {
        get { lock.withLock { storedNotifiesOnCompletion } }
        set {
            let changed = lock.withLock {
                guard storedNotifiesOnCompletion != newValue else { return false }
                storedNotifiesOnCompletion = newValue
                defaults?.set(newValue, forKey: Self.notifiesOnCompletionKey)
                return true
            }
            if changed { publish(.notifiesOnCompletion) }
        }
    }

    var preventsSleepWhileProcessing: Bool {
        get { lock.withLock { storedPreventsSleepWhileProcessing } }
        set {
            let changed = lock.withLock {
                guard storedPreventsSleepWhileProcessing != newValue else { return false }
                storedPreventsSleepWhileProcessing = newValue
                defaults?.set(newValue, forKey: Self.preventsSleepWhileProcessingKey)
                return true
            }
            if changed { publish(.preventsSleepWhileProcessing) }
        }
    }

    var localizer: AppLocalization { lock.withLock { cachedLocalizer } }
    var locale: Locale { localizer.locale }

    private func publish(_ change: Change) {
        changeSubject.send(change)
        // Production UI mutations are main-actor driven. A background caller is
        // still safe: keep SwiftUI invalidation on its required main queue.
        if Thread.isMainThread { objectWillChange.send() }
        else { DispatchQueue.main.async { [weak self] in self?.objectWillChange.send() } }
    }

    private static func validLanguage(_ value: String) -> String {
        languageCodes.contains(value) ? value : "system"
    }

    private static func validAppearance(_ value: String) -> String {
        appearances.contains(value) ? value : "system"
    }
}
