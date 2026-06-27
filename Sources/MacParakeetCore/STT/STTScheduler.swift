import Foundation
import OSLog

public enum STTSchedulerError: Error, LocalizedError, Equatable {
    case droppedDueToBackpressure(job: STTJobKind)
    case unavailable

    public var errorDescription: String? {
        switch self {
        case .droppedDueToBackpressure(let job):
            return "Speech job dropped due to backpressure: \(String(describing: job))"
        case .unavailable:
            return "Speech scheduler is temporarily unavailable"
        }
    }
}

/// Centralized broker for all STT work in the app process.
///
/// Jobs execute independently per slot so dictation can remain responsive while
/// meeting and file work share an explicitly prioritized background path.
public actor STTScheduler: STTManaging, SpeechEngineRoutedTranscribing, SpeechEngineSwitching, SpeechEngineSwitchAvailabilityProviding, SpeechEngineSessionManaging, StreamingDictationBrokering {
    private struct ScheduledJob: Sendable {
        let id: UUID
        let audioPath: String
        let job: STTJobKind
        let speechEngine: SpeechEngineSelection?
        let enqueueOrder: UInt64
        let onProgress: (@Sendable (Int, Int) -> Void)?

        var slot: SchedulerSlot {
            SchedulerSlot(job: job)
        }
    }

    private struct SlotState {
        var pendingJobs: [ScheduledJob] = []
        var currentJob: ScheduledJob?
        var currentExecutionTask: Task<STTResult, Error>?
        var currentWaitTask: Task<Void, Never>?
    }

    private let logger = Logger(subsystem: "com.macparakeet.core", category: "STTScheduler")
    private let runtime: STTRuntimeProtocol
    private let meetingLiveChunkBacklogLimit: Int
    private let runtimeOperationWatchdogTimeout: Duration

    private var enqueueCounter: UInt64 = 0
    private var continuations: [UUID: CheckedContinuation<STTResult, Error>] = [:]
    private var slotStates: [SchedulerSlot: SlotState] = Dictionary(
        uniqueKeysWithValues: SchedulerSlot.allCases.map { ($0, SlotState()) }
    )
    private var cancelledJobIDs: Set<UUID> = []
    private var acceptsNewJobs = true
    private var activeSpeechEngineSessionIDs: Set<UUID> = []
    private var speechEngineSwitchTask: Task<Void, Error>?
    /// A live streaming dictation session holds the interactive slot (ADR-023).
    /// While true, engine switches are blocked and batch `.dictation` jobs are
    /// rejected so the slot has a single interactive consumer.
    private var activeStreamingDictation = false

    /// - Parameter meetingLiveChunkBacklogLimit: Maximum pending live-preview chunks before the
    ///   oldest is dropped. 120 ≈ 4 minutes of dual-source 5-second chunks emitted every ~4
    ///   seconds, enough to absorb a prolonged dictation burst before preview starts dropping.
    /// - Parameter runtimeOperationWatchdogTimeout: How long an STT runtime call (cancel-drain,
    ///   model-cache clear, shutdown, engine swap) may take before we emit
    ///   `stt_runtime_unhealthy` telemetry. Detection-only — no behavior changes; the caller
    ///   continues to await regardless. 30 s is generous enough that legitimate slow operations
    ///   on thermally throttled hardware should not trip it.
    public init(
        runtime: STTRuntime = STTRuntime(),
        meetingLiveChunkBacklogLimit: Int = 120,
        runtimeOperationWatchdogTimeout: Duration = .seconds(30)
    ) {
        self.runtime = runtime as STTRuntimeProtocol
        self.meetingLiveChunkBacklogLimit = max(1, meetingLiveChunkBacklogLimit)
        self.runtimeOperationWatchdogTimeout = runtimeOperationWatchdogTimeout
    }

    init(
        runtimeProvider: STTRuntimeProtocol,
        meetingLiveChunkBacklogLimit: Int = 120,
        runtimeOperationWatchdogTimeout: Duration = .seconds(30)
    ) {
        self.runtime = runtimeProvider
        self.meetingLiveChunkBacklogLimit = max(1, meetingLiveChunkBacklogLimit)
        self.runtimeOperationWatchdogTimeout = runtimeOperationWatchdogTimeout
    }

    public func transcribe(
        audioPath: String,
        job: STTJobKind,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> STTResult {
        let id = UUID()
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                enqueue(
                    ScheduledJob(
                        id: id,
                        audioPath: audioPath,
                        job: job,
                        speechEngine: nil,
                        enqueueOrder: nextEnqueueOrder(),
                        onProgress: onProgress
                    ),
                    continuation: continuation
                )
            }
        } onCancel: {
            Task { [weak self] in
                await self?.cancel(jobID: id)
            }
        }
    }

    public func transcribe(
        audioPath: String,
        job: STTJobKind,
        speechEngine: SpeechEngineSelection,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> STTResult {
        let id = UUID()
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                enqueue(
                    ScheduledJob(
                        id: id,
                        audioPath: audioPath,
                        job: job,
                        speechEngine: speechEngine,
                        enqueueOrder: nextEnqueueOrder(),
                        onProgress: onProgress
                    ),
                    continuation: continuation
                )
            }
        } onCancel: {
            Task { [weak self] in
                await self?.cancel(jobID: id)
            }
        }
    }

    public func warmUp(onProgress: (@Sendable (String) -> Void)?) async throws {
        try await runtime.warmUp(onProgress: onProgress)
    }

    public func backgroundWarmUp() async {
        await runtime.backgroundWarmUp()
    }

    public func observeWarmUpProgress() async -> (id: UUID, stream: AsyncStream<STTWarmUpState>) {
        await runtime.observeWarmUpProgress()
    }

    public func removeWarmUpObserver(id: UUID) async {
        await runtime.removeWarmUpObserver(id: id)
    }

    public func isReady() async -> Bool {
        await runtime.isReady()
    }

    public func clearModelCache() async {
        await quiesce(restoreAcceptsNewJobs: true)
        await observingRuntimeTimeout(reason: "clear_model_cache") {
            await runtime.clearModelCache()
        }
    }

    public func shutdown() async {
        await quiesce(restoreAcceptsNewJobs: false)
        await observingRuntimeTimeout(reason: "shutdown") {
            await runtime.shutdown()
        }
    }

    public func setSpeechEngine(_ preference: SpeechEnginePreference) async throws {
        try await setSpeechEngine(preference, onProgress: nil)
    }

    public func setSpeechEngine(
        _ preference: SpeechEnginePreference,
        onProgress: (@Sendable (String) -> Void)?
    ) async throws {
        guard acceptsNewJobs,
              activeSpeechEngineSessionIDs.isEmpty,
              !hasQueuedOrRunningJobs,
              speechEngineSwitchTask == nil,
              !activeStreamingDictation else {
            throw STTError.engineBusy
        }

        acceptsNewJobs = false
        let switchTask = Task {
            try await runtime.setSpeechEngine(preference, onProgress: onProgress)
        }
        speechEngineSwitchTask = switchTask
        defer {
            speechEngineSwitchTask = nil
            acceptsNewJobs = true
        }
        try await observingRuntimeTimeoutThrowing(reason: "set_speech_engine") {
            try await withTaskCancellationHandler {
                try await switchTask.value
            } onCancel: {
                switchTask.cancel()
            }
        }
    }

    public func engineSwitchAvailability() async -> SpeechEngineSwitchAvailability {
        if speechEngineSwitchTask != nil {
            return .switchInProgress
        }
        if activeStreamingDictation {
            return .liveDictationActive
        }
        if !activeSpeechEngineSessionIDs.isEmpty {
            return .meetingActive
        }
        if hasQueuedOrRunningJobs {
            return .transcribing
        }
        if !acceptsNewJobs {
            return .unavailable
        }
        return .available
    }

    public func beginSpeechEngineSession() async -> SpeechEngineLease {
        if let speechEngineSwitchTask {
            let result = await speechEngineSwitchTask.result
            if case .failure(let error) = result {
                logger.warning("Proceeding with speech engine session after failed engine switch: \(error.localizedDescription, privacy: .public)")
            }
        }
        let lease = SpeechEngineLease(selection: await runtime.currentSpeechEngineSelection())
        activeSpeechEngineSessionIDs.insert(lease.id)
        return lease
    }

    public func endSpeechEngineSession(_ lease: SpeechEngineLease) async {
        activeSpeechEngineSessionIDs.remove(lease.id)
    }

    // MARK: - Live streaming dictation (ADR-023)

    public func prepareStreamingDictation(onProgress: (@Sendable (String) -> Void)?) async throws {
        try await runtime.prepareStreamingDictation(onProgress: onProgress)
    }

    public func isStreamingDictationReady() async -> Bool {
        await runtime.isStreamingDictationReady()
    }

    public func beginStreamingDictation() async throws -> StreamingDictationSession {
        // Note: an active meeting engine lease (activeSpeechEngineSessionIDs) does
        // NOT block live dictation — the streaming engine is independent of the
        // meeting's engine/slot, so the two run concurrently (ADR-015). Only a
        // shutdown/quiesce, an in-flight engine switch, or another live session
        // blocks here.
        guard acceptsNewJobs,
              speechEngineSwitchTask == nil,
              !activeStreamingDictation else {
            throw STTError.engineBusy
        }
        // Set the flag synchronously (no suspension since the guard) so a second
        // concurrent begin can't race past the guard; clear it if the runtime's
        // readiness gate throws (no silent fallback — ADR-021).
        activeStreamingDictation = true
        do {
            return try await runtime.beginStreamingDictationSession()
        } catch {
            activeStreamingDictation = false
            throw error
        }
    }

    public func endStreamingDictation() async {
        activeStreamingDictation = false
    }

    private func enqueue(
        _ job: ScheduledJob,
        continuation: CheckedContinuation<STTResult, Error>
    ) {
        if Task.isCancelled || cancelledJobIDs.remove(job.id) != nil {
            continuation.resume(throwing: CancellationError())
            return
        }

        guard acceptsNewJobs else {
            continuation.resume(throwing: STTSchedulerError.unavailable)
            return
        }

        // A live streaming session reserves the interactive slot — reject a
        // concurrent batch dictation so the slot has a single interactive
        // consumer (ADR-016/ADR-023).
        if job.job == .dictation, activeStreamingDictation {
            continuation.resume(throwing: STTSchedulerError.unavailable)
            return
        }

        continuations[job.id] = continuation
        var currentSlotState = slotState(for: job.slot)

        if job.job == .meetingLiveChunk,
           pendingMeetingLiveJobCount(in: currentSlotState) >= meetingLiveChunkBacklogLimit,
           let droppedJob = dropOldestPendingMeetingLiveJob(in: &currentSlotState) {
            logger.notice(
                "stt_backpressure drop_pending_meeting_live_chunk id=\(droppedJob.id.uuidString, privacy: .public)"
            )
            continuations.removeValue(forKey: droppedJob.id)?.resume(
                throwing: STTSchedulerError.droppedDueToBackpressure(job: .meetingLiveChunk)
            )
        }

        currentSlotState.pendingJobs.append(job)
        setSlotState(currentSlotState, for: job.slot)
        startNextJobIfNeeded(in: job.slot)
    }

    private func nextEnqueueOrder() -> UInt64 {
        defer { enqueueCounter &+= 1 }
        return enqueueCounter
    }

    private func slotState(for slot: SchedulerSlot) -> SlotState {
        slotStates[slot, default: SlotState()]
    }

    private func setSlotState(_ slotState: SlotState, for slot: SchedulerSlot) {
        slotStates[slot] = slotState
    }

    private var hasQueuedOrRunningJobs: Bool {
        slotStates.values.contains { state in
            state.currentJob != nil || !state.pendingJobs.isEmpty
        }
    }

    private func pendingMeetingLiveJobCount(in slotState: SlotState) -> Int {
        slotState.pendingJobs.reduce(into: 0) { count, job in
            if job.job == .meetingLiveChunk {
                count += 1
            }
        }
    }

    private func dropOldestPendingMeetingLiveJob(in slotState: inout SlotState) -> ScheduledJob? {
        guard let index = slotState.pendingJobs.enumerated()
            .filter({ $0.element.job == .meetingLiveChunk })
            .min(by: { $0.element.enqueueOrder < $1.element.enqueueOrder })?
            .offset else {
            return nil
        }
        return slotState.pendingJobs.remove(at: index)
    }

    private func startNextJobIfNeeded(in slot: SchedulerSlot) {
        var currentSlotState = slotState(for: slot)
        guard currentSlotState.currentJob == nil else { return }
        guard let next = dequeueNextJob(in: &currentSlotState) else {
            setSlotState(currentSlotState, for: slot)
            return
        }

        currentSlotState.currentJob = next
        currentSlotState.currentExecutionTask = Task {
            if let speechEngine = next.speechEngine {
                try await runtime.transcribe(
                    audioPath: next.audioPath,
                    job: next.job,
                    speechEngine: speechEngine,
                    onProgress: next.onProgress
                )
            } else {
                try await runtime.transcribe(audioPath: next.audioPath, job: next.job, onProgress: next.onProgress)
            }
        }
        currentSlotState.currentWaitTask = Task { [weak self] in
            await self?.awaitCurrentJobCompletion(jobID: next.id, in: slot)
        }
        setSlotState(currentSlotState, for: slot)
    }

    private func dequeueNextJob(in slotState: inout SlotState) -> ScheduledJob? {
        guard let index = slotState.pendingJobs.indices.min(by: { lhs, rhs in
            let left = slotState.pendingJobs[lhs]
            let right = slotState.pendingJobs[rhs]
            if left.job.priorityRank != right.job.priorityRank {
                return left.job.priorityRank < right.job.priorityRank
            }
            return left.enqueueOrder < right.enqueueOrder
        }) else {
            return nil
        }
        return slotState.pendingJobs.remove(at: index)
    }

    private func awaitCurrentJobCompletion(jobID: UUID, in slot: SchedulerSlot) async {
        let slotState = slotState(for: slot)
        guard slotState.currentJob?.id == jobID, let executionTask = slotState.currentExecutionTask else { return }

        let result: Result<STTResult, Error>
        do {
            result = .success(try await executionTask.value)
        } catch {
            result = .failure(error)
        }

        finishCurrentJob(jobID: jobID, in: slot, result: result)
    }

    private func finishCurrentJob(jobID: UUID, in slot: SchedulerSlot, result: Result<STTResult, Error>) {
        var slotState = slotState(for: slot)
        guard slotState.currentJob?.id == jobID else { return }

        let continuation = continuations.removeValue(forKey: jobID)
        cancelledJobIDs.remove(jobID)
        slotState.currentJob = nil
        slotState.currentExecutionTask = nil
        slotState.currentWaitTask = nil
        setSlotState(slotState, for: slot)

        switch result {
        case .success(let value):
            continuation?.resume(returning: value)
        case .failure(let error):
            continuation?.resume(throwing: error)
        }

        startNextJobIfNeeded(in: slot)
    }

    private func cancel(jobID: UUID) {
        for slot in SchedulerSlot.allCases {
            var currentSlotState = slotState(for: slot)
            if let index = currentSlotState.pendingJobs.firstIndex(where: { $0.id == jobID }) {
                currentSlotState.pendingJobs.remove(at: index)
                setSlotState(currentSlotState, for: slot)
                cancelledJobIDs.remove(jobID)
                continuations.removeValue(forKey: jobID)?.resume(throwing: CancellationError())
                return
            }

            if currentSlotState.currentJob?.id == jobID {
                currentSlotState.currentExecutionTask?.cancel()
                cancelledJobIDs.remove(jobID)
                setSlotState(currentSlotState, for: slot)
                return
            }
        }

        cancelledJobIDs.insert(jobID)
    }

    private func cancelAllPendingJobs() {
        let pendingIDs = SchedulerSlot.allCases.flatMap { slotState(for: $0).pendingJobs.map(\.id) }
        for slot in SchedulerSlot.allCases {
            var currentSlotState = slotState(for: slot)
            currentSlotState.pendingJobs.removeAll()
            setSlotState(currentSlotState, for: slot)
        }
        for id in pendingIDs {
            continuations.removeValue(forKey: id)?.resume(throwing: CancellationError())
        }
    }

    private func quiesce(restoreAcceptsNewJobs: Bool) async {
        acceptsNewJobs = false
        cancelAllPendingJobs()
        await cancelAndDrainRunningJobs()
        if restoreAcceptsNewJobs {
            acceptsNewJobs = true
        }
    }

    private func cancelAndDrainRunningJobs() async {
        let waitTasks = SchedulerSlot.allCases.compactMap { slot -> Task<Void, Never>? in
            let slotState = slotState(for: slot)
            slotState.currentExecutionTask?.cancel()
            return slotState.currentWaitTask
        }
        guard !waitTasks.isEmpty else { return }
        await observingRuntimeTimeout(reason: "cancel_drain") {
            for task in waitTasks {
                await task.value
            }
        }
    }

    /// Watchdog probe for an STT runtime call that may hang if the underlying
    /// runtime (FluidAudio / WhisperKit) ignores cancellation. If `operation`
    /// exceeds `runtimeOperationWatchdogTimeout`, emits
    /// `stt_runtime_unhealthy` telemetry. The caller continues to await; this
    /// is observability-only.
    private func observingRuntimeTimeout<T: Sendable>(
        reason: String,
        operation: () async -> T
    ) async -> T {
        let watchdog = Self.makeRuntimeWatchdog(
            reason: reason,
            timeout: runtimeOperationWatchdogTimeout
        )
        defer { watchdog.cancel() }
        return await operation()
    }

    private func observingRuntimeTimeoutThrowing<T: Sendable>(
        reason: String,
        operation: () async throws -> T
    ) async throws -> T {
        let watchdog = Self.makeRuntimeWatchdog(
            reason: reason,
            timeout: runtimeOperationWatchdogTimeout
        )
        defer { watchdog.cancel() }
        return try await operation()
    }

    private nonisolated static func makeRuntimeWatchdog(
        reason: String,
        timeout: Duration
    ) -> Task<Void, Never> {
        Task.detached(priority: .background) {
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            Telemetry.send(.sttRuntimeUnhealthy(reason: reason))
        }
    }
}

private enum SchedulerSlot: CaseIterable, Sendable {
    case interactive
    case background

    init(job: STTJobKind) {
        switch job {
        case .dictation:
            self = .interactive
        case .meetingFinalize, .meetingLiveChunk, .fileTranscription:
            self = .background
        }
    }
}

private extension STTJobKind {
    // Priority is compared only within a slot. `dictation` and `meetingFinalize`
    // both rank highest, but they never contend because they execute on different slots.
    var priorityRank: Int {
        switch self {
        case .dictation:
            0
        case .meetingFinalize:
            0
        case .meetingLiveChunk:
            1
        case .fileTranscription:
            2
        }
    }
}
