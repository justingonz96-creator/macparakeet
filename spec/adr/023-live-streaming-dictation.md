# ADR-023: Live Streaming Dictation (Parakeet Unified 0.6B)

> Status: **Accepted / Implemented** on `main`/Beta, behind `AppFeatures.liveDictationEnabled` (pending hands-on real-model validation)
> Date: 2026-06-27
> Implementation: merged behind the flag on `main` with full `swift test` green (REQ-LIVEDICT-001). Stable DMG exposure remains gated on the model-license confirmation in §10 and a dev-app smoke against the real CoreML model.
> Related: ADR-001 (Parakeet primary/default), ADR-005 (first-run onboarding / model download), ADR-007 (FluidAudio CoreML/ANE, no Python), ADR-015 (concurrent dictation + shared mic), ADR-016 (centralized STT runtime + two-slot scheduler), ADR-021 (explicit engine selection, no auto-fallback)

## Context

Echo's dictation is **batch-only**: the user holds a hotkey, speaks, releases, and only *then* does text appear — `DictationService.processCapturedAudio` writes a WAV and calls the scheduler's one-shot `transcribe(audioPath:job:.dictation)` ([DictationService.swift:603](../../Sources/MacParakeetCore/Services/Dictation/DictationService.swift)). There is no "text appears as I speak" experience.

FluidAudio 0.15.4 (the version this work also pins — STEP 1, [Package.swift:12](../../Package.swift)) ships a purpose-built streaming backend: **`StreamingUnifiedAsrManager`** (Parakeet Unified 0.6B, "chunked-attention streaming + offline batch", added in 0.15.3). It is a stateful actor with a clean incremental API — `appendAudio(AVAudioPCMBuffer)` → `processBufferedAudio()` → live partials via `setPartialTranscriptCallback`/`getPartialTranscript()` → `finish() -> String`, plus `consumeTokenTimings() -> [TokenTiming]`. Its encoder is stateless per chunk (re-encodes a `[left | chunk | right]` window with a baked-in chunked-attention mask); only the RNNT decoder LSTM state persists, so the streamed transcript matches the offline output closely ("word-for-word on validation audio" per the manager's own docs). The model bundle is `FluidInference/parakeet-unified-en-0.6b-coreml` — **English-only** — and downloads separately from the existing ~6 GB TDT-v3 cache.

This ADR is the **keystone** for several follow-on speech upgrades (LS-EEND diarization, Nemotron multilingual, Silero VAD v6) that build on the 0.15.4 baseline. It locks the architecture for an **opt-in, English-only, real-time partial-results dictation mode**, integrated through the existing single STT control plane.

### Why this needs an ADR (not just a plan)

The streaming session does not fit the scheduler's execution contract, so naïve wiring would either (a) bolt a second control plane onto the runtime (violating ADR-016) or (b) silently fall back to batch when the streaming model is absent (violating ADR-021). Both failure modes are easy to reach and hard to undo later. The decisions below were hardened by a multi-agent verification pass against the real code on 2026-06-27.

## Decision

### 1. Scope: opt-in, English-only, Beta

Live Streaming Dictation is a **distinct, explicit dictation path**, not a replacement. It is:

- **Opt-in** via a single Settings toggle ("Live dictation"). When off, dictation behaves exactly as today — zero behavior change.
- **English-only** — the unified model is `…-en-…`. It is its own explicit English path, independent of the global Parakeet/Whisper engine selection. Non-English (Whisper/CJK) dictation continues to use the normal non-live engine. There is **no silent fallback** between live and batch (§7) and no language auto-detection.
- **Beta**, gated behind a new compile-time flag `AppFeatures.liveDictationEnabled` ([AppFeatures.swift](../../Sources/MacParakeetCore/AppFeatures.swift)), default `false` on Stable, `true` on `main` — the same pattern as `transformsEnabled`/`calendarEnabled`. The flag controls **visibility** of the toggle and all entry points; the data/services/tests remain compiled in either state.

Classic Parakeet TDT v3 remains the default engine for file/meeting batch transcription **and** for non-live dictation (ADR-001).

### 2. Engine and model

Live dictation uses **Parakeet Unified 0.6B** via FluidAudio's `StreamingUnifiedAsrManager`, model repo `FluidInference/parakeet-unified-en-0.6b-coreml`, default `encoderPrecision: .int8` on CPU+ANE (the int8 encoder must not route to the GPU — FluidAudio coerces this internally; consistent with ADR-007 ANE-first). Default streaming context is 70/13/13 frames ≈ **2.08 s theoretical latency** (the model card's best-WER mode); partials refine roughly once per ~1 s chunk. Latency/quality are tunable later via `UnifiedConfig` at a small accuracy cost; v1 uses the default.

This is a **third** local speech engine alongside TDT-v3 batch and optional WhisperKit — distinct model bundle, distinct lifecycle.

### 3. Control plane: runtime owns the session; scheduler grants the lease (ADR-016 honored)

**The streaming session does NOT route audio through the scheduler.** `STTScheduler`'s only execution seam is the one-shot batch `transcribe(audioPath:job:onProgress:)` ([STTScheduler.swift:86](../../Sources/MacParakeetCore/STT/STTScheduler.swift)); a stateful `appendAudio → finish` session has no home there, and forcing one would fragment the control plane.

Instead:

- **`STTRuntime` owns the streaming session lifecycle** — lazy model download/load with progress, open/close session, reset/cleanup — exactly as it already owns the `AsrManager`s and the optional `WhisperEngine`. One process-wide runtime; no second scheduler.
- **The scheduler is used only for arbitration**, via a small `StreamingDictationBrokering` surface it exposes: `beginStreamingDictation()` sets a dedicated `activeStreamingDictation` flag and asks the runtime to open the session; `endStreamingDictation()` clears it. While the flag is set, `engineSwitchAvailability()` reports the new `.liveDictationActive` reason and `setSpeechEngine` throws — so **engine switches are blocked for the session lifetime**. A dedicated flag (rather than reusing the meeting `beginSpeechEngineSession` lease) is what lets Settings name the real reason *and* lets live dictation run **concurrently with a meeting** (ADR-015): a meeting's engine lease does not block `beginStreamingDictation`.
- The interactive (`.dictation`) slot is **reserved** for the session: batch `.dictation` enqueue is rejected while a live session is active, so two interactive consumers never contend. (Meeting jobs use the background slot and are unaffected.)

ADR-016 holds: a single scheduler still arbitrates the interactive slot, the live-session flag, and all engine leases; only the *audio transport* for streaming lives in the runtime, where the model lifecycle already lives.

### 4. New engine-switch availability reason

Add an additive case `SpeechEngineSwitchAvailability.liveDictationActive` ([STTClientProtocol.swift](../../Sources/MacParakeetCore/STT/STTClientProtocol.swift)) rather than reusing `.meetingActive`, so Settings can honestly explain *why* the engine switch is disabled ("Live dictation is active") instead of falsely naming a meeting.

### 5. Testability seam: a Core-owned protocol

Introduce `StreamingDictationEngine` — a `Sendable` protocol in `MacParakeetCore/STT/` wrapping the FluidAudio surface:

```swift
public protocol StreamingDictationEngine: Sendable {
    func prepare(onProgress: (@Sendable (String) -> Void)?) async throws
    func isReady() async -> Bool
    func setPartialTranscriptCallback(_ callback: @escaping @Sendable (String) -> Void) async
    func appendAudio(samples: [Float]) async throws   // 16 kHz mono Float32
    func processBufferedAudio() async throws
    func finish() async throws -> StreamingDictationResult   // text + [TimestampedWord]
    func reset() async throws
    func cleanup() async
}
```

Audio crosses this boundary as `[Float]` (16 kHz mono) — a `Sendable` value type — not `AVAudioPCMBuffer`, so feeding the engine from an actor needs no `@unchecked Sendable` wrapper or buffer-lifetime reasoning. The concrete `FluidStreamingDictationEngine` rebuilds the `AVAudioPCMBuffer` its backend wants.

`STTRuntime` depends on this protocol, never on the concrete `StreamingUnifiedAsrManager`. A concrete `FluidStreamingDictationEngine` adapter conforms it to FluidAudio 0.15.4 (download path, `int8` config, `consumeTokenTimings()` → `[TimestampedWord]`). CI exercises a **mock** only — the real CoreML model is never run in tests, matching how `AsrManager` is already handled.

### 6. Microphone fan-out: an AudioRecorder buffer sink (not a second subscriber)

`DictationService` has no mic-buffer handle today — it talks only to `AudioProcessorProtocol` (start/stop). To feed the streaming session, add an **optional `@Sendable (AVAudioPCMBuffer) -> Void` buffer sink to `AudioRecorder`**, invoked inside `processCopiedBuffer` *after* conversion to **16 kHz mono Float32**, on `sharedProcessingQueue` (off the render thread) — near [AudioRecorder.swift:336](../../Sources/MacParakeetCore/Audio/AudioRecorder.swift). The sink is installed/cleared per session through `AudioProcessorProtocol`.

This is chosen over a second independent `SharedMicrophoneStream.subscribe` deliberately: the sink reuses the mandatory `extractChannelZero` + `copyPCMBufferForAsyncUse` discipline AudioRecorder already owns (Audio/README §"Channel 0 mono extraction"; §"Tap closures run on the audio render thread"). A second raw subscriber would re-deliver multi-channel buffers on the render thread and force re-implementing that discipline — strictly higher risk. The manager *accepts any format and resamples to 16 kHz mono internally*, so the choice is about **safety, not sample rate**: the sink emits AudioRecorder's post-`extractChannelZero`, post-conversion 16 kHz mono Float32 buffer, which (a) avoids handing the model a raw multi-channel/VPIO buffer whose default channel-averaging would corrupt the post-AEC signal, and (b) avoids redundant resampling. Channel-0 extraction is mandatory under VPIO (PR #189).

The **WAV-always-written invariant is preserved** — AudioRecorder still writes the full dictation WAV regardless of streaming. That WAV underpins history, audio retention, and undo (§7).

### 7. DictationService streaming branch (no silent fallback)

When `liveDictationEnabled()` is true (injected `@Sendable () -> Bool` closure, mirroring `aiFormatterEnabled` at [AppEnvironment.swift:170](../../Sources/MacParakeet/App/AppEnvironment.swift)):

- **Start** (`startRecording`, [DictationService.swift:164](../../Sources/MacParakeetCore/Services/Dictation/DictationService.swift)): an explicit **streaming-model-readiness gate throws *before* `_state = .recording`** ([:223](../../Sources/MacParakeetCore/Services/Dictation/DictationService.swift)) if the model is missing/evicted — so failure surfaces immediately, not after the user has spoken. On success, acquire the lease (§3), open the session, install the buffer sink (§6).
- **Live**: partials flow to the overlay (§8).
- **Stop** (`stopRecording` → `processCapturedAudio`, [:590](../../Sources/MacParakeetCore/Services/Dictation/DictationService.swift)): call `finish()`, synthesize an `STTResult` from its `String` + optional token timings (`engine: .parakeet`, `engineVariant: "unified"`, `language: "en"`; `durationMs` degrades gracefully via the existing `computeDurationMs` fallback when timings are absent), then run it through the **existing** clean/raw + AI-formatter + WAV/Dictation-row save tail **unchanged**. The live partials are a draft; the pasted text is the processed final.
- **Cancel/Undo**: `confirmCancel` resets/discards the session; `undoCancel` re-transcribes from the **retained WAV via the batch `processCapturedAudio` path** ([:500](../../Sources/MacParakeetCore/Services/Dictation/DictationService.swift)) — partials are never the source of truth for undo.
- **No silent fallback (ADR-021)**: if the streaming model is missing, live dictation throws a clear error; it never silently re-runs batch Parakeet. On an empty/failed `finish()`, surface the existing no-speech/error dictation states — any future batch-recovery on the same WAV must be a separately documented decision (it is *not* an engine fallback, but it is out of scope for v1).

### 8. Overlay: bounded live-text row within the fixed panel

- Add `var partialTranscript: String = ""` to `DictationOverlayViewModel` — which lives in the **GUI target** at [DictationOverlayController.swift:184](../../Sources/MacParakeet/Views/Dictation/DictationOverlayController.swift) (`@MainActor @Observable`), **not** in `MacParakeetViewModels` and **not** a Core type.
- Render partials as a **separate, full-width, low-emphasis row below** the existing control HStack in `recordingContent`/`holdToTalkContent` ([DictationOverlayView.swift:437](../../Sources/MacParakeet/Views/Dictation/DictationOverlayView.swift)) — `lineLimit(2)`, `~0.55` white opacity, bounded `maxWidth (~240)`, shown only while `!partialTranscript.isEmpty`.
- **The overlay NSPanel is a fixed 300×160 window never resized at runtime** (`updateSize` is dead code, [DictationOverlayController.swift:173](../../Sources/MacParakeet/Views/Dictation/DictationOverlayController.swift)). v1 renders **within** that fixed panel — no panel resize, no touching the hardcoded `pillWidth = 210` hover hit-test geometry ([:153](../../Sources/MacParakeet/Views/Dictation/DictationOverlayController.swift)). A separate row keeps the control-row width stable so the cancel/stop hover zones stay aligned. Panel growth is explicitly **deferred**.
- **Transport**: partials ride the same MainActor path that already pushes `audioLevel` — `DictationFlowCoordinator.runRecordingLevelLoop` ([DictationFlowCoordinator.swift:1022](../../Sources/MacParakeet/App/DictationFlowCoordinator.swift)). `setPartialTranscriptCallback` fires off the manager actor, so its body **must** hop to MainActor via `Task { @MainActor in … }` (the idiom at [:246](../../Sources/MacParakeet/App/DictationFlowCoordinator.swift)). `partialTranscript` is cleared on stop/cancel/processing transitions **and on session-generation change** to prevent leaking the previous session's last partial.
- **Command sessions** (`sessionKind == .command`) never show partials and never open a streaming session — this is English dictation-only.

### 9. Settings + model download

A toggle "Live dictation (Beta) — English only" in the engine/Modes settings surface ([SettingsView.swift](../../Sources/MacParakeet/Views/Settings/SettingsView.swift)), gated behind `AppFeatures.liveDictationEnabled`. A `liveDictationEnabled` `UserDefaults`-backed preference is added to `AppRuntimePreferences` ([AppRuntimePreferences.swift](../../Sources/MacParakeetCore/AppRuntimePreferences.swift)) and read by the AppEnvironment closure (§7). Enabling the toggle **downloads the model first, with progress**, reusing the warm-up/`observeWarmUpProgress` plumbing and the Whisper cold-switch UX precedent; the toggle does not flip on if the download fails. The toggle is disabled-with-reason while a live or engine session is active (`.liveDictationActive`).

### 10. Licensing (gate for Stable DMG, not for development)

The base NVIDIA Parakeet TDT 0.6B is **CC-BY-4.0**; the FluidInference CoreML conversion Echo already ships (`parakeet-tdt-0.6b-v3-coreml`) is **Apache-2.0**. The unified streaming repo (`parakeet-unified-en-0.6b-coreml`) is the same org and base family but has **no published model-card/license tag yet**. Neither base nor precedent is the restrictive NVIDIA Open Model License the original task worried about.

Decision: **build and ship behind Beta now**; before any **Stable DMG** exposure, confirm the unified repo carries an Apache-2.0/CC-BY-4.0 tag and add attribution to the app's NOTICES/about. This is a release checklist item, not a development blocker.

### 11. Out of scope (this iteration)

File/meeting streaming; multilingual streaming; CLI streaming (no `transcribe --stream`, no `Sources/CLI/CHANGELOG.md` change); overlay panel growth; persisting/displaying live partials in history; lower-latency `UnifiedConfig` tuning.

## ADR compliance

- **ADR-001 (Parakeet primary/default):** TDT v3 stays the default for all non-live paths; live is an additive English path. Compliant.
- **ADR-007 (FluidAudio CoreML/ANE, no Python):** the unified model is CoreML on CPU+ANE (int8). No Python. Compliant.
- **ADR-016 (one scheduler):** no second scheduler; the runtime owns the session and the *existing* scheduler grants the interactive-slot lease + blocks engine switches. Compliant (§3).
- **ADR-021 (explicit engine selection, no auto-fallback):** live is an explicit, separately-selected English engine with a start-time readiness gate and no silent fallback. Compliant (§7).
- **ADR-015 (shared mic):** the buffer sink rides AudioRecorder's existing shared-mic subscription; no new subscriber, no VPIO change. Compliant (§6).

## Testing strategy

Everything hangs off the `StreamingDictationEngine` protocol mock (the concrete adapter is excluded from CI, matching `AsrManager`). Integration-first, per the repo philosophy:

- Final-text path: `finish()` text flows through refine + formatter + save; saved `Dictation` has `engine = .parakeet`, `engineVariant = "unified"`, `language = "en"`.
- Start-time readiness gate throws before `.recording`; **batch transcriber gets zero calls** on a missing model (no silent fallback).
- Cancel resets the engine + clears partials + retains the WAV; undo re-transcribes the WAV via the batch path (streaming engine untouched).
- Buffer-sink format asserted 16 kHz mono Float32, invoked off the render thread.
- Partial transport sets the VM on MainActor; partials cleared across two sequential sessions (no leak).
- Lease/slot: a live session makes `engineSwitchAvailability()` return `.liveDictationActive`; `setSpeechEngine` is blocked; `endSpeechEngineSession` restores `.available`; concurrent batch `.dictation` enqueue is rejected/serialized.
- Feature gate: with `AppFeatures.liveDictationEnabled == false`, the streaming engine is never constructed.
- Command sessions never open a streaming session.

## Consequences

**Positive:** real "text as you speak" English dictation; offline-quality final paste; one control plane preserved; a clean, mockable engine seam that the follow-on streaming upgrades (Nemotron multilingual, etc.) can reuse; zero change to existing flows when the flag/toggle is off.

**Negative / accepted:** a third local speech model to download and keep on disk; ~2 s partial latency at the default config; overlay panel growth deferred (bounded text only); a third engine increases STT surface area and test matrix. The license-tag confirmation is an external dependency for Stable.

**Neutral:** the keystone for subsequent 0.15.4-based speech work; revisitable latency/quality via `UnifiedConfig`.
