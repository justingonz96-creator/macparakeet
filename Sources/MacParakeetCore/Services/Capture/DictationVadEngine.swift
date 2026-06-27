import FluidAudio
import Foundation
import OSLog

/// Adapter so the real `VadManager` actor and a test mock present the same
/// minimal streaming surface to `DictationVadEngine`. The real `VadManager` is
/// itself an `actor` (FluidAudio 0.14.5), so all of its instance members require
/// `await` when called from outside the actor — even the technically-sync ones
/// like `isAvailable` and `makeStreamState()`. The protocol therefore marks them
/// `async` to accommodate actor-isolated conformers without an `@unchecked Sendable`
/// hack. Non-actor mocks simply mark the implementations `async` and the widening
/// is harmless.
public protocol VadManagerProviding: Sendable {
    /// Whether the Silero model is loaded and ready. Actor-isolated on
    /// `VadManager`, so callers always `await` this across the isolation boundary.
    var isAvailable: Bool { get async }
    /// Returns a fresh `VadStreamState` (mirrors Silero's `reset_states`).
    func makeStreamState() async -> VadStreamState
    /// Process one 4096-sample chunk, returning the updated state and any
    /// boundary event (`nil` event means no speech-boundary this chunk).
    func processStreamingChunk(_ chunk: [Float], state: VadStreamState) async throws -> VadStreamResult
}

/// Conformance bridge: declares `VadManager` as conforming to `VadManagerProviding`
/// and adds the 2-arg `processStreamingChunk` overload that pins FluidAudio's
/// defaulted `config`, `returnSeconds`, and `timeResolution` params.
///
/// `VadManager` is an `actor`. The protocol uses `async` on `isAvailable` and
/// `makeStreamState` so that actor-isolated conformers can satisfy the requirements
/// (actor isolation is compatible with `async` protocol requirements in Swift 6).
/// The existing actor-isolated `makeStreamState()` and `isAvailable` on `VadManager`
/// satisfy those requirements directly; only the 2-arg shim is added here.
extension VadManager: VadManagerProviding {
    public func processStreamingChunk(
        _ chunk: [Float],
        state: VadStreamState
    ) async throws -> VadStreamResult {
        try await processStreamingChunk(chunk, state: state, config: .default)
    }
}

/// Owns the Silero `VadManager` for dictation endpointing. Lives in the
/// capture/endpointing plane (ADR-016 carve-out, like diarization) — never
/// routed through `STTRuntime`. Warmed once per app launch, reused across
/// dictation sessions, single-flight guarded (mirrors `STTRuntime.ensureInitialized`).
public actor DictationVadEngine {
    private let logger = Logger(subsystem: "com.macparakeet.core", category: "DictationVadEngine")
    private let makeManager: @Sendable () async throws -> VadManagerProviding
    private var manager: VadManagerProviding?
    private var loadFailed = false
    private var warmUpTask: Task<Void, Never>?

    /// Designated initializer. The `makeManager` closure is called at most once.
    /// The default builds a real `VadManager` (downloads the Silero model if
    /// missing). Tests inject a mock.
    public init(
        makeManager: @escaping @Sendable () async throws -> VadManagerProviding = {
            try await VadManager()
        }
    ) {
        self.makeManager = makeManager
    }

    /// True once a usable manager is loaded and reports itself available.
    /// `false` ⇒ caller falls back to the RMS gate.
    public var isAvailable: Bool {
        get async {
            guard let manager else { return false }
            return await manager.isAvailable
        }
    }

    /// Build the `VadManager` once (downloads the ~1.3 MB Silero v6 asset if
    /// missing) and JIT the ANE path with one throwaway 4096-zero chunk.
    /// Single-flight: concurrent calls coalesce onto the first-started `Task`;
    /// subsequent calls after warm-up return immediately from the `manager != nil`
    /// guard.
    public func warmUpIfNeeded() async {
        // Fast path: already warmed (or permanently failed).
        if manager != nil || loadFailed { return }
        // Coalesce concurrent callers onto the in-flight Task.
        if let warmUpTask {
            await warmUpTask.value
            return
        }
        let task = Task { [makeManager] in
            await self.performWarmUp(makeManager)
        }
        warmUpTask = task
        await task.value
        // Safe to clear: `performWarmUp` has already set `manager` (success) or
        // `loadFailed` (failure), so the fast-path guards above now reflect the
        // result and no future caller will re-enter the build path.
        warmUpTask = nil
    }

    private func performWarmUp(_ make: @Sendable () async throws -> VadManagerProviding) async {
        // Re-check under the actor's isolation (another Task may have won the race).
        if manager != nil || loadFailed { return }
        do {
            let built = try await make()
            guard await built.isAvailable else {
                loadFailed = true
                logger.warning("dictation_vad_warmup_unavailable")
                return
            }
            // JIT the ANE execution path on the LOCAL `built` (result and errors
            // intentionally ignored) BEFORE publishing. The `await`s below suspend
            // the actor; if we assigned `manager` first, a concurrent `process`/
            // `makeStreamState` could observe a non-nil-but-un-JIT'd model and
            // defeat the warm-up. Publishing last guarantees `manager != nil`
            // implies the model is both available and JIT-primed.
            let state = await built.makeStreamState()
            _ = try? await built.processStreamingChunk(
                [Float](repeating: 0, count: VadManager.chunkSize),
                state: state
            )
            manager = built
            logger.info("dictation_vad_warmup_ready")
        } catch {
            loadFailed = true
            logger.warning("dictation_vad_warmup_failed error=\(error.localizedDescription, privacy: .public)")
        }
    }

    /// Returns a fresh `VadStreamState`, or `nil` if the engine is unavailable
    /// (caller uses RMS fallback instead of starting a VAD session).
    public func makeStreamState() async -> VadStreamState? {
        // `manager` is published only after warm-up confirms availability, so
        // non-nil ⇒ available — no redundant `isAvailable` actor hop needed.
        guard let manager else { return nil }
        return await manager.makeStreamState()
    }

    /// Process one 4096-sample chunk through the loaded Silero model.
    ///
    /// Returns a **double-optional** to distinguish two failure modes:
    /// - `nil` (outer)     — engine unavailable or processing error → RMS fallback.
    /// - `.some(nil)`      — engine running fine, no speech-boundary event this chunk.
    /// - `.some(.some(e))` — a `VadStreamEvent` (`.speechStart` or `.speechEnd`).
    ///
    /// The caller owns `state` and must pass it back on each successive call so
    /// the Silero LSTM's recurrent state is threaded correctly across chunks.
    public func process(chunk: [Float], state: inout VadStreamState) async -> VadStreamEvent?? {
        guard let manager else { return nil }
        do {
            let result = try await manager.processStreamingChunk(chunk, state: state)
            state = result.state
            // result.event is VadStreamEvent? — wrap it in Optional to form the
            // double-optional return: .some(result.event) == VadStreamEvent??.some(_)
            return .some(result.event)
        } catch {
            // Any processing failure signals RMS fallback via outer nil.
            return nil
        }
    }
}
