import Foundation

/// Structured progress updates emitted by TranscriptionService.
/// The UI layer converts these to display strings — the service never emits human-readable text.
public enum TranscriptionProgress: Sendable {
    case converting
    case downloading(percent: Int)
    case transcribing(percent: Int)
    case identifyingSpeakers
    case finalizing
    /// Speech engine is preparing (loading model, Core ML compilation, etc.).
    /// The optional `message` carries human-readable status emitted by the
    /// engine's warm-up watchdog — used to keep the UI alive during long
    /// first-load CoreML compiles (5–10 minutes for Whisper Turbo after
    /// each install because the cache is keyed by code signature).
    case preparingSpeechModel(message: String?)

    /// The progress fraction (0.0–1.0) if this phase carries a percentage.
    public var fraction: Double? {
        switch self {
        case .downloading(let percent), .transcribing(let percent):
            return min(Double(percent), 100) / 100
        case .converting, .identifyingSpeakers, .finalizing, .preparingSpeechModel:
            return nil
        }
    }
}
