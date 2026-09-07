import FluidAudio
import Foundation

public struct MacParakeetDiarizationResult: Sendable {
    public let segments: [SpeakerSegment]
    public let speakerCount: Int
    public let speakers: [SpeakerInfo]

    public init(segments: [SpeakerSegment], speakerCount: Int, speakers: [SpeakerInfo]) {
        self.segments = segments
        self.speakerCount = speakerCount
        self.speakers = speakers
    }
}

public struct SpeakerSegment: Sendable {
    public let speakerId: String
    public let startMs: Int
    public let endMs: Int

    public init(speakerId: String, startMs: Int, endMs: Int) {
        self.speakerId = speakerId
        self.startMs = startMs
        self.endMs = endMs
    }
}

public enum SpeakerDiarizationConstraint: Hashable, Sendable {
    case exact(Int)
    case range(min: Int?, max: Int?)
}

public protocol DiarizationServiceProtocol: Sendable {
    /// Diarizes `audioURL`. `speakerConstraint` is a per-call hint from the
    /// caller (for example the meeting attendee prior); a service constructed
    /// with an explicit constraint keeps that constraint and ignores the hint.
    func diarize(
        audioURL: URL,
        speakerConstraint: SpeakerDiarizationConstraint?
    ) async throws -> MacParakeetDiarizationResult
    func prepareModels(onProgress: (@Sendable (String) -> Void)?) async throws
    func isReady() async -> Bool
    func hasCachedModels() async -> Bool
    /// The constraint the service was constructed with (CLI `--speaker-*`
    /// flags), or `nil`. Callers use it to report which policy actually
    /// applied.
    func explicitSpeakerConstraint() async -> SpeakerDiarizationConstraint?
}

extension DiarizationServiceProtocol {
    public func diarize(audioURL: URL) async throws -> MacParakeetDiarizationResult {
        try await diarize(audioURL: audioURL, speakerConstraint: nil)
    }

    public func explicitSpeakerConstraint() async -> SpeakerDiarizationConstraint? {
        nil
    }

    public func prepareModels() async throws {
        try await prepareModels(onProgress: nil)
    }

    public func hasCachedModels() async -> Bool {
        false
    }
}

protocol OfflineDiarizerManaging: AnyObject, Sendable {
    func prepareModels(at directory: URL) async throws
    func process(audioURL: URL) async throws -> DiarizationResult
}

extension OfflineDiarizerManager: OfflineDiarizerManaging {
    func prepareModels(at directory: URL) async throws {
        try await prepareModels(directory: directory)
    }

    func process(audioURL: URL) async throws -> DiarizationResult {
        try await process(audioURL)
    }
}

// @unchecked Sendable: a manager is published to callers only after its
// preparation task has completed, its configuration is immutable after init,
// and `process` reads the initialized models with request-local state. No
// caller mutates a manager after publication.
extension OfflineDiarizerManager: @retroactive @unchecked Sendable {}

public actor DiarizationService: DiarizationServiceProtocol {
    typealias ManagerFactory = @Sendable (SpeakerDiarizationConstraint?) -> any OfflineDiarizerManaging

    private let makeManager: ManagerFactory
    private let modelsDirectory: URL
    private let inferenceGate: ANEInferenceGate
    /// Constraint the service was constructed with (CLI `--speaker-*` flags).
    /// When set it wins over any per-call hint.
    private let explicitConstraint: SpeakerDiarizationConstraint?
    /// One prepared `OfflineDiarizerManager` per distinct constraint, keyed by
    /// the effective constraint. FluidAudio's `prepareModels(directory:)` owns
    /// download, corrupt-cache purge, and retry; concurrent cold callers await
    /// the same task, and a failed task is dropped so the next call retries.
    /// Each distinct constraint loads the CoreML models once more per process;
    /// the domain is tiny (nil, the meeting prior's `bounds(1, n + 1)`, CLI
    /// values) and diarization is async work measured in tens of seconds, so
    /// the extra load is cheaper than sharing model objects across managers.
    private var managers: [SpeakerDiarizationConstraint?: Task<any OfflineDiarizerManaging, Error>] = [:]
    private var modelsReady = false

    /// Uses the high-accuracy async configuration. Pass `config` only to
    /// override it deliberately (tests, benchmarks).
    public init(
        config: OfflineDiarizerConfig = DiarizationService.highAccuracyConfig,
        modelsDirectory: URL? = nil
    ) {
        self.init(
            makeManager: { constraint in OfflineDiarizerManager(config: Self.applying(constraint, to: config)) },
            modelsDirectory: modelsDirectory ?? AppPaths.fluidAudioModelsDirURL,
            explicitConstraint: nil
        )
    }

    public init(
        speakerConstraint: SpeakerDiarizationConstraint,
        modelsDirectory: URL? = nil
    ) {
        self.init(
            makeManager: { _ in OfflineDiarizerManager(config: Self.offlineConfig(speakerConstraint: speakerConstraint)) },
            modelsDirectory: modelsDirectory ?? AppPaths.fluidAudioModelsDirURL,
            explicitConstraint: speakerConstraint
        )
    }

    init(
        makeManager: @escaping ManagerFactory,
        modelsDirectory: URL,
        explicitConstraint: SpeakerDiarizationConstraint? = nil,
        inferenceGate: ANEInferenceGate = .shared
    ) {
        self.makeManager = makeManager
        self.modelsDirectory = modelsDirectory.standardizedFileURL
        self.explicitConstraint = explicitConstraint
        self.inferenceGate = inferenceGate
    }

    public func diarize(
        audioURL: URL,
        speakerConstraint: SpeakerDiarizationConstraint?
    ) async throws -> MacParakeetDiarizationResult {
        // The explicit constraint already lives in the manager's config, so a
        // per-call hint must not override the user's flag.
        let manager = try await preparedManager(for: explicitConstraint == nil ? speakerConstraint : nil)

        let fluidResult: DiarizationResult
        do {
            // Serialize Neural Engine inference on macOS 14 (no-op on macOS 15+):
            // offline diarization runs its own CoreML models outside the STT
            // scheduler, so it must not overlap an in-flight ASR inference, which
            // intermittently SIGBUSes the shared Neural Engine queue on macOS 14.
            // See `ANEInferenceGate`.
            fluidResult = try await inferenceGate.withExclusiveAccess {
                try await manager.process(audioURL: audioURL)
            }
        } catch let error as OfflineDiarizationError where error.isNoSpeechDetected {
            return MacParakeetDiarizationResult(segments: [], speakerCount: 0, speakers: [])
        }

        // Sort by start time before assigning stable IDs so "S1" is the
        // first speaker to *talk* (chronologically), not the first speaker
        // to appear in whatever order FluidAudio's offline pipeline happens
        // to return segments. FluidAudio doesn't formally document the
        // ordering of its `segments` array, so we don't rely on it.
        let chronologicalSegments = fluidResult.segments.sorted { lhs, rhs in
            lhs.startTimeSeconds < rhs.startTimeSeconds
        }

        // Collect unique speaker IDs from FluidAudio (e.g. "speaker_0", "speaker_1")
        // and normalize to stable IDs ("S1", "S2") in chronological encounter order.
        var idMapping: [String: String] = [:]
        var nextIndex = 1
        for segment in chronologicalSegments {
            if idMapping[segment.speakerId] == nil {
                idMapping[segment.speakerId] = "S\(nextIndex)"
                nextIndex += 1
            }
        }

        let segments: [SpeakerSegment] = chronologicalSegments.map { seg in
            let mappedId = idMapping[seg.speakerId] ?? seg.speakerId
            let startMs = max(0, Int((seg.startTimeSeconds * 1000).rounded()))
            let endMs = max(0, Int((seg.endTimeSeconds * 1000).rounded()))
            return SpeakerSegment(speakerId: mappedId, startMs: startMs, endMs: endMs)
        }

        let speakers: [SpeakerInfo] = idMapping
            .sorted { Int($0.value.dropFirst()) ?? 0 < Int($1.value.dropFirst()) ?? 0 }
            .map { _, stableId in
                let number = String(stableId.dropFirst())
                return SpeakerInfo(id: stableId, label: "Speaker \(number)")
            }

        return MacParakeetDiarizationResult(
            segments: segments,
            speakerCount: speakers.count,
            speakers: speakers
        )
    }

    public func prepareModels(onProgress: (@Sendable (String) -> Void)? = nil) async throws {
        onProgress?("Downloading speaker models...")
        _ = try await preparedManager(for: nil)
        onProgress?("Speaker models ready")
    }

    public func explicitSpeakerConstraint() async -> SpeakerDiarizationConstraint? {
        explicitConstraint
    }

    private func preparedManager(
        for constraint: SpeakerDiarizationConstraint?
    ) async throws -> any OfflineDiarizerManaging {
        let task: Task<any OfflineDiarizerManaging, Error>
        if let existing = managers[constraint] {
            task = existing
        } else {
            let manager = makeManager(constraint)
            let directory = modelsDirectory
            let inferenceGate = self.inferenceGate
            task = Task {
                // FluidAudio prewarms the segmentation and embedding models
                // inside `prepareModels`, which is Neural Engine inference, so
                // preparation takes the gate on its own, before and separately
                // from the `process` acquisition above (never nested).
                try await inferenceGate.withExclusiveAccess {
                    try await manager.prepareModels(at: directory)
                }
                return manager
            }
            managers[constraint] = task
        }

        let manager: any OfflineDiarizerManaging
        do {
            manager = try await task.value
        } catch {
            if managers[constraint] == task { managers[constraint] = nil }
            throw error
        }
        if constraint == nil { modelsReady = true }
        try Task.checkCancellation()
        return manager
    }

    public func isReady() async -> Bool {
        modelsReady
    }

    public func hasCachedModels() async -> Bool {
        Self.isModelCached(directory: modelsDirectory)
    }

    public nonisolated static func isModelCached(directory: URL? = nil) -> Bool {
        let repoDirectory = modelCacheDirectory(directory: directory)
        return requiredModelNames().allSatisfy { modelName in
            FileManager.default.fileExists(
                atPath: repoDirectory.appendingPathComponent(modelName, isDirectory: false).path
            )
        }
    }

    public nonisolated static func clearModelCache(directory: URL? = nil) {
        try? FileManager.default.removeItem(at: modelCacheDirectory(directory: directory))
    }

    nonisolated static func modelCacheDirectory(directory: URL? = nil) -> URL {
        let baseDirectory = (directory ?? AppPaths.fluidAudioModelsDirURL).standardizedFileURL
        return baseDirectory.appendingPathComponent(Repo.diarizer.folderName, isDirectory: true)
    }

    nonisolated static func requiredModelNames() -> [String] {
        Array(ModelNames.OfflineDiarizer.requiredModels)
    }

    /// Diarization always runs after transcription, off the interactive path,
    /// so it takes FluidAudio's slower high-accuracy settings rather than
    /// `OfflineDiarizerConfig.default` (the fast preset). FluidAudio's
    /// 0.15.4-era VoxConverse table (collar 0.25 s, overlap ignored; not yet
    /// re-run under 0.15.6) put `stepRatio 0.1` / `minSegmentDuration 0` at
    /// 13.89% versus 15.07% DER for about half the throughput. See ADR-010
    /// (2026-09-06 amendment) and issue #972.
    ///
    /// Left at library defaults on purpose: `clustering.threshold` (the app
    /// never tuned it, and 0.15.6 changed its semantics to a plain distance
    /// cut), `clustering.constrainedAssignment` (on since 0.15.6), and the
    /// K-Means re-clustering seed, which FluidAudio fixes at `baseSeed 0` with
    /// `nInit 10` so constrained runs are deterministic.
    public nonisolated static var highAccuracyConfig: OfflineDiarizerConfig {
        var config = OfflineDiarizerConfig.default
        // 10 s windows with a 1 s hop instead of 2 s: more embeddings per
        // speaker turn and finer change points.
        config.segmentation.stepRatio = 0.1
        // Keep short turns: the embedding stage no longer falls back to the
        // overlap-inclusive mask under 1 s, and reconstruction no longer drops
        // segments shorter than 1 s.
        config.embedding.minSegmentDurationSeconds = 0
        // Re-embed spans that received no cluster votes instead of
        // tie-breaking them into cluster 0 (absorbing a speaker's turn into
        // the surrounding speaker).
        config.zeroVoteReembed = OfflineDiarizerConfig.ZeroVoteReembed(enabled: true)
        return config
    }

    nonisolated static func offlineConfig(
        speakerConstraint: SpeakerDiarizationConstraint?
    ) -> OfflineDiarizerConfig {
        applying(speakerConstraint, to: highAccuracyConfig)
    }

    nonisolated static func applying(
        _ speakerConstraint: SpeakerDiarizationConstraint?,
        to config: OfflineDiarizerConfig
    ) -> OfflineDiarizerConfig {
        guard let speakerConstraint else { return config }

        switch speakerConstraint {
        case .exact(let count):
            return config.withSpeakers(exactly: count)
        case .range(let min, let max):
            return config.withSpeakers(min: min, max: max)
        }
    }
}

extension OfflineDiarizationError {
    var isNoSpeechDetected: Bool {
        if case .noSpeechDetected = self { return true }
        return false
    }
}

public actor MockDiarizationService: DiarizationServiceProtocol {
    public var diarizeResult: MacParakeetDiarizationResult?
    public var diarizeError: Error?
    public var diarizeCalled = false
    /// Constraints passed to `diarize(audioURL:speakerConstraint:)`, in call order.
    public var receivedSpeakerConstraints: [SpeakerDiarizationConstraint?] = []
    public var prepareModelsCalled = false
    public var prepareModelsError: Error?
    public var ready = false
    public var cachedModels = false
    public var explicitConstraint: SpeakerDiarizationConstraint?

    public init() {}

    public func configureExplicitConstraint(_ constraint: SpeakerDiarizationConstraint?) {
        explicitConstraint = constraint
    }

    public func explicitSpeakerConstraint() async -> SpeakerDiarizationConstraint? {
        explicitConstraint
    }

    public func configure(result: MacParakeetDiarizationResult) {
        self.diarizeResult = result
        self.diarizeError = nil
    }

    public func configure(error: Error) {
        self.diarizeError = error
        self.diarizeResult = nil
    }

    public func configurePrepareModels(error: Error?) {
        self.prepareModelsError = error
    }

    public func configureReady(_ ready: Bool) {
        self.ready = ready
    }

    public func configureCachedModels(_ cachedModels: Bool) {
        self.cachedModels = cachedModels
    }

    public func diarize(
        audioURL: URL,
        speakerConstraint: SpeakerDiarizationConstraint?
    ) async throws -> MacParakeetDiarizationResult {
        diarizeCalled = true
        receivedSpeakerConstraints.append(speakerConstraint)
        if let error = diarizeError { throw error }
        return diarizeResult ?? MacParakeetDiarizationResult(segments: [], speakerCount: 0, speakers: [])
    }

    public func prepareModels(onProgress: (@Sendable (String) -> Void)?) async throws {
        prepareModelsCalled = true
        if let error = prepareModelsError { throw error }
        ready = true
        cachedModels = true
    }

    public func isReady() async -> Bool {
        ready
    }

    public func hasCachedModels() async -> Bool {
        cachedModels
    }
}
