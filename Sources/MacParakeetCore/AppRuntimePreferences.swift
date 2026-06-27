import Foundation

public protocol AppRuntimePreferencesProtocol: Sendable {
    var processingMode: Dictation.ProcessingMode { get }
    var voiceReturnTrigger: String? { get }
    var shouldSaveAudioRecordings: Bool { get }
    var shouldSaveDictationHistory: Bool { get }
    var shouldSaveTranscriptionAudio: Bool { get }
    var youtubeAudioQuality: YouTubeAudioQuality { get }
    var shouldDiarize: Bool { get }
    var aiFormatterEnabled: Bool { get }
    var aiFormatterPrompt: String { get }
    var numberNormalizationEnabled: Bool { get }
    var numberRefinementMode: NumberRefinementMode { get }
    var selectedMicrophoneDeviceUID: String? { get }
    var meetingAudioSourceMode: MeetingAudioSourceMode { get }
    var pauseMediaDuringDictation: Bool { get }
    /// Opt-in live streaming dictation (ADR-023). When `true` (and
    /// `AppFeatures.liveDictationEnabled` exposes the toggle), dictation runs
    /// through the Parakeet Unified streaming engine so partial text appears
    /// as the user speaks. Default `false` — strictly opt-in, English-only.
    var liveDictationEnabled: Bool { get }
    var hasCompletedFirstDictation: Bool { get }
    /// Flip the one-shot "first dictation completed" flag. Returns `true` only
    /// the first time it transitions (so callers can fire a one-shot side
    /// effect like the activation telemetry event); `false` on every
    /// subsequent call.
    @discardableResult
    func markFirstDictationCompleted() -> Bool
}

public enum YouTubeAudioQuality: String, CaseIterable, Hashable, Sendable, Equatable {
    case m4a
    case bestAvailable = "best_available"

    public var displayTitle: String {
        switch self {
        case .m4a:
            return "M4A"
        case .bestAvailable:
            return "Best available"
        }
    }

    public var detail: String {
        switch self {
        case .m4a:
            return "Download an Apple-friendly m4a file. Smaller and slightly faster; transcripts are close to Best available for most videos."
        case .bestAvailable:
            return "YouTube's highest-quality audio stream — recommended when transcription accuracy matters most (issue #237 measured ~10% lower WER on a Stanford speech). WebM/Opus downloads are converted to m4a in the background so the in-app audio scrubber works."
        }
    }

    public var ytDlpFormatSelector: String {
        switch self {
        case .m4a:
            return "bestaudio[ext=m4a]/bestaudio/best"
        case .bestAvailable:
            return "bestaudio/best"
        }
    }

    public static func current(defaults: UserDefaults = .standard) -> YouTubeAudioQuality {
        guard let raw = defaults.string(forKey: UserDefaultsAppRuntimePreferences.youtubeAudioQualityKey),
              let quality = YouTubeAudioQuality(rawValue: raw) else {
            return .m4a
        }
        return quality
    }
}

public enum MeetingAudioSourceMode: String, CaseIterable, Hashable, Sendable, Equatable {
    case microphoneAndSystem = "microphone_and_system"
    case systemOnly = "system_only"

    public var capturesMicrophone: Bool {
        self == .microphoneAndSystem
    }

    public var displayTitle: String {
        switch self {
        case .microphoneAndSystem:
            return "Microphone + System Audio"
        case .systemOnly:
            return "System Audio Only"
        }
    }

    public var detail: String {
        switch self {
        case .microphoneAndSystem:
            return "Capture your microphone and computer audio. Weak mic bleed is suppressed live."
        case .systemOnly:
            return "Capture computer audio for meetings. Your microphone is still used for dictation."
        }
    }

    public static func current(defaults: UserDefaults = .standard) -> MeetingAudioSourceMode {
        guard let raw = defaults.string(forKey: UserDefaultsAppRuntimePreferences.meetingAudioSourceModeKey),
              let mode = MeetingAudioSourceMode(rawValue: raw) else {
            return .microphoneAndSystem
        }
        return mode
    }
}

/// User-selectable number-formatting tier (Vocabulary > Numbers card, now in AI tab).
///
/// - `off`: leave numbers as the speech engine wrote them.
/// - `deterministic`: run `NumberNormalizer` (rules-based, fast, on-device).
/// - `smart`: run `NumberNormalizer` first, then ask the configured LLM to
///   polish years, decimals, large cardinals, and clock times that the rules
///   miss. Falls back silently to `deterministic` behavior when no LLM
///   provider is configured or the call fails. See
///   `Sources/MacParakeetCore/Services/NumberLLMRefiner.swift`.
///
/// Smart only runs in file/meeting transcription paths. `DictationService`
/// reads this preference but collapses `smart` to `deterministic` because
/// the LLM round-trip would add visible paste latency to dictation.
public enum NumberRefinementMode: String, CaseIterable, Hashable, Sendable, Equatable {
    case off
    case deterministic
    case smart

    public var displayTitle: String {
        switch self {
        case .off: return "Off"
        case .deterministic: return "Deterministic"
        case .smart: return "Smart"
        }
    }

    public var detail: String {
        switch self {
        case .off:
            return "Numbers stay exactly as the speech engine wrote them."
        case .deterministic:
            return "Fast on-device rules convert spelled numbers to digits (\"twenty-five\" → \"25\"). No AI needed."
        case .smart:
            return "Runs the rules, then your AI provider polishes harder cases (years, decimals, large numbers). Falls back to Deterministic if your AI provider isn't set up."
        }
    }

    public static func current(defaults: UserDefaults = .standard) -> NumberRefinementMode {
        guard let raw = defaults.string(forKey: UserDefaultsAppRuntimePreferences.numberRefinementModeKey),
              let mode = NumberRefinementMode(rawValue: raw) else {
            return .off
        }
        return mode
    }
}

public final class UserDefaultsAppRuntimePreferences: AppRuntimePreferencesProtocol, @unchecked Sendable {
    public static let showIdlePillKey = "showIdlePill"
    public static let silenceAutoStopKey = "silenceAutoStop"
    public static let silenceDelayKey = "silenceDelay"
    public static let voiceReturnEnabledKey = "voiceReturnEnabled"
    public static let voiceReturnTriggerKey = "voiceReturnTrigger"
    public static let processingModeKey = "processingMode"
    public static let saveDictationHistoryKey = "saveDictationHistory"
    public static let saveAudioRecordingsKey = "saveAudioRecordings"
    public static let saveTranscriptionAudioKey = "saveTranscriptionAudio"
    public static let youtubeAudioQualityKey = "youtubeAudioQuality"
    public static let speakerDiarizationKey = "speakerDiarization"
    public static let aiFormatterEnabledKey = "aiFormatterEnabled"
    public static let aiFormatterPromptKey = "aiFormatterPrompt"
    public static let numberNormalizationEnabledKey = "numberNormalizationEnabled"
    public static let numberRefinementModeKey = "numberRefinementMode"
    public static let selectedMicrophoneDeviceUIDKey = "selectedMicrophoneDeviceUID"
    public static let meetingAudioSourceModeKey = "meetingAudioSourceMode"
    public static let pauseMediaDuringDictationKey = "pauseMediaDuringDictation"
    public static let liveDictationEnabledKey = "liveDictationEnabled"
    public static let hasCompletedFirstDictationKey = "hasCompletedFirstDictation"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var processingMode: Dictation.ProcessingMode {
        let raw = defaults.string(forKey: Self.processingModeKey)
        return Dictation.ProcessingMode(rawValue: raw ?? Dictation.ProcessingMode.raw.rawValue) ?? .raw
    }

    public var voiceReturnTrigger: String? {
        guard defaults.bool(forKey: Self.voiceReturnEnabledKey) else { return nil }
        let trigger = (defaults.string(forKey: Self.voiceReturnTriggerKey) ?? "press return")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trigger.isEmpty ? nil : trigger
    }

    public var shouldSaveAudioRecordings: Bool {
        defaults.object(forKey: Self.saveAudioRecordingsKey) as? Bool ?? true
    }

    public var shouldSaveDictationHistory: Bool {
        defaults.object(forKey: Self.saveDictationHistoryKey) as? Bool ?? true
    }

    public var shouldSaveTranscriptionAudio: Bool {
        defaults.object(forKey: Self.saveTranscriptionAudioKey) as? Bool ?? true
    }

    public var youtubeAudioQuality: YouTubeAudioQuality {
        YouTubeAudioQuality.current(defaults: defaults)
    }

    public var shouldDiarize: Bool {
        defaults.object(forKey: Self.speakerDiarizationKey) as? Bool ?? false
    }

    public var aiFormatterEnabled: Bool {
        defaults.object(forKey: Self.aiFormatterEnabledKey) as? Bool ?? false
    }

    public var aiFormatterPrompt: String {
        let prompt = defaults.string(forKey: Self.aiFormatterPromptKey) ?? ""
        return AIFormatter.normalizedPromptTemplate(prompt)
    }

    public var numberNormalizationEnabled: Bool {
        defaults.object(forKey: Self.numberNormalizationEnabledKey) as? Bool ?? false
    }

    /// Three-state number formatting preference. The first read after upgrading
    /// from a build that used the legacy `numberNormalizationEnabled` bool
    /// migrates it (`true → .deterministic`, `false → .off`) and removes the
    /// old key. Subsequent reads take the fast path.
    public var numberRefinementMode: NumberRefinementMode {
        if let raw = defaults.string(forKey: Self.numberRefinementModeKey),
           let mode = NumberRefinementMode(rawValue: raw) {
            return mode
        }
        // One-shot migration from the legacy bool key.
        let legacy = defaults.object(forKey: Self.numberNormalizationEnabledKey) as? Bool
        let migrated: NumberRefinementMode = (legacy == true) ? .deterministic : .off
        defaults.set(migrated.rawValue, forKey: Self.numberRefinementModeKey)
        defaults.removeObject(forKey: Self.numberNormalizationEnabledKey)
        return migrated
    }

    public var selectedMicrophoneDeviceUID: String? {
        AudioDeviceManager.normalizedUID(defaults.string(forKey: Self.selectedMicrophoneDeviceUIDKey))
    }

    public var meetingAudioSourceMode: MeetingAudioSourceMode {
        MeetingAudioSourceMode.current(defaults: defaults)
    }

    public var pauseMediaDuringDictation: Bool {
        defaults.object(forKey: Self.pauseMediaDuringDictationKey) as? Bool ?? false
    }

    public var liveDictationEnabled: Bool {
        defaults.object(forKey: Self.liveDictationEnabledKey) as? Bool ?? false
    }

    public var hasCompletedFirstDictation: Bool {
        defaults.bool(forKey: Self.hasCompletedFirstDictationKey)
    }

    @discardableResult
    public func markFirstDictationCompleted() -> Bool {
        guard !hasCompletedFirstDictation else { return false }
        defaults.set(true, forKey: Self.hasCompletedFirstDictationKey)
        return true
    }
}
