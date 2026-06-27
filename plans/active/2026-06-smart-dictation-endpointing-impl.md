# Smart Dictation Endpointing — Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace dictation's crude RMS silence gate with Silero VAD v6 endpointing behind a pure, testable `DictationEndpointer`, with graceful RMS fallback — opt-in, default-off, decision-only.

**Architecture:** A pure `DictationEndpointer` (Core) owns the stop decision. A capture-plane `DictationVadEngine` (ADR-016 carve-out, like diarization) owns the Silero `VadManager`. A decision-only VAD fork in `AudioRecorder` — placed *after* the WAV write — publishes a `VadSnapshot` that the coordinator's 50 ms loop feeds to the endpointer. Shipped in two stacked PRs: **PR 1** (pure logic + exact RMS parity, zero FluidAudio surface) then **PR 2** (VAD wiring). Both compile on the **current FluidAudio 0.14.5 pin** — Silero v6 + streaming VAD are already present, so the separate keystone 0.15.4 bump is NOT a prerequisite.

**Tech Stack:** Swift 6 (strict concurrency, actors), FluidAudio (Silero VAD v6 on the ANE), XCTest, `OSAllocatedUnfairLock`, `AsyncStream`.

**Source spec:** [`plans/active/2026-06-smart-dictation-endpointing.md`](2026-06-smart-dictation-endpointing.md) (§6 Phase-1 design, §7 PR split, §9 testing, §13 acceptance).

**Provenance:** Drafted from exact current source and adversarially reviewed by a multi-agent pass (verdict: minor-fixes). The reviewer's fixes are applied inline below: (1) the non-existent `runtimePreferences.silenceAutoStop` is replaced with a `UserDefaults` read; (2) the `AudioProcessorProtocol.vadState` addition gets a default implementation so the 4 existing mock conformances still compile; (3) the per-chunk-`Task` VAD-state **data race** is replaced with a single ordered `AsyncStream` consumer that owns its state locally; (4) endpoint telemetry emission is explicitly scoped; (5) the write-cadence invariant's verification is stated honestly.

---

## PR 1 — pure DictationEndpointer + RMS-parity rewrite

> Branch: current feature branch (`claude/dreamy-kilby-7bd7b9`) — no new branch needed.
> Target dependency: FluidAudio **0.14.5** (pinned). PR 1 touches **zero** FluidAudio surface.
> Goal: land the pure stop-decision type + tests, and rewrite `runRecordingLevelLoop()` to delegate to it, such that with `vadAvailable == false` (always, until PR 2) behavior is **identical to today's RMS gate** (modulo a sub-millisecond first-tick seeding difference, see Task 1 note). Establishes the green `swift test` baseline before any VAD wiring.

### Files-touched map

| Action | Path | What |
|--------|------|------|
| Create | `Sources/MacParakeetCore/Services/Dictation/DictationEndpointer.swift` | Pure value type: `Config` / `Input` / `Decision` / `StopReason` + `evaluate`, plus a Phase-1 placeholder `CompletenessVeto`. Phase-1 logic only (VAD-silence path + exact RMS-parity fallback + one-stop latch). Phase-2 fields present-but-inert. |
| Create | `Tests/MacParakeetTests/Services/Dictation/DictationEndpointerTests.swift` | Table-driven tests, injected clock: RMS parity vs today, VAD-silence stop timing, disabled (push-to-talk) never stops, one-stop latch, `vadAvailable == false` uses RMS. |
| Modify | `Sources/MacParakeet/App/DictationFlowCoordinator.swift` | Rewrite `runRecordingLevelLoop()` → `runRecordingLevelLoop(mode:)` to build a `DictationEndpointer` and consult it each tick with `vadAvailable: false`; thread the recording `mode` from the call site; remove inline `lastNonSilenceAt`/`didAutoStop` locals; keep the `overlayViewModel?.audioLevel` feed. |

---

### Task 1 — Create the pure `DictationEndpointer` (Phase-1 logic)

> TDD note: this is a pure value type with no dependencies, so the natural red→green cycle is Task 2 (the test file is authored and run there, failing first because the type doesn't exist, then green). Task 1 creates the implementation; Task 2 is the executable red→green. We deliberately do NOT author a throwaway "skeleton" test first — that would be a contradictory non-cycle for a zero-dependency pure type. The "byte-for-byte vs today" wording is softened to "behaviorally identical": the endpointer seeds its silence anchor on the first tick at `input.now`, whereas today's loop sets `lastNonSilenceAt = Date()` a few hundred microseconds earlier — behaviorally irrelevant at the 50 ms tick granularity, but not literally byte-identical.

- [ ] **1a. Confirm the target test directory exists** (so Task 2's test file lands beside the precedent):

  ```bash
  ls Tests/MacParakeetTests/Services/Dictation/
  # Expected: DictationStopDecisionTests.swift (and siblings) — confirms the target dir exists.
  ```

- [ ] **1b. Create `Sources/MacParakeetCore/Services/Dictation/DictationEndpointer.swift`** with the complete implementation below. This is a pure value type — no clock (time is injected via `Input.now` / `Input.vadSilenceElapsed`), no async, no I/O — exactly mirroring the `DictationStopDecision.swift` precedent (pure value type + focused test). `DictationStopDecider` is left untouched (it answers a different, orthogonal question).

  ```swift
  import Foundation

  /// Phase-2 placeholder. The grammatical-completeness layer (spec §8) will
  /// replace this with the real veto payload
  /// (`{ verdict, modelEouSignaled, generatedAt, sessionID }`). Phase 1 never
  /// reads it; it exists only so `DictationEndpointer.Input.completenessVeto`
  /// type-checks and the interface is stable across PRs.
  public struct CompletenessVeto: Sendable, Equatable {
      public init() {}
  }

  /// Pure, unit-testable "is the user done speaking?" decision for dictation.
  ///
  /// Sibling of `DictationStopDecision` — the exact precedent in this folder
  /// (a pure value type with a focused test). No clock, no async, no I/O: the
  /// caller injects time through `Input.now` and `Input.vadSilenceElapsed`, so
  /// every branch is deterministically testable.
  ///
  /// Phase 1 (this cycle) implements two paths:
  ///   1. VAD path (when `Input.vadAvailable`): stop after `silenceDuration`
  ///      of VAD-judged silence.
  ///   2. RMS fallback path (when VAD is unavailable): reproduce today's exact
  ///      energy-gate arithmetic — `audioLevel >= rmsThreshold` resets the
  ///      silence timer; otherwise stop once `silenceDuration` has elapsed.
  ///
  /// The Phase-2 fields (`completenessEnabled`, `extensionMaxWait`,
  /// `completenessVeto`) are present so the interface is stable, but
  /// `evaluate(_:)` ignores them in Phase 1.
  public struct DictationEndpointer: Sendable {

      public struct Config: Sendable, Equatable {
          /// `silenceAutoStop && recordingMode == .persistent`. When false,
          /// `evaluate(_:)` never returns `.stop` — push-to-talk (hold) and the
          /// opt-out default both flow through here.
          public var enabled: Bool
          /// Reinterpreted `silenceDelay`: duration of VAD-judged (or, in
          /// fallback, RMS-judged) silence before auto-stop.
          public var silenceDuration: TimeInterval
          /// Fallback energy gate — today's `silenceAutoStopThreshold` (0.03).
          public var rmsThreshold: Float
          // Phase-2 fields: present so the interface is stable; unused in Phase 1.
          public var completenessEnabled: Bool
          /// Extension-window bound (NOT total elapsed). See spec §8.4. Phase 2.
          public var extensionMaxWait: TimeInterval

          public init(
              enabled: Bool,
              silenceDuration: TimeInterval,
              rmsThreshold: Float = 0.03,
              completenessEnabled: Bool = false,
              extensionMaxWait: TimeInterval = 0
          ) {
              self.enabled = enabled
              self.silenceDuration = silenceDuration
              self.rmsThreshold = rmsThreshold
              self.completenessEnabled = completenessEnabled
              self.extensionMaxWait = extensionMaxWait
          }
      }

      public struct Input: Sendable, Equatable {
          /// Wall-clock at this tick (injected; never read from a global clock).
          public var now: Date
          /// Seconds since recording began. Phase-1 `evaluate` does not read it;
          /// it exists for the Phase-2 extension-window math.
          public var elapsed: TimeInterval
          /// Smoothed mic energy (the value already fed to the waveform).
          public var audioLevel: Float
          /// False ⇒ use the RMS fallback path (today's behavior).
          public var vadAvailable: Bool
          /// VAD verdict for this tick: speech vs. silence.
          public var speechActive: Bool
          /// `now − lastSpeechAt`; nil if the user never spoke yet.
          public var vadSilenceElapsed: TimeInterval?
          /// Phase-2 pre-arrived completeness verdict; nil in Phase 1.
          public var completenessVeto: CompletenessVeto?

          public init(
              now: Date,
              elapsed: TimeInterval,
              audioLevel: Float,
              vadAvailable: Bool,
              speechActive: Bool,
              vadSilenceElapsed: TimeInterval?,
              completenessVeto: CompletenessVeto? = nil
          ) {
              self.now = now
              self.elapsed = elapsed
              self.audioLevel = audioLevel
              self.vadAvailable = vadAvailable
              self.speechActive = speechActive
              self.vadSilenceElapsed = vadSilenceElapsed
              self.completenessVeto = completenessVeto
          }
      }

      public enum Decision: Sendable, Equatable {
          case keepListening
          case stop(reason: StopReason)
      }

      public enum StopReason: Sendable, Equatable {
          case vadSilence
          case rmsSilence
          case grammaticallyComplete   // Phase 2
          case extensionMaxWait        // Phase 2
      }

      private let config: Config

      /// Mirrors today's `var lastNonSilenceAt = Date()` seeded before the loop.
      /// nil until the first `evaluate` call, then pinned to that first `now`
      /// (or refreshed whenever the RMS gate sees non-silence). Only the RMS
      /// fallback path uses this; the VAD path trusts `Input.vadSilenceElapsed`.
      private var lastNonSilenceAt: Date?

      /// One-stop latch: today's `var didAutoStop = false` ensured a single stop
      /// per session. Once we return `.stop`, every later tick is `.keepListening`.
      private var didStop = false

      public init(config: Config) {
          self.config = config
      }

      public mutating func evaluate(_ input: Input) -> Decision {
          // Disabled ⇒ never auto-stop (push-to-talk hold, or opt-out default).
          guard config.enabled else { return .keepListening }
          // One stop per session.
          guard !didStop else { return .keepListening }

          if input.vadAvailable {
              // VAD path: stop after `silenceDuration` of VAD-judged silence.
              // The caller owns `lastSpeechAt`; we read the derived elapsed.
              if !input.speechActive,
                 let silenceElapsed = input.vadSilenceElapsed,
                 silenceElapsed >= config.silenceDuration {
                  didStop = true
                  return .stop(reason: .vadSilence)
              }
              return .keepListening
          }

          // RMS fallback path — reproduce today's exact arithmetic:
          //   level >= threshold  -> reset the silence timer
          //   else if elapsed >= silenceDuration -> stop
          // Seed the timer on the first tick, matching today's
          // `var lastNonSilenceAt = Date()` set immediately before the loop.
          let anchor = lastNonSilenceAt ?? input.now
          if input.audioLevel >= config.rmsThreshold {
              lastNonSilenceAt = input.now
              return .keepListening
          }
          if input.now.timeIntervalSince(anchor) >= config.silenceDuration {
              didStop = true
              return .stop(reason: .rmsSilence)
          }
          // Not yet silent long enough: remember the anchor for next tick.
          lastNonSilenceAt = anchor
          return .keepListening
      }
  }
  ```

- [ ] **1c. Build to confirm the new type compiles** (the test file from Task 2 doesn't exist yet, so this is a source-only build):

  ```bash
  swift build --target MacParakeetCore
  # Expected: Compiling ... DictationEndpointer.swift ... Build complete!
  ```

---

### Task 2 — Add the table-driven `DictationEndpointerTests` (red → green)

- [ ] **2a. Create `Tests/MacParakeetTests/Services/Dictation/DictationEndpointerTests.swift`** with the complete test below. It mirrors `DictationStopDecisionTests` (focused, value-type) but is table-driven with an injected clock (a `Date` base + offsets), covering: RMS parity with today, VAD-silence stop timing, disabled-never-stops (push-to-talk), the one-stop latch, and `vadAvailable == false` using the RMS path.

  ```swift
  import XCTest
  @testable import MacParakeetCore

  final class DictationEndpointerTests: XCTestCase {

      /// Fixed clock base so offsets are exact and deterministic.
      private let t0 = Date(timeIntervalSinceReferenceDate: 0)

      // MARK: - RMS fallback parity with today's gate

      /// Today: `level >= 0.03` keeps resetting the timer, so loud audio never
      /// auto-stops no matter how long it runs.
      func testRMSFallback_loudAudioNeverStops() {
          var endpointer = DictationEndpointer(
              config: .init(enabled: true, silenceDuration: 2.0)
          )
          for second in 0...10 {
              let decision = endpointer.evaluate(
                  .init(
                      now: t0.addingTimeInterval(Double(second)),
                      elapsed: Double(second),
                      audioLevel: 0.5,            // well above 0.03
                      vadAvailable: false,
                      speechActive: false,
                      vadSilenceElapsed: nil
                  )
              )
              XCTAssertEqual(decision, .keepListening, "loud tick \(second) must keep listening")
          }
      }

      /// Today: once `level < 0.03` for `silenceDelay`, it stops. Boundary is
      /// `>=` (inclusive), exactly reproducing the production arithmetic.
      func testRMSFallback_stopsAfterSilenceDuration() {
          var endpointer = DictationEndpointer(
              config: .init(enabled: true, silenceDuration: 2.0)
          )
          // First tick seeds the anchor at t0 (silence already).
          XCTAssertEqual(
              endpointer.evaluate(rmsSilent(at: 0.0)),
              .keepListening
          )
          // 1.0s of silence: not enough.
          XCTAssertEqual(
              endpointer.evaluate(rmsSilent(at: 1.0)),
              .keepListening
          )
          // Just before the threshold: still listening.
          XCTAssertEqual(
              endpointer.evaluate(rmsSilent(at: 1.999)),
              .keepListening
          )
          // Exactly at the threshold (>=): stop.
          XCTAssertEqual(
              endpointer.evaluate(rmsSilent(at: 2.0)),
              .stop(reason: .rmsSilence)
          )
      }

      /// Today: a loud tick mid-silence resets the timer, delaying the stop.
      func testRMSFallback_loudTickResetsSilenceTimer() {
          var endpointer = DictationEndpointer(
              config: .init(enabled: true, silenceDuration: 2.0)
          )
          XCTAssertEqual(endpointer.evaluate(rmsSilent(at: 0.0)), .keepListening)
          XCTAssertEqual(endpointer.evaluate(rmsSilent(at: 1.5)), .keepListening)
          // Loud at 1.6 resets the anchor to 1.6.
          XCTAssertEqual(endpointer.evaluate(rmsLoud(at: 1.6)), .keepListening)
          // 2.0s after start but only 0.4s after reset: keep listening.
          XCTAssertEqual(endpointer.evaluate(rmsSilent(at: 2.0)), .keepListening)
          // 3.6s = 2.0s after the reset: stop.
          XCTAssertEqual(
              endpointer.evaluate(rmsSilent(at: 3.6)),
              .stop(reason: .rmsSilence)
          )
      }

      /// The configured threshold is honored (parity-check that `rmsThreshold`
      /// drives the gate, defaulting to today's 0.03).
      func testRMSFallback_usesConfiguredThreshold() {
          var endpointer = DictationEndpointer(
              config: .init(enabled: true, silenceDuration: 1.0, rmsThreshold: 0.03)
          )
          // 0.029 is below 0.03 → counts as silence.
          XCTAssertEqual(
              endpointer.evaluate(
                  .init(now: t0, elapsed: 0, audioLevel: 0.029,
                        vadAvailable: false, speechActive: false, vadSilenceElapsed: nil)
              ),
              .keepListening
          )
          XCTAssertEqual(
              endpointer.evaluate(
                  .init(now: t0.addingTimeInterval(1.0), elapsed: 1.0, audioLevel: 0.029,
                        vadAvailable: false, speechActive: false, vadSilenceElapsed: nil)
              ),
              .stop(reason: .rmsSilence)
          )
      }

      // MARK: - VAD-silence stop timing

      func testVAD_stopsAfterSilenceDuration() {
          var endpointer = DictationEndpointer(
              config: .init(enabled: true, silenceDuration: 2.0)
          )
          // Speaking: never stops, regardless of level.
          XCTAssertEqual(
              endpointer.evaluate(vad(at: 0.0, speechActive: true, silenceElapsed: nil)),
              .keepListening
          )
          // Silence began; 1.0s elapsed: not enough.
          XCTAssertEqual(
              endpointer.evaluate(vad(at: 1.0, speechActive: false, silenceElapsed: 1.0)),
              .keepListening
          )
          // 2.0s of VAD silence (>=): stop.
          XCTAssertEqual(
              endpointer.evaluate(vad(at: 2.0, speechActive: false, silenceElapsed: 2.0)),
              .stop(reason: .vadSilence)
          )
      }

      /// VAD says speech is active → never stop even past silenceDuration.
      func testVAD_activeSpeechNeverStops() {
          var endpointer = DictationEndpointer(
              config: .init(enabled: true, silenceDuration: 1.0)
          )
          for second in 0...5 {
              XCTAssertEqual(
                  endpointer.evaluate(
                      vad(at: Double(second), speechActive: true, silenceElapsed: 10.0)
                  ),
                  .keepListening,
                  "active-speech tick \(second) must keep listening"
              )
          }
      }

      /// VAD path ignores `audioLevel` entirely (the whole point: noisy room,
      /// high level, but VAD knows it's silence → stop).
      func testVAD_ignoresAudioLevelInNoisyRoom() {
          var endpointer = DictationEndpointer(
              config: .init(enabled: true, silenceDuration: 1.0)
          )
          XCTAssertEqual(
              endpointer.evaluate(
                  .init(now: t0.addingTimeInterval(1.0), elapsed: 1.0,
                        audioLevel: 0.9,            // loud fan/music
                        vadAvailable: true,
                        speechActive: false,        // but VAD says no speech
                        vadSilenceElapsed: 1.0)
              ),
              .stop(reason: .vadSilence)
          )
      }

      // MARK: - Disabled (push-to-talk / opt-out) never stops

      func testDisabled_neverStops_RMSPath() {
          var endpointer = DictationEndpointer(
              config: .init(enabled: false, silenceDuration: 0.1)
          )
          for second in 0...10 {
              XCTAssertEqual(
                  endpointer.evaluate(rmsSilent(at: Double(second))),
                  .keepListening
              )
          }
      }

      func testDisabled_neverStops_VADPath() {
          var endpointer = DictationEndpointer(
              config: .init(enabled: false, silenceDuration: 0.1)
          )
          for second in 0...10 {
              XCTAssertEqual(
                  endpointer.evaluate(
                      vad(at: Double(second), speechActive: false, silenceElapsed: 99.0)
                  ),
                  .keepListening
              )
          }
      }

      // MARK: - One-stop latch

      func testOneStopLatch_RMS() {
          var endpointer = DictationEndpointer(
              config: .init(enabled: true, silenceDuration: 1.0)
          )
          XCTAssertEqual(endpointer.evaluate(rmsSilent(at: 0.0)), .keepListening)
          XCTAssertEqual(
              endpointer.evaluate(rmsSilent(at: 1.0)),
              .stop(reason: .rmsSilence)
          )
          // Every later tick — even more silence — must NOT stop again.
          XCTAssertEqual(endpointer.evaluate(rmsSilent(at: 2.0)), .keepListening)
          XCTAssertEqual(endpointer.evaluate(rmsSilent(at: 5.0)), .keepListening)
      }

      func testOneStopLatch_VAD() {
          var endpointer = DictationEndpointer(
              config: .init(enabled: true, silenceDuration: 1.0)
          )
          XCTAssertEqual(
              endpointer.evaluate(vad(at: 1.0, speechActive: false, silenceElapsed: 1.0)),
              .stop(reason: .vadSilence)
          )
          XCTAssertEqual(
              endpointer.evaluate(vad(at: 2.0, speechActive: false, silenceElapsed: 2.0)),
              .keepListening
          )
      }

      // MARK: - vadAvailable == false routes to RMS

      func testVADUnavailable_usesRMSPath() {
          var endpointer = DictationEndpointer(
              config: .init(enabled: true, silenceDuration: 1.0)
          )
          // vadAvailable == false: speechActive/silenceElapsed must be ignored,
          // and the RMS gate (audioLevel) decides instead.
          XCTAssertEqual(
              endpointer.evaluate(
                  .init(now: t0, elapsed: 0, audioLevel: 0.5,    // loud → RMS keeps listening
                        vadAvailable: false,
                        speechActive: false,                     // would stop on VAD path
                        vadSilenceElapsed: 99.0)                 // huge, but ignored
              ),
              .keepListening
          )
          // Now go silent on the RMS path and confirm it stops via .rmsSilence
          // (NOT .vadSilence), proving the VAD fields were ignored.
          XCTAssertEqual(endpointer.evaluate(rmsSilent(at: 0.0)), .keepListening)
          XCTAssertEqual(
              endpointer.evaluate(rmsSilent(at: 1.0)),
              .stop(reason: .rmsSilence)
          )
      }

      // MARK: - Helpers

      private func rmsSilent(at offset: TimeInterval) -> DictationEndpointer.Input {
          .init(
              now: t0.addingTimeInterval(offset),
              elapsed: offset,
              audioLevel: 0.0,
              vadAvailable: false,
              speechActive: false,
              vadSilenceElapsed: nil
          )
      }

      private func rmsLoud(at offset: TimeInterval) -> DictationEndpointer.Input {
          .init(
              now: t0.addingTimeInterval(offset),
              elapsed: offset,
              audioLevel: 0.5,
              vadAvailable: false,
              speechActive: false,
              vadSilenceElapsed: nil
          )
      }

      private func vad(
          at offset: TimeInterval,
          speechActive: Bool,
          silenceElapsed: TimeInterval?
      ) -> DictationEndpointer.Input {
          .init(
              now: t0.addingTimeInterval(offset),
              elapsed: offset,
              audioLevel: 0.0,
              vadAvailable: true,
              speechActive: speechActive,
              vadSilenceElapsed: silenceElapsed
          )
      }
  }
  ```

- [ ] **2b. Run the focused suite — expect GREEN** (the implementation from Task 1 already satisfies these):

  ```bash
  swift test --filter DictationEndpointerTests
  # Expected: Test Suite 'DictationEndpointerTests' passed. Executed 12 tests, with 0 failures.
  ```

  > If any test fails, the failure pinpoints which arithmetic branch diverged from today's gate — fix `evaluate(_:)`, not the test, since the tests encode the spec's RMS-parity requirement (§6.5).

---

### Task 3 — Rewrite `runRecordingLevelLoop()` to consult `DictationEndpointer`

- [ ] **3a. Replace the `runRecordingLevelLoop()` method** in `Sources/MacParakeet/App/DictationFlowCoordinator.swift` (currently lines ~1022-1047). The rewrite: takes the recording `mode`, builds one endpointer with `enabled: silenceAutoStop && mode == .persistent` (the push-to-talk gate), consults it each tick with `vadAvailable: false` (so behavior == today's RMS gate exactly until PR 2 supplies a real VAD snapshot), keeps the `overlayViewModel?.audioLevel` waveform feed, and drops the inline `lastNonSilenceAt`/`didAutoStop` locals.

  Replace:

  ```swift
      private func runRecordingLevelLoop() async {
          let (autoStopEnabled, silenceDelay) = (settingsViewModel.silenceAutoStop, settingsViewModel.silenceDelay)
          var lastNonSilenceAt = Date()
          var didAutoStop = false

          while !Task.isCancelled {
              let snapshot = await serviceSession.recordingSnapshot()
              guard case .recording = snapshot.state else { break }

              let level = snapshot.audioLevel
              overlayViewModel?.audioLevel = level

              if autoStopEnabled {
                  let now = Date()
                  if level >= Self.silenceAutoStopThreshold {
                      lastNonSilenceAt = now
                  } else if !didAutoStop, now.timeIntervalSince(lastNonSilenceAt) >= silenceDelay {
                      didAutoStop = true
                      stopDictation()
                      break
                  }
              }

              try? await Task.sleep(for: .milliseconds(50))
          }
      }
  ```

  With:

  ```swift
      private func runRecordingLevelLoop(mode: FnKeyStateMachine.RecordingMode) async {
          // Auto-stop is opt-in (default OFF) and hard-gated to persistent
          // (hands-free) mode so silence can never cut off a physical hold.
          let startedAt = Date()
          var endpointer = DictationEndpointer(
              config: .init(
                  enabled: settingsViewModel.silenceAutoStop && mode == .persistent,
                  silenceDuration: settingsViewModel.silenceDelay,
                  rmsThreshold: Self.silenceAutoStopThreshold
              )
          )

          while !Task.isCancelled {
              let snapshot = await serviceSession.recordingSnapshot()
              guard case .recording = snapshot.state else { break }

              let level = snapshot.audioLevel
              overlayViewModel?.audioLevel = level

              // PR 1: VAD is not wired yet, so `vadAvailable` is always false and
              // the endpointer reproduces today's exact RMS energy gate. PR 2
              // replaces these two literals with the published `VadSnapshot`.
              let now = Date()
              let decision = endpointer.evaluate(
                  .init(
                      now: now,
                      elapsed: now.timeIntervalSince(startedAt),
                      audioLevel: level,
                      vadAvailable: false,
                      speechActive: false,
                      vadSilenceElapsed: nil
                  )
              )
              if case .stop = decision {
                  stopDictation()
                  break
              }

              try? await Task.sleep(for: .milliseconds(50))
          }
      }
  ```

- [ ] **3b. Update the single call site** to thread `mode`. In `startRecordingTask(mode:generation:sessionID:)` (line ~872), the surrounding closure already captures the `mode` parameter. Change:

  ```swift
                  await self.runRecordingLevelLoop()
  ```

  to:

  ```swift
                  await self.runRecordingLevelLoop(mode: mode)
  ```

  > `mode` is the `FnKeyStateMachine.RecordingMode` parameter of `startRecordingTask` (line 843) and is in scope at the call site. This is the sole caller of `runRecordingLevelLoop` (confirmed by grep — only line 872 invokes it).

- [ ] **3c. Build the app target** to confirm the rewrite compiles under Swift 6 strict concurrency:

  ```bash
  swift build
  # Expected: Build complete!
  ```

---

### Task 4 — Full suite, then commit

- [ ] **4a. Run the full deterministic suite** (no regressions; ~1-2 min per CLAUDE.md):

  ```bash
  swift test
  # Expected: Test Suite 'All tests' passed. ... 0 failures.
  ```

- [ ] **4b. Sanity-grep** that the inline locals are gone and the new type is referenced:

  ```bash
  grep -n "lastNonSilenceAt\|didAutoStop" Sources/MacParakeet/App/DictationFlowCoordinator.swift
  # Expected: no matches (both inline locals removed; logic now lives in DictationEndpointer).
  grep -n "DictationEndpointer" Sources/MacParakeet/App/DictationFlowCoordinator.swift
  # Expected: one match inside runRecordingLevelLoop(mode:).
  ```

- [ ] **4c. Commit** (conventional style; feature branch, no new branch needed):

  ```bash
  git add Sources/MacParakeetCore/Services/Dictation/DictationEndpointer.swift \
          Tests/MacParakeetTests/Services/Dictation/DictationEndpointerTests.swift \
          Sources/MacParakeet/App/DictationFlowCoordinator.swift
  git commit -m "feat(dictation): extract pure DictationEndpointer for auto-stop decision

Introduce a pure, unit-testable DictationEndpointer value type (sibling of
DictationStopDecision) and route runRecordingLevelLoop through it. Phase-1
logic only: a VAD-judged-silence path plus an exact reproduction of today's
RMS energy gate, with a one-stop latch. With vadAvailable == false (always,
until VAD wiring lands in PR 2) behavior is behaviorally identical to the
prior inline RMS gate. Push-to-talk is hard-gated off by requiring
silenceAutoStop && mode == .persistent. Phase-2 fields are present but inert
so the interface is stable.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
  ```

---

### Acceptance for PR 1
- `swift test --filter DictationEndpointerTests` passes (12 tests).
- Full `swift test` passes with no regressions.
- `runRecordingLevelLoop(mode:)` consults `DictationEndpointer` with `vadAvailable: false`; auto-stop behavior is identical to today's RMS gate; push-to-talk (hold) is never auto-stopped (`enabled` is false for `.holdToTalk`); auto-stop OFF (default) is unchanged.
- Zero FluidAudio surface touched; compiles on the pinned 0.14.5.
- The `DictationEndpointer.Config/Input/Decision/StopReason` interface (including inert Phase-2 fields) is in place for PR 2 to feed a real `VadSnapshot`.

---

## PR 2 — Silero VAD v6 wiring (decision-only dictation endpointing)

> Stacked on **PR 1** (pure `DictationEndpointer` + `runRecordingLevelLoop` rewrite). Builds on the current **0.14.5** FluidAudio pin — Silero v6 + streaming VAD are already present. **Do NOT touch `Package.swift`.** Implements spec `plans/active/2026-06-smart-dictation-endpointing.md` §6.1–6.4, §6.7–6.10. Every step is TDD: write the failing test, run it (expect fail), add the minimal implementation, run it (expect pass), commit.

### Files-touched map

| File | Change |
|------|--------|
| `Sources/MacParakeetCore/Services/Capture/DictationVadProcessor.swift` | **New.** `VadProcessingDiagnostics`, `DictationVadProcessing` protocol, `PassthroughDictationVadProcessor`, `StreamingDictationVadProcessor` (4096 accumulator). |
| `Sources/MacParakeetCore/Services/Capture/DictationVadEngine.swift` | **New.** `VadManagerProviding` adapter, `extension VadManager`, `DictationVadEngine` actor. |
| `Sources/MacParakeetCore/Audio/AudioRecorder.swift` | `VadSnapshot` type; `enableVad`/`vadEngine` init params; `atomicVadSnapshot` lock; VAD fork after WAV write at `:336`; per-session reset at `:205`; stop reset at `:483`; `vadState` accessor. |
| `Sources/MacParakeetCore/Audio/AudioProcessor.swift` | New `init(sharedMicStream:enableVad:vadEngine:)`; `vadState` seam; file-only `init()` stays no-VAD. |
| `Sources/MacParakeetCore/Audio/AudioProcessorProtocol.swift` | `var vadState: VadSnapshot { get async }`. |
| `Sources/MacParakeetCore/Services/Dictation/DictationService.swift` | `vadState` forward. |
| `Sources/MacParakeetCore/Services/Dictation/DictationServiceSession.swift` | `recordingSnapshot()` tuple gains `vad`. |
| `Sources/MacParakeet/App/AppEnvironment.swift` | Construct `DictationVadEngine`; `enableVad` closure from `silenceAutoStop`; inject into `AudioProcessor`. |
| `Sources/MacParakeet/AppDelegate.swift` | Fold VAD warm-up into deferred pre-warm. |
| `Sources/MacParakeet/App/DictationFlowCoordinator.swift` | Pass live VAD fields into `DictationEndpointer.Input`. |
| `Sources/MacParakeet/Views/Settings/SettingsView.swift` | Reword auto-stop copy (`~727`). |
| `Sources/MacParakeetCore/Services/Telemetry/TelemetryEvent.swift` | Additive `endpoint_reason` + `vad_available`. |
| `Tests/MacParakeetTests/Services/Capture/DictationVadProcessorTests.swift` | **New.** Byte-exact chunking. |
| `Tests/MacParakeetTests/Services/Capture/DictationVadEngineTests.swift` | **New.** Mock VAD: available/unavailable/error. |
| `Tests/MacParakeetTests/Services/Capture/DictationVadIntegrationTests.swift` | **New.** Write-cadence regression + offline→RMS. |

---

### Task 1 — `VadProcessingDiagnostics` + `DictationVadProcessing` protocol + `PassthroughDictationVadProcessor`

Mirrors `MicConditioner.swift` (`MeetingEchoSuppressionDiagnostics` + `MicConditioning` + `PassthroughMicConditioner`).

- [ ] **Write failing test** — create `Tests/MacParakeetTests/Services/Capture/DictationVadProcessorTests.swift`:

```swift
import XCTest
@testable import MacParakeetCore

final class DictationVadProcessorTests: XCTestCase {
    func testPassthroughEmitsNothingAndReportsLoadedDiagnostics() {
        let processor = PassthroughDictationVadProcessor()
        var emitted: [[Float]] = []
        processor.accept(samples: [0.1, 0.2, 0.3]) { emitted.append($0) }
        XCTAssertTrue(emitted.isEmpty, "passthrough never emits VAD chunks")
        XCTAssertEqual(processor.diagnostics.processorName, "passthrough")
        XCTAssertTrue(processor.diagnostics.loaded)
        XCTAssertEqual(processor.diagnostics.chunksEmitted, 0)
    }
}
```

- [ ] **Run** `swift test --filter DictationVadProcessorTests/testPassthroughEmitsNothingAndReportsLoadedDiagnostics` → **expect FAIL** (symbols don't exist).
- [ ] **Implement** — create `Sources/MacParakeetCore/Services/Capture/DictationVadProcessor.swift`:

```swift
import Foundation

/// Per-session diagnostic counters for the dictation VAD frame processor.
/// Contains no transcript or audio content — only frame/chunk tallies.
/// Mirrors `MeetingEchoSuppressionDiagnostics` in `MicConditioner.swift`.
struct VadProcessingDiagnostics: Sendable, Equatable {
    var processorName: String
    var loaded: Bool
    var samplesAccumulated: Int
    var chunksEmitted: Int
    var oversizedChunksDropped: Int
    var processingFailures: Int

    static func passthrough(
        processorName: String = "passthrough",
        loaded: Bool = true
    ) -> VadProcessingDiagnostics {
        VadProcessingDiagnostics(
            processorName: processorName,
            loaded: loaded,
            samplesAccumulated: 0,
            chunksEmitted: 0,
            oversizedChunksDropped: 0,
            processingFailures: 0
        )
    }
}

/// Splits an arbitrary stream of 16 kHz mono Float32 samples into fixed
/// 4096-sample chunks for Silero VAD. Decision-only: it never touches the WAV
/// writer. Mirrors the `MicConditioning` protocol shape in `MicConditioner.swift`.
protocol DictationVadProcessing: AnyObject, Sendable {
    var diagnostics: VadProcessingDiagnostics { get }
    /// Append converted samples; `emit` is called synchronously, once per
    /// complete 4096-sample chunk, in order. Leftover (< 4096) is retained.
    func accept(samples: [Float], emit: (_ chunk: [Float]) -> Void)
    func reset()
}

/// No-op baseline used whenever VAD is off / unavailable. Never emits a chunk,
/// so the recorder's published snapshot stays `.unavailable` and the endpointer
/// uses the RMS fallback. Matches `PassthroughMicConditioner`.
final class PassthroughDictationVadProcessor: DictationVadProcessing, @unchecked Sendable {
    private let lock = NSLock()
    private var diagnosticsStorage = VadProcessingDiagnostics.passthrough()

    var diagnostics: VadProcessingDiagnostics {
        lock.lock(); defer { lock.unlock() }
        return diagnosticsStorage
    }

    func accept(samples: [Float], emit: (_ chunk: [Float]) -> Void) {}

    func reset() {
        lock.lock(); defer { lock.unlock() }
        diagnosticsStorage = VadProcessingDiagnostics.passthrough()
    }
}
```

- [ ] **Run** the same filter → **expect PASS**.
- [ ] **Commit**: `feat(stt): add VAD processing diagnostics + passthrough processor`

---

### Task 2 — `StreamingDictationVadProcessor` 4096-sample accumulator (byte-exact)

The highest-risk Phase-1 detail (§6.3). Converted buffers are ~1486 samples, so the accumulator must span ~3 buffers per 4096 chunk and **never** hand a chunk > 4096.

- [ ] **Write failing test** — append to `DictationVadProcessorTests.swift`:

```swift
extension DictationVadProcessorTests {
    /// Feed a contiguous ramp in ~1486-sample buffers; the emitted 4096-chunks
    /// must reconstruct the input exactly, in order, with no dropped/duplicated
    /// samples across buffer boundaries, and no chunk may exceed 4096.
    func testStreamingChunkingIsByteExactAcrossBufferBoundaries() {
        let processor = StreamingDictationVadProcessor()
        let bufferSize = 1486
        let bufferCount = 9 // 9 * 1486 = 13374 samples -> 3 full 4096 chunks + 1086 leftover
        var input: [Float] = []
        input.reserveCapacity(bufferSize * bufferCount)
        for i in 0..<(bufferSize * bufferCount) { input.append(Float(i)) }

        var emitted: [[Float]] = []
        var cursor = 0
        for _ in 0..<bufferCount {
            let buffer = Array(input[cursor..<(cursor + bufferSize)])
            cursor += bufferSize
            processor.accept(samples: buffer) { emitted.append($0) }
        }

        XCTAssertEqual(emitted.count, 3, "13374 samples -> 3 complete 4096 chunks")
        for chunk in emitted {
            XCTAssertEqual(chunk.count, 4096, "VAD chunk must be exactly 4096 samples")
        }
        XCTAssertLessThanOrEqual(
            emitted.map(\.count).max() ?? 0, 4096,
            "must never emit a chunk larger than 4096"
        )
        let reconstructed = emitted.flatMap { $0 }
        XCTAssertEqual(reconstructed, Array(input.prefix(reconstructed.count)),
                       "emitted chunks reconstruct the input contiguously")
        XCTAssertEqual(reconstructed.count, 3 * 4096)
        XCTAssertEqual(processor.diagnostics.chunksEmitted, 3)
        XCTAssertEqual(processor.diagnostics.samplesAccumulated, bufferSize * bufferCount)
    }

    func testStreamingLeftoverTailIsRetainedNotEmitted() {
        let processor = StreamingDictationVadProcessor()
        var emitted: [[Float]] = []
        // 4096 + 100 leftover -> exactly one chunk emitted, 100 retained.
        let input = (0..<4196).map { Float($0) }
        processor.accept(samples: input) { emitted.append($0) }
        XCTAssertEqual(emitted.count, 1)
        XCTAssertEqual(emitted[0].count, 4096)
        // Next 3996 samples complete the second chunk using the retained 100.
        let more = (4196..<8192).map { Float($0) }
        processor.accept(samples: more) { emitted.append($0) }
        XCTAssertEqual(emitted.count, 2)
        XCTAssertEqual(emitted[1], (4096..<8192).map { Float($0) })
    }

    func testResetClearsAccumulatorAndDiagnostics() {
        let processor = StreamingDictationVadProcessor()
        processor.accept(samples: (0..<2000).map { Float($0) }) { _ in }
        processor.reset()
        var emitted: [[Float]] = []
        // After reset the retained 2000 samples are gone, so 2096 new samples
        // are not yet a full chunk.
        processor.accept(samples: (0..<2096).map { Float($0) }) { emitted.append($0) }
        XCTAssertTrue(emitted.isEmpty)
        XCTAssertEqual(processor.diagnostics.chunksEmitted, 0)
        XCTAssertEqual(processor.diagnostics.samplesAccumulated, 2096)
    }
}
```

- [ ] **Run** `swift test --filter DictationVadProcessorTests` → **expect FAIL**.
- [ ] **Implement** — append to `DictationVadProcessor.swift`:

```swift
/// Accumulates 16 kHz mono samples and emits exactly-4096-sample chunks
/// (256 ms) for Silero VAD. Single-threaded by contract: the recorder calls
/// `accept` only on the serial `sharedProcessingQueue`, so no internal lock is
/// needed for the buffer (the diagnostics lock guards cross-thread reads only).
final class StreamingDictationVadProcessor: DictationVadProcessing, @unchecked Sendable {
    static let chunkSize = VadManager.chunkSize // 4096

    private var accumulator: [Float] = []
    private let lock = NSLock()
    private var diagnosticsStorage = VadProcessingDiagnostics(
        processorName: "silero-vad-v6",
        loaded: true,
        samplesAccumulated: 0,
        chunksEmitted: 0,
        oversizedChunksDropped: 0,
        processingFailures: 0
    )

    var diagnostics: VadProcessingDiagnostics {
        lock.lock(); defer { lock.unlock() }
        return diagnosticsStorage
    }

    func accept(samples: [Float], emit: (_ chunk: [Float]) -> Void) {
        guard !samples.isEmpty else { return }
        accumulator.append(contentsOf: samples)
        lock.lock()
        diagnosticsStorage.samplesAccumulated += samples.count
        lock.unlock()

        while accumulator.count >= Self.chunkSize {
            // `Array(prefix)` copies; never pass more than chunkSize (Silero
            // silently truncates oversized chunks, which would desync timing).
            let chunk = Array(accumulator.prefix(Self.chunkSize))
            accumulator.removeFirst(Self.chunkSize)
            lock.lock()
            diagnosticsStorage.chunksEmitted += 1
            lock.unlock()
            emit(chunk)
        }
    }

    func reset() {
        accumulator.removeAll(keepingCapacity: true)
        lock.lock(); defer { lock.unlock() }
        diagnosticsStorage = VadProcessingDiagnostics(
            processorName: "silero-vad-v6",
            loaded: true,
            samplesAccumulated: 0,
            chunksEmitted: 0,
            oversizedChunksDropped: 0,
            processingFailures: 0
        )
    }
}
```

> Note `import FluidAudio` at the top of `DictationVadProcessor.swift` for `VadManager.chunkSize`.

- [ ] **Run** `swift test --filter DictationVadProcessorTests` → **expect PASS**.
- [ ] **Commit**: `feat(stt): add 4096-sample streaming VAD accumulator (byte-exact chunking)`

---

### Task 3 — `VadManagerProviding` adapter + `DictationVadEngine` actor (mock-driven)

A small actor — the only place that touches `VadManager` (§6.2). The adapter protocol lets a mock stand in for the real actor in tests.

- [ ] **Write failing test** — create `Tests/MacParakeetTests/Services/Capture/DictationVadEngineTests.swift`:

```swift
import XCTest
import FluidAudio
@testable import MacParakeetCore

private actor MockVadManager: VadManagerProviding {
    enum Behavior { case available, throwsOnProcess, neverLoads }
    private let behavior: Behavior
    private(set) var processCalls = 0
    init(_ behavior: Behavior) { self.behavior = behavior }

    var isAvailable: Bool { get async { behavior != .neverLoads } }

    func makeStreamState() async -> VadStreamState { VadStreamState.initial() }

    func processStreamingChunk(_ chunk: [Float], state: VadStreamState) async throws -> VadStreamResult {
        processCalls += 1
        if behavior == .throwsOnProcess { throw VadError.modelProcessingFailed("mock") }
        // Emit a speechStart on first call so callers can assert event flow.
        let event = VadStreamEvent(kind: .speechStart, sampleIndex: 0, time: nil)
        var next = state
        next.processedSamples += chunk.count
        return VadStreamResult(state: next, event: event, probability: 0.99)
    }
}

final class DictationVadEngineTests: XCTestCase {
    func testWarmUpMakesEngineAvailableAndProcessReturnsEvent() async {
        let mock = MockVadManager(.available)
        let engine = DictationVadEngine(makeManager: { mock })
        await engine.warmUpIfNeeded()
        let available = await engine.isAvailable
        XCTAssertTrue(available)

        var state = await engine.makeStreamState()
        XCTAssertNotNil(state)
        var s = state!
        let outer = await engine.process(chunk: [Float](repeating: 0, count: 4096), state: &s)
        // Double-optional: outer nil == unavailable/error; inner nil == no event.
        XCTAssertNotNil(outer)
        XCTAssertNotNil(outer!)
        XCTAssertEqual(outer!!.kind, .speechStart)
    }

    func testUnavailableManagerKeepsEngineUnavailable() async {
        let mock = MockVadManager(.neverLoads)
        let engine = DictationVadEngine(makeManager: { mock })
        await engine.warmUpIfNeeded()
        let available = await engine.isAvailable
        XCTAssertFalse(available)
        let state = await engine.makeStreamState()
        XCTAssertNil(state, "no stream state when manager is unavailable")
    }

    func testProcessErrorYieldsOuterNilFallbackSignal() async {
        let mock = MockVadManager(.throwsOnProcess)
        let engine = DictationVadEngine(makeManager: { mock })
        await engine.warmUpIfNeeded()
        var s = (await engine.makeStreamState())!
        let outer = await engine.process(chunk: [Float](repeating: 0, count: 4096), state: &s)
        XCTAssertNil(outer, "process error -> outer nil -> recorder falls back to RMS")
    }

    func testWarmUpIsSingleFlight() async {
        actor Counter { var n = 0; func bump() { n += 1 }; func get() -> Int { n } }
        let counter = Counter()
        let engine = DictationVadEngine(makeManager: {
            await counter.bump()
            return MockVadManager(.available)
        })
        async let a: Void = engine.warmUpIfNeeded()
        async let b: Void = engine.warmUpIfNeeded()
        _ = await (a, b)
        await engine.warmUpIfNeeded()
        let n = await counter.get()
        XCTAssertEqual(n, 1, "manager built exactly once across concurrent + repeat warm-ups")
    }
}
```

- [ ] **Run** `swift test --filter DictationVadEngineTests` → **expect FAIL**.
- [ ] **Implement** — create `Sources/MacParakeetCore/Services/Capture/DictationVadEngine.swift`:

```swift
import FluidAudio
import Foundation
import OSLog

/// Adapter so the real `VadManager` actor and a test mock present the same
/// minimal streaming surface to `DictationVadEngine`. The real signatures
/// (verified against FluidAudio 0.14.5) are `makeStreamState() -> VadStreamState`
/// and `processStreamingChunk(_:state:config:returnSeconds:timeResolution:)`;
/// we pin the defaulted config args here.
public protocol VadManagerProviding: Sendable {
    var isAvailable: Bool { get async }
    func makeStreamState() async -> VadStreamState
    func processStreamingChunk(_ chunk: [Float], state: VadStreamState) async throws -> VadStreamResult
}

extension VadManager: VadManagerProviding {
    public func processStreamingChunk(
        _ chunk: [Float],
        state: VadStreamState
    ) async throws -> VadStreamResult {
        try await processStreamingChunk(chunk, state: state, config: .default)
    }
}

/// Owns the Silero `VadManager` for dictation endpointing. Lives in the
/// capture/endpointing plane (ADR-016 carve-out, §6.1) — never routed through
/// `STTRuntime`. Warmed once, reused across dictations, single-flight guarded
/// (mirrors `STTRuntime.ensureInitialized`).
public actor DictationVadEngine {
    private let logger = Logger(subsystem: "com.macparakeet.core", category: "DictationVadEngine")
    private let makeManager: @Sendable () async throws -> VadManagerProviding
    private var manager: VadManagerProviding?
    private var loadFailed = false
    private var warmUpTask: Task<Void, Never>?

    public init(
        makeManager: @escaping @Sendable () async throws -> VadManagerProviding = {
            try await VadManager()
        }
    ) {
        self.makeManager = makeManager
    }

    /// True once a usable manager is loaded. `nil`/failed ⇒ false ⇒ RMS fallback.
    public var isAvailable: Bool {
        get async {
            guard let manager else { return false }
            return await manager.isAvailable
        }
    }

    /// Build the `VadManager` once (downloads the ~1.3 MB Silero v6 asset if
    /// missing) and JIT the ANE path with one throwaway 4096-zero chunk.
    /// Single-flight: concurrent and repeat calls coalesce onto one task.
    public func warmUpIfNeeded() async {
        if manager != nil || loadFailed { return }
        if let warmUpTask {
            await warmUpTask.value
            return
        }
        let task = Task { [makeManager] in
            await self.performWarmUp(makeManager)
        }
        warmUpTask = task
        await task.value
        warmUpTask = nil
    }

    private func performWarmUp(_ makeManager: @Sendable () async throws -> VadManagerProviding) async {
        if manager != nil || loadFailed { return }
        do {
            let built = try await makeManager()
            guard await built.isAvailable else {
                loadFailed = true
                logger.warning("dictation_vad_warmup_unavailable")
                return
            }
            manager = built
            // JIT the ANE path; ignore the result and any error.
            var state = await built.makeStreamState()
            _ = try? await built.processStreamingChunk(
                [Float](repeating: 0, count: VadManager.chunkSize),
                state: state
            )
            _ = state
            logger.info("dictation_vad_warmup_ready")
        } catch {
            loadFailed = true
            logger.warning("dictation_vad_warmup_failed error=\(error.localizedDescription, privacy: .public)")
        }
    }

    /// nil ⇒ unavailable; caller uses RMS fallback.
    public func makeStreamState() async -> VadStreamState? {
        guard let manager, await manager.isAvailable else { return nil }
        return await manager.makeStreamState()
    }

    /// Returns a double-optional: outer `nil` ⇒ unavailable/error (RMS
    /// fallback); inner `nil` ⇒ no speech event this chunk.
    public func process(chunk: [Float], state: inout VadStreamState) async -> VadStreamEvent?? {
        guard let manager else { return nil }
        do {
            let result = try await manager.processStreamingChunk(chunk, state: state)
            state = result.state
            return .some(result.event)
        } catch {
            return nil
        }
    }
}
```

- [ ] **Run** `swift test --filter DictationVadEngineTests` → **expect PASS**.
- [ ] **Commit**: `feat(stt): add DictationVadEngine actor + VadManagerProviding adapter`

---

### Task 4 — `VadSnapshot` value type in `AudioRecorder.swift`

The published verdict (§6.3). Placed in `AudioRecorder.swift` next to `RecordingDeviceInfo`.

- [ ] **Write failing test** — append to `DictationVadProcessorTests.swift` (it is in the same test target and `@testable import MacParakeetCore`):

```swift
extension DictationVadProcessorTests {
    func testVadSnapshotUnavailableDefault() {
        let s = VadSnapshot.unavailable
        XCTAssertFalse(s.available)
        XCTAssertFalse(s.speechActive)
        XCTAssertNil(s.lastSpeechAt)
    }
}
```

- [ ] **Run** `swift test --filter DictationVadProcessorTests/testVadSnapshotUnavailableDefault` → **expect FAIL**.
- [ ] **Implement** — in `Sources/MacParakeetCore/Audio/AudioRecorder.swift`, add immediately after the `RecordingDeviceInfo` struct (after line 23):

```swift
/// Decision-only snapshot of the Silero VAD verdict for the live dictation
/// session, published from the audio path via an `OSAllocatedUnfairLock` (the
/// same discipline as `atomicAudioLevel`). Carries no transcript or audio.
/// `available == false` ⇒ the coordinator's endpointer uses the RMS gate.
public struct VadSnapshot: Sendable, Equatable {
    public var available: Bool
    public var speechActive: Bool
    public var lastSpeechAt: Date?

    public init(available: Bool, speechActive: Bool, lastSpeechAt: Date?) {
        self.available = available
        self.speechActive = speechActive
        self.lastSpeechAt = lastSpeechAt
    }

    public static let unavailable = VadSnapshot(
        available: false, speechActive: false, lastSpeechAt: nil
    )
}
```

- [ ] **Run** the filter → **expect PASS**.
- [ ] **Commit**: `feat(stt): add VadSnapshot decision-only verdict type`

---

### Task 5 — `AudioRecorder` init params + lock + accessor + per-session/stop resets

Add `enableVad`/`vadEngine` injection, the published-snapshot lock, the `vadState` accessor, and the resets. The VAD **fork** itself comes in Task 6.

- [ ] **Implement (compile-driven; covered by Task 7 integration test)** — in `AudioRecorder.swift`:

1. Add stored props next to `atomicAudioLevel` (after line 74):

```swift
    /// VAD verdict published from the audio path. Its own lock — never shared
    /// with the writer path — so VAD can never backpressure the WAV write
    /// (§6.10 decision-only invariant).
    nonisolated private let atomicVadSnapshot = OSAllocatedUnfairLock<VadSnapshot>(
        initialState: .unavailable
    )
    private let enableVad: @Sendable () -> Bool
    private let vadEngine: DictationVadEngine?
```

2. Extend `init` (replace the existing init at line 127–135):

```swift
    public init(
        sharedStream: SharedMicrophoneStream,
        permissionProvider: @escaping @Sendable () -> Bool = {
            AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        },
        enableVad: @escaping @Sendable () -> Bool = { false },
        vadEngine: DictationVadEngine? = nil
    ) {
        self.sharedStream = sharedStream
        self.permissionProvider = permissionProvider
        self.enableVad = enableVad
        self.vadEngine = vadEngine
    }
```

3. Add the actor-isolated accessor next to `audioLevel` (after line 140):

```swift
    public var vadState: VadSnapshot {
        atomicVadSnapshot.withLock { $0 }
    }
```

4. Per-session reset — add to the reset block at line 205–208 (after `self.sampleCounter.withLock { $0 = 0 }`):

```swift
        self.atomicVadSnapshot.withLock { $0 = .unavailable }
```

5. Stop reset — add next to `atomicAudioLevel.withLock { $0 = 0.0 }` at line 483:

```swift
        atomicVadSnapshot.withLock { $0 = .unavailable }
```

- [ ] **Run** `swift build` → **expect SUCCESS** (no new behavior yet; AppEnvironment still uses the defaulted no-VAD init).
- [ ] **Commit**: `feat(stt): add VAD injection + published snapshot lock to AudioRecorder`

---

### Task 6 — The decision-only VAD fork in `AudioRecorder` (after the WAV write)

The fork (§6.3, §6.10). **Concurrency design (data-race fix):** the per-chunk-`Task` + shared mutable `VadStreamState` box from the first draft was a real data race — `accept` synchronously *spawns* a Task and returns, so two chunks' Tasks could interleave reads/writes of the shared state on the cooperative pool, corrupting `VadStreamState`. We instead use **one per-session `AsyncStream<[Float]>`** drained by **one long-lived consumer `Task` that owns its `VadStreamState` as a local `var`** — strictly ordered, no shared mutable state, bounded by the stream's buffering policy. The serial-queue `accept` body only `yield`s owned `[Float]` chunks (non-blocking, never touches the writer's lock).

- [ ] **Implement** — in `AudioRecorder.swift`:

1. Add two per-session actor props next to the other VAD state (near `atomicVadSnapshot`, from Task 5):

```swift
    /// Per-session VAD pipeline teardown handles. Non-nil only while a VAD-active
    /// session is recording. The consumer Task owns its VadStreamState locally,
    /// so there is no shared mutable streaming state (the prior box was a race).
    private var vadChunkContinuation: AsyncStream<[Float]>.Continuation?
    private var vadConsumerTask: Task<Void, Never>?
```

2. Inside `start()`, just before `let processCopiedBuffer = ...` (line 216), build the processor, the chunk stream, and the single consumer (only when auto-stop is on AND the engine warmed — otherwise stay `.unavailable` for the RMS fallback and allocate nothing):

```swift
        // VAD pipeline (decision-only). Active only when auto-stop is on AND the
        // engine warmed; otherwise the snapshot stays `.unavailable` (RMS gate)
        // and no stream/consumer/accumulator is created.
        let vadProcessor: DictationVadProcessing
        let vadContinuation: AsyncStream<[Float]>.Continuation?
        if self.enableVad(), let vadEngine, await vadEngine.isAvailable,
           let initialVadState = await vadEngine.makeStreamState() {
            vadProcessor = StreamingDictationVadProcessor()
            // Bound memory under any engine stall: drop oldest chunks rather than
            // grow unbounded. ~16 chunks ≈ 4 s of 256 ms frames. Under normal
            // load (ANE inference ≪ 256 ms) the buffer never fills.
            let (stream, continuation) = AsyncStream<[Float]>.makeStream(
                bufferingPolicy: .bufferingNewest(16)
            )
            vadContinuation = continuation
            self.atomicVadSnapshot.withLock {
                $0 = VadSnapshot(available: true, speechActive: false, lastSpeechAt: nil)
            }
            // ONE consumer drains the stream in order, owning `state` locally.
            let consumer = Task<Void, Never>.detached(priority: .utility) { [weak self] in
                guard let self else { return }
                var state = initialVadState
                for await chunk in stream {
                    guard self.sessionGeneration.withLock({ $0 }) == tapGeneration else { continue }
                    let event = await vadEngine.process(chunk: chunk, state: &state)
                    guard self.sessionGeneration.withLock({ $0 }) == tapGeneration else { continue }
                    switch event {
                    case .none:
                        // Unavailable/error mid-session -> fall back to RMS.
                        self.atomicVadSnapshot.withLock { $0 = .unavailable }
                    case .some(let inner):
                        self.atomicVadSnapshot.withLock { snapshot in
                            snapshot.available = true
                            if let inner {
                                switch inner.kind {
                                case .speechStart:
                                    snapshot.speechActive = true
                                    snapshot.lastSpeechAt = Date()
                                case .speechEnd:
                                    snapshot.speechActive = false
                                }
                            } else if snapshot.speechActive {
                                // Still in a speech run with no boundary event:
                                // refresh lastSpeechAt so the endpointer measures
                                // silence from the last speech frame.
                                snapshot.lastSpeechAt = Date()
                            }
                        }
                    }
                }
            }
            self.vadConsumerTask = consumer
        } else {
            vadProcessor = PassthroughDictationVadProcessor()
            vadContinuation = nil
        }
```

3. Inside `processCopiedBuffer`, in the `.haveData` branch, **after** `self.runtimeMetrics.withLock { $0.outputBufferCount += 1 }` (immediately after line 338) and still inside the `do { ... }` and the generation guard, append a COPY of the converted frames and yield completed 4096-chunks to the consumer:

```swift
                    // ── VAD fork (decision-only). Runs AFTER the WAV write,
                    //    inside the generation guard. Reads a COPY of the
                    //    converted frames and only `yield`s to the AsyncStream —
                    //    no lock the writer path uses, no inference on this queue.
                    if let vadContinuation,
                       let data = convertedBuffer.floatChannelData?[0],
                       convertedFrameLength > 0 {
                        let frames = Array(UnsafeBufferPointer(start: data, count: convertedFrameLength))
                        vadProcessor.accept(samples: frames) { chunk in
                            vadContinuation.yield(chunk)   // ordered, non-blocking
                        }
                    }
```

4. Assign the continuation onto the actor for teardown — in `start()`, in the success tail where `self.recording = true` is set (next to `self.sharedSubscriberToken = token`, ~line 427):

```swift
        self.vadChunkContinuation = vadContinuation
```

   …and in the `lostRace` cleanup branch (just before the `throw AudioProcessorError.recordingFailed("interrupted during subscribe")`, ~line 421), tear the pipeline down so an orphaned session leaves nothing running:

```swift
            vadContinuation?.finish()
            self.vadConsumerTask?.cancel()
            self.vadConsumerTask = nil
```

5. In `stop()`, finish the stream and drop the handles next to the `atomicVadSnapshot` reset (added in Task 5, ~line 483). Finishing the stream ends the consumer's `for await` loop:

```swift
        vadChunkContinuation?.finish()
        vadChunkContinuation = nil
        vadConsumerTask = nil
```

> `import FluidAudio` is already present at the top of `AudioRecorder.swift` (line 3). There is **no** `VadStreamStateBox` — the consumer's local `var state` replaces it, which is what removes the race. `vadEngine` and `tapGeneration` are already in scope in `start()`; `AsyncStream.Continuation` is `Sendable` and safe to both capture into the serial-queue closure and store on the actor.

- [ ] **Run** `swift build` → **expect SUCCESS** (Swift 6 strict concurrency: no `@unchecked Sendable` box, no shared mutable streaming state).
- [ ] **Commit**: `feat(stt): wire decision-only VAD fork (single AsyncStream consumer) after the WAV write`

---

### Task 7 — `DictationVadIntegrationTests`: write-cadence regression + offline→RMS

Asserts the decision-only invariant (§6.10): output-buffer / write cadence is unchanged with VAD enabled, and an unavailable engine keeps the snapshot `.unavailable` (RMS path).

> **Write-cadence invariant — how it is verified (§6.10).** There is no in-process seam to run a full `AudioRecorder` capture against a fake `SharedMicrophoneStream`, so the "writer untouched while VAD runs" invariant is NOT asserted by a unit test. Instead it is guaranteed **structurally** (the VAD fork runs strictly *after* `fileBox.file.write(...)` inside the existing generation guard, reads a copy, and only `yield`s to an `AsyncStream` whose consumer holds no lock the writer path uses — see Task 6) and **verified empirically** by the dev-app smoke step (Task 14), which compares the `dictation_capture_stop` diagnostics line (`output_buffers`, `input_buffers`) with VAD on vs off. The unit tests below pin the two things that ARE unit-testable: the byte-exact chunker (Task 2) and the engine-unavailable → no-chunks-consumed (offline → RMS) path.

- [ ] **Write failing test** — create `Tests/MacParakeetTests/Services/Capture/DictationVadIntegrationTests.swift` with the engine-level tests below.

```swift
import XCTest
import FluidAudio
@testable import MacParakeetCore

final class DictationVadIntegrationTests: XCTestCase {
    /// Offline / unavailable engine: warm-up reports unavailable, so the
    /// recorder builds a passthrough processor and the published snapshot stays
    /// `.unavailable` — the coordinator then uses the RMS gate.
    func testUnavailableEngineKeepsSnapshotUnavailable() async {
        let engine = DictationVadEngine(makeManager: { MockUnavailableManager() })
        await engine.warmUpIfNeeded()
        let available = await engine.isAvailable
        XCTAssertFalse(available)
        // The recorder's gate is `enableVad() && isAvailable && makeStreamState != nil`;
        // with isAvailable false it never allocates a streaming processor.
        let state = await engine.makeStreamState()
        XCTAssertNil(state)
    }

    /// Passthrough processor consumes zero chunks, so an unavailable VAD path
    /// performs no per-chunk work — proving the writer path is untouched.
    func testPassthroughProcessorConsumesNoChunks() {
        let processor = PassthroughDictationVadProcessor()
        var emitted = 0
        for _ in 0..<10 {
            processor.accept(samples: [Float](repeating: 0.1, count: 1486)) { _ in emitted += 1 }
        }
        XCTAssertEqual(emitted, 0)
    }
}

private actor MockUnavailableManager: VadManagerProviding {
    var isAvailable: Bool { get async { false } }
    func makeStreamState() async -> VadStreamState { .initial() }
    func processStreamingChunk(_ chunk: [Float], state: VadStreamState) async throws -> VadStreamResult {
        VadStreamResult(state: state, event: nil, probability: 0)
    }
}
```

- [ ] **Run** `swift test --filter DictationVadIntegrationTests` → **expect FAIL** then (after the symbols from Tasks 1–6 exist) **PASS**.
- [ ] **Commit**: `test(stt): VAD offline->RMS + passthrough no-work regression`

---

### Task 8 — Plumb `vadState` through the protocol + processor + service + session

§6.4: mirror the `audioLevel` seam end-to-end.

- [ ] **Write failing test** — append to `DictationVadEngineTests.swift`:

```swift
extension DictationVadEngineTests {
    func testAudioProcessorFileOnlyInitReportsUnavailableVad() async {
        let processor = AudioProcessor() // CLI/test init: no VAD
        let snapshot = await processor.vadState
        XCTAssertEqual(snapshot, .unavailable)
    }
}
```

- [ ] **Run** `swift test --filter DictationVadEngineTests/testAudioProcessorFileOnlyInitReportsUnavailableVad` → **expect FAIL**.
- [ ] **Implement**:

1. `AudioProcessorProtocol.swift` — add the requirement after the `recordingDeviceInfo` requirement (line 20):

```swift
    /// Latest Silero VAD verdict for the active dictation; `.unavailable` when
    /// VAD is off, not warmed, or errored (the consumer then uses the RMS gate).
    var vadState: VadSnapshot { get async }
```

   **AND** add a default implementation in the SAME file (below the `AudioProcessorError` enum, outside the protocol) so the 4 existing conformances that don't capture VAD — `MockAudioProcessor` (Tests/MacParakeetTests/Audio/MockAudioProcessor.swift), `StartInterruptedAudioProcessor` / `StartInterruptedDelayedStopAudioProcessor` (DictationServiceTests.swift), `DictationRaceAudioProcessor` (DictationServiceSessionTests.swift) — compile unchanged. Only the real `AudioProcessor` overrides it (step 2):

```swift
public extension AudioProcessorProtocol {
    /// Conformers without a VAD path (CLI, all test doubles) report
    /// `.unavailable`, so the endpointer falls back to the RMS gate.
    var vadState: VadSnapshot {
        get async { .unavailable }
    }
}
```

   > Without this default extension, adding the requirement breaks `swift build`/`swift test` on those 4 mocks. Verify after step 2 with `grep -rln "AudioProcessorProtocol" Tests/` to confirm no mock needs a hand-written `vadState`.

2. `AudioProcessor.swift` — replace the two inits and add the seam:

```swift
    public init(
        sharedMicStream: SharedMicrophoneStream,
        enableVad: @escaping @Sendable () -> Bool = { false },
        vadEngine: DictationVadEngine? = nil
    ) {
        self.recorder = AudioRecorder(
            sharedStream: sharedMicStream,
            enableVad: enableVad,
            vadEngine: vadEngine
        )
        self.converter = AudioFileConverter()
    }

    /// File-only init (CLI, tests). No VAD ever loads.
    public init() {
        let stream = SharedMicrophoneStream(platform: AVAudioEngineMicrophonePlatform())
        self.recorder = AudioRecorder(sharedStream: stream)
        self.converter = AudioFileConverter()
    }
```

   and add the accessor next to `audioLevel` (after line 26):

```swift
    public var vadState: VadSnapshot {
        get async { await recorder.vadState }
    }
```

3. `DictationService.swift` — add next to `audioLevel` (after line 105):

```swift
    public var vadState: VadSnapshot {
        get async { await audioProcessor.vadState }
    }
```

4. `DictationServiceSession.swift` — replace `recordingSnapshot()` (lines 26–30):

```swift
    public func recordingSnapshot() async -> (state: DictationState, audioLevel: Float, vad: VadSnapshot) {
        async let state = service.state
        async let audioLevel = service.audioLevel
        async let vad = service.vadState
        return await (state: state, audioLevel: audioLevel, vad: vad)
    }
```

- [ ] **Run** `swift test --filter DictationVadEngineTests/testAudioProcessorFileOnlyInitReportsUnavailableVad` → **expect PASS**, then `swift build` → **expect SUCCESS** (the coordinator's `recordingSnapshot()` call still compiles: tuple is read by field name in PR1's rewrite, and the new `vad` field is additive).
- [ ] **Commit**: `feat(stt): surface VadSnapshot through audio processor + dictation service seam`

---

### Task 9 — Telemetry: additive `endpoint_reason` + `vad_available`

§6.8: additive optional props, no content. House style favors additive props over new events.

- [ ] **Write failing test** — find the telemetry props test file (`grep -rn "dictation_completed" Tests/`) and append (in the matching `TelemetryEventTests`-style file):

```swift
    func testDictationCompletedIncludesEndpointReasonAndVadAvailable() {
        let props = TelemetryEventSpec.dictationCompleted(
            durationSeconds: 3.0,
            wordCount: 5,
            mode: .persistent,
            endpointReason: "vad_silence",
            vadAvailable: true
        ).props
        XCTAssertEqual(props["endpoint_reason"], "vad_silence")
        XCTAssertEqual(props["vad_available"], "true")
    }

    func testDictationCompletedOmitsEndpointReasonWhenNil() {
        let props = TelemetryEventSpec.dictationCompleted(
            durationSeconds: 3.0, wordCount: 5, mode: .persistent
        ).props
        XCTAssertNil(props["endpoint_reason"])
        XCTAssertNil(props["vad_available"])
    }
```

> If the props accessor differs (e.g. a `properties(for:)` helper), match the existing test's call style — the existing `dictationCompleted` entry already has a props test to mirror.

- [ ] **Run** `swift test --filter TelemetryEvent` → **expect FAIL**.
- [ ] **Implement** — in `TelemetryEvent.swift`:

1. Extend the `dictationCompleted` case (lines 409–418) with two defaulted params:

```swift
    case dictationCompleted(
        durationSeconds: Double,
        wordCount: Int,
        mode: TelemetryDictationMode?,
        speechEngine: String? = nil,
        engineVariant: String? = nil,
        language: String? = nil,
        appCategory: TelemetryAppCategory? = nil,
        device: RecordingDeviceInfo? = nil,
        endpointReason: String? = nil,
        vadAvailable: Bool? = nil
    )
```

2. Update its destructure + props (lines 926–944):

```swift
        case .dictationCompleted(
            let durationSeconds,
            let wordCount,
            let mode,
            let speechEngine,
            let engineVariant,
            let language,
            let appCategory,
            let device,
            let endpointReason,
            let vadAvailable
        ):
            return Self.mergeDevice(Self.compactProps(
                ("duration_seconds", Self.format(durationSeconds)),
                ("word_count", "\(wordCount)"),
                ("mode", mode?.rawValue),
                ("speech_engine", speechEngine),
                ("engine_variant", Self.safeEngineVariant(engineVariant)),
                ("language", Self.safeLanguageCode(language)),
                ("app_category", appCategory?.rawValue),
                ("endpoint_reason", endpointReason),
                ("vad_available", vadAvailable.map(Self.boolString))
            ), device)
```

3. Identically extend `dictationOperation` (case at line 426 + destructure/props at 960–991): add `endpointReason: String? = nil, vadAvailable: Bool? = nil` params and the two `compactProps` lines.

- [ ] **Run** `swift test --filter TelemetryEvent` → **expect PASS**.
- [ ] **Commit**: `feat(telemetry): add additive endpoint_reason + vad_available props`

---

### Task 10 — Wire `DictationVadEngine` in `AppEnvironment` (warm-up gated on `silenceAutoStop`)

§6.2: owned process-wide, injected into `AudioProcessor`; `enableVad` is the `silenceAutoStop` closure.

- [ ] **Implement (compile-driven)** — in `AppEnvironment.swift`:

1. Add the stored property (after line 22, next to `audioProcessor`):

```swift
    let dictationVadEngine: DictationVadEngine
```

2. Construct it and pass into `AudioProcessor` — replace line 96:

```swift
        let vadEngine = DictationVadEngine()
        dictationVadEngine = vadEngine
        // `silenceAutoStop` is a SettingsViewModel/UserDefaults-backed pref — it
        // is NOT on AppRuntimePreferencesProtocol (that protocol exposes only the
        // KEY: `silenceAutoStopKey`). Read the persisted key directly so the
        // closure is @Sendable with no non-Sendable captures and reflects live
        // toggles every time the recorder calls it.
        let silenceAutoStopEnabled: @Sendable () -> Bool = {
            UserDefaults.standard.bool(forKey: UserDefaultsAppRuntimePreferences.silenceAutoStopKey)
        }
        audioProcessor = AudioProcessor(
            sharedMicStream: sharedMicStream,
            enableVad: silenceAutoStopEnabled,
            vadEngine: vadEngine
        )
```

> Confirmed against source: `silenceAutoStopKey` is `AppRuntimePreferences.swift:150`; the `silenceAutoStop: Bool` property lives on `SettingsViewModel` (`SettingsViewModel.swift:130`), not on `AppRuntimePreferencesProtocol`. Reading `UserDefaults.standard.bool(forKey:)` is the correct, compiling form (the earlier `runtimePreferences.silenceAutoStop` would not compile).

- [ ] **Run** `swift build` → **expect SUCCESS**.
- [ ] **Commit**: `feat(stt): own DictationVadEngine in AppEnvironment and gate it on silenceAutoStop`

---

### Task 11 — Fold VAD warm-up into the deferred speech pre-warm (gated on `silenceAutoStop`)

§6.2 / §6.9: warm VAD only when auto-stop is on; fold the ~1.3 MB Silero asset into the existing warm/onboarding path.

- [ ] **Implement (compile-driven; behavior is the warm-up call)** — in `AppDelegate.swift`, inside `scheduleDeferredSpeechPreWarm(environment:)`, capture the engine and call it after the STT warm-up. Replace the closure body's tail (the `await sttRuntime.backgroundWarmUp()` block, lines ~498–508):

```swift
        let sttRuntime = env.sttRuntime
        let vadEngine = env.dictationVadEngine
        let deferralMs = preWarmDeferralMs
        let onboardingCompletedKey = OnboardingViewModel.onboardingCompletedKey

        speechPreWarmTask = Task(priority: .utility) { @MainActor [weak self, sttRuntime, vadEngine] in
            defer { self?.speechPreWarmTask = nil }
            try? await Task.sleep(for: .milliseconds(deferralMs))
            guard !Task.isCancelled else { return }
            let onboardingDone = UserDefaults.standard.string(forKey: onboardingCompletedKey) != nil
            guard onboardingDone else { return }
            await sttRuntime.backgroundWarmUp()
            guard !Task.isCancelled else { return }
            // Warm Silero VAD only when the user has opted into auto-stop — the
            // ~1.3 MB asset is fetched on first VadManager init. No-op (and no
            // download) when auto-stop is off. Read the persisted key directly
            // (same resolution as AppEnvironment Task 10).
            let autoStopOn = UserDefaults.standard.bool(
                forKey: UserDefaultsAppRuntimePreferences.silenceAutoStopKey
            )
            if autoStopOn {
                await vadEngine.warmUpIfNeeded()
            }
        }
```

> Reads `silenceAutoStopKey` from `UserDefaults` (matching Task 10), since `silenceAutoStop` is not on `AppRuntimePreferencesProtocol`. `runtimePreferences` is no longer captured.

- [ ] **Run** `swift build` → **expect SUCCESS**.
- [ ] **Commit**: `feat(stt): warm Silero VAD in the deferred pre-warm when auto-stop is on`

---

### Task 12 — Pass the live VAD fields into `DictationEndpointer.Input` (replace PR1's `vadAvailable=false`)

§6.6. PR1's `runRecordingLevelLoop(mode:)` already builds the endpointer and feeds `Input` with `vadAvailable: false`. This step swaps in the live snapshot fields.

- [ ] **Implement** — in `DictationFlowCoordinator.swift`, in PR1's `runRecordingLevelLoop` body, replace the per-tick `Input` construction so it reads the new `vad` tuple field. The tick should become:

```swift
            let snapshot = await serviceSession.recordingSnapshot()
            guard case .recording = snapshot.state else { break }

            overlayViewModel?.audioLevel = snapshot.audioLevel

            let now = Date()
            let vad = snapshot.vad
            let vadSilenceElapsed: TimeInterval? = vad.lastSpeechAt.map { now.timeIntervalSince($0) }

            let input = DictationEndpointer.Input(
                now: now,
                elapsed: now.timeIntervalSince(loopStartedAt),
                audioLevel: snapshot.audioLevel,
                vadAvailable: vad.available,
                speechActive: vad.speechActive,
                vadSilenceElapsed: vadSilenceElapsed,
                completenessVeto: nil
            )
            switch endpointer.evaluate(input) {
            case .keepListening:
                break
            case .stop(let reason):
                lastEndpointReason = reason
                stopDictation()
                break
            }

            try? await Task.sleep(for: .milliseconds(50))
```

> `loopStartedAt`, `endpointer`, and `lastEndpointReason` are PR1 locals declared before the loop. `Input`'s exact field names (`now`, `elapsed`, `audioLevel`, `vadAvailable`, `speechActive`, `vadSilenceElapsed`, `completenessVeto`) match PR1. If PR1 named any field differently, adjust to match — see assumptions.

- [ ] **Telemetry emission — explicitly deferred to Phase 2 (not wired in PR 2).** Task 9 lands the additive `endpoint_reason` / `vad_available` props on `dictationCompleted` / `dictationOperation` (compiled + unit-tested), so the envelope is ready. Actually *emitting* them requires threading `lastEndpointReason` from the GUI coordinator into the Core `DictationService` stop/telemetry path (the completion events are sent by the service, not the coordinator). That cross-layer wiring is folded into the Phase-2 PR, which already restructures this exact path. Rationale: the props are additive and harmless un-emitted; spec §6.8 marks endpoint telemetry "optional but recommended" and §13 does NOT list it as a Phase-1 acceptance gate; deferring avoids a speculative coordinator↔service handle that isn't verified here. Track `lastEndpointReason` in the loop now (it costs nothing and is consumed in Phase 2).
- [ ] **Run** `swift build` → **expect SUCCESS**.
- [ ] **Commit**: `feat(stt): feed live Silero VAD verdict into the dictation endpointer`

---

### Task 13 — Settings copy reword (§6.7)

No new keys. Reword so it no longer describes an energy gate.

- [ ] **Implement** — in `SettingsView.swift`, replace the auto-stop row detail (line 729) and the silence-delay detail (line 738):

```swift
                settingsToggleRow(
                    title: "Auto-stop after silence",
                    detail: "Listens for your voice and stops recording when you stop speaking.",
                    isOn: $viewModel.silenceAutoStop
                )
```

```swift
                        rowText(
                            title: "Silence delay",
                            detail: "How long to wait after you stop speaking before recording stops."
                        )
```

- [ ] **Run** `swift build` → **expect SUCCESS**.
- [ ] **Commit**: `docs(settings): reword auto-stop copy for VAD-judged silence`

---

### Task 14 — Full verification + dev-app smoke

- [ ] **Run** `swift test` → **expect all pass** (~1–2 min). Confirms no regressions, the new VAD tests green, and PR1's `DictationEndpointerTests` still pass.
- [ ] **Run** `swift build` → **expect SUCCESS** (no `Package.swift` change — VAD compiles on 0.14.5).
- [ ] **Dev-app smoke** (`scripts/dev/run_app.sh`): with **Auto-stop after silence ON**, dictate in a noisy room (fan/music) — recording should stop on a real speech pause, not be held open by noise; then trail off quietly — it should stop appropriately. Toggle **push-to-talk (hold)** — confirm silence never cuts it off (endpointer hard-gated to `.persistent` in PR1). Force VAD-down (toggle auto-stop off → on with network off so the asset never fetched) — confirm dictation still auto-stops via the RMS fallback. Confirm Auto-stop **OFF** (default) behaves exactly as before and no VAD model loads.
- [ ] **Commit** (if any smoke-driven tweaks): `chore(stt): finalize Silero VAD wiring after dev-app smoke`
---

## Plan self-review (writing-plans checklist)

- **Spec coverage:** §6.1 capture-plane ownership → PR2 Task 3/10; §6.2 engine → PR2 Task 3; §6.3 4096 byte-exact chunking → PR2 Task 2; §6.3 published snapshot → PR2 Task 4/5/6; §6.4 seam → PR2 Task 8; §6.5 pure endpointer + RMS parity → PR1 Task 1/2; §6.6 loop rewrite + push-to-talk gate → PR1 Task 3 / PR2 Task 12; §6.7 settings copy → PR2 Task 13; §6.8 telemetry props → PR2 Task 9 (emission scoped per note); §6.9 offline→RMS → PR2 Task 7; §6.10 decision-only invariant → PR2 Task 6 structure + Task 7/14 verification; §13 acceptance → PR1 Task 4 + PR2 Task 14.
- **Placeholders:** none — the reviewer's flagged conditional/"optional" prose has been resolved to concrete code or an explicit, rationalized deferral.
- **Type consistency:** `DictationEndpointer.Config/Input/Decision/StopReason` and `VadSnapshot { available, speechActive, lastSpeechAt }` are defined once (PR1 Task 1; PR2 Task 4) and used with identical field names in PR2 Tasks 6/8/12.
- **TDD/ordering:** PR1 lands and is fully `swift test`-green before PR2; PR2 is test-first per task with `swift build` for wiring/infra steps.

## Out of scope (Phase 2 — see spec §8)
Grammatical-completeness gate, Tier A re-transcribe, Tier B `StreamingEouAsrManager`, the new `dictationEndpointPreview` job kind, ADR-023, `REQ-DICT-007` text, and endpoint-telemetry *emission* wiring are deferred to the Phase-2 cycle.
