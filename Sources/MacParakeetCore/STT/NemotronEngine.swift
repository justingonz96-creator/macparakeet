import FluidAudio
import Foundation
import OSLog

/// Optional, opt-in STT engine for European/Latin-script audio (ADR-023).
/// Wraps FluidAudio's `StreamingNemotronMultilingualAsrManager`, driven in a
/// feed-whole-file-then-finish pattern so it satisfies Echo's batch contract.
/// Mirrors `WhisperEngine`'s structure (serialized via `AsyncPermit`).
public actor NemotronEngine: STTTranscribing {
    private let logger = Logger(subsystem: "com.macparakeet.core", category: "NemotronEngine")

    /// Always fetch the Latin-script-pruned subtree, regardless of the user's
    /// language pin — passing "auto" to FluidAudio would download the heavy
    /// multilingual model. `languageDirectory(for:)` maps any of the six
    /// European codes to the `latin/` subtree, so "en" is a safe router.
    /// See ADR-023 §4.
    public static let downloadRoutingLanguage = "en"
    /// Batch default chunk tier. The published variant subtree is
    /// `latin/<chunkMs>ms` (confirmed against FluidAudio v0.15.4 source).
    public static let defaultChunkMs = 2240
    public static let variantLabel = "nemotron-european"

    private let defaultLanguage: String?   // canonical European code, or nil = auto-within-latin
    private let downloadBase: URL
    private let chunkMs: Int
    private let transcriptionPermit = AsyncPermit()

    private var manager: StreamingNemotronMultilingualAsrManager?
    private var isLoaded = false

    public init(
        language: String? = nil,
        downloadBase: URL? = nil,
        chunkMs: Int = NemotronEngine.defaultChunkMs
    ) {
        self.defaultLanguage = SpeechEnginePreference.normalizeNemotronLanguage(language)
        self.downloadBase = downloadBase ?? Self.defaultDownloadBase
        self.chunkMs = chunkMs
    }

    public static var defaultDownloadBase: URL {
        URL(fileURLWithPath: AppPaths.nemotronModelsDir, isDirectory: true)
    }

    /// Local folder for the pruned `latin/<chunkMs>ms` variant, or nil if absent.
    /// FluidAudio lands files under `<downloadBase>/<repoFolder>/latin/<chunkMs>ms/`.
    /// `repoFolder` ("nemotron-multilingual") confirmed against
    /// `Repo.nemotronMultilingual.folderName` in FluidAudio v0.15.4.
    public static func localModelFolder(
        downloadBase: URL = NemotronEngine.defaultDownloadBase,
        chunkMs: Int = NemotronEngine.defaultChunkMs
    ) -> URL? {
        let dir = downloadBase
            .appendingPathComponent("nemotron-multilingual", isDirectory: true)
            .appendingPathComponent("latin", isDirectory: true)
            .appendingPathComponent("\(chunkMs)ms", isDirectory: true)
        return FileManager.default.fileExists(atPath: dir.path) ? dir : nil
    }

    public static func isModelDownloaded(
        downloadBase: URL = NemotronEngine.defaultDownloadBase,
        chunkMs: Int = NemotronEngine.defaultChunkMs
    ) -> Bool {
        localModelFolder(downloadBase: downloadBase, chunkMs: chunkMs) != nil
    }

    /// Group per-sub-word `TokenTiming`s into word-level `TimestampedWord`s by the
    /// SentencePiece word-boundary marker (▁). Timing is encoder-frame-coarse and
    /// confidence is FluidAudio's hardcoded 1.0 placeholder (ADR-023 §5) — we pass
    /// it through as a sentinel, not a real probability. Pure + testable.
    public static func mapTokenTimings(_ timings: [TokenTiming]) -> [TimestampedWord] {
        let marker = "\u{2581}"
        var words: [TimestampedWord] = []
        var current: (text: String, start: Int, end: Int)?

        func flush() {
            if let c = current, !c.text.isEmpty {
                words.append(TimestampedWord(
                    word: c.text, startMs: c.start, endMs: max(c.start, c.end), confidence: 1.0))
            }
            current = nil
        }

        for t in timings {
            let startsWord = t.token.hasPrefix(marker)
            let clean = t.token.replacingOccurrences(of: marker, with: "")
            let startMs = Int((max(0, t.startTime) * 1_000).rounded())
            let endMs = Int((max(0, t.endTime) * 1_000).rounded())
            if startsWord || current == nil {
                flush()
                current = (clean, startMs, endMs)
            } else {
                current?.text += clean
                current?.end = endMs
            }
        }
        flush()
        return words
    }

    public func isReady() -> Bool { isLoaded && manager != nil }

    /// `STTTranscribing` conformance — transcribes with this engine's
    /// construction-time default language.
    public func transcribe(
        audioPath: String,
        job: STTJobKind,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> STTResult {
        try await transcribe(audioPath: audioPath, job: job, language: defaultLanguage, onProgress: onProgress)
    }

    /// Per-call language variant (mirrors `WhisperEngine.transcribe(audioURL:language:…)`).
    /// The FluidAudio manager is cached and reused across calls, so two invariants matter:
    /// 1. The language is applied on EVERY call (`nil` = auto-detect within Latin, which
    ///    also clears a prior call's pinned language) — not just at construction.
    /// 2. The manager is reset on BOTH the success AND error paths: a throw mid-stream
    ///    (decode failure, cancellation, bad audio) would otherwise leave dirty streaming
    ///    state (buffered audio + accumulated tokens) that corrupts the next reuse.
    public func transcribe(
        audioPath: String,
        job: STTJobKind,
        language: String?,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> STTResult {
        let resolved = SpeechEnginePreference.normalizeNemotronLanguage(language)
        try await transcriptionPermit.wait()
        defer { transcriptionPermit.signal() }
        try Task.checkCancellation()
        try await prepareLocked(onProgress: nil)
        guard let manager else { throw STTError.modelNotLoaded }

        await manager.setLanguage(resolved)
        onProgress?(0, 100)
        do {
            let samples = try AudioConverter().resampleAudioFile(URL(fileURLWithPath: audioPath))
            _ = try await manager.process(samples: samples)
            let (text, timings) = try await manager.finishWithTokenTimings()
            let detected = await manager.detectedLanguage()
            await manager.reset()
            onProgress?(100, 100)

            return STTResult(
                text: text,
                words: Self.mapTokenTimings(timings),
                segments: nil,
                language: detected ?? resolved,
                engine: .nemotron,
                engineVariant: Self.variantLabel
            )
        } catch {
            await manager.reset()
            throw try Self.mapError(error)
        }
    }

    public func prepare(onProgress: (@Sendable (String) -> Void)? = nil) async throws {
        try await transcriptionPermit.wait()
        defer { transcriptionPermit.signal() }
        try Task.checkCancellation()
        try await prepareLocked(onProgress: onProgress)
    }

    private func prepareLocked(onProgress: (@Sendable (String) -> Void)? = nil) async throws {
        if isLoaded, manager != nil { return }
        guard let dir = Self.localModelFolder(downloadBase: downloadBase, chunkMs: chunkMs) else {
            throw STTError.engineStartFailed(
                "Nemotron model is not downloaded. Run `macparakeet-cli models download nemotron-european` first.")
        }
        do {
            try AppPaths.ensureDirectories()
            onProgress?("Loading Nemotron model on Neural Engine...")
            let m = StreamingNemotronMultilingualAsrManager()
            try await m.loadModels(from: dir)
            manager = m
            isLoaded = true
            onProgress?("Ready")
        } catch {
            isLoaded = false
            manager = nil
            throw try Self.mapError(error)
        }
    }

    public func unload() async {
        do { try await transcriptionPermit.wait() } catch { return }
        defer { transcriptionPermit.signal() }
        guard !Task.isCancelled else { return }
        if let manager { await manager.cleanup() }
        manager = nil
        isLoaded = false
    }

    public static func downloadModel(
        downloadBase: URL = NemotronEngine.defaultDownloadBase,
        chunkMs: Int = NemotronEngine.defaultChunkMs,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> URL {
        try AppPaths.ensureDirectories()
        return try await StreamingNemotronMultilingualAsrManager.downloadVariant(
            languageCode: downloadRoutingLanguage,
            chunkMs: chunkMs,
            to: downloadBase,
            progressHandler: { progress in
                // FluidAudio's DownloadProgress exposes only `fractionCompleted`
                // (0...1), not unit counts. Project it onto a 0...100 scale so the
                // (completed, total) progress contract Echo uses elsewhere holds.
                let completed = max(0, min(100, Int((progress.fractionCompleted * 100).rounded())))
                onProgress?(completed, 100)
            }
        )
    }

    /// Rethrows `CancellationError` so a cancelled transcription surfaces as a
    /// clean cancel (matching `WhisperEngine`), not a spurious `.transcriptionFailed`.
    private static func mapError(_ error: Error) throws -> STTError {
        if error is CancellationError { throw error }
        if let sttError = error as? STTError { return sttError }
        return .transcriptionFailed(error.localizedDescription)
    }
}
