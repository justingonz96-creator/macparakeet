import Foundation

/// Phase-2 placeholder. The grammatical-completeness layer (spec §8) will
/// replace this with the real veto payload
/// (`{ verdict, modelEouSignaled, generatedAt, sessionID }`). Phase 1 never
/// reads it; it exists only so `DictationEndpointer.Input.completenessVeto`
/// type-checks and the interface is stable across PRs.
public struct CompletenessVeto: Sendable, Equatable {
    public init() {}
}

/// Pure, unit-testable "is the user done speaking?" decision for dictation.
///
/// Sibling of `DictationStopDecision` — the exact precedent in this folder
/// (a pure value type with a focused test). No clock, no async, no I/O: the
/// caller injects time through `Input.now` and `Input.vadSilenceElapsed`, so
/// every branch is deterministically testable.
///
/// Phase 1 (this cycle) implements two paths:
///   1. VAD path (when `Input.vadAvailable`): stop after `silenceDuration`
///      of VAD-judged silence, measured from `lastSpeechAt` once the user has
///      spoken. If the user never speaks this session (`vadSilenceElapsed ==
///      nil`), silence is measured from recording start (`Input.elapsed`) so a
///      fully silent hands-free session still auto-stops, matching the RMS path.
///   2. RMS fallback path (when VAD is unavailable): reproduce today's exact
///      energy-gate arithmetic — `audioLevel >= rmsThreshold` resets the
///      silence timer; otherwise stop once `silenceDuration` has elapsed.
///
/// The Phase-2 fields (`completenessEnabled`, `extensionMaxWait`,
/// `completenessVeto`) are present so the interface is stable, but
/// `evaluate(_:)` ignores them in Phase 1.
public struct DictationEndpointer: Sendable {

    public struct Config: Sendable, Equatable {
        /// `silenceAutoStop && recordingMode == .persistent`. When false,
        /// `evaluate(_:)` never returns `.stop` — push-to-talk (hold) and the
        /// opt-out default both flow through here.
        public var enabled: Bool
        /// Reinterpreted `silenceDelay`: duration of VAD-judged (or, in
        /// fallback, RMS-judged) silence before auto-stop.
        public var silenceDuration: TimeInterval
        /// Fallback energy gate — today's `silenceAutoStopThreshold` (0.03).
        public var rmsThreshold: Float
        // Phase-2 fields: present so the interface is stable; unused in Phase 1.
        public var completenessEnabled: Bool
        /// Extension-window bound (NOT total elapsed). See spec §8.4. Phase 2.
        public var extensionMaxWait: TimeInterval

        public init(
            enabled: Bool,
            silenceDuration: TimeInterval,
            rmsThreshold: Float = 0.03,
            completenessEnabled: Bool = false,
            extensionMaxWait: TimeInterval = 0
        ) {
            self.enabled = enabled
            self.silenceDuration = silenceDuration
            self.rmsThreshold = rmsThreshold
            self.completenessEnabled = completenessEnabled
            self.extensionMaxWait = extensionMaxWait
        }
    }

    public struct Input: Sendable, Equatable {
        /// Wall-clock at this tick (injected; never read from a global clock).
        public var now: Date
        /// Seconds since recording began. Phase-1 `evaluate` does not read it;
        /// it exists for the Phase-2 extension-window math.
        public var elapsed: TimeInterval
        /// Smoothed mic energy (the value already fed to the waveform).
        public var audioLevel: Float
        /// False ⇒ use the RMS fallback path (today's behavior).
        public var vadAvailable: Bool
        /// VAD verdict for this tick: speech vs. silence.
        public var speechActive: Bool
        /// `now − lastSpeechAt`; nil if the user never spoke yet.
        public var vadSilenceElapsed: TimeInterval?
        /// Phase-2 pre-arrived completeness verdict; nil in Phase 1.
        public var completenessVeto: CompletenessVeto?

        public init(
            now: Date,
            elapsed: TimeInterval,
            audioLevel: Float,
            vadAvailable: Bool,
            speechActive: Bool,
            vadSilenceElapsed: TimeInterval?,
            completenessVeto: CompletenessVeto? = nil
        ) {
            self.now = now
            self.elapsed = elapsed
            self.audioLevel = audioLevel
            self.vadAvailable = vadAvailable
            self.speechActive = speechActive
            self.vadSilenceElapsed = vadSilenceElapsed
            self.completenessVeto = completenessVeto
        }
    }

    public enum Decision: Sendable, Equatable {
        case keepListening
        case stop(reason: StopReason)
    }

    public enum StopReason: Sendable, Equatable {
        case vadSilence
        case rmsSilence
        case grammaticallyComplete   // Phase 2
        case extensionMaxWait        // Phase 2
    }

    private let config: Config

    /// Mirrors today's `var lastNonSilenceAt = Date()` seeded before the loop.
    /// nil until the first `evaluate` call, then pinned to that first `now`
    /// (or refreshed whenever the RMS gate sees non-silence). Only the RMS
    /// fallback path uses this; the VAD path trusts `Input.vadSilenceElapsed`.
    private var lastNonSilenceAt: Date?

    /// One-stop latch: today's `var didAutoStop = false` ensured a single stop
    /// per session. Once we return `.stop`, every later tick is `.keepListening`.
    private var didStop = false

    public init(config: Config) {
        self.config = config
    }

    public mutating func evaluate(_ input: Input) -> Decision {
        // Disabled ⇒ never auto-stop (push-to-talk hold, or opt-out default).
        guard config.enabled else { return .keepListening }
        // One stop per session.
        guard !didStop else { return .keepListening }

        if input.vadAvailable {
            // VAD path: stop after `silenceDuration` of VAD-judged silence.
            // The caller owns `lastSpeechAt`; we read the derived elapsed.
            if !input.speechActive {
                if let silenceElapsed = input.vadSilenceElapsed {
                    if silenceElapsed >= config.silenceDuration {
                        didStop = true
                        return .stop(reason: .vadSilence)
                    }
                } else if input.elapsed >= config.silenceDuration {
                    // No speech ever detected this session: measure silence from
                    // recording start, matching the RMS path's "silent session
                    // still auto-stops" behavior.
                    didStop = true
                    return .stop(reason: .vadSilence)
                }
            }
            return .keepListening
        }

        // RMS fallback path — reproduce today's exact arithmetic:
        //   level >= threshold  -> reset the silence timer
        //   else if elapsed >= silenceDuration -> stop
        // Seed the timer on the first tick, matching today's
        // `var lastNonSilenceAt = Date()` set immediately before the loop.
        let anchor = lastNonSilenceAt ?? input.now
        if input.audioLevel >= config.rmsThreshold {
            lastNonSilenceAt = input.now
            return .keepListening
        }
        if input.now.timeIntervalSince(anchor) >= config.silenceDuration {
            didStop = true
            return .stop(reason: .rmsSilence)
        }
        // Not yet silent long enough: remember the anchor for next tick.
        lastNonSilenceAt = anchor
        return .keepListening
    }
}
