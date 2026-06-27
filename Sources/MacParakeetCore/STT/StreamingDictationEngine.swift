import Foundation

/// Final result of a live streaming dictation session (ADR-023).
///
/// `text` is the engine's flushed transcript; `words` carries per-word timings
/// when the engine provides them (Parakeet Unified exposes per-token timings),
/// otherwise it is empty and downstream duration falls back to a word-count
/// estimate — see `DictationService.computeDurationMs`.
public struct StreamingDictationResult: Sendable {
    public let text: String
    public let words: [TimestampedWord]

    public init(text: String, words: [TimestampedWord] = []) {
        self.text = text
        self.words = words
    }
}

/// Core-owned seam over a real-time, partial-results speech engine (ADR-023 §5).
///
/// This protocol is the single mockable boundary for live streaming dictation:
/// `STTRuntime` depends on it, never on the concrete FluidAudio actor, so CI
/// exercises a mock and the real CoreML model is never run in tests (matching
/// the `AsrManager` posture).
///
/// Audio crosses the boundary as 16 kHz mono Float32 `[Float]` samples — a
/// `Sendable` value type — rather than `AVAudioPCMBuffer`, so feeding the engine
/// from an actor needs no `@unchecked Sendable` wrapper and no buffer-lifetime
/// reasoning. The concrete adapter rebuilds whatever buffer its backend wants.
public protocol StreamingDictationEngine: Sendable {
    /// Download (if needed) and load the streaming model into memory. Idempotent
    /// after a successful first call. Reports human-readable progress.
    func prepare(onProgress: (@Sendable (String) -> Void)?) async throws

    /// Whether the model is loaded and ready to transcribe right now.
    func isReady() async -> Bool

    /// Install the callback invoked whenever the partial transcript advances.
    /// The callback is `@Sendable` and may fire on the engine's executor — the
    /// consumer is responsible for hopping to its own isolation domain.
    func setPartialTranscriptCallback(_ callback: @escaping @Sendable (String) -> Void) async

    /// Append 16 kHz mono Float32 samples to the engine's rolling buffer.
    func appendAudio(samples: [Float]) async throws

    /// Decode whatever complete chunks the buffered audio now allows. Cheap when
    /// no full chunk is ready yet.
    func processBufferedAudio() async throws

    /// Flush remaining audio and return the final transcript.
    func finish() async throws -> StreamingDictationResult

    /// Clear decode + buffer state for a new session. Models stay loaded.
    func reset() async throws

    /// Release loaded models and free memory.
    func cleanup() async
}
