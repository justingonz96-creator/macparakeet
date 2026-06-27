# ADR-023: Nemotron as an Optional European-Language STT Engine

> Status: PROPOSAL
> Date: 2026-06-27
> Related: ADR-001 (Parakeet primary STT), ADR-007 (FluidAudio CoreML migration), ADR-016 (centralized STT runtime + scheduler), ADR-021 (WhisperKit optional multilingual STT), ADR-012 (telemetry)

## Context

ADR-021 added WhisperKit as an optional, opt-in second STT engine so MacParakeet/Echo
could transcribe languages Parakeet TDT v3 does not cover (Korean, Japanese, Chinese,
and ~95 more), while keeping Parakeet as the fast default. That decision still holds.

WhisperKit's cost is its download: the default `large-v3-v20240930_turbo_632MB` variant is
a ~632 MB download and pays a multi-minute, per-install CoreML "optimize for this Mac" step
on first load. For a user whose audio is **European / Latin-script** (English, Spanish,
French, Italian, Portuguese, German) but who wants something other than Parakeet — or who
wants streaming — that is a heavy install for a narrow need.

FluidAudio 0.15.x ships a CoreML/ANE build of **NVIDIA Nemotron 3.5 ASR Streaming
Multilingual 0.6B**. It includes a **Latin-script-pruned** variant covering exactly
EN/ES/FR/IT/PT/DE, distributed as precompiled `.mlmodelc` (no multi-minute optimize step),
and is a smaller, lighter alternative to the 632 MB Whisper download for those languages.

The requirement is the same shape as ADR-021:

- keep Parakeet TDT v3 the default fast path for dictation, file, and meeting work;
- keep WhisperKit for breadth (~100 languages, including CJK);
- add Nemotron as a **third optional, opt-in** engine for European/Latin-script audio;
- selection stays **explicit** — no automatic fallback (ADR-021 §"Why not auto-fallback");
- expose it through the versioned CLI;
- **do not ship it until the model license is confirmed.**

This ADR is verified against the actual FluidAudio source at tag `v0.15.4`
(commit `b9d43724`), the current Echo codebase, and the live Hugging Face model cards
(June 2026). Where FluidAudio's own docs disagreed with its source, the source governs.

### Why Nemotron does **not** replace Parakeet or Whisper

- Parakeet TDT v3 is the accuracy/latency default; Nemotron's streaming WER on Latin
  languages (~4.8–10.8%) is higher than Parakeet's batch WER (~2.5%).
- Whisper keeps the breadth role: Nemotron's pruned build is European-only, and the full
  multilingual Nemotron build is weak at Chinese/Japanese (high CER) — so adding the full
  build would mostly duplicate Whisper at lower quality. We ship **only the pruned European
  build** and leave CJK/breadth to Whisper.

## Decision

### 1. Add `.nemotron` as a third `SpeechEnginePreference`, opt-in and flag-gated

```swift
public enum SpeechEnginePreference: String, CaseIterable, Codable, Sendable {
    case parakeet
    case whisper
    case nemotron   // NEW
}
```

Parakeet stays the default. Nemotron is never auto-selected. Every user-facing surface is
gated behind a new compile-time flag (see §7).

### 2. Scope: finished-audio (batch) only this round

Echo's transcription control plane (ADR-016) processes **finished audio in one pass**
(a file, a captured dictation buffer, a meeting recording). Nemotron plugs into that same
path, exactly like `WhisperEngine`. The FluidAudio Nemotron manager is a *streaming* API,
but we drive it in a feed-the-whole-file-then-finish pattern (see §3) to fit the existing
batch contract.

**Live, as-you-speak streaming dictation is explicitly out of scope** for this ADR. It
would require new wiring outside ADR-016's batch scheduler and is deferred to a future ADR
if there is demand.

### 3. Add `NemotronEngine`, modeled on `WhisperEngine`

A new actor `Sources/MacParakeetCore/STT/NemotronEngine.swift` conforms to the same
`STTTranscribing` shape and mirrors `WhisperEngine`'s structure (serialized via an
`AsyncPermit`, lazy `prepare()`, `unload()`, `isReady()`, static `downloadModel(...)`,
`isModelDownloaded(...)`, `STTError` mapping). It wraps FluidAudio's
**`StreamingNemotronMultilingualAsrManager`** (a public Swift `actor`).

Verified batch-over-streaming flow for a finished file (FluidAudio `v0.15.4`):

1. Load once: `let m = StreamingNemotronMultilingualAsrManager(); try await m.loadModels(from: variantDir)`.
2. Set the language prompt: `await m.setLanguage("fr-FR")` (optional; see §4).
3. Resample to 16 kHz mono Float32: `let samples = try AudioConverter().resampleAudioFile(fileURL)`
   (FluidAudio's `AudioConverter`, the same component Parakeet uses).
4. Feed the whole buffer: `_ = try await m.process(samples: samples)` — `process(...)`
   always returns `""`; it internally chunks the buffer.
5. Finalize: `let (text, timings) = try await m.finishWithTokenTimings()`.
6. Language: `let detected = await m.detectedLanguage()`.

The wrapper returns an `STTResult(engine: .nemotron, ...)`. Timing handling is the one
substantive difference from Whisper and is specified in §5.

### 4. European-only by construction; `NemotronLanguageCatalog`

FluidAudio selects the **Latin-script-pruned** build by *language-routing in the
downloader*: `languageDirectory(for:)` returns `"latin"` for codes prefixed
`en/es/fr/it/pt/de`, and `"multilingual"` for everything else (including `"auto"`, `zh`,
`ja`, `ko`). The chosen folder becomes the Hugging Face subdirectory
`<latin|multilingual>/<chunkMs>ms` inside the single repo
`FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML`.

**Critical consequence:** passing `"auto"` downloads the *full 13k-token multilingual*
model — the heavy build we explicitly do not want. Therefore `NemotronEngine` **always
routes its download to the `latin/` subtree** (European-only by construction), regardless
of the user's language pin. The user's language pin is used only as the inference
`prompt_id` (via `setLanguage`), never to widen the download.

A new `Sources/MacParakeetCore/NemotronLanguageCatalog.swift` defines the allowlisted set
— EN/ES/FR/IT/PT/DE plus an in-set "auto" that still resolves to the `latin` build. We do
**not** reuse `WhisperLanguageCatalog` (it accepts ~99 languages, which would let a user pin
Korean to a model that can't produce it). `SpeechEnginePreference.normalizeLanguage` must
gain a Nemotron-specific path that validates against this catalog.

### 5. Timing: derived word-level timestamps, with documented caveats

The Nemotron API returns the transcript as a plain `String` from `finish()`. Timestamps are
available only via `finishWithTokenTimings() -> (text: String, timings: [TokenTiming])`,
where `TokenTiming` is **per SentencePiece sub-word token** (`token`, `tokenId`,
`startTime`, `endTime`, `confidence`).

`NemotronEngine` reconstructs `TimestampedWord`s by grouping tokens on the `▁` word-boundary
marker and taking each word's span as `[first token startTime, last token endTime]`. This
gives Echo word-level output — including timed subtitle cues — for Nemotron transcripts.

Two honest caveats, recorded so downstream features and docs don't over-trust the output:

- **Coarse timing.** `startTime` is encoder-frame-quantized (`frame * secondsPerEncoderFrame`)
  and `endTime` is one encoder frame later — approximate, not true word onset/offset.
- **Synthetic confidence.** FluidAudio hardcodes `TokenTiming.confidence = 1.0`; it is a
  placeholder, not a real probability. `NemotronEngine` maps it through but treats it as
  "unknown," not "perfectly confident."

`STTResult.segments` stays `nil` for Nemotron (no native sentence segmentation); the subtitle
exporter falls back to its existing `NLTokenizer` cue boundaries over the timed words.

### 6. Routing: extend the runtime, leave the scheduler structurally unchanged

ADR-016's centralized control plane is unchanged. `STTRuntime` gains a `nemotronEngine`
field and a `.nemotron` arm in each engine `switch` (transcribe dispatch, warm-up,
`isReady`, the load and unload halves of `performSpeechEngineSwitch`, `currentSpeechEngineSelection`,
and the two telemetry mappers). `STTScheduler` needs **no structural change** — its routing,
switch guards, and meeting engine-leases already operate on the engine-agnostic
`SpeechEngineSelection`. The two-slot policy is untouched; Nemotron gets no special lane.

`SpeechEngineSelection.init` currently drops the language hint for any non-Whisper engine —
a **silent data-loss bug** for Nemotron. The predicate must become
`engine == .whisper || engine == .nemotron`, and every selection-builder that mirrors that
ternary (runtime convenience/`current`/`currentSpeechEngineSelection`, CLI `resolveSpeechEngine`,
the retranscribe/progress builders in `TranscriptionViewModel`) must carry the Nemotron
language too.

The binary `SpeechEnginePreference.alternative` toggle (used by "re-transcribe with the other
engine") keeps its two-engine pairing (`parakeet↔whisper`, and `nemotron→parakeet`) so
existing behavior and its locked tests are unchanged while the flag is off. A real
three-engine "alternatives" affordance, if wanted, is added separately and gated by the flag.

Meeting recordings continue to pin their engine at start (ADR-021 §5). One guard to verify:
`LiveChunkTranscriber` hard-throws for a pinned non-Parakeet engine on its non-routed
fallback path — Nemotron meetings must always take the routed-transcriber branch (or that
guard must be extended).

### 7. `AppFeatures.nemotronEnabled` — built, shipped off

Following the `calendarEnabled` / `transformsEnabled` idiom, add:

```swift
public static let nemotronEnabled: Bool = false
```

While `false`, the flag hides **every** user-facing surface and — most importantly —
**no code path may fetch the FluidInference CoreML artifact**. Gated surfaces: the Settings
engine tile + Nemotron language card + model-download row/progress; any default-preference
resolution or meeting-session pinning that could select Nemotron; the CLI `--engine nemotron`
value (rejected at runtime with a clear message, since ArgumentParser enums are compile-time);
and any Nemotron telemetry events.

The model is migrated/wired either way; flipping the flag is a no-data operation. The flag
stays `false` in every release build until the license gate (§8) is cleared.

### 8. License gate (blocking for shipping; does not block building)

The artifact FluidAudio actually downloads is the **FluidInference CoreML conversion**, and
its Hugging Face card is self-contradictory:

- a license **badge** of `openmdw-1.1`, but
- `license_name = nvidia-software-and-model-evaluation-license`, a link to NVIDIA's
  evaluation license, and prose: *"governed by the NVIDIA Software and Model Evaluation
  License."*

The NVIDIA evaluation license grants use **only for internal test/evaluation, not in
production**, forbids making the materials **"available to others,"** and even contemplates
**NVIDIA GPUs** (a Mac is not). There is **no `LICENSE` file** committed to the repo, and
access is **manually gated** (Discord approval). The upstream base model
(`nvidia/nemotron-3.5-asr-streaming-0.6b`) is cleanly **OpenMDW-1.1** (commercial +
redistribution OK), but Echo downloads the *conversion*, not the base — so the base's
permissive terms do not cure the conversion's stated terms.

**Download-at-runtime does not rescue this.** A shipped GPL-3.0 DMG that instructs every
user's Mac to fetch and run an eval-only artifact in production is outside that license's
grant. The conversion is therefore acceptable for **local developer testing only**, never
for a distributed build, until the gate below is cleared.

**Flip-to-ship checklist (all required before `nemotronEnabled = true` in a release):**

1. Written confirmation from FluidInference and/or NVIDIA that the *specific downloaded
   artifact* (including the `latin/` subtree) is OpenMDW-1.1 (production + redistribution OK)
   and **not** the NVIDIA evaluation license. Do not rely on the `openmdw-1.1` badge alone.
2. FluidInference corrects the contradictory card and commits a real `LICENSE` file.
3. The artifact is **programmatically fetchable** without manual Discord approval (or Echo
   vendors an approved mirror with confirmed terms) — a shipped app cannot depend on a
   manually-gated download.
4. Confirm GPL-3.0 compatibility for the download-at-runtime posture (OpenMDW-1.1's
   notice-retention obligations are light and a separately-fetched data file is mere
   aggregation, so this is expected to pass once #1 holds).
5. Ship attribution **before** flipping (see §9).
6. If Nemotron emits engine-specific telemetry, get the website telemetry allowlist to accept
   it first (same discipline as `transform_executed` for `transformsEnabled`).
7. Verify, by test and manual check, that no artifact is fetched and no surface appears while
   the flag is off.

> **Note on developer testing:** because the repo is access-gated today, even local
> end-to-end model inference may be blocked until access is granted. This is why all
> automated tests mock the FluidAudio manager (§10) and never require a real download — the
> feature is fully buildable and unit-testable without the model in hand.

### 9. Attribution

When the flag is eventually flipped, add a **"Nemotron 3.5 ASR Model"** section to
`THIRD_PARTY_LICENSES.md` (the repo's existing credits surface; it already lists Parakeet TDT
and Whisper with a "Not bundled in the app; downloaded at runtime" status). The entry records
the confirmed license name, the OpenMDW-1.1 license text + NVIDIA notices of origin (as
OpenMDW-1.1 requires on redistribution/aggregation), the provider
(NVIDIA base + FluidInference CoreML conversion), both HF source URLs, and the
"downloaded at runtime" status. Do **not** label it OpenMDW-1.1 while the card still says
otherwise.

### 10. CLI surface

`transcribe --engine nemotron --language es` (add `.nemotron` to the CLI engine enum and
`resolveSpeechEngine`; `--language` becomes meaningful for both whisper and nemotron, validated
against the European set). `models download nemotron-…` and `models status` learn the Nemotron
model id; `models clear` also removes the Nemotron cache dir. `config` learns any Nemotron
default-language key. The CLI is a versioned public contract → `Sources/CLI/CHANGELOG.md` gets
an entry. Because the CLI has no compile-time access to a runtime flag, `--engine nemotron` is
**rejected at runtime with a clear message while `nemotronEnabled` is false** — this satisfies
the §8 requirement that no code path fetch the artifact while the flag is off.

### 11. Storage, telemetry, onboarding

- **Storage:** add `AppPaths.nemotronModelsDir` (`…/models/stt/nemotron`) to `ensureDirectories()`
  and to the cache-clear paths, parallel to `whisperModelsDir`.
- **Telemetry (ADR-012):** add a single `TelemetryModelKind.nemotronSTT` value; the
  `speech_engine` prop flows the `.nemotron` rawValue through automatically. No content
  (audio, transcript, prompt, path) is ever logged — language and variant pass through the
  existing `safeLanguageCode` / `safeEngineVariant` sanitizers.
- **Onboarding:** unchanged. The CJK locale branch (ADR-021 amendment) recommends Whisper for
  `ko/ja/zh/yue` only; Nemotron's European languages are Parakeet's territory and never trigger
  a recommendation. Nemotron is reachable purely via flag-gated Settings and the CLI.

### 12. The keystone: FluidAudio 0.14.5 → 0.15.4 bump first

Nemotron exists only in FluidAudio 0.15.x, so the dependency bump is Phase 0 and lands and
verifies on its own *before* any Nemotron code. The bump is **source-compatible** for every
FluidAudio symbol Echo uses today:

- `AsrManager` init/`loadModels`/`cleanup`/`transcribe` — unchanged (the new `language:`
  param on `transcribe` is defaulted).
- `AsrModels.downloadAndLoad` — gained a defaulted `encoderComputeUnits:` param; existing
  calls still compile.
- The offline diarization pipeline — `process(_:)` gained a defaulted progress callback;
  everything else unchanged.

The only risk is behavioral: internal v3 Parakeet decoder changes between 0.14.5 and 0.15.4
could shift transcription output/speed slightly. Phase 0 therefore = bump, re-resolve, run
the STT integration tests, and watch for output drift.

## Rationale

- **Why a third engine, not a Whisper swap:** Nemotron's pruned build is a genuinely lighter
  install for European audio than 632 MB Whisper, ships precompiled (no multi-minute optimize),
  and uses a streaming model. It does not displace Parakeet (accuracy/latency) or Whisper
  (breadth).
- **Why batch-only:** it fits ADR-016 with a small, safe change and reuses the WhisperEngine
  template. Streaming is a separate, larger effort.
- **Why European-only + always-`latin` download:** keeps the "lighter alternative" promise,
  avoids duplicating Whisper at lower quality for CJK, and prevents the `"auto"` footgun that
  silently pulls the heavy multilingual model.
- **Why flag-gated and off:** the downloaded artifact's stated license currently forbids
  production distribution. Building behind a disabled flag delivers all engineering value with
  zero shipping risk, exactly as `calendarEnabled` does for ADR-017.
- **Why explicit selection, no fallback:** consistent with ADR-021; auto-fallback is
  surprising and hard to debug.

## Consequences

### Positive

- Lighter, precompiled local engine for EN/ES/FR/IT/PT/DE; a real alternative to the 632 MB
  Whisper download for those users.
- Parakeet stays the default; Whisper keeps breadth; no regression to existing flows.
- Word-level/timed output is available for Nemotron (better than first expected), enabling
  subtitle export with documented caveats.
- The bump unblocks future FluidAudio capabilities and is low-risk.

### Negative / costs

- A third model cache and a third engine to maintain and test.
- Nemotron timing is coarse and its confidence is synthetic — subtitle/diarization timing for
  Nemotron transcripts is approximate.
- The binary `alternative` toggle and several exhaustive `switch`es must each learn `.nemotron`;
  `SpeechEngineSelection`'s language gating is a silent-bug trap if missed.
- The Settings engine row no longer fits two-up cleanly with a third tile (layout change).
- **The feature cannot ship until the license gate (§8) is cleared, and may be hard to
  end-to-end test locally until repo access is granted.**

## Implementation Notes

Verified change-sites (FluidAudio `v0.15.4`, current codebase):

- `Package.swift`: bump `FluidAudio` to `0.15.4` (Phase 0).
- `AppFeatures.swift`: add `nemotronEnabled = false` with a gated-surface doc comment.
- `SpeechEnginePreference.swift`: `case nemotron`; `displayName`; `alternative` (nemotron→parakeet);
  `isColdSwitch` (precompiled → likely no cold path); `SpeechEngineSelection.init`/`current`
  language predicate; Nemotron default-language UserDefaults key; a Nemotron-aware
  `normalizeLanguage`.
- New: `STT/NemotronEngine.swift`, `NemotronLanguageCatalog.swift`.
- `STT/STTRuntime.swift`: `nemotronEngine` field + `.nemotron` arms in transcribe dispatch,
  warm-up, `isReady`, `performSpeechEngineSwitch` (load + unload), `currentSpeechEngineSelection`,
  `telemetryModelKind`, `telemetryEngineVariant`, `shutdown`, `clearModelCache`.
- `Services/AppPaths.swift`: `nemotronModelsDir` + `ensureDirectories` + cache-clear.
- `Services/Telemetry/TelemetryEvent.swift`: `TelemetryModelKind.nemotronSTT`.
- `Services/Capture/LiveChunkTranscriber.swift`: confirm/extend the pinned-engine guard.
- CLI: `Commands/TranscribeCommand.swift` (engine enum, `resolveSpeechEngine`, run() construction,
  help, runtime flag rejection), `Commands/ModelsCommand.swift` (download id parsing, selectable
  models, status, clear), `Commands/ConfigCommand.swift` (engine parse error text, nemotron-language
  key); `Sources/CLI/CHANGELOG.md`.
- UI (all flag-gated): `Views/Settings/SettingsView.swift` (third `EngineOptionTile`; grid/wrap
  layout for three; `engineNemotronLanguageCard`; status/download-row analogs),
  `Views/Settings/SettingsStatusRules.swift` (`localModelsCardStatus` `.nemotron` arm),
  `SettingsViewModel.swift` (`applySpeechEngineChange`, `initialSpeechEngineSwitchDetail`, status),
  `TranscriptionViewModel.swift` (`subline`, retranscribe alternatives),
  `Views/Transcription/TranscriptResultView.swift` (`engineAttributionLabel`, `EngineOptionCard`
  icon/subtitle/`languageDetail`).
- Tests: new `NemotronEngineTests`, `NemotronLanguageCatalogTests`; update
  `SpeechEnginePreferenceTests`, `STTSchedulerTests`/`STTClientTests`, `SettingsStatusRulesTests`,
  `SettingsViewModelTests`, `TranscribeCommandTests`, `ConfigCommandTests`,
  `ModelLifecycleCommandTests`, `TelemetryServiceTests`, and an `OnboardingViewModelTests`
  regression guard. Real-model inference stays out of unit tests (mock the manager, as Whisper
  does).
- Docs: this ADR; `spec/06-stt-engine.md`; `spec/README.md` / `spec/02-features.md` progress;
  `Sources/MacParakeetCore/STT/README.md`; `THIRD_PARTY_LICENSES.md` (on flip).

### Open items to pin at implementation time

- The exact `chunkMs` tiers published under the `latin/` HF subdirectory (source docstring lists
  560/1120/2240/4480, default config 1120; FluidAudio's own doc is stale). Choose the batch
  default once the published tiers are confirmed; a missing `<lang>/<chunkMs>ms` subdir makes the
  download fail.
- Whether the published `latin` model's `metadata.json` `prompt_dictionary` actually maps all six
  European codes (`setLanguage` silently falls back to the default prompt for unknown codes).
- Whether Nemotron pays any non-trivial first-load ANE specialization (it ships precompiled, so we
  assume no heavy cold-switch UI; revisit if first load is slow).

## References

- [ADR-001: Parakeet TDT 0.6B-v3 as Primary STT Engine](001-parakeet-stt.md)
- [ADR-016: Centralized STT Runtime and Scheduler](016-centralized-stt-runtime-scheduler.md)
- [ADR-021: WhisperKit as Optional Multilingual STT Engine](021-whisperkit-multilingual-stt.md)
- FluidAudio `v0.15.4` source: `StreamingNemotronMultilingualAsrManager.swift`,
  `StreamingNemotronMultilingualAsrManager+Shared.swift`, `NemotronMultilingualStreamingConfig.swift`,
  `AsrTypes.swift` (`TokenTiming`), `ModelNames.swift`, `Shared/AudioConverter.swift`.
- Hugging Face: `nvidia/nemotron-3.5-asr-streaming-0.6b` (OpenMDW-1.1),
  `FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML` (license currently conflicted).
- OpenMDW-1.1: https://openmdw.ai/license/1-1/
- NVIDIA Software and Model Evaluation License:
  https://www.nvidia.com/en-us/agreements/enterprise-software/nvidia-software-and-model-evaluation-license/
