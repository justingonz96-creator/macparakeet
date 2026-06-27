import AppKit
import Foundation
import MacParakeetCore
import OSLog

/// The `@MainActor` coordinator that owns the Command Mode hold gesture and ties
/// together the five moving parts of a run: the hotkey monitor (press-start /
/// press-end), selection capture, microphone recording, STT, the executor, and
/// the floating progress pill. See ADR-023 and Task 11 of
/// `plans/active/2026-06-command-mode-voice-trigger.md`.
///
/// One run, in plain English: the user holds the Command Mode key, we grab
/// whatever text is selected, start the mic, and show the pill. When the user
/// releases, we stop the mic, transcribe the spoken instruction, run the
/// executor (which either applies a deterministic edit or rewrites via the LLM
/// and pastes the result back), then dismiss the pill.
///
/// There is no unit test for this class — it is GUI/mic/AppKit glue verified by
/// the manual matrix in Task 14. It is constructed and owned by `AppDelegate`
/// in the next task; here we only build the class.
@MainActor
final class CommandModeCoordinator {
    /// State for the in-flight hold. `runID` lets every async continuation
    /// check it is still operating on the current hold (a re-press starts a new
    /// `runID`, so stale tasks bail out via the `activeHold?.runID == runID`
    /// guard). `captured` is filled in once `beginCaptureAndRecord` succeeds.
    private struct ActiveHold {
        let runID: UUID
        var captured: SelectionCaptureResult?
    }

    private let monitor = CommandModeHotkeyMonitor()
    /// The single `SelectionCaptureService` instance the coordinator owns. It is
    /// used both directly (to capture the selection and do the §4.8 early
    /// clipboard restore) and indirectly via the executor, which restores the
    /// clipboard around replacement using the same instance.
    private let captureService = SelectionCaptureService()
    private let executor: CommandModeExecutor
    private let arbiter: MicrophoneArbiter
    private let audioProcessor: AudioProcessorProtocol
    private let sttScheduler: STTScheduler
    private let panel = TransformSpikeProgressPanelController()
    private let onLLMProviderRequired: () -> Void
    private let suspendOtherHotkeys: (Bool) -> Void
    private let logger = Logger(subsystem: "com.macparakeet", category: "CommandModeCoordinator")

    private var activeHold: ActiveHold?
    /// True once the 120 ms min-hold debounce has fired for the current hold.
    /// Until then a release is treated as an accidental tap and nothing was
    /// captured or recorded, so we just tear down.
    private var minHoldElapsed = false

    init(
        llmServiceProvider: @escaping @Sendable () -> LLMServiceProtocol?,
        arbiter: MicrophoneArbiter,
        audioProcessor: AudioProcessorProtocol,
        sttScheduler: STTScheduler,
        currentShortcut: @escaping () -> KeyboardShortcut?,
        onLLMProviderRequired: @escaping () -> Void,
        suspendOtherHotkeys: @escaping (Bool) -> Void
    ) {
        self.executor = CommandModeExecutor(
            captureService: captureService,
            llmServiceProvider: llmServiceProvider
        )
        self.arbiter = arbiter
        self.audioProcessor = audioProcessor
        self.sttScheduler = sttScheduler
        self.onLLMProviderRequired = onLLMProviderRequired
        self.suspendOtherHotkeys = suspendOtherHotkeys
        monitor.onPressStart = { [weak self] in self?.handlePressStart() }
        monitor.onPressEnd = { [weak self] in self?.handlePressEnd() }
        refreshShortcut(currentShortcut())
    }

    /// Arm the event tap. No-op when the feature flag is off or no shortcut is
    /// set (the monitor stays dormant until `setShortcut` gives it a chord).
    func start() {
        guard AppFeatures.commandModeEnabled else { return }
        _ = monitor.start()
    }

    /// Re-point the monitor at a new (or nil) shortcut, e.g. after the user
    /// changes the Command Mode binding in Settings.
    func refreshShortcut(_ shortcut: KeyboardShortcut?) {
        monitor.setShortcut(shortcut)
    }

    // MARK: - Hold lifecycle

    private func handlePressStart() {
        // A new press while a prior hold is still active (rapid re-press): tear
        // the prior hold down first so its arbiter lease + hotkey suspension are
        // released exactly once before we acquire fresh ones below.
        if let prior = activeHold { teardown(prior) }

        // Mutual exclusion with dictation/meeting capture (ADR-023 §4 / the
        // MicrophoneArbiter rule). If the mic is busy, tell the user and bail.
        guard arbiter.tryAcquire(.commandMode) else {
            showToast("Finish dictating first.")
            return
        }
        suspendOtherHotkeys(true)
        let runID = UUID()
        activeHold = ActiveHold(runID: runID, captured: nil)
        minHoldElapsed = false

        // Min-hold debounce: an accidental tap shorter than 120 ms should never
        // capture, record, or flash the pill. Only after the floor elapses do we
        // begin real work — and only if this is still the current hold.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard let self, self.activeHold?.runID == runID else { return }
            self.minHoldElapsed = true
            await self.beginCaptureAndRecord(runID: runID)
        }
    }

    private func beginCaptureAndRecord(runID: UUID) async {
        let captured = await captureService.captureSelection()
        guard activeHold?.runID == runID else { return }
        switch captured {
        case .empty:
            showToast("Select text first — highlight what you want to change, then hold the key and speak.")
            finishHold(runID)
            return
        case .failed:
            showToast("Couldn't read the selection.")
            finishHold(runID)
            return
        case .ax, .clipboard:
            break
        }

        // Long-hold clipboard hygiene (§4.8): the selected text is now held in
        // memory, so restore the user's original clipboard immediately rather
        // than leaving our Cmd+C hijack live for the whole hold. The guard
        // inside this call only restores if the pasteboard is still at our
        // change count, so user copies made mid-hold are preserved.
        await captureService.restoreClipboardCaptureIfCurrent(captured)
        activeHold?.captured = captured

        do {
            try await audioProcessor.startCapture()
            panel.showWorking(message: "Listening…")
        } catch {
            logger.error("command-mode: mic start failed: \(error.localizedDescription, privacy: .public)")
            showToast("Couldn't start the microphone.")
            finishHold(runID)
        }
    }

    private func handlePressEnd() {
        guard let hold = activeHold else { return }
        let runID = hold.runID

        // Released before the debounce floor, or before capture/mic came up:
        // nothing was recorded, so just release the hold cleanly.
        guard minHoldElapsed, let captured = hold.captured else {
            finishHold(runID)
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let wav = try await self.audioProcessor.stopCapture()
                guard self.activeHold?.runID == runID else { return }

                // "Transcribing…" — honor the user's persisted engine/language
                // (ADR-021). SpeechEngineSelection.current() reads the persisted
                // engine + default language from UserDefaults.
                self.panel.updateWorking(message: "Transcribing…")
                let engine = SpeechEngineSelection.current()
                let stt = try await self.sttScheduler.transcribe(
                    audioPath: wav.path,
                    job: .dictation,
                    speechEngine: engine
                )
                try? FileManager.default.removeItem(at: wav)
                guard self.activeHold?.runID == runID else { return }

                // "Rewriting…" — run the executor; it routes to a deterministic
                // edit or an LLM rewrite and pastes the result back in place.
                let result = try await self.executor.run(
                    instruction: stt.text,
                    captured: captured
                ) { progress in
                    Task { @MainActor in self.applyProgress(progress, runID: runID) }
                }
                guard self.activeHold?.runID == runID else { return }

                self.sendExecutedTelemetry(result)
                self.panel.done(message: "Done")
            } catch let error as CommandModeExecutorError {
                self.handleExecutorError(error)
            } catch {
                self.logger.error("command-mode: run failed: \(error.localizedDescription, privacy: .public)")
                self.panel.fail(message: "Command Mode failed.")
            }
            self.finishHold(runID)
        }
    }

    // MARK: - Progress, errors, telemetry

    /// Map executor progress beats to the pill's working-state label. The pill's
    /// `updateWorking(message:)` shows the beat beside the spinner; terminal
    /// success/failure is surfaced by the caller via `panel.done(...)` /
    /// `panel.fail(...)`. Deterministic edits resolve fast and jump straight to
    /// done, so they need no intermediate label.
    private func applyProgress(_ progress: CommandModeProgress, runID: UUID) {
        guard activeHold?.runID == runID else { return }
        switch progress {
        case .routing:
            logger.debug("command-mode beat: routing")
        case .deterministicApplied(let command):
            logger.debug("command-mode beat: deterministic \(command.rawValue, privacy: .public)")
        case .llmStarted, .llmStreaming:
            // The LLM rewrite path: a single steady "Rewriting…" beat. Streamed
            // chunks accumulate inside the executor; the pill mirrors the stage,
            // not the partial text.
            panel.updateWorking(message: "Rewriting…")
        case .pasting:
            logger.debug("command-mode beat: pasting")
        case .done:
            // Terminal success is surfaced by the caller via panel.done(...).
            break
        case .failed(let message):
            logger.debug("command-mode beat: failed \(message, privacy: .public)")
        }
    }

    /// Surface an executor error on the pill and emit failure telemetry. A
    /// missing LLM provider also triggers the "open AI settings" affordance,
    /// mirroring `TransformsCoordinator.handleMissingLLMProvider`.
    private func handleExecutorError(_ error: CommandModeExecutorError) {
        switch error {
        case .llmNotConfigured:
            onLLMProviderRequired()
            panel.fail(message: "Add an LLM provider in Settings to use Command Mode.")
        default:
            panel.fail(message: error.localizedDescription)
        }
        Telemetry.send(.commandModeFailed(reason: failureReason(for: error)))
        logger.notice("command-mode failed: \(error.localizedDescription, privacy: .public)")
    }

    /// Emit the success telemetry for a completed run: enum codes + timings +
    /// coarse app category only (no selected text, no instruction, no output).
    private func sendExecutedTelemetry(_ result: CommandModeResult) {
        let path: TelemetryCommandModePath
        let deterministicCommand: TelemetryCommandModeDeterministic
        switch result.applied {
        case .rewrite:
            path = .rewrite
            deterministicCommand = .none
        case .deterministic(let command):
            path = .deterministic
            deterministicCommand = telemetryDeterministic(command)
        }

        Telemetry.send(.commandModeExecuted(
            path: path,
            deterministicCommand: deterministicCommand,
            llmMs: result.llmElapsedMs,
            totalMs: result.totalElapsedMs,
            appCategory: TelemetryAppCategory(bundleIdentifier: result.target?.bundleIdentifier)
        ))
    }

    /// All user-facing messages route through the pill, exactly as
    /// `TransformsCoordinator` surfaces its errors (`panel.show()` then
    /// `panel.fail(message:)`). There is no separate toast system.
    private func showToast(_ message: String) {
        panel.show()
        panel.fail(message: message)
    }

    // MARK: - Hold teardown (refcount-paired with press-start)

    /// Release everything acquired in `handlePressStart` exactly once for the
    /// hold identified by `runID`: the arbiter lease, the hotkey suspension, and
    /// the `activeHold` slot. No-op if the current hold is not `runID` (a newer
    /// hold already owns the resources).
    private func finishHold(_ runID: UUID) {
        guard activeHold?.runID == runID else { return }
        arbiter.release(.commandMode)
        suspendOtherHotkeys(false)
        activeHold = nil
    }

    /// Tear down a prior hold being abandoned by a re-press. Same release
    /// semantics as `finishHold` (each exactly once), plus it dismisses the pill
    /// so the new hold starts clean.
    private func teardown(_ hold: ActiveHold) {
        guard activeHold?.runID == hold.runID else { return }
        arbiter.release(.commandMode)
        suspendOtherHotkeys(false)
        activeHold = nil
        panel.close()
    }

    // MARK: - Telemetry mapping helpers

    private func failureReason(for error: CommandModeExecutorError) -> TelemetryCommandModeFailureReason {
        switch error {
        case .emptySelection: return .emptySelection
        case .emptyInstruction: return .emptyInstruction
        case .llmNotConfigured: return .noProvider
        case .llmFailed: return .llmFailed
        case .replacementFailed: return .replacementFailed
        case .cancelled: return .cancelled
        }
    }

    private func telemetryDeterministic(_ command: DeterministicCommand) -> TelemetryCommandModeDeterministic {
        switch command {
        case .clearSelection: return .clearSelection
        case .uppercase: return .uppercase
        case .lowercase: return .lowercase
        case .titleCase: return .titleCase
        case .trim: return .trim
        }
    }
}
