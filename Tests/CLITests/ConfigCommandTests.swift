import ArgumentParser
import XCTest
@testable import CLI
@testable import MacParakeetCore

final class ConfigCommandTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        // Isolate each test in a unique UserDefaults suite so we never touch
        // the user's real `com.macparakeet.MacParakeet` plist.
        suiteName = "macparakeet.test.config.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - read

    func testSupportedKeysIncludeAgentTranscriptionDefaults() {
        XCTAssertEqual(ConfigCommand.supportedKeys, [
            "telemetry",
            "processing-mode",
            "speech-engine",
            "whisper-language",
            "speaker-detection",
            "save-transcription-audio",
            "youtube-audio-quality",
        ])
    }

    func testReadTelemetryDefaultsToOn() throws {
        // Mirror AppPreferences.isTelemetryEnabled: missing key → on.
        let value = try ConfigCommand.read(key: "telemetry", defaults: defaults)
        XCTAssertEqual(value, "on")
    }

    func testReadTelemetryReflectsExplicitFalse() throws {
        defaults.set(false, forKey: AppPreferences.telemetryEnabledKey)
        XCTAssertEqual(try ConfigCommand.read(key: "telemetry", defaults: defaults), "off")
    }

    func testReadTelemetryReflectsExplicitTrue() throws {
        defaults.set(true, forKey: AppPreferences.telemetryEnabledKey)
        XCTAssertEqual(try ConfigCommand.read(key: "telemetry", defaults: defaults), "on")
    }

    func testReadAgentDefaultsReflectGUIFallbacks() throws {
        XCTAssertEqual(try ConfigCommand.read(key: "processing-mode", defaults: defaults), "raw")
        XCTAssertEqual(try ConfigCommand.read(key: "speech-engine", defaults: defaults), "parakeet")
        XCTAssertEqual(try ConfigCommand.read(key: "whisper-language", defaults: defaults), "auto")
        XCTAssertEqual(try ConfigCommand.read(key: "speaker-detection", defaults: defaults), "off")
        XCTAssertEqual(try ConfigCommand.read(key: "save-transcription-audio", defaults: defaults), "on")
        XCTAssertEqual(try ConfigCommand.read(key: "youtube-audio-quality", defaults: defaults), "m4a")
    }

    func testReadCanonicalizesUnderscoreKeys() throws {
        defaults.set(YouTubeAudioQuality.bestAvailable.rawValue, forKey: UserDefaultsAppRuntimePreferences.youtubeAudioQualityKey)
        XCTAssertEqual(try ConfigCommand.read(key: "youtube_audio_quality", defaults: defaults), "best-available")
    }

    func testCanonicalKeyNormalizesUnderscoreAliases() throws {
        XCTAssertEqual(try ConfigCommand.canonicalKey(" youtube_audio_quality "), "youtube-audio-quality")
        XCTAssertEqual(try ConfigCommand.canonicalKey("SPEAKER_DETECTION"), "speaker-detection")
    }

    func testReadUnknownKeyThrowsValidationError() {
        // Maps to errorType="validation" / exit code 2 in --json failure envelope.
        XCTAssertThrowsError(try ConfigCommand.read(key: "bogus", defaults: defaults)) { error in
            XCTAssertTrue(error is ValidationError, "Expected ValidationError, got \(type(of: error))")
            XCTAssertTrue("\(error)".contains("bogus"))
        }
    }

    // MARK: - write

    func testWriteTelemetryOffPersists() throws {
        let canonical = try ConfigCommand.write(key: "telemetry", value: "off", defaults: defaults)
        XCTAssertEqual(canonical, "off")
        XCTAssertEqual(defaults.object(forKey: AppPreferences.telemetryEnabledKey) as? Bool, false)
    }

    func testWriteTelemetryOnPersists() throws {
        defaults.set(false, forKey: AppPreferences.telemetryEnabledKey)
        let canonical = try ConfigCommand.write(key: "telemetry", value: "on", defaults: defaults)
        XCTAssertEqual(canonical, "on")
        XCTAssertEqual(defaults.object(forKey: AppPreferences.telemetryEnabledKey) as? Bool, true)
    }

    func testWriteAgentTranscriptionDefaultsPersist() throws {
        XCTAssertEqual(try ConfigCommand.write(key: "processing-mode", value: "clean", defaults: defaults), "clean")
        XCTAssertEqual(
            defaults.string(forKey: UserDefaultsAppRuntimePreferences.processingModeKey),
            Dictation.ProcessingMode.clean.rawValue
        )

        XCTAssertEqual(try ConfigCommand.write(key: "speech-engine", value: "whisper", defaults: defaults), "whisper")
        XCTAssertEqual(defaults.string(forKey: SpeechEnginePreference.defaultsKey), SpeechEnginePreference.whisper.rawValue)

        XCTAssertEqual(try ConfigCommand.write(key: "whisper-language", value: "ko", defaults: defaults), "ko")
        XCTAssertEqual(defaults.string(forKey: SpeechEnginePreference.whisperDefaultLanguageKey), "ko")

        XCTAssertEqual(try ConfigCommand.write(key: "speaker-detection", value: "on", defaults: defaults), "on")
        XCTAssertEqual(defaults.object(forKey: UserDefaultsAppRuntimePreferences.speakerDiarizationKey) as? Bool, true)

        XCTAssertEqual(try ConfigCommand.write(key: "save-transcription-audio", value: "off", defaults: defaults), "off")
        XCTAssertEqual(defaults.object(forKey: UserDefaultsAppRuntimePreferences.saveTranscriptionAudioKey) as? Bool, false)

        XCTAssertEqual(try ConfigCommand.write(key: "youtube-audio-quality", value: "best-available", defaults: defaults), "best-available")
        XCTAssertEqual(
            defaults.string(forKey: UserDefaultsAppRuntimePreferences.youtubeAudioQualityKey),
            YouTubeAudioQuality.bestAvailable.rawValue
        )
    }

    func testWriteCanonicalizesUnderscoreKeys() throws {
        XCTAssertEqual(try ConfigCommand.write(key: "speaker_detection", value: "on", defaults: defaults), "on")
        XCTAssertEqual(defaults.object(forKey: UserDefaultsAppRuntimePreferences.speakerDiarizationKey) as? Bool, true)
    }

    func testWriteWhisperLanguageAutoClearsStoredDefault() throws {
        defaults.set("ko", forKey: SpeechEnginePreference.whisperDefaultLanguageKey)

        XCTAssertEqual(try ConfigCommand.write(key: "whisper-language", value: "auto", defaults: defaults), "auto")
        XCTAssertNil(defaults.string(forKey: SpeechEnginePreference.whisperDefaultLanguageKey))
    }

    func testWriteAcceptsAllBoolSynonyms() throws {
        for (synonym, expectedBool) in [
            ("on", true), ("ON", true), ("true", true), ("yes", true),
            ("1", true), ("enable", true), ("enabled", true),
            ("off", false), ("OFF", false), ("false", false), ("no", false),
            ("0", false), ("disable", false), ("disabled", false)
        ] {
            let canonical = try ConfigCommand.write(key: "telemetry", value: synonym, defaults: defaults)
            XCTAssertEqual(canonical, expectedBool ? "on" : "off",
                           "Synonym '\(synonym)' should canonicalize to \(expectedBool ? "on" : "off")")
            XCTAssertEqual(defaults.object(forKey: AppPreferences.telemetryEnabledKey) as? Bool, expectedBool)
        }
    }

    func testWriteRejectsInvalidAgentDefaultValues() {
        XCTAssertThrowsError(try ConfigCommand.write(key: "processing-mode", value: "fancy", defaults: defaults)) { error in
            XCTAssertTrue(error is ValidationError)
        }
        XCTAssertThrowsError(try ConfigCommand.write(key: "speech-engine", value: "cloud", defaults: defaults)) { error in
            XCTAssertTrue(error is ValidationError)
        }
        XCTAssertThrowsError(try ConfigCommand.write(key: "youtube-audio-quality", value: "wav", defaults: defaults)) { error in
            XCTAssertTrue(error is ValidationError)
        }
    }

    func testWriteRejectsInvalidValueAsValidationError() {
        XCTAssertThrowsError(try ConfigCommand.write(key: "telemetry", value: "maybe", defaults: defaults)) { error in
            XCTAssertTrue(error is ValidationError, "Expected ValidationError, got \(type(of: error))")
            XCTAssertTrue("\(error)".contains("maybe"))
        }
        // Defaults must not have been mutated.
        XCTAssertNil(defaults.object(forKey: AppPreferences.telemetryEnabledKey))
    }

    func testWriteUnknownKeyThrowsValidationError() {
        XCTAssertThrowsError(try ConfigCommand.write(key: "bogus", value: "on", defaults: defaults)) { error in
            XCTAssertTrue(error is ValidationError, "Expected ValidationError, got \(type(of: error))")
        }
    }

    // MARK: - parseSpeechEngine

    func testParseSpeechEngineAcceptsNemotron() throws {
        XCTAssertEqual(try ConfigCommand.parseSpeechEngine("nemotron"), .nemotron)
    }

    // MARK: - parseBool

    func testParseBoolRejectsEmpty() {
        XCTAssertThrowsError(try ConfigCommand.parseBool("", key: "telemetry")) { error in
            XCTAssertTrue(error is ValidationError)
        }
    }

    func testParseBoolRejectsWhitespaceOnly() {
        XCTAssertThrowsError(try ConfigCommand.parseBool("   ", key: "telemetry")) { error in
            XCTAssertTrue(error is ValidationError)
        }
    }

    func testParseBoolTrimsNewlines() throws {
        XCTAssertTrue(try ConfigCommand.parseBool("\n on \n", key: "telemetry"))
        XCTAssertFalse(try ConfigCommand.parseBool("\n off \n", key: "telemetry"))
    }
}
