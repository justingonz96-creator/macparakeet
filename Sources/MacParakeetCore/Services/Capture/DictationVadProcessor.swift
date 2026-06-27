import FluidAudio
import Foundation

/// Per-session diagnostic counters for the dictation VAD frame processor.
/// Contains no transcript or audio content — only frame/chunk tallies.
/// Mirrors `MeetingEchoSuppressionDiagnostics` in `MicConditioner.swift`.
struct VadProcessingDiagnostics: Sendable, Equatable {
    var processorName: String
    var loaded: Bool
    var samplesAccumulated: Int
    var chunksEmitted: Int
    var oversizedChunksDropped: Int
    var processingFailures: Int

    static func passthrough(
        processorName: String = "passthrough",
        loaded: Bool = true
    ) -> VadProcessingDiagnostics {
        VadProcessingDiagnostics(
            processorName: processorName,
            loaded: loaded,
            samplesAccumulated: 0,
            chunksEmitted: 0,
            oversizedChunksDropped: 0,
            processingFailures: 0
        )
    }
}

/// Splits an arbitrary stream of 16 kHz mono Float32 samples into fixed
/// 4096-sample chunks for Silero VAD. Decision-only: it never touches the WAV
/// writer. Mirrors the `MicConditioning` protocol shape in `MicConditioner.swift`.
protocol DictationVadProcessing: AnyObject, Sendable {
    var diagnostics: VadProcessingDiagnostics { get }
    /// Append converted samples; `emit` is called synchronously, once per
    /// complete 4096-sample chunk, in order. Leftover (< 4096) is retained.
    func accept(samples: [Float], emit: (_ chunk: [Float]) -> Void)
    func reset()
}

/// No-op baseline used whenever VAD is off / unavailable. Never emits a chunk,
/// so the recorder's published snapshot stays `.unavailable` and the endpointer
/// uses the RMS fallback. Matches `PassthroughMicConditioner`.
final class PassthroughDictationVadProcessor: DictationVadProcessing, @unchecked Sendable {
    private let lock = NSLock()
    private var diagnosticsStorage = VadProcessingDiagnostics.passthrough()

    var diagnostics: VadProcessingDiagnostics {
        lock.lock(); defer { lock.unlock() }
        return diagnosticsStorage
    }

    func accept(samples: [Float], emit: (_ chunk: [Float]) -> Void) {}

    func reset() {
        lock.lock(); defer { lock.unlock() }
        diagnosticsStorage = VadProcessingDiagnostics.passthrough()
    }
}
