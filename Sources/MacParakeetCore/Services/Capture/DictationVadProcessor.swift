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

    static func passthrough(
        processorName: String = "passthrough",
        loaded: Bool = true
    ) -> VadProcessingDiagnostics {
        VadProcessingDiagnostics(
            processorName: processorName,
            loaded: loaded,
            samplesAccumulated: 0,
            chunksEmitted: 0
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

/// Accumulates 16 kHz mono samples and emits exactly-4096-sample chunks
/// (256 ms) for Silero VAD. Single-threaded by contract: the recorder calls
/// `accept` only on the serial `sharedProcessingQueue`, so no internal lock is
/// needed for the buffer (the diagnostics lock guards cross-thread reads only).
final class StreamingDictationVadProcessor: DictationVadProcessing, @unchecked Sendable {
    static let chunkSize = VadManager.chunkSize // 4096

    private var accumulator: [Float] = []
    private let lock = NSLock()
    private var diagnosticsStorage = VadProcessingDiagnostics(
        processorName: "silero-vad-v6",
        loaded: true,
        samplesAccumulated: 0,
        chunksEmitted: 0
    )

    var diagnostics: VadProcessingDiagnostics {
        lock.lock(); defer { lock.unlock() }
        return diagnosticsStorage
    }

    func accept(samples: [Float], emit: (_ chunk: [Float]) -> Void) {
        guard !samples.isEmpty else { return }
        accumulator.append(contentsOf: samples)

        var chunksThisCall = 0
        while accumulator.count >= Self.chunkSize {
            // `Array(prefix)` copies; never pass more than chunkSize (Silero
            // silently truncates oversized chunks, which would desync timing).
            let chunk = Array(accumulator.prefix(Self.chunkSize))
            accumulator.removeFirst(Self.chunkSize)
            chunksThisCall += 1
            emit(chunk)
        }

        // Single lock per call (never held across `emit`): bump both counters
        // once, mirroring how the meeting suppressor batches its diagnostics.
        lock.lock()
        diagnosticsStorage.samplesAccumulated += samples.count
        diagnosticsStorage.chunksEmitted += chunksThisCall
        lock.unlock()
    }

    func reset() {
        accumulator.removeAll(keepingCapacity: true)
        lock.lock(); defer { lock.unlock() }
        diagnosticsStorage = VadProcessingDiagnostics(
            processorName: "silero-vad-v6",
            loaded: true,
            samplesAccumulated: 0,
            chunksEmitted: 0
        )
    }
}
