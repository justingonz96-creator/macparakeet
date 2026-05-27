import Foundation
import XCTest

@testable import MacParakeetCore

final class AppRuntimePreferencesTests: XCTestCase {
    private func makePreferences() -> UserDefaultsAppRuntimePreferences {
        UserDefaultsAppRuntimePreferences(
            defaults: UserDefaults(suiteName: "app-runtime-prefs-\(UUID().uuidString)")!
        )
    }

    func testMarkFirstDictationCompletedReturnsTrueOnlyOnFirstTransition() {
        let preferences = makePreferences()
        XCTAssertFalse(preferences.hasCompletedFirstDictation)

        // First call flips the flag and reports the transition so the caller
        // can fire the one-shot activation telemetry event.
        XCTAssertTrue(preferences.markFirstDictationCompleted())
        XCTAssertTrue(preferences.hasCompletedFirstDictation)

        // Every subsequent call is a no-op and reports no transition.
        XCTAssertFalse(preferences.markFirstDictationCompleted())
        XCTAssertFalse(preferences.markFirstDictationCompleted())
        XCTAssertTrue(preferences.hasCompletedFirstDictation)
    }

    func testFirstDictationFlagPersistsAcrossInstances() {
        let suite = "app-runtime-prefs-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!

        let first = UserDefaultsAppRuntimePreferences(defaults: defaults)
        XCTAssertTrue(first.markFirstDictationCompleted())

        // A fresh instance over the same store already sees the flag set, so a
        // user who has dictated before never re-emits the activation event.
        let second = UserDefaultsAppRuntimePreferences(defaults: defaults)
        XCTAssertTrue(second.hasCompletedFirstDictation)
        XCTAssertFalse(second.markFirstDictationCompleted())
    }

    func testPauseMediaDuringDictationDefaultsToFalseAndReadsPersistedValue() {
        let suite = "app-runtime-prefs-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertFalse(UserDefaultsAppRuntimePreferences(defaults: defaults).pauseMediaDuringDictation)

        defaults.set(true, forKey: UserDefaultsAppRuntimePreferences.pauseMediaDuringDictationKey)

        XCTAssertTrue(UserDefaultsAppRuntimePreferences(defaults: defaults).pauseMediaDuringDictation)
    }

    // MARK: - NumberRefinementMode migration

    func testNumberRefinementModeMigratesLegacyTrueToDeterministic() {
        let suite = "app-runtime-prefs-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(true, forKey: UserDefaultsAppRuntimePreferences.numberNormalizationEnabledKey)

        let prefs = UserDefaultsAppRuntimePreferences(defaults: defaults)
        XCTAssertEqual(prefs.numberRefinementMode, .deterministic)

        // Legacy key is consumed; new key holds the value.
        XCTAssertNil(defaults.object(forKey: UserDefaultsAppRuntimePreferences.numberNormalizationEnabledKey))
        XCTAssertEqual(
            defaults.string(forKey: UserDefaultsAppRuntimePreferences.numberRefinementModeKey),
            "deterministic"
        )
    }

    func testNumberRefinementModeMigratesLegacyFalseToOff() {
        let suite = "app-runtime-prefs-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(false, forKey: UserDefaultsAppRuntimePreferences.numberNormalizationEnabledKey)

        let prefs = UserDefaultsAppRuntimePreferences(defaults: defaults)
        XCTAssertEqual(prefs.numberRefinementMode, .off)
        XCTAssertNil(defaults.object(forKey: UserDefaultsAppRuntimePreferences.numberNormalizationEnabledKey))
    }

    func testNumberRefinementModeMigratesAbsentLegacyToOff() {
        let suite = "app-runtime-prefs-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let prefs = UserDefaultsAppRuntimePreferences(defaults: defaults)
        XCTAssertEqual(prefs.numberRefinementMode, .off)
    }

    func testNumberRefinementModeUsesNewKeyWhenAlreadySet() {
        let suite = "app-runtime-prefs-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        // New key set to .smart; legacy key set to true — fast path should
        // ignore the legacy key entirely.
        defaults.set("smart", forKey: UserDefaultsAppRuntimePreferences.numberRefinementModeKey)
        defaults.set(true, forKey: UserDefaultsAppRuntimePreferences.numberNormalizationEnabledKey)

        let prefs = UserDefaultsAppRuntimePreferences(defaults: defaults)
        XCTAssertEqual(prefs.numberRefinementMode, .smart)

        // Legacy key is untouched on the fast path.
        XCTAssertEqual(
            defaults.object(forKey: UserDefaultsAppRuntimePreferences.numberNormalizationEnabledKey) as? Bool,
            true
        )
    }
}
