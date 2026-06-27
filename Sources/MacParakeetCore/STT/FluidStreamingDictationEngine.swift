@preconcurrency import AVFoundation
import FluidAudio
import Foundation
import os

/// Concrete `StreamingDictationEngine` over FluidAudio's
/// `StreamingUnifiedAsrManager` (Parakeet Unified 0.6B, English-only — repo
/// `FluidInference/parakeet-unified-en-0.6b-coreml`). ADR-023.
///
/// This is trusted boundary code, excluded from CI like the batch `AsrManager`
/// and `WhisperEngine` adapters — the real CoreML model is never run in tests
/// (`STTRuntime` injects a mock through the `StreamingDictationEngine` seam).
public actor FluidStreamingDictationEngine: StreamingDictationEngine {
    private let logger = Logger(subsystem: "com.macparakeet.core", category: "FluidStreamingDictation")
    private let manager: StreamingUnifiedAsrManager
    private var ready = false

    public init() {
        // Default int8 encoder on CPU+ANE (FluidAudio coerces int8 off the GPU);
        // default 70/13/13 context ≈ 2.08 s best-WER streaming latency.
        self.manager = StreamingUnifiedAsrManager()
    }

    public func prepare(onProgress: (@Sendable (String) -> Void)?) async throws {
        let handler: DownloadUtils.ProgressHandler? = onProgress.map { callback in
            let sendable: @Sendable (DownloadUtils.DownloadProgress) -> Void = { progress in
                if let message = Self.progressMessage(from: progress) { callback(message) }
            }
            return sendable
        }
        do {
            try await manager.loadModels(to: nil, configuration: nil, progressHandler: handler)
            ready = true
            onProgress?("Ready")
        } catch {
            ready = false
            throw error
        }
    }

    public func isReady() async -> Bool { ready }

    public func setPartialTranscriptCallback(_ callback: @escaping @Sendable (String) -> Void) async {
        await manager.setPartialTranscriptCallback(callback)
    }

    public func appendAudio(samples: [Float]) async throws {
        guard !samples.isEmpty else { return }
        let buffer = try Self.makeBuffer(from: samples)
        try await manager.appendAudio(buffer)
    }

    public func processBufferedAudio() async throws {
        try await manager.processBufferedAudio()
    }

    public func finish() async throws -> StreamingDictationResult {
        let text = try await manager.finish()
        let timings = await manager.consumeTokenTimings()
        return StreamingDictationResult(text: text, words: ParakeetTokenTimingMerger.merge(timings))
    }

    public func reset() async throws {
        try await manager.reset()
    }

    public func cleanup() async {
        await manager.cleanup()
        ready = false
    }

    // MARK: - Helpers

    /// Wrap 16 kHz mono Float32 samples in an `AVAudioPCMBuffer`. The manager
    /// resamples internally, but we already hand it the model's native rate so
    /// the resample is a no-op.
    private static func makeBuffer(from samples: [Float]) throws -> AVAudioPCMBuffer {
        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16_000,
                channels: 1,
                interleaved: false
            ),
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(samples.count)
            )
        else {
            throw STTError.transcriptionFailed("Failed to build streaming audio buffer")
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let channel = buffer.floatChannelData {
            samples.withUnsafeBufferPointer { pointer in
                if let base = pointer.baseAddress {
                    channel[0].update(from: base, count: samples.count)
                }
            }
        }
        return buffer
    }

    private static func progressMessage(from progress: DownloadUtils.DownloadProgress) -> String? {
        switch progress.phase {
        case .listing:
            return "Preparing live dictation model download..."
        case .downloading(let completedFiles, let totalFiles):
            guard totalFiles > 0 else { return nil }
            let percent = max(0, min(100, Int(progress.fractionCompleted * 100.0)))
            return "Downloading live dictation model... \(percent)% (\(completedFiles)/\(totalFiles))"
        case .compiling:
            return "Compiling live dictation model..."
        }
    }
}
