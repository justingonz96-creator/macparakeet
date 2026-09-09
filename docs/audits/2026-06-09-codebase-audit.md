# Codebase Audit — 2026-06-09

> **Status:** ACTIVE. Two-pass independent audit of the `macparakeet` codebase
> at `main` HEAD `92c3dfdfb` (post-v0.6.22). Covers the ~1,418 commits landed
> since the 2026-04-26 audit: WhisperKit/Nemotron engines, Parakeet model
> selection, multi-platform URL + podcast transcription, productized
> Transforms, VAD-guided live chunking, instant dictation, and CLI v2.x
> surface growth. Numbering continues from the prior audit (AUDIT-071+).
> Refuted findings retained with rationale, per house style.

| | Count |
|---|---:|
| Pass-1 raw findings (all severities) | ~40 |
| Pass-1 P0/P1 claims | 20 |
| CONFIRMED after verification | 3 P1 + 9 P2 |
| REFUTED on verification | 16 |
| Baseline `swift test` at `92c3dfdfb` | green (exit 0) |

---

## Methodology

### Pass 1 — broad scan

Six parallel read-only Explore agents, scoped to the post-April churn:

| Scope | Focus |
|---|---|
| Audio + meeting recording | SharedMicrophoneStream, raw multichannel fix (`92c3dfdfb`), VAD live chunking, pause/resume, crash recovery, instant-dictation warm capture |
| STT runtime + engines | STTRuntime/Scheduler, WhisperKit + Nemotron routing, engine-switch guards, meeting engine leases, model downloads |
| URL transcription + external processes | MediaPlatform, yt-dlp invocations + auto-update, podcasts (iTunes resolution, feed parsing), FFmpeg, batch drain |
| Transforms + LLM layer | TransformsCoordinator/Executor, selection capture/replace, hotkey registry, provider adapters, key scrubbing |
| Database + concurrency hygiene | Migrations since April, lifetime-stats invariant, actor isolation, continuation/Task lifetime, known bug classes (defer-clobber, terminal-state overwrite) |
| CLI contract + telemetry/privacy | CLI v2.8.0 semver/envelope consistency, batch mode, two-repo telemetry allowlist, payload privacy |

### Pass 2 — adversarial verification

Five independent verifier agents attempted to **refute** every Pass-1 P0/P1
with line-cited evidence; the two contested verdicts (AUDIT-071's actor race,
AUDIT-072's replace-phase race) plus every surviving P1 were then re-verified
by direct line-by-line reads of the primary sources (`STTScheduler.swift`,
`TransformsCoordinator.swift`, `TransformExecutor.swift`,
`SelectionReplacementService.swift`, `TranscribeCommand.swift`,
`SelectionCaptureService.swift`, and both telemetry repos).

**Refutation rate on P0/P1 claims: ~70%** (vs ~20% in the April audit). The
defensive patterns institutionalized since April — per-call generation guards,
actor isolation, documented cancellation gates — killed most plausible-looking
race claims. Both Pass-1 "P0" claims were downgraded (one to P1, one to P2).

---

## Confirmed findings

Severity legend: P0 = data loss/crash/security · P1 = correctness/reliability
· P2 = polish/hygiene. All statuses OPEN unless noted.

### P1

**AUDIT-071 — STTScheduler engine-switch TOCTOU across lease creation**
`STTScheduler.swift:258-268` vs `:186-191`. `beginSpeechEngineSession()`
suspends at line 265 (`await runtime.currentSpeechEngineSelection()`)
**before** inserting the lease ID at line 266. During that suspension,
`setSpeechEngine` can run on the actor: its guard sees
`activeSpeechEngineSessionIDs.isEmpty == true` and proceeds, so an engine
switch interleaves with meeting-session start. Result: the meeting's lease
pins engine A while the runtime switches to engine B (wrong engine for
live/final transcription and wrong crash-recovery pin), or the switch
unloads/reloads models exactly as meeting work begins. Plausible trigger:
calendar auto-start firing while the user changes engines in Settings. The
line-259 drain only covers a switch *already in flight* — not one that
*starts* during the line-265 suspension. The same window exists for
`setParakeetModelVariant` (line 217). **Fix:** reserve the lease synchronously
before the first `await` (insert a placeholder ID, then resolve the
selection), or re-validate `speechEngineSwitchTask == nil` after resume and
loop until stable.
**Status: FIXED** — PR #476 (`59548faa1`, merged 2026-06-10). The session ID
is now reserved synchronously before the first `await`; two regression tests
(engine switch + variant swap blocked while a session begin is suspended
mid-selection-read) were verified to fail against the unfixed scheduler.

**AUDIT-072 — Transforms re-trigger races the deliberately-uncancellable
replace phase**
`TransformsCoordinator.swift:198-204` + `TransformExecutor.swift:202-215` +
`SelectionReplacementService.swift:211-251`. `handleTrigger()` cancels the
in-flight task and immediately starts a new executor without awaiting the old
one. But the executor documents that past its final cancellation gate
(line 210) the replace phase intentionally runs to completion — and inside
`pasteAndRestore` both `Task.sleep` calls are `try?` (cancellation swallowed)
and `activateAndWaitForTarget` **re-activates the original target app**. So
for the ~0.5–1s replace window (clipboard write → app activation → ⌘V →
500 ms settle → restore), a re-trigger interleaves with the new run: the old
run can yank focus back to its target app mid-capture, and the new run's
`captureSelection()` (clipboard-fallback path) can capture the old run's
payload text off the pasteboard as the "selection." Realistic trigger: user
re-fires a Transform hotkey because the first felt slow, or fires a second
Transform in another app. **Fix:** `handleTrigger` should `await` the old
task's completion after cancelling (it terminates quickly once in the replace
phase) before the new executor's capture begins; alternatively serialize
executors through a single gate.
**Status: FIXED** — PR #475 (`067664d2d`, merged 2026-06-10). New
`TransformRunSerializer` (@MainActor, generation-guarded) defers each run's
body until the cancelled predecessor fully winds down; review round
additionally fixed `cancel()` nil-ing the task reference (which would have
let a cancel-then-retrigger skip the wind-down wait).

**AUDIT-073 — `snippet_edited` missing from website telemetry allowlist
(live data loss since 2026-05-23)**
Swift emits `snippet_edited` (`TextSnippetsViewModel.swift:152`, enum case at
`TelemetryEvent.swift:62`, added in `0f4298b7a` on 2026-05-23), but
`ALLOWED_EVENTS` in `macparakeet-website/functions/api/telemetry.ts` does not
contain it. The Worker rejects the **entire batch** on any unknown event, so
every user who edits a snippet silently loses that batch — including valid
co-batched events. Bidirectional diff confirms this is the only Swift event
missing (97 Swift cases; allowlist extras `app_updated`,
`llm_summary_used/failed`, `paywall_viewed` are benign legacy stubs).
This is the third occurrence of the two-repo allowlist failure mode —
consider a CI check that diffs `TelemetryEventName` against the website
repo's allowlist.
**Status: FIXED** — `macparakeet-website@af776c9`, deployed 2026-06-09 and
verified live (`snippet_edited` → HTTP 200 `stored:1`; unknown-event
rejection still HTTP 400).

### P2

| ID | Title | Detail / fix |
|---|---|---|
| AUDIT-074 | yt-dlp `fetchMetadata` missing `--` separator | `YouTubeDownloader.swift:197-202` lacks the `--` that `downloadAudioArguments` has (line ~417). Unreachable today — `DownloadableMediaURLValidator` requires an `http(s)://` prefix with no whitespace, so a leading-dash string cannot reach argv — but it is a latent defect for any future caller that skips validation. One-line fix for parity. **FIXED** — PR #477 (`bcf2e5905`). |
| AUDIT-075 | Whisper engine creation lacks Nemotron's busy-guard | `STTRuntime.swift:~154` creates/assigns `WhisperEngine` on nil without the `activeTranscriptionCount <= 1` guard the Nemotron path has (~line 891). Unreachable today because the scheduler's single background slot serializes Whisper jobs; asymmetric latent hazard. Mirror the guard. **FIXED** — PR #477 (`98f9c6a4a`; `d901af512` documents why warmUp/switch stay inline). |
| AUDIT-076 | `scrubAPIKeyArtifacts` regex gaps | `LLMClient.swift:1146` — `key=` pattern requires 20+ chars and the char class `[A-Za-z0-9._\-]` excludes `%`, so URL-encoded tokens and short keys escape scrubbing. Widen patterns conservatively. **FIXED** — PR #477 (`65a9b922b`; `56b6781bf` extends coverage to raw Base64 tokens after review). |
| AUDIT-077 | yt-dlp auto-update trusts same-origin checksum (TOFU) | `BinaryBootstrap.swift:210-238` downloads the binary and its SHA2-256SUMS from the same GitHub release over TLS; integrity-against-corruption only, no protection from a compromised release. Same class as deferred AUDIT-070 (Node SHASUMS). Revisit if yt-dlp ever ships signed releases. |
| AUDIT-078 | Podcast feed parser retains unbounded episodes | `PodcastFeedParser.swift:83-92` — XMLParser streams, but every `<item>` is retained; feed URL is user-pasted (attacker-choosable). Practical exhaustion needs millions of items; add a generous cap (e.g. 10k) for hygiene. |
| AUDIT-079 | Speech-boundary chunker's serialization contract is comment-only | `SpeechBoundaryMeetingLiveAudioChunker.swift:40-51` documents that it is externally serialized by `MeetingRecordingService`; nothing enforces it. Add a debug precondition / assertion so a future parallel-ingest refactor fails loudly. |
| AUDIT-080 | Batch + `--format json` failure envelope undocumented | `TranscribeCommand.swift:533` emits the standard failure envelope to stdout when a batch run ends with `CLIBatchError.someFailed`. This is *consistent* with the general envelope contract (CHANGELOG §`--json` failure envelope) but the batch section documents only the stderr `✗` lines + non-zero exit. Add one sentence to the CHANGELOG batch section. **FIXED** — PR #477 (`ab3925444`). |
| AUDIT-081 | Stale website allowlist entries | RESOLVED AS RETAIN (2026-06-09): `llm_summary_used/failed` were emitted by shipped builds 2026-03-13 → 2026-04-04 (removed in `95abeb4e3`), so pre-v0.5.5 stragglers still send them — removal would recreate the AUDIT-073 batch-rejection bug. `app_updated`/`paywall_viewed` were never emitted; removal is optional and valueless. No action. |
| AUDIT-082 | Audio downmix diagnostics polish | Pass-1 audio P2 cluster: log which downmix path (VPIO channel-0 vs raw multichannel) was attempted when `microphoneCaptureMonoBuffer()` returns nil (`AudioRecorder.swift:378-384`); add a comment documenting the normalize-then-average invariant in `fillDownmixedInt16/32`; first-buffer watchdog re-arms can log spuriously on sub-2s stop/start cycles (`MicrophoneCapture.swift:400-418`). |

---

## Refuted findings (kept with rationale)

| # | Claim (Pass 1) | Why refuted |
|---|---|---|
| R-1 | ~~P0: engine lease race is race-free by actor isolation~~ — counter-refutation | Recorded for completeness: one verifier argued AUDIT-071 was impossible because `beginSpeechEngineSession` drains `speechEngineSwitchTask`. Direct read shows the drain covers only an *in-flight* switch; the line-265 suspension window is real. AUDIT-071 stands (as P1, not P0). |
| R-2 | Downmix returns original buffer for 1-channel input, violating tap copy contract (`AudioRecorder.swift:1071`) | The buffer reaching `downmixChannelsToMono` is already the deep copy made via `copyPCMBufferForAsyncUse` before queueing; returning it unchanged is safe. |
| R-3 | Stale `isVPIOEngaged` flag applied across capture generations (`AudioRecorder.swift:711`) | Generation guard inside `appendPreRollBuffer` (line ~788) discards the buffer before the stale flag can be applied. |
| R-4 | `resumeRecording()` early-return leaves dangling `pausedHostTime` | No reachable state has `pausedHostTime != nil` while `paused == false`; the guard's early return is correct. |
| R-5 | `failCapture()` leaves `paused == true`, wedging pause/resume | Moot: `captureFailed` gates both `pauseRecording` and `resumeRecording`; the session is dead and torn down regardless. |
| R-6 | Orphaned warm-capture retry Tasks on rapid disable/enable (`AudioRecorder.swift:777`) | The delayed retry re-checks `instantDictationEnabled` and `lifecycleGeneration` before acting; worst case is a benign early return. |
| R-7 | Diagnostic `Task` in capture callback retains buffers unboundedly (`AudioRecorder.swift:431`) | Captures only scalar format values; fires once per session behind `firstBufferLogged`. |
| R-8 | `microphoneTestTask` self-clearing blocks future mic tests (`SettingsViewModel.swift:1007`) | The entry path cancels-and-replaces rather than guarding on nil; no blocking state exists. |
| R-9 | v0.21 hidden-dictation scrub should recompute lifetime stats (`DatabaseManager.swift:985`) | Hidden rows are metric-only **by design** (`spec/01-data-model.md` ~line 94): transcripts scrubbed, duration/word stats intentionally retained. |
| R-10 | STTScheduler continuations leak on shutdown | `shutdown()` → `quiesce()` → `cancelAllPendingJobs()` resumes every stored continuation with `CancellationError`; `cancelAndDrainRunningJobs` covers in-flight. Singleton lifecycle besides. |
| R-11 | `reloadBindings()` non-atomic → crash on unknown promptID (`TransformsCoordinator.swift:133`) | Coordinator is `@MainActor`; `reloadBindings` has no suspension points, and the unknown-promptID path is a graceful `guard … else { reloadBindings(); return }` (line 175), not a crash. |
| R-12 | Stale-event window between Task creation and `activeRunID` check (`TransformsCoordinator.swift:228`) | The guard executes *inside* the Task before any UI mutation; stale events are dropped regardless of scheduling order. |
| R-13 | Clipboard restore-skip "silently loses" user's copy (`SelectionReplacementService.swift:298`) | Skipping restore when changeCount advanced **preserves** the user's newer copy — the documented, correct trade-off. Only the pre-transform snapshot is forfeited, by user action. |
| R-14 | `.llmStreaming` progress un-gated by runID | The coordinator's progress callback acts only on `.failed`; all other progress events are dropped entirely, so nothing stale can reach the UI. |
| R-15 | Pasteboard snapshot loses rich media (`SelectionCaptureService.swift:388`) | Snapshot deep-copies every declared type's data into fresh `NSPasteboardItem`s and restores via `writeObjects`; images/RTF survive. Minor caveat: lazily-promised pasteboard data is forced at snapshot time. |
| R-16 | ffmpeg thumbnail path injection (`ThumbnailCacheService.swift:71`) | All callers pass internal `fileURL.path`; argv arrays don't shell-parse; no attacker-controlled path reaches the call. |
| R-17 | iTunes JSON memory-exhaustion / injection (`PodcastEpisodeResolver.swift:107`) | First-party Apple endpoint; decoded fields feed display + further HTTPS fetches only — no argv/SQL/path sinks. |
| R-18 | CLI batch JSON envelope violates batch contract (`TranscribeCommand.swift:533`) | The general envelope rule ("any post-parse failure emits the envelope on stdout") covers batch mode; per-file results go to files, stdout is otherwise empty. Downgraded to AUDIT-080 (doc clarity). |
| R-19 | `CLIErrorEnvelope` path leakage is a privacy issue (`CLIHelpers.swift:342`) | Local stdout echoing operator-supplied paths back to the operator is not a privacy boundary; telemetry is, and envelope strings don't feed it. Watch item only. |
| R-20 | `snippet_edited` mis-attributed as CLI operation | The event is emitted only from the GUI ViewModel; no CLI path sends it. (The real issue is AUDIT-073.) |

---

## Cross-cutting themes

1. **TOCTOU across actor suspension points is the surviving race class.**
   Plain data races are gone (actors + `@MainActor` everywhere), and the
   generation-guard pattern from PRs #192/#210 has been institutionalized.
   What remains is guards checked before an `await` and acted on after
   (AUDIT-071). Review heuristic: any `guard` on actor state followed by an
   `await` before the corresponding mutation deserves a re-check or a
   synchronous reservation.

2. **Deliberate non-cancellation needs a serialization owner.** The
   Transforms replace phase correctly refuses mid-flight cancellation to
   avoid half-pasted states — but that design transfers a "never overlap
   executions" obligation to the coordinator, which it doesn't currently meet
   (AUDIT-072). When a component documents "cancel is ignored past this
   point," its caller must await, not fire-and-forget.

3. **The two-repo telemetry allowlist keeps biting.** Third occurrence
   (AUDIT-073). The failure is silent, batch-destroying, and invisible until
   someone diffs the repos. A CI guard that extracts `TelemetryEventName`
   cases and compares against the website allowlist would close the class.

4. **External-input hardening is in good shape, with two latent seams.**
   Every user-pasted URL is gated by strict validators before reaching
   yt-dlp, and argv discipline (`--`) is followed except at one metadata call
   site (AUDIT-074). Binary updates verify SHA256 but trust the same origin
   (AUDIT-077).

---

## Strengths preserved (worth not regressing)

- **Generation guards are now pervasive** — warm capture, background warm-up
  state, pre-roll buffers all carry per-call/lifecycle generations; both
  Pass-1 attempts to re-find the PR #192/#210 bug classes failed.
- **`TransformExecutor` abort hygiene** — every failure path calls
  `restoreIfAbandoning` before throwing; the final-cancellation-gate design
  is explicitly documented in code.
- **`SelectionReplacementService` changeCount semantics** — restore-if-safe
  correctly prefers the user's newer clipboard over snapshot restoration,
  with the rationale in comments.
- **STTScheduler quiesce/shutdown** — pending continuations drained with
  `CancellationError`, running jobs cancelled and awaited; no leak paths.
- **CLI batch mode** — continue-on-error, `uniqueURL()` collision suffixes,
  sanitized basenames, stderr/stdout discipline.
- **Telemetry hygiene** — custom Transform names collapse to `custom`;
  app targets map to coarse categories; error details pass the classifier.
- **`ChildProcessWaiter`** — timeout → SIGTERM → SIGKILL with pipe draining
  has propagated to new process call sites.
- **URL validators** — `DownloadableMediaURLValidator` (scheme + host, no
  whitespace) gates every yt-dlp entry point; no platform allowlist needed.

---

## Coverage notes

- Re-audited: everything in the six Pass-1 scopes above, weighted to
  post-2026-04-26 churn.
- **Not** re-audited this round: Sparkle/distribution scripts, onboarding
  flow, hotkey state machine internals (light coverage only), SwiftUI view
  layer, diarization pipeline. Prior deferred items (AUDIT-001, -042, -047,
  -050, -059/-063, -067/-068 et al.) were not re-litigated; their April
  status stands.
- Runtime-only behavior (real multichannel USB hardware, ScreenCaptureKit
  stream lifecycle under stress, model-download interruption) was reviewed
  statically only.

---

## Recommended follow-up sequence

1. **AUDIT-073** — ~~one-line website allowlist fix + deploy~~ **DONE**
   (`macparakeet-website@af776c9`, verified live). The CI cross-repo diff
   guard (theme 3) remains open.
2. **AUDIT-072** — ~~await the cancelled executor before starting the next~~
   **DONE** (PR #475 `067664d2d`).
3. **AUDIT-071** — ~~reserve the lease before the first suspension point in
   `beginSpeechEngineSession`~~ **DONE** (PR #476 `59548faa1`; the
   `setParakeetModelVariant` window is covered by the same reservation).
4. **AUDIT-074/-075/-076** — ~~three small hardening one-liners, bundle into
   one hygiene PR~~ **DONE** (PR #477, which also covers AUDIT-080).
5. **AUDIT-077 through -079, -082** — opportunistic; none urgent.
6. Noted during PR #476's final review (pre-existing, deferred): the quiesce
   paths (`clearModelCache`/`shutdown`) don't check
   `activeSpeechEngineSessionIDs`, and `beginSpeechEngineSession` doesn't
   check `acceptsNewJobs` — so a lease can be granted during quiesce and a
   cache clear can run under an active meeting lease. Candidate AUDIT item
   for the next audit pass.

---

## Changelog

- **2026-06-09 Pass 1** — six scoped agents, ~40 raw findings at `92c3dfdfb`.
- **2026-06-09 Pass 2** — five adversarial verifiers + direct line-by-line
  adjudication of contested verdicts; 16 refutations recorded, both P0 claims
  downgraded, AUDIT-071 through AUDIT-082 confirmed.
