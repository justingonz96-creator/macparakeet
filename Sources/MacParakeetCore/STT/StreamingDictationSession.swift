import Foundation

/// One live dictation session over a `StreamingDictationEngine` (ADR-023).
///
/// Lifecycle: `start(onPartial:)` to install the partial callback, then
/// `append(samples:)` for each chunk of 16 kHz mono audio (which decodes any
/// complete window), and finally `finish()` for the offline-quality result —
/// or `cancel()` to discard. Owned by `STTRuntime`, created per dictation.
///
/// Appends after `finish()`/`cancel()` are dropped so a late mic buffer (the
/// sink fires off the audio queue) can never reopen a closed session.
public actor StreamingDictationSession {
    private let engine: StreamingDictationEngine
    private var isClosed = false

    public init(engine: StreamingDictationEngine) {
        self.engine = engine
    }

    public func start(onPartial: @escaping @Sendable (String) -> Void) async {
        await engine.setPartialTranscriptCallback(onPartial)
    }

    public func append(samples: [Float]) async throws {
        guard !isClosed else { return }
        try await engine.appendAudio(samples: samples)
        try await engine.processBufferedAudio()
    }

    public func finish() async throws -> StreamingDictationResult {
        isClosed = true
        return try await engine.finish()
    }

    public func cancel() async {
        isClosed = true
        try? await engine.reset()
    }
}
