import Observation
import XCTest
@testable import Waifu2x

final class AppPreferencesTests: XCTestCase {
    func testFreshPreferencesFollowSystemAndCheckUpdatesAutomatically() {
        let preferences = AppPreferences(defaults: nil, systemLanguages: ["es", "ja-JP"])
        XCTAssertEqual(preferences.languageCode, "system")
        XCTAssertEqual(preferences.localizer.language, "ja")
        XCTAssertEqual(preferences.locale.identifier, "ja")
        XCTAssertEqual(preferences.appearance, "system")
        XCTAssertTrue(preferences.automaticallyCheckUpdates)
        XCTAssertFalse(preferences.notifiesOnCompletion)
        XCTAssertTrue(preferences.preventsSleepWhileProcessing)
    }

    func testPreferencesPersistInTheirInjectedSuite() throws {
        let name = "AppPreferencesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let originalSystemLanguages = defaults.stringArray(forKey: "AppleLanguages")
        let preferences = AppPreferences(defaults: defaults, systemLanguages: ["en"])
        preferences.languageCode = "zh-Hant"
        preferences.appearance = "dark"
        preferences.automaticallyCheckUpdates = false
        preferences.notifiesOnCompletion = true
        preferences.preventsSleepWhileProcessing = false

        let restored = AppPreferences(defaults: defaults, systemLanguages: ["ja"])
        XCTAssertEqual(restored.languageCode, "zh-Hant")
        XCTAssertEqual(restored.localizer.language, "zh-Hant")
        XCTAssertEqual(restored.appearance, "dark")
        XCTAssertFalse(restored.automaticallyCheckUpdates)
        XCTAssertTrue(restored.notifiesOnCompletion)
        XCTAssertFalse(restored.preventsSleepWhileProcessing)
        XCTAssertEqual(defaults.stringArray(forKey: "AppleLanguages"), originalSystemLanguages)
    }

    func testInMemorySessionsAreIndependent() {
        let first = AppPreferences(defaults: nil, systemLanguages: ["en"])
        first.languageCode = "ru"
        first.appearance = "light"
        first.automaticallyCheckUpdates = false
        first.notifiesOnCompletion = true
        first.preventsSleepWhileProcessing = false
        let second = AppPreferences(defaults: nil, systemLanguages: ["fr"])
        XCTAssertEqual(second.languageCode, "system")
        XCTAssertEqual(second.localizer.language, "fr")
        XCTAssertEqual(second.appearance, "system")
        XCTAssertTrue(second.automaticallyCheckUpdates)
        XCTAssertFalse(second.notifiesOnCompletion)
        XCTAssertTrue(second.preventsSleepWhileProcessing)
    }

    func testInvalidStoredAndAssignedChoicesFallBackToSystem() throws {
        let name = "AppPreferencesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("unsupported", forKey: AppPreferences.languageKey)
        defaults.set("unsupported", forKey: AppPreferences.appearanceKey)
        defaults.set("unsupported", forKey: AppPreferences.automaticallyCheckUpdatesKey)
        defaults.set("unsupported", forKey: AppPreferences.notifiesOnCompletionKey)
        defaults.set("unsupported", forKey: AppPreferences.preventsSleepWhileProcessingKey)
        let preferences = AppPreferences(defaults: defaults, systemLanguages: ["ko"])
        XCTAssertEqual(preferences.languageCode, "system")
        XCTAssertEqual(preferences.appearance, "system")
        XCTAssertTrue(preferences.automaticallyCheckUpdates)
        XCTAssertFalse(preferences.notifiesOnCompletion)
        XCTAssertTrue(preferences.preventsSleepWhileProcessing)
        preferences.languageCode = "en"
        preferences.languageCode = "de"
        preferences.appearance = "dark"
        preferences.appearance = "sepia"
        XCTAssertEqual(preferences.languageCode, "system")
        XCTAssertEqual(preferences.localizer.language, "ko")
        XCTAssertEqual(preferences.appearance, "system")
    }

    func testEveryLanguageCanBeSelectedAndSystemCanBeRestored() {
        let preferences = AppPreferences(defaults: nil, systemLanguages: ["fr-CA"])
        for language in AppLocalization.supportedLanguages {
            preferences.languageCode = language
            XCTAssertEqual(preferences.localizer.language, language)
            XCTAssertEqual(preferences.locale.identifier, language)
        }
        preferences.languageCode = "system"
        XCTAssertEqual(preferences.localizer.language, "fr")
    }

    func testLocalizationAndLocaleReadsObserveLanguageChanges() {
        let preferences = AppPreferences(defaults: nil, systemLanguages: ["en"])
        let localizationChanges = PreferenceObservationCounter()
        let localeChanges = PreferenceObservationCounter()
        withObservationTracking {
            _ = preferences.localizer.string("图像增强")
        } onChange: {
            localizationChanges.increment()
        }
        withObservationTracking {
            _ = preferences.locale
        } onChange: {
            localeChanges.increment()
        }
        preferences.appearance = "dark"
        preferences.automaticallyCheckUpdates = false
        XCTAssertEqual(localizationChanges.value, 0)
        XCTAssertEqual(localeChanges.value, 0)
        preferences.languageCode = "ja"
        XCTAssertEqual(localizationChanges.value, 1)
        XCTAssertEqual(localeChanges.value, 1)
        XCTAssertEqual(preferences.localizer.language, "ja")
    }

    func testSelectingTheCurrentChoiceDoesNotInvalidateObservers() {
        let preferences = AppPreferences(defaults: nil)
        let changes = PreferenceObservationCounter()
        withObservationTracking {
            _ = preferences.languageCode
            _ = preferences.appearance
            _ = preferences.automaticallyCheckUpdates
            _ = preferences.notifiesOnCompletion
            _ = preferences.preventsSleepWhileProcessing
        } onChange: {
            changes.increment()
        }
        preferences.languageCode = "system"
        preferences.appearance = "system"
        preferences.automaticallyCheckUpdates = true
        preferences.notifiesOnCompletion = false
        preferences.preventsSleepWhileProcessing = true
        XCTAssertEqual(changes.value, 0)
    }

    func testWorkflowPreferencesNotifyObserversOnlyWhenChanged() {
        let preferences = AppPreferences(defaults: nil)
        let notificationChanges = PreferenceObservationCounter()
        let sleepChanges = PreferenceObservationCounter()
        withObservationTracking { _ = preferences.notifiesOnCompletion } onChange: { notificationChanges.increment() }
        withObservationTracking { _ = preferences.preventsSleepWhileProcessing } onChange: { sleepChanges.increment() }
        preferences.notifiesOnCompletion = true
        XCTAssertEqual(notificationChanges.value, 1)
        XCTAssertEqual(sleepChanges.value, 0)
        preferences.preventsSleepWhileProcessing = false
        XCTAssertEqual(sleepChanges.value, 1)
    }

    func testBackgroundLocalizationReadsDuringLanguageChanges() {
        let preferences = AppPreferences(defaults: nil, systemLanguages: ["en"])
        let readers = DispatchGroup()
        for _ in 0..<4 {
            readers.enter()
            DispatchQueue.global().async {
                defer { readers.leave() }
                for _ in 0..<500 {
                    let localizer = preferences.localizer
                    XCTAssertEqual(localizer.locale.identifier, localizer.language)
                    XCTAssertTrue(AppLocalization.supportedLanguages.contains(localizer.language))
                    _ = localizer.string("图像增强")
                }
            }
        }
        for index in 0..<100 {
            preferences.languageCode = AppLocalization.supportedLanguages[index % AppLocalization.supportedLanguages.count]
        }
        XCTAssertEqual(readers.wait(timeout: .now() + 5), .success)
    }
}

private final class PreferenceObservationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
