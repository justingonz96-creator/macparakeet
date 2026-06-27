# Smart Dictation Endpointing — Design Spec

> Status: **ACTIVE — DESIGN (pre-implementation)**
> Date: 2026-06-27
> Scope: dictation endpointing (deciding when the user is done speaking).
> Phase 1 is the build target this cycle. Phase 2 is specified here but built in a later cycle.
> Related: ADR-001, ADR-015, ADR-016, ADR-021; `spec/05-audio-pipeline.md`, `spec/06-stt-engine.md`;
> `plans/active/2026-05-meeting-neural-echo-suppression.md` (the `MicConditioning` pattern this mirrors);
> `plans/active/2026-05-dictation-stall-integration-tests.md` (the separate Core-Audio silent-stall bug — VAD must not perturb it).

This spec was hardened by a multi-agent verification pass: every FluidAudio API claim was checked
against source, every repo integration point against `file:line`, and the combined design was put
through an adversarial review. The structural fixes from that review are baked in below.

---

## 1. Plain-English summary

Today, dictation can auto-stop after silence, but only crudely: it watches the raw microphone
*loudness* and stops when loudness drops below a fixed number for a couple of seconds. That fails in
noise (a fan or music keeps "loudness" high so it never stops) and when you trail off quietly (it
stops too eagerly). This work makes the "am I done?" decision smart in two stages:

- **Phase 1 (build now):** replace the loudness gate with a real **voice-activity detector** (Silero
  VAD v6, via FluidAudio, running on the Neural Engine). It distinguishes *speech* from *silence*
  robustly even in noise. This only runs when the user has opted into "Auto-stop after silence"
  (default OFF — no change for anyone who hasn't).
- **Phase 2 (spec only, build later):** add a *grammatical-completeness* layer so a pause **mid-thought**
  ("send the email to… *[pause]* …Sarah") doesn't cut you off. When the VAD detects a pause, we check
  whether the words so far look like a *finished* sentence; if not, keep listening. The words come from
  a **swappable source**: Tier A (default) re-transcribes with our existing engine; Tier B (opt-in,
  high-power) uses a streaming engine. No large language model — the completeness check is plain
  deterministic Swift.

---

## 2. Corrected premises (verified against code + the dependency)

The original task brief contained two assumptions that the verification pass disproved. The spec is
built on the corrected facts:

1. **"Dictation has no silence-based endpointing" — false.** It already does, just crudely. The gate
   lives in the GUI layer at [`DictationFlowCoordinator.runRecordingLevelLoop()`](../../Sources/MacParakeet/App/DictationFlowCoordinator.swift:1022),
   polling `recordingSnapshot().audioLevel` every 50 ms and stopping when `audioLevel < 0.03`
   (`silenceAutoStopThreshold`, [line 42](../../Sources/MacParakeet/App/DictationFlowCoordinator.swift:42))
   persists for `silenceDelay` seconds. It is opt-in via `silenceAutoStop` (default OFF) with a
   `silenceDelay` setting (default 2.0 s). **This work refines that mechanism; it does not introduce
   it.**

2. **"The FluidAudio 0.15.4 bump is a hard prerequisite for VAD v6" — false.** The currently-pinned
   **0.14.5** already contains: `VadManager+Streaming.swift` (`makeStreamState` / `processStreamingChunk`),
   the streaming result/event types, **Silero v6.0.0** (`ModelNames.sileroVad = "silero-vad-unified-256ms-v6.0.0"`),
   and `StreamingEouAsrManager`. Phase 1 (and even Tier B) build on the **current pin**. The separate
   keystone 0.15.4 bump is therefore a *recommended baseline / clean recompile*, **not** a blocker for
   this feature. Per the owner's decision, the bump stays **out of this branch**; this spec targets the
   API as available on 0.14.5, and the bump task — when it lands — is verified to be a no-op for these
   files (see §12).

---

## 3. Goals / non-goals

### Goals
- Replace the fixed RMS energy gate with Silero VAD v6 streaming for robust speech/silence detection
  (Phase 1).
- Keep auto-stop opt-in and default-off; reuse the existing `silenceAutoStop` / `silenceDelay`
  settings; reinterpret `silenceDelay` as "duration of VAD-judged silence before stop."
- Centralize the stop decision in a pure, unit-testable `DictationEndpointer` in `MacParakeetCore`.
- Graceful degradation: if VAD is unavailable/errors, fall back to today's exact RMS behavior.
- Spec a deterministic grammatical-completeness layer (Phase 2) with a swappable word source
  (Tier A default re-transcribe; Tier B opt-in streaming EOU), capability-gated, English-first.
- Never change the saved transcript path: it always remains the post-stop Parakeet TDT 0.6B pass
  (ADR-001 / ADR-016 preserved).
- Keep endpointing strictly decision-only — it must never sit between the mic tap and the WAV writer,
  so it cannot cause or worsen the separate Core-Audio silent-stall bug.

### Non-goals
- No always-on auto-stop; default stays OFF.
- No change to push-to-talk (hold) behavior — endpointing is hard-gated to persistent/hands-free mode.
- No heavy GPU/Python full-duplex turn-taking LMs (Moshi etc.). The completeness check is deterministic
  Swift; no LLM.
- No change to the model that produces the saved transcript (TDT 0.6B-v3 stays locked, ADR-001).
- No FluidAudio dependency bump in this branch (separate keystone task).
- Phase 2 is **not** implemented this cycle.

---

## 4. Verified dependency facts (FluidAudio, on the pinned 0.14.5 — identical at 0.15.4)

### 4.1 Silero VAD streaming (Phase 1)
- `VadManager` is a `public actor`; runs on ANE (`VadConfig.computeUnits = .cpuAndNeuralEngine`).
  Self-labeled **Beta** → treat VAD failures as an expected runtime path, not an exception.
- Streaming surface (type names from **source**, which differ from FluidAudio's docs — code against source):
  ```swift
  public func makeStreamState() -> VadStreamState
  public func processStreamingChunk(
      _ audioChunk: [Float],
      state: VadStreamState,
      config: VadSegmentationConfig = .default,   // NOT "VadStreamConfig" (docs are wrong)
      returnSeconds: Bool = false,
      timeResolution: Int = 1
  ) async throws -> VadStreamResult
  // VadStreamResult { state, event: VadStreamEvent?, probability: Float }
  // VadStreamEvent { kind: .speechStart|.speechEnd, sampleIndex: Int, time: TimeInterval? }
  ```
- `VadConfig.defaultThreshold = 0.85` in source (docs say 0.75 — trust source). `VadSegmentationConfig`
  carries hysteresis knobs; `minSilenceDuration` default **0.75 s** gates `speechEnd`.
- **Input contract: 16 kHz mono Float32, exactly 4096 samples/chunk (256 ms)** + 64-sample internal
  context. **Chunks > 4096 are silently truncated** (`.prefix(4096)`); chunks < 4096 are padded by
  repeating the last sample. `state.processedSamples` advances by the *real* count, so timing stays
  correct for the final short chunk.
- Model: `silero-vad-unified-256ms-v6.0.0.mlmodelc`, downloaded from HuggingFace repo
  `FluidInference/silero-vad-coreml` into `~/Library/Application Support/FluidAudio/Models/` — a small
  (~1.3 MB) asset, separate from the ~6 GB Parakeet bundle. Synchronous `init(config:vadModel:)` exists
  for pre-warmed/test injection.
- **Independent of `AsrManager`/`AsrModels`** at the library layer (separate HF repo, separate model
  object). Owning it outside `STTRuntime` is library-legal (see §6.1 for the ADR-016 reading).

### 4.2 Streaming EOU ASR (Phase 2 Tier B)
- `StreamingEouAsrManager` is a `public actor`. Real init (all defaulted):
  `init(configuration: MLModelConfiguration = …, chunkSize: StreamingChunkSize = .ms160, eouDebounceMs: Int = 1280, debugFeatures: Bool = false)`.
- `setPartialCallback` emits the **cumulative** transcript string after each chunk; `setEouCallback`
  fires once when end-of-utterance is confirmed after `eouDebounceMs` of model-judged silence;
  `eouDetected: Bool` is pollable. `process(audioBuffer:)` **returns `""`** — text comes only from the
  callbacks / `finish()`. Accepts any `AVAudioPCMBuffer` (resamples internally to 16 kHz mono Float32).
- Model: **Parakeet EOU 120M** (`FluidInference/parakeet-realtime-eou-120m-coreml`, 160 ms variant
  ≈ **224 MB** download), **separate** from TDT 0.6B-v3. **English-only, no punctuation/capitalization**
  in output. Runtime memory is **undocumented (~few hundred MB, MUST MEASURE)**. macOS 14 floor — OK.

### 4.3 Bump risk (informational; bump owned separately)
- Every FluidAudio symbol this repo compiles against is identical or source-compatible 0.14.5 → 0.15.4
  (one additive defaulted `progressCallback:` on offline diarizer `process(...)`, still compiles).
  `Package.swift` `.upToNextMinor(from: "0.14.5")` caps `< 0.15.0`, so the bump task must widen that
  rule. None of that is in scope for this branch.

---

## 5. Architecture overview

```text
mic (SharedMicrophoneStream)
        │  buffers (native rate)
        ▼
AudioRecorder.processCopiedBuffer  ── converts to 16 kHz mono Float32 ──► WAV file (UNCHANGED path)
        │                                                                  + sampleCounter + atomicAudioLevel
        │  (NEW, Phase 1) copy of converted frames, AFTER the WAV write, inside the sessionGeneration guard
        ▼
DictationVadProcessor (4096-sample accumulator)  ──►  DictationVadEngine (owns VadManager, ANE)
        │                                                     │ speechStart/speechEnd + probability
        ▼                                                     ▼
   VadSnapshot { available, speechActive, lastSpeechAt }  (published via OSAllocatedUnfairLock, like atomicAudioLevel)
        │
        ▼  surfaced through DictationService.recordingSnapshot()  (same seam as audioLevel)
DictationFlowCoordinator.runRecordingLevelLoop (50 ms tick)
        │  builds DictationEndpointer.Input each tick
        ▼
DictationEndpointer (PURE, Core)  ──►  .keepListening | .stop(reason)
        │  on .stop → stopDictation() (existing path)
        ▼
(unchanged) state machine → DictationService.stopRecording → TDT 0.6B post-stop transcribe → paste
```

Phase 2 adds a **word source** consulted by the coordinator during speech (not on the stop path) whose
verdict is fed to the endpointer as a pre-arrived veto (see §8).

---

## 6. Phase 1 — detailed design (BUILD THIS CYCLE)

### 6.1 Ownership: VAD lives in the capture plane, not `STTRuntime` (ADR-016 reading)

ADR-016 centralizes the **ASR control plane** (job admission, the two inference slots, TDT/Whisper
model lifecycle). VAD is **not ASR** — it produces a speech/silence *decision signal*, never a
transcript, and never occupies an inference slot. It is the same architectural category as
**diarization**, which ADR-016 §8 explicitly keeps *out* of the speech-slot scheduler. ADR-016 §3 also
states the scheduler does not own audio capture. Therefore:

- The Silero `VadManager` is owned in the **capture/endpointing layer**, mirroring the
  `MeetingEchoSuppressionRuntime` factory pattern — **not** routed through `STTRuntime`.
- This is recorded as an explicit, traceable carve-out in a new ADR (§11), analogous to diarization.

### 6.2 `DictationVadEngine` (new, `Sources/MacParakeetCore/Services/Capture/DictationVadEngine.swift`)

A small `actor` — the only place that touches `VadManager`. Warmed once, reused across dictations,
single-flight guarded (mirrors `STTRuntime.ensureInitialized`):

```swift
public actor DictationVadEngine {
    private var manager: VadManager?     // nil until warm; nil ⇒ unavailable
    private var loadFailed = false
    private var warming = false

    public func warmUpIfNeeded() async        // builds VadManager() (downloads v6 if missing) + one
                                              // throwaway 4096-zero chunk to JIT the ANE path
    public var isAvailable: Bool { manager != nil }
    public func makeStreamState() async -> VadStreamState?
    public func process(chunk: [Float], state: inout VadStreamState) async -> VadStreamEvent??  // nil ⇒ unavailable/error
}
```

- `VadConfig.default` (threshold 0.85) kept for Phase 1. **Silence-timing authority decision:** the
  library's `minSilenceDuration` is left at default and the **`DictationEndpointer` owns the
  `silenceDelay` timer** measured off `lastSpeechAt`. We do **not** map `silenceDelay` onto
  `VadSegmentationConfig.minSilenceDuration` (avoids double-counting and preserves the setting's
  meaning). The recorder updates `lastSpeechAt` whenever the per-chunk verdict is "speech," so the
  endpointer's silence timer starts at the last speech frame.
- Owned process-wide by `AppEnvironment` (next to `sttRuntime`/`sharedMicStream`/`audioProcessor`),
  injected into `AudioProcessor`/`AudioRecorder`. Warm-up is triggered **only when
  `silenceAutoStop` is true** (a `@Sendable () -> Bool` closure, like other runtime-pref closures).
  CLI/test `AudioProcessor()` init passes a no-VAD path so headless never loads it.

### 6.3 The VAD frame processor in `AudioRecorder` (decision-only, mirrors `MicConditioning`)

- New protocol + passthrough/unavailable baseline + streaming wrapper + per-frame diagnostics struct
  (no transcript/audio content), modeled exactly on
  [`MicConditioner.swift`](../../Sources/MacParakeetCore/Services/Capture/MicConditioner.swift:40)
  (`PassthroughMicConditioner` + `StreamingMeetingEchoSuppressor` + `MeetingEchoSuppressionDiagnostics`).
- **Fork point:** add the VAD tap **after** the successful `fileBox.file.write(from: convertedBuffer)`
  at [`AudioRecorder.swift:336`](../../Sources/MacParakeetCore/Audio/AudioRecorder.swift:336), inside
  the existing `sessionGeneration == tapGeneration` guard. The write path, sample counter, and stall
  diagnostics run first and are byte-for-byte unchanged. The fork only reads a *copy* of
  `convertedBuffer.floatChannelData?[0]`.
- **4096-sample accumulator (the highest-risk Phase-1 detail):** converted buffers are ~1486 samples
  (48 k→16 k), so the accumulator MUST span ~3 buffers to assemble one 256 ms VAD chunk. Never hand
  `processStreamingChunk` more than 4096 samples (silent truncation). The accumulator + `VadStreamState`
  are per-session, captured into the `processCopiedBuffer` closure (boxed `@unchecked Sendable` like
  `TapConverterCache`); because that closure runs on the serial `sharedProcessingQueue`, no extra lock
  is needed for the accumulator.
- The actual `processStreamingChunk` (an async actor call) runs on the engine's executor via a
  **non-blocking enqueue** of the owned `[Float]` chunk — never on `sharedProcessingQueue`. If the
  engine is busy/down, the writer is never backpressured.
- **Published verdict:** a new `OSAllocatedUnfairLock`-guarded `VadSnapshot` next to `atomicAudioLevel`
  ([`AudioRecorder.swift:74`](../../Sources/MacParakeetCore/Audio/AudioRecorder.swift:74)):
  ```swift
  public struct VadSnapshot: Sendable, Equatable {
      public var available: Bool          // false ⇒ coordinator uses RMS gate
      public var speechActive: Bool
      public var lastSpeechAt: Date?      // set whenever speechActive
      public static let unavailable = VadSnapshot(available: false, speechActive: false, lastSpeechAt: nil)
  }
  ```
  The enqueue's result handler updates the snapshot under the lock, dropping any result whose
  `tapGeneration` ≠ live generation. Reset to `.unavailable` per session next to the existing counter
  resets ([`:205`](../../Sources/MacParakeetCore/Audio/AudioRecorder.swift:205)) and on stop next to the
  `atomicAudioLevel` reset ([`:483`](../../Sources/MacParakeetCore/Audio/AudioRecorder.swift:483)).
- **RMS-fallback flag** is set around subscribe (not in the hot path): if the engine isn't warm/failed,
  `VadSnapshot.available` stays false and no accumulator is built — fully cold, zero cost when
  `silenceAutoStop` is off or VAD is down.

### 6.4 Surfacing the verdict (mirror the `audioLevel` seam — lowest-risk, no AsyncStream)
- `AudioProcessorProtocol`: add `var vadState: VadSnapshot { get async }`.
- `AudioProcessor` → `recorder.vadState`; `DictationService` forwards it (mirror `audioLevel`,
  [`DictationService.swift:103`](../../Sources/MacParakeetCore/Services/Dictation/DictationService.swift:103)).
- `DictationServiceSession.recordingSnapshot()` extends its returned tuple from `(state, audioLevel)`
  to `(state, audioLevel, vad: VadSnapshot)` via `async let` (its only caller is the loop).

### 6.5 The pure `DictationEndpointer` (new, `Sources/MacParakeetCore/Services/Dictation/DictationEndpointer.swift`)

Sibling of [`DictationStopDecision.swift`](../../Sources/MacParakeetCore/Services/Dictation/DictationStopDecision.swift)
— the exact precedent (pure value type + focused test). No clock (time injected), no async, no I/O.
`DictationStopDecider` is left untouched (it answers a different, orthogonal question).

```swift
public struct DictationEndpointer {
    public struct Config: Sendable, Equatable {
        public var enabled: Bool            // silenceAutoStop && recordingMode == .persistent
        public var silenceDuration: TimeInterval   // silenceDelay; VAD-judged silence
        public var rmsThreshold: Float = 0.03      // fallback gate (today's value)
        // Phase-2 fields, present so the interface is stable; unused in Phase 1:
        public var completenessEnabled: Bool = false
        public var extensionMaxWait: TimeInterval = 0   // see §8.4 — extension window, NOT total
    }
    public struct Input: Sendable, Equatable {
        public var now: Date
        public var elapsed: TimeInterval
        public var audioLevel: Float
        public var vadAvailable: Bool
        public var speechActive: Bool
        public var vadSilenceElapsed: TimeInterval?     // now − lastSpeechAt, nil if never spoke
        public var completenessVeto: CompletenessVeto?  // Phase 2 pre-arrived verdict; nil in Phase 1
    }
    public enum Decision: Sendable, Equatable { case keepListening; case stop(reason: StopReason) }
    public enum StopReason: Sendable, Equatable {
        case vadSilence; case rmsSilence; case grammaticallyComplete; case extensionMaxWait
    }
    public init(config: Config)
    public mutating func evaluate(_ input: Input) -> Decision
}
```

Phase-1 logic: when `vadAvailable`, stop after `silenceDuration` of VAD-judged silence
(`!speechActive` and `vadSilenceElapsed >= silenceDuration`); otherwise reproduce today's RMS
arithmetic exactly (`audioLevel >= rmsThreshold` resets the silence timer; else stop after
`silenceDuration`). A `didStop` latch ensures one `.stop` per session.

### 6.6 Rewrite `runRecordingLevelLoop()`
- Build one `DictationEndpointer` before the loop with
  `Config(enabled: silenceAutoStop && mode == .persistent, silenceDuration: silenceDelay, rmsThreshold: 0.03)`.
  **Push-to-talk gate:** thread the recording `mode` (carried in `.recording(mode:)`,
  [`:80`](../../Sources/MacParakeet/App/DictationFlowCoordinator.swift:80)) into the loop and require
  `.persistent`, so silence can never cut off a physical hold.
- Each tick: keep `overlayViewModel?.audioLevel = snapshot.audioLevel` (drives the waveform); compute
  `vadSilenceElapsed`; build `Input`; call `endpointer.evaluate`; on `.stop`, `stopDictation()` + break.
- Remove the inline `lastNonSilenceAt`/`didAutoStop` locals (now inside the endpointer). No
  state-machine or hotkey-controller changes.

### 6.7 Settings / UX (Phase 1 reuses existing keys)
- No new keys. `silenceAutoStop` now means "VAD-judged silence"; `silenceDelay` now means "duration of
  VAD-judged silence before stop." **Update the helper copy** in
  [`SettingsView.swift`](../../Sources/MacParakeet/Views/Settings/SettingsView.swift:728) so it no longer
  describes an energy gate. Default stays OFF.

### 6.8 Telemetry (Phase 1; additive, no content)
- `silenceAutoStop` setting event already exists. Add **additive optional props** to the existing
  `dictationCompleted`/`dictationOperation` events (house style favors additive props over new events):
  `endpoint_reason` (enum `vad_silence | rms_fallback | manual`) and `vad_available: Bool`. The
  endpointer returns only an enum → the coordinator buckets it at completion. **Never** log audio,
  partial text, or which signal matched.

### 6.9 VAD asset & the offline guarantee (ADR-002)
The Silero v6 asset (~1.3 MB) is fetched on first `VadManager` init. To keep auto-stop reliable offline
and honor ADR-002 local-first: **fold the VAD asset into the existing model warm/onboarding download
path** (negligible vs the 6 GB Parakeet bundle). Until fetched, auto-stop transparently uses the RMS
fallback for that session. (A test covers the offline-unavailable → RMS path.)

### 6.10 Invariant: decision-only vs the silent-stall bug
Phase 1 changes only the *stop trigger*, never the audio data path. The WAV is written by unchanged
code before the VAD fork runs; VAD reads a copy and publishes a poll-able boolean. There is no path
where VAD can prevent or delay a file write, so it cannot create or worsen the silent stall. The VAD
enqueue must never share a lock with the writer path; the published snapshot uses its own
`OSAllocatedUnfairLock` exactly like `atomicAudioLevel`. A regression check asserts `output_buffers`
/ write cadence in `dictation_capture_stop` diagnostics are unchanged with VAD enabled.

---

## 7. Phase 1 — PR sequencing (risk isolation)

Land in two PRs even though both compile on 0.14.5:

- **PR 1 — pure logic, zero FluidAudio surface (highest value, lowest risk):** `DictationEndpointer.swift`
  + tests, and the `runRecordingLevelLoop` rewrite wired so that with `vadAvailable == false` it
  reproduces today's RMS behavior exactly (the snapshot just always reports `.unavailable` until PR 2).
  Fully `swift test`-verifiable immediately; establishes the green baseline CLAUDE.md requires.
- **PR 2 — VAD wiring:** `DictationVadEngine`, the `AudioRecorder` frame processor + accumulator,
  `VadSnapshot` plumbing, warm-up, onboarding asset, telemetry. Builds on 0.14.5; the separate keystone
  bump remains a future no-op.

---

## 8. Phase 2 — grammatical completeness (SPEC ONLY; build later)

> **Status: PROPOSAL — not built this cycle.** Builds on the Phase-1 seams. The adversarial review's
> structural fixes are incorporated; the original "synchronous query on the stop path" design is
> explicitly rejected.

### 8.1 The completeness rule set (pure, deterministic)
New pure value type `GrammaticalCompletenessChecker` (Core, sibling of `DictationStopDecision.swift`):
`(text, language, config) -> CompletenessVerdict` where verdict is `.complete` / `.incomplete(reason)` /
`.indeterminate`. Normalize (trim, NFC, word-tokenize). Rules:
- **R1 terminal punctuation** (strong positive): last non-whitespace char is `. ! ? …` (Latin/Cyrillic/Greek)
  or `。！？…` (CJK, Whisper path). Closing quote/paren preceded by terminal punct counts; `;` does not.
- **R2 trailing-token blocklist** (strong negative → `.incomplete`): last word is a conjunction,
  preposition, article/determiner, dangling auxiliary / to-infinitive, or filler (um/uh/like/so/…).
  Finite, language-keyed tables (English shipped first).
- **R3 min words** (gate): `< minWords` (default 3) is not stop-eligible unless R1 fired and
  `minWordsWithTerminalPunct` (default 1) is met (so "Okay." is complete; bare "okay" is not).
- **R4 extension max-wait** (safety; owned by the endpointer, see §8.4).
- **Precedence:** R2 (dangling tail) → incomplete; else R1 + R3 → complete; else `.indeterminate`.
- **Language handling:** ship English tables; for other Parakeet languages with no table, use R1
  (script-aware) + R3 + R4 and **skip R2** — degrades to "stop on terminal punctuation or max-wait,"
  still strictly better than Phase-1 silence-only, never worse.

### 8.2 Swappable word source
```swift
public protocol EndpointWordSource: Sendable {
    func beginSession(sessionID: Int) async
    func endSession(sessionID: Int) async
    /// Tier A: latest cached verdict from speculative-during-speech transcribes.
    /// Tier B: latest cumulative partial + EOU flag. Returns nil ⇒ no signal (treat as no veto).
    func latestVeto(sessionID: Int) async -> CompletenessVeto?
}
```
- `RetranscribeWordSource` (Tier A, default), `StreamingEouWordSource` (Tier B, opt-in),
  `PassthroughWordSource` (fallback → Phase-1 VAD-silence-only). Mirrors the `PassthroughMicConditioner`
  fallback discipline.
- `CompletenessVeto { verdict: CompletenessVerdict, modelEouSignaled: Bool, generatedAt: Date, sessionID: Int }`
  is the **only** thing that reaches the GUI/endpointer — the partial **text never leaves Core** (privacy, §8.7).

### 8.3 The critical fix: completeness is a *pre-arrived veto*, not a stop-path query
The original design queried a transcribe synchronously at silence-onset and judged a *stale pre-pause*
partial — adding latency to every stop and risking never-stop-until-max-wait. **Rejected.** Instead:
- The endpointer's **default is to stop on VAD silence** (Phase-1 behavior). Completeness only
  **extends** listening when a *fresh* veto says `.incomplete`.
- Tier A runs the preview transcribe **speculatively during speech** (debounced, ~every 1.5 s of
  accumulated audio), caches the latest `CompletenessVeto`. At silence-onset the endpointer consults the
  cached veto with a **freshness deadline** (e.g. < 800 ms old). No fresh veto ⇒ stop on `vadSilence`.
  This bounds added stop-path latency to **zero** in the happy path.
- The coordinator passes the cached veto into `Input.completenessVeto` each tick; `evaluate` stays
  synchronous and pure (testable with synthetic vetoes). No `requestCompletenessCheck` async gap in the
  loop.

### 8.4 `extensionMaxWait` (not total elapsed)
`hardMaxWait` is redefined as a bound on the **extension window** — the time spent waiting *past*
`silenceDelay` because completeness said incomplete (e.g. 4 s). It is **not** total recording time, so
long continuous hands-free dictation is never force-stopped mid-sentence. Enforced in the endpointer
(it has the clock); reason `.extensionMaxWait`.

### 8.5 Tier A — audio-so-far, scheduler, cancellation (ADR-016-compliant)
- **Audio-so-far:** the Phase-1 VAD frame processor *also* appends converted frames to a
  capacity-bounded (≈30 s) `[Float]` ring owned by the VAD coordinator. The ring is written on the
  already-serial `sharedProcessingQueue` (no new lock); Tier A reads it via a **copy-out published as an
  immutable snapshot** (double-buffer, mirroring `atomicAudioLevel`) so the reader never holds a lock the
  writer path needs. Never touches the live WAV writer. A regression test asserts write cadence is
  unchanged with the ring enabled.
- **Scheduler:** add a new `STTJobKind.dictationEndpointPreview` mapped to the **background** slot with
  `priorityRank` below `fileTranscription` (lowest). It **must not** reuse `.dictation` (which occupies
  the reserved interactive slot and would delay the user-visible post-stop paste transcribe). Route only
  through the existing `sttScheduler`/`STTClient` — never a standalone `AsrManager` (ADR-016 / CLAUDE.md).
- **Contention + cancellation:** hard-cancel any in-flight preview the instant `.stopRequested` fires,
  *before* the real `.dictation` job is enqueued; the preview checks a cancellation flag between chunks.
  Invariant (+ test): **zero preview jobs in flight when the interactive dictation transcribe starts.**
- **Session safety:** every `CompletenessVeto` and every coordinator feedback call is stamped with the
  `sessionID` captured at request time; before applying a veto or stopping, re-check `sessionID` matches
  and state is still `.recording`. Tests: restart-during-await, toggle-stop-during-await,
  cancel-during-await.

### 8.6 Tier B — `StreamingEouAsrManager` (opt-in, capability-gated, default OFF)
- Owned in the endpointing layer (a `DictationEouEngine` actor), **not** in `STTRuntime`; recorded as an
  explicit ADR-016 carve-out (analogous to diarization). Lifecycle bounded to the dictation session;
  lazy `loadModels()` of the 160 ms variant; never holds an STT scheduler slot.
- **Capability gate — all must hold to offer/engage:** compile-time `AppFeatures.highAccuracyEndpointingEnabled`;
  `ProcessInfo.physicalMemory >= 16 GB` (shipped heuristic, owner-tunable — **MUST MEASURE** real RSS
  first); resolved language == **English** (EOU is English-only/unpunctuated → R1 never fires, leans on
  R2/R3 + the model's `<EOU>`); successful lazy model load (else permanent fall-back to Tier A).
- **Meeting concurrency (hysteretic, not flapping):** decide Tier B vs Tier A **once at dictation
  start** based on whether a meeting recording session is active; if active, use Tier A for the whole
  dictation. Do not suspend/resume per intermittent meeting live-chunk job (that would oscillate the
  word source mid-dictation). This sidesteps needing a new fine-grained scheduler query and keeps
  ADR-015/016 invariants intact.
- **EOU contradiction rule:** if the model signals `<EOU>` but our deterministic checker says
  `.incomplete` (dangling tail), our checker wins (keep listening) — conservative, avoids cutting a
  dangling clause on a model false-positive. If checker is `.complete`/`.indeterminate` and EOU fired →
  stop (`.grammaticallyComplete`), since EOU output has no punctuation for R1.
- Download (~224 MB) is **lazy on first Tier-B enable**, not onboarding.

### 8.7 Settings, telemetry, overlay (Phase 2)
- New keys (mirror `silenceAutoStop`/`silenceDelay`): `sentenceEndAutoStop` (Tier A; default OFF) and
  `highAccuracyEndpointing` (Tier B; default OFF, `isBeta`, gated by `AppFeatures` + capability). If it
  ever needs 3 mutually-exclusive states, prefer one `endpointingMode` enum (per `NumberRefinementMode`).
  Rows added under the existing auto-stop block, the sentence-end row shown only when `silenceAutoStop`
  is on.
- Telemetry: add `TelemetrySettingName.sentenceEndAutoStop` / `.highAccuracyEndpointing`; extend
  endpoint outcome with `tier (a|b)`, `completeness_passed: Bool`, `wait_ms` (bucketed),
  `endpoint_reason` (+ `sentence_complete | model_eou | extension_max_wait`). **Never** the partial
  string, the matched word, or the language-table key. Consider passing a pre-computed `CompletenessVeto`
  (not raw text) so the GUI layer never holds the transcript at all.
- **Overlay UX (the one missing-coverage UX decision):** during the extension window (VAD silence
  expired but endpointer is waiting for completeness), the overlay must show a subtle "still listening"
  state so users don't think auto-stop is broken. Define this when Phase 2 is built.

### 8.8 Engine interaction (ADR-021)
- VAD endpointing is engine-agnostic (taps pre-STT 16 kHz samples). Tier A uses whatever engine/language
  is active (Parakeet auto-detect or Whisper), so its partials are punctuated/cased → R1 works
  cross-language. Tier B is Parakeet-EOU-only/English-only → hard-disabled for Whisper/non-English,
  silently falling back to Tier A.

### 8.9 Edge cases (selected)
- "Hi." → R1 + `minWordsWithTerminalPunct` → complete. Bare "hi" → too-short → wait → extension-max-wait.
- "I think that" → R2 dangling → never stops on completeness, only extension-max-wait (the bug Phase 2 fixes).
- User resumes before `silenceDelay` → completeness never consulted; fold new audio, re-judge next pause.
- VAD unavailable mid-session → RMS fallback; completeness gate inert (no reliable pause signal).
- Push-to-talk → endpointing hard-gated to `.persistent`; Tier A/B never run in hold-to-talk.

---

## 9. Testing strategy

**Phase 1 (this cycle):**
- `DictationEndpointerTests` — pure, table-driven, injected clock (mirror `DictationStopDecisionTests`):
  VAD-silence stop timing, RMS fallback parity with today, push-to-talk-disabled (`enabled=false` never
  stops), one-stop latch.
- `DictationVadProcessorTests` — mock VAD; **byte-exact chunking**: feed a known ramp in ~1486-sample
  buffers, assert emitted 4096-chunks reconstruct the input contiguously with zero dropped/duplicated
  samples across buffer boundaries and that **no chunk > 4096** is ever emitted; leftover-tail at stop
  handled; unavailable/error → fallback diagnostics (mirror `MeetingEchoSuppressorTests` /
  `MeetingEchoSuppressionRuntimeTests`).
- `SettingsViewModelTests` — copy/behavior unchanged for `silenceAutoStop`/`silenceDelay`.
- Decision-only regression: assert `dictation_capture_stop` `output_buffers`/write cadence unchanged
  with VAD enabled.
- Offline → RMS fallback path test.
- Synthetic-audio integration tests (clean speech / noisy / trailing-pause) gated like
  `MACPARAKEET_HARDWARE_TESTS` (real-mic/asset-dependent).
- Full `swift test` (must pass), then dev-app smoke via `scripts/dev/run_app.sh`: dictate with
  auto-stop on (noisy + quiet-trail-off), confirm push-to-talk unaffected, confirm VAD-down → RMS.

**Phase 2 (later):** `GrammaticalCompletenessCheckerTests` (rule tables, languages); veto-freshness +
session-stamp race tests (restart/toggle/cancel during await); preview-cancel-on-stop invariant test;
ring write-cadence regression; privacy regression (no partial/saved text in any endpointing telemetry
payload); long-continuous-speech-never-force-stopped test.

---

## 10. Latency budget (explicit)
Happy-path stop decision must fire within **one poll tick (~50 ms)** of `silenceDelay` expiry. No design
may add a *synchronous* transcribe to the stop path (this is why Tier A is a pre-arrived veto, §8.3).
Any future change that adds synchronous work to the stop decision fails this budget.

---

## 11. ADR / spec / kernel updates
- **New ADR-023** "Grammatical-completeness dictation endpointing + VAD/EOU capture-plane carve-out":
  records (a) Silero VAD owned in the capture plane (ADR-016 carve-out, like diarization), (b) the
  deterministic completeness rule set, (c) the Tier-A/Tier-B swappable source + the Tier-B EOU
  off-scheduler carve-out with the per-session meeting-hysteresis guard, (d) the new
  `dictationEndpointPreview` background `STTJobKind`, (e) preservation of ADR-001 (saved transcript
  always TDT 0.6B). Cross-reference ADR-001/002/015/016/021.
- `spec/kernel/requirements.yaml`: add **`REQ-DICT-007`** "Smart dictation endpointing — Silero VAD v6
  judged silence (Phase 1) + deterministic grammatical-completeness gate (Phase 2), opt-in, RMS
  fallback." `spec/kernel/traceability.md`: map to the new/changed files + tests. Leave `REQ-STT-001`
  unchanged (this feature must not alter the Parakeet/runtime path).
- Doc hygiene: `spec/05-audio-pipeline.md` (endpointing subsection: silence onset → completeness gate),
  `spec/06-stt-engine.md` (promote Silero VAD + EOU 120M to documented endpointing features; note EOU's
  English-only/no-punctuation), `spec/02-features.md`/`spec/README.md` progress markers.

---

## 12. Risks & open decisions
- **Tier B memory + 16 GB threshold are MUST-MEASURE-BEFORE-SHIP**, not defaults. Treat as blockers when
  Phase 2 is built.
- **VAD threshold tuning** (0.85 default vs dictation close-mic) — validate during Phase 1 dev; expose
  only if needed.
- **Keystone bump:** out of this branch. When it lands, verify it's a clean recompile for the FluidAudio
  symbols this repo uses (the bump-risk pass found only one additive defaulted param on offline
  diarizer `process`); no source edits expected here beyond the bump task widening `Package.swift`.
- **`silenceDelay` default (2.0 s)** kept; revisit if VAD makes a shorter default feel right.

---

## 13. Acceptance criteria (Phase 1)
- With auto-stop ON in a noisy environment, dictation no longer fails to stop (VAD distinguishes
  noise from speech); when trailing off quietly, it stops appropriately.
- Auto-stop OFF (default) behaves exactly as today; no VAD model is loaded.
- VAD unavailable/offline → exact today's RMS behavior; auto-stop never breaks.
- Push-to-talk (hold) is never auto-stopped.
- No change to saved-transcript accuracy or the post-stop transcribe path.
- VAD cannot cause/worsen the silent-stall bug (decision-only invariant; write cadence unchanged).
- Full `swift test` passes; dev-app smoke confirms the above.
