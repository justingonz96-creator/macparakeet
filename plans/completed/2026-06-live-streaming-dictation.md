# Live Streaming Dictation

> Status: **IMPLEMENTED** — merged behind `AppFeatures.liveDictationEnabled` on `main`; full `swift test` green (REQ-LIVEDICT-001). Pending: hands-on dev-app smoke against the real CoreML model + Stable-DMG license confirmation (ADR-023 §10).
> Drafted: 2026-06-27
> ADR: `spec/adr/023-live-streaming-dictation.md` (locks the architecture); also `spec/adr/016-centralized-stt-runtime-scheduler.md`, `spec/adr/021-whisperkit-multilingual-stt.md`, `spec/adr/001-parakeet-stt.md`, `spec/adr/007-fluidaudio-coreml-migration.md`
> Scope: Add an opt-in, English-only, Beta live-streaming dictation path (FluidAudio `StreamingUnifiedAsrManager`) behind `AppFeatures.liveDictationEnabled`. No change to batch dictation, file/meeting transcription, the scheduler slot topology, or any flow when the flag/toggle is off.
> Prereq: STEP 1 done — FluidAudio pinned to 0.15.4 (`Package.swift`), `swift build` + `swift test` green.

## 1. Problem

Dictation is batch-only: text appears only after the user stops speaking (`DictationService.processCapturedAudio` → `transcribe(audioPath:job:.dictation)`, `DictationService.swift:603`). FluidAudio 0.15.4 ships a real streaming backend (`StreamingUnifiedAsrManager`, Parakeet Unified 0.6B, English-only) that can drive live partial results. The challenge is wiring a **stateful** streaming session through Echo's **single** STT control plane (ADR-016) without a second scheduler and without a silent fallback (ADR-021). ADR-023 locks the design; this plan executes it TDD-first.

## 2. Architecture in one paragraph (per ADR-023)

`STTRuntime` owns the streaming session (model download/load, open/close, reset/cleanup) — like it already owns `AsrManager`/`WhisperEngine`. The **scheduler is touched only for the lease**: a live session calls the existing `beginSpeechEngineSession()`/`endSpeechEngineSession()`, which already blocks engine switches; we add a `.liveDictationActive` availability reason and guard concurrent batch `.dictation`. Mic audio reaches the session via a new **AudioRecorder buffer sink** (post-conversion 16 kHz mono Float32, off the render thread) — the WAV is still written. `DictationService` gains a streaming branch: a start-time readiness gate, partials to the overlay, and on stop `finish()`'s text re-enters `processCapturedAudio` (synthesized `STTResult`) so the existing clean/format/save tail is unchanged. Everything mockable hangs off one Core-owned `StreamingDictationEngine` protocol.

## 3. Files

**Create**
| Path | Purpose |
|---|---|
| `Sources/MacParakeetCore/STT/StreamingDictationEngine.swift` | Core `Sendable` protocol + `StreamingDictationResult` (text + optional `[TimestampedWord]`). THE mock seam. |
| `Sources/MacParakeetCore/STT/FluidStreamingDictationEngine.swift` | Concrete adapter over FluidAudio `StreamingUnifiedAsrManager` (download `parakeet-unified-en-0.6b-coreml`, int8 load w/ progress, `consumeTokenTimings()` → words). |
| `Tests/MacParakeetTests/StreamingDictationEngineMock.swift` | Scriptable mock: partials, `finish()` text + timings, failure/empty, readiness toggle, reset/cleanup assertions. |
| `Tests/MacParakeetTests/LiveDictationFlowTests.swift` | `DictationService` streaming-branch integration tests (final-text pipeline, cancel/undo, start-gate, lease). |
| `Tests/MacParakeetTests/STTRuntimeStreamingSessionTests.swift` | Runtime opens/closes session + blocks engine switch (`.liveDictationActive`) for session lifetime. |

**Modify**
| Path | Change |
|---|---|
| `Sources/MacParakeetCore/AppFeatures.swift` | Add `liveDictationEnabled` (default `false`; `true` on `main`). |
| `Sources/MacParakeetCore/AppRuntimePreferences.swift` | Add `liveDictationEnabled` `UserDefaults` pref + accessor. |
| `Sources/MacParakeetCore/STT/STTClientProtocol.swift` | Add `SpeechEngineSwitchAvailability.liveDictationActive`; surface the begin/end live-session API on the session-managing protocol. |
| `Sources/MacParakeetCore/STT/STTRuntime.swift` | Own `StreamingDictationEngine` (lazy prepare/download w/ progress); open/close session + `isStreamingReady`. Batch path untouched. |
| `Sources/MacParakeetCore/STT/STTScheduler.swift` | Map the live lease into `engineSwitchAvailability()` (`.liveDictationActive`); guard batch `.dictation` enqueue while a live session holds the interactive slot. Reuse `begin/endSpeechEngineSession`. |
| `Sources/MacParakeetCore/Audio/AudioRecorder.swift` | Optional `@Sendable ([Float])->Void` sink (16 kHz mono Float32 samples — `Sendable`, no buffer-lifetime risk), invoked in `processCopiedBuffer` after conversion (~:336), on `sharedProcessingQueue`. |
| `Sources/MacParakeetCore/Audio/AudioProcessor.swift` (+ `AudioProcessorProtocol.swift`) | Install/clear the streaming buffer sink per session. |
| `Sources/MacParakeetCore/Services/Dictation/DictationService.swift` | `liveDictationEnabled` closure dep; streaming branch in `startRecording` (readiness gate before `_state=.recording`; open session + install sink), `stopRecording`/`processCapturedAudio` (`finish()` → synthesized `STTResult`), `confirmCancel`/`undoCancel` (reset session; undo via batch WAV path). |
| `Sources/MacParakeet/App/AppEnvironment.swift` | Add `liveDictationEnabledClosure` over `runtimePreferences` (mirror `aiFormatterEnabledClosure` ~:170) and pass into `DictationService` (~:193). |
| `Sources/MacParakeet/Views/Dictation/DictationOverlayController.swift` | Add `var partialTranscript: String = ""` to `DictationOverlayViewModel` (~:213-232). |
| `Sources/MacParakeet/Views/Dictation/DictationOverlayView.swift` | Bounded low-emphasis partial row below `recordingContent`/`holdToTalkContent` (`lineLimit(2)`, opacity ~0.55, `maxWidth ~240`); suppressed for command sessions. |
| `Sources/MacParakeet/App/DictationFlowCoordinator.swift` | Register MainActor-hopping partial callback (pattern at :246-265); clear on stop/cancel/processing + generation change. |
| `Sources/MacParakeet/Views/Settings/SettingsView.swift` (engine/Modes section) | "Live dictation (Beta) — English only" toggle gated on `AppFeatures.liveDictationEnabled`; model download-on-enable with progress; disabled-with-reason during live/engine session. |
| `spec/kernel/requirements.yaml` / `spec/kernel/traceability.md` | New requirement ID + source/test mapping. |
| `spec/README.md`, `spec/02-features.md`, `spec/06-stt-engine.md`, `CLAUDE.md` | Doc updates (Beta live dictation) once shipping. |

## 4. Build sequence (TDD; verify after each step)

1. **Flag + pref + closure.** `AppFeatures.liveDictationEnabled`, `AppRuntimePreferences.liveDictationEnabled`, `AppEnvironment` closure. → Verify: builds; closure `false` by default; `swift test` baseline green.
2. **Protocol + mock.** `StreamingDictationEngine` + `StreamingDictationResult` + `StreamingDictationEngineMock`. → Verify: trivial conformance test (red→green).
3. **Runtime session.** `STTRuntime` open/close live session + lazy `prepare(onProgress:)` over the protocol (inject mock). → Verify: `STTRuntimeStreamingSessionTests` green.
4. **Scheduler lease/availability.** Add `.liveDictationActive`; wire into `engineSwitchAvailability()` + batch `.dictation` enqueue guard, reusing `begin/endSpeechEngineSession`. → Verify: lease/slot tests green; existing STT tests green.
5. **AudioRecorder sink.** Post-conversion 16 kHz sink + `AudioProcessor`/protocol install/clear. → Verify: buffer-format test (16 kHz mono Float32, off render thread); existing Audio tests green.
6. **DictationService branch.** Readiness gate, session open + sink install on start, `finish()`→`processCapturedAudio` with synthesized `STTResult` on stop, reset/teardown + batch-WAV undo on cancel/undo. Write `LiveDictationFlowTests` FIRST (red), then implement (green).
7. **Overlay text.** `partialTranscript` on the VM; bounded separate row in the view (command sessions suppressed). → Verify: VM property test + manual visual check within 300×160.
8. **Coordinator transport.** MainActor-hopping partial callback; clear on stop/cancel/processing + generation change. → Verify: partial-transport + no-leak tests green.
9. **Settings toggle.** Gated toggle + download-on-enable progress + disabled-with-reason. → Verify: gating test; manual Settings smoke.
10. **Adapter + docs.** `FluidStreamingDictationEngine` against real 0.15.4; ADR/kernel/spec doc updates; full `swift test`; `scripts/dev/run_app.sh` end-to-end (download model, dictate live, paste, cancel/undo). → Verify: green + ADR-001/007/016/021 compliance reviewed.

## 5. Risk register (from the 2026-06-27 hardening pass)

| Risk | Sev | Mitigation |
|---|---|---|
| Second control plane / ADR-016 breach | High | Runtime owns session; scheduler only leases the interactive slot via existing `begin/endSpeechEngineSession`. No buffers through the scheduler. |
| Render-thread / `Sendable` violation forwarding buffers | High | Option (a) sink only — invoked in `processCopiedBuffer` on `sharedProcessingQueue` after copy+convert. Never a second raw render-thread subscriber. |
| Raw multi-channel/VPIO buffer → channel-averaging corruption | High | Sink emits AudioRecorder's post-`extractChannelZero`, 16 kHz mono Float32 buffer (~AudioRecorder:336); test asserts mono 16 kHz. (Manager resamples internally, so rate alone is not the risk — channel extraction is.) |
| Missing/evicted model surfaces only after speaking (ADR-021) | High | Start-time readiness gate throws before `_state=.recording`; Settings-time download for cold case; no silent batch fallback. |
| Overlay clipping in fixed 300×160 panel | Med | Bounded separate row (`lineLimit(2)`, `maxWidth~240`); no panel resize; don't touch `pillWidth=210` hover geometry. |
| Stale partial leaks into next session | Med | Clear `partialTranscript` on stop/cancel/processing + session-generation change; assert in flow tests. |
| `@MainActor` data race from off-actor partial callback | Med | Hop to MainActor (`Task { @MainActor in … }`, the :246-265 idiom). |
| `finish()` empty/failure with no recovery | Med | Surface existing no-speech/error states; no silent batch re-run (any recovery is a separate ADR decision). |
| Engine-switch reason mislabeled `.meetingActive` | Low | Add `.liveDictationActive` and use it in Settings copy. |
| Coarse `durationMs` without word timings | Low | Use `consumeTokenTimings()`; `wordCount*150ms` fallback acceptable when absent. |
| CI can't run real CoreML | Low | All tests target the protocol mock; adapter excluded from unit tests (AsrManager posture). |
| Extra model disk footprint confuses users | Low | Settings-time download with progress + clear copy; confirm cache path/size before string copy. |

## 6. Out of scope

File/meeting streaming; multilingual streaming; CLI streaming; overlay panel growth; live-partial persistence in history; `UnifiedConfig` latency tuning. (See ADR-023 §11.)

## 7. Definition of done

All §4 verifications pass; full `swift test` green; live dictation works end-to-end via `scripts/dev/run_app.sh` (download → live partials → offline-quality paste → cancel/undo); flag `false` ⇒ zero behavior change; ADR-023 + kernel/spec docs updated; license confirmation tracked as the Stable-DMG gate (ADR-023 §10).
