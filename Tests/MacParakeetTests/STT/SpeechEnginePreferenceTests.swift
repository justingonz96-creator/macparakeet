import XCTest
@testable import MacParakeetCore

final class SpeechEnginePreferenceTests: XCTestCase {
    func testFriendlyVariantNameMapsDefaultWhisperVariant() {
        let raw = SpeechEnginePreference.defaultWhisperModelVariant
        XCTAssertEqual(SpeechEnginePreference.friendlyVariantName(raw), "Large v3 Turbo")
    }

    func testFriendlyVariantNameFallsBackToRawForUnknownShape() {
        XCTAssertEqual(
            SpeechEnginePreference.friendlyVariantName("large-v30-experimental-build"),
            "large-v30-experimental-build"
        )
    }

    // MARK: - Whisper optimized-variant tracking

    private func makeIsolatedDefaults() -> (UserDefaults, String) {
        let suite = "test.SpeechEnginePreference.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            fatalError("Could not create isolated UserDefaults suite")
        }
        return (defaults, suite)
    }

    func testWhisperOptimizedDefaultsToFalse() {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertFalse(
            SpeechEnginePreference.hasOptimizedWhisper(
                variant: SpeechEnginePreference.defaultWhisperModelVariant,
                defaults: defaults
            )
        )
    }

    func testMarkWhisperOptimizedRoundTrips() {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let variant = SpeechEnginePreference.defaultWhisperModelVariant
        SpeechEnginePreference.markWhisperOptimized(variant: variant, defaults: defaults)

        XCTAssertTrue(SpeechEnginePreference.hasOptimizedWhisper(variant: variant, defaults: defaults))
    }

    func testMarkWhisperOptimizedIsIdempotent() {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let variant = SpeechEnginePreference.defaultWhisperModelVariant
        SpeechEnginePreference.markWhisperOptimized(variant: variant, defaults: defaults)
        SpeechEnginePreference.markWhisperOptimized(variant: variant, defaults: defaults)

        let stored = defaults.stringArray(forKey: SpeechEnginePreference.whisperOptimizedVariantsKey) ?? []
        XCTAssertEqual(stored, [variant])
    }

    func testWhisperOptimizedNormalizesVariantPrefix() {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        // Marked with the "whisper-" prefix, queried without it (and vice versa).
        let bare = SpeechEnginePreference.defaultWhisperModelVariant
        SpeechEnginePreference.markWhisperOptimized(variant: "whisper-\(bare)", defaults: defaults)

        XCTAssertTrue(SpeechEnginePreference.hasOptimizedWhisper(variant: bare, defaults: defaults))
    }

    func testWhisperOptimizedIsTrackedPerVariant() {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        SpeechEnginePreference.markWhisperOptimized(variant: "large-v3-turbo", defaults: defaults)

        XCTAssertTrue(SpeechEnginePreference.hasOptimizedWhisper(variant: "large-v3-turbo", defaults: defaults))
        XCTAssertFalse(SpeechEnginePreference.hasOptimizedWhisper(variant: "small", defaults: defaults))
    }

    func testColdSwitchOnlyAppliesToUnoptimizedActiveWhisperVariant() {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        SpeechEnginePreference.saveWhisperModelVariant("small", defaults: defaults)

        XCTAssertFalse(SpeechEnginePreference.isColdSwitch(to: .parakeet, defaults: defaults))
        XCTAssertTrue(SpeechEnginePreference.isColdSwitch(to: .whisper, defaults: defaults))

        SpeechEnginePreference.markWhisperOptimized(variant: "small", defaults: defaults)

        XCTAssertFalse(SpeechEnginePreference.isColdSwitch(to: .whisper, defaults: defaults))
    }

    // MARK: - Nemotron (ADR-023)

    func testNemotronDisplayNameAndRawValue() {
        XCTAssertEqual(SpeechEnginePreference.nemotron.rawValue, "nemotron")
        XCTAssertEqual(SpeechEnginePreference.nemotron.displayName, "Nemotron")
        XCTAssertTrue(SpeechEnginePreference.allCases.contains(.nemotron))
    }

    func testAlternativeStaysBinaryWithNemotronMappingToParakeet() {
        XCTAssertEqual(SpeechEnginePreference.parakeet.alternative, .whisper)
        XCTAssertEqual(SpeechEnginePreference.whisper.alternative, .parakeet)
        // New: nemotron's "other engine" is the default, so existing
        // parakeet<->whisper retranscribe behavior is unchanged.
        XCTAssertEqual(SpeechEnginePreference.nemotron.alternative, .parakeet)
    }

    func testNemotronSelectionCarriesEuropeanLanguageOnly() {
        XCTAssertEqual(
            SpeechEngineSelection(engine: .nemotron, language: "fr-FR").language, "fr")
        // Non-European pins are dropped (cannot be honored by the pruned model).
        XCTAssertNil(SpeechEngineSelection(engine: .nemotron, language: "ko").language)
        // Parakeet still never carries a language.
        XCTAssertNil(SpeechEngineSelection(engine: .parakeet, language: "en").language)
    }

    func testNemotronDefaultLanguageRoundTrips() {
        let defaults = UserDefaults(suiteName: "nemotron-lang-test")!
        defaults.removePersistentDomain(forName: "nemotron-lang-test")
        SpeechEnginePreference.saveNemotronDefaultLanguage("de-DE", defaults: defaults)
        XCTAssertEqual(SpeechEnginePreference.nemotronDefaultLanguage(defaults: defaults), "de")
        SpeechEnginePreference.saveNemotronDefaultLanguage("ko", defaults: defaults) // rejected
        XCTAssertNil(SpeechEnginePreference.nemotronDefaultLanguage(defaults: defaults))
    }
}
