# Command Mode — Voice Trigger for Transforms + Deterministic Self-Correction

> Status: **ACTIVE DESIGN**. Feeds ADR-023 and the implementation plan
> `plans/active/2026-06-command-mode-voice-trigger.md` (to be written).
> Date: 2026-06-27
> Related: ADR-022 (Transforms — system-wide rewrites; this resolves its
> "Voice-driven trigger" non-decision), ADR-021 (WhisperKit / per-engine STT),
> ADR-011 (LLM providers), ADR-016 (centralized STT runtime/scheduler), ADR-015
> (concurrent dictation + meeting), ADR-009 (custom hotkeys),
> `plans/active/2026-05-voice-command-agent-mode.md` (the exploration this
> productizes), `docs/research/transforms-design-2026-05.md` (frames Transforms as
> "the hotkey-driven half of Command Mode").

## 1. Thesis

MacParakeet already ships the rewrite primitive: select text anywhere on macOS,
press a bound hotkey, and the selection is rewritten in place through the user's
configured LLM provider (ADR-022). The only missing half of "Command Mode" is the
**voice trigger** — say what you want instead of pre-binding a fixed prompt.

This design adds exactly that, plus a **deterministic self-correction router** so
the most common edits ("scratch that", "uppercase that") run **offline with no
LLM at all** — a privacy-friendly baseline that works even when no provider is
configured. Everything else the user speaks becomes a one-off rewrite through
their existing provider.

The work is deliberately small because the pieces exist: AX-first selection
capture, clipboard-hijack fallback, in-place replacement, the LLM transform
stream, the floating progress pill, the mic capture path, and the STT scheduler
are all built and exercised. The net-new code is a hold-to-talk hotkey, a thin
GUI coordinator, a pure command router, and a Core executor that wires the
existing primitives together.

**Supersedes the removed F10/F10a "Command Mode".** `spec/02-features.md` contains
an older **F10 / F10a "Command Mode"** epic marked **REMOVED** — the original
"select text, speak a natural-language command, edit in place via a bundled local
LLM (Qwen3-8B)" concept, dropped when the bundled-local-LLM path was abandoned.
This design **revives that concept on a different foundation**: BYO/pluggable
provider (ADR-011) instead of a bundled model, plus a deterministic-first offline
router. The §10 doc updates annotate the F10/F10a blocks as *"superseded by
ADR-023"* rather than overwriting their REMOVED history, and the feature takes a
new identifier (**F-CMD**, v0.7) to avoid colliding with the retired F10 numbers.

## 2. Locked product decisions

Settled with the owner on 2026-06-27 during the brainstorming pass:

| Decision | Choice | Rationale |
|---|---|---|
| **Trigger** | Dedicated **hold-to-talk** hotkey, separate from the dictation hotkey and the per-Transform ⌥-digit keys. | Cleanest dictation-vs-command disambiguation. Matches the requirement to use an *explicit* modifier/hotkey rather than always-listening intent classification. |
| **Self-correction surface** | **Unified inside Command Mode.** Spoken instructions run through one router: known phrases execute deterministically (offline); everything else is a provider rewrite. | One surface, one disambiguation gate. The deterministic commands work with no provider configured at all. |
| **Offline command set** | **"Scratch that" family + simple text ops** (case + trim). | No LLM, fully deterministic and testable, immediately useful, privacy-preserving. |
| **Default binding** | Ships **unbound** (opt-in via Settings). The feature is "on" iff a hotkey is bound. | Consistent with ADR-022 §5 "no global toggle" — gesture-as-affordance. |
| **Concurrency** | Command Mode mic capture holds a **bidirectional, session-length lock** that is mutually exclusive with dictation/meeting mic in v1. | Avoids racing the shared mic stream and the reserved STT slot; simultaneous fan-out is deferred. |

## 3. Scope

### In scope (v1)

1. A dedicated, user-configurable **hold-to-talk** global hotkey (default: *unbound*).
2. Hold → capture current selection → record spoken instruction → transcribe →
   route → apply (deterministic edit **or** provider rewrite) → replace in place.
3. A pure **`CommandModeRouter`** that classifies the transcribed instruction as
   deterministic vs. rewrite.
4. Deterministic, offline edits: **scratch-that family** (clear selection) +
   **case ops** (upper/lower/title) + **trim**.
5. Provider rewrites for any other instruction, via the user's already-configured
   LLM provider (local or cloud — cloud is explicit opt-in, unchanged).
6. Progress pill reuse with Command-Mode beats ("Listening…", "Transcribing…",
   "Rewriting…", "Done").
7. Friendly, recoverable failure UX (empty selection, empty speech, no provider,
   LLM/replace failure) — clipboard always restored.
8. A Settings surface to bind/clear the Command Mode hotkey, with collision checks
   against dictation, meeting, and Transform hotkeys (both directions).
9. Opt-out, content-free telemetry mirroring the Transforms events.
10. Tests: pure-unit for the router/edits/prompt builder; mock-based for the
    executor; collision tests for the hotkey.

### Out of scope (v1) — explicit non-goals

- **Always-listening intent classification.** No background classifier deciding
  "was that dictation or a command?". Disambiguation is the explicit hotkey.
- **Mid-dictation interception of the dictation stream.** Self-correction is a
  Command Mode instruction on a *selection*, not a scan of live dictation text.
- **Simultaneous mic fan-out** with dictation/meeting (deferred; v1 is mutually
  exclusive, bidirectional).
- **Agent/tool actions** ("turn this into todos", press-return-after, app
  automation). Tracked in `plans/active/2026-05-voice-command-agent-mode.md`.
- **Streaming tokens into the target field** (same reasoning as ADR-022 §Alt-C).
- **Implicit select-all on empty selection** (same reasoning as ADR-022 §Alt-D) —
  empty selection shows an educational toast and does nothing else.
- **A CLI surface for the *voice* trigger.** AX capture + mic are GUI-only. The
  deterministic edits and the rewrite-prompt builder are pure and unit-tested;
  a `command-mode`-style CLI subcommand is a possible follow-up, not v1.

## 4. Architecture

Five units. Three are new pure/testable Core types, one is a new Core actor, one
is a new GUI coordinator. Everything else is reuse.

```
 ┌────────────────────────── GUI (Sources/MacParakeet) ──────────────────────────┐
 │  CommandModeHotkeyMonitor  ──onPressStart/onPressEnd──▶  CommandModeCoordinator │
 │   (event tap, 1 chord,                                    (@MainActor)          │
 │    hold gesture)                                          owns mic + STT + pill │
 └───────────────────────────────────────────────┬────────────────────────────────┘
                                                  │ instruction text + captured sel
                                                  ▼
 ┌────────────────────── Core (Sources/MacParakeetCore) ──────────────────────────┐
 │  CommandModeExecutor (actor)                                                    │
 │    1. (selection captured at key-down, passed in)     ← reuse SelectionCapture  │
 │    2. CommandModeRouter.route(instruction) ─┬─ .deterministic(cmd)              │
 │                                             │     └▶ DeterministicTextEdit/clear │
 │                                             ├─ .rewrite(prompt)                  │
 │                                             │     └▶ LLMService.transformStream  ← reuse │
 │                                             └─ .empty → throw                    │
 │    3. SelectionReplacementService.replace(.pasteIntoCurrentFocus)  ← reuse      │
 └────────────────────────────────────────────────────────────────────────────────┘
```

### 4.1 New Core unit: `CommandModeRouter` (pure)

`Sources/MacParakeetCore/Services/CommandMode/CommandModeRouter.swift`

```swift
public enum CommandModeAction: Sendable, Equatable {
    case deterministic(DeterministicCommand)
    case rewrite(prompt: String)   // built via CommandModePrompts
    case empty                     // nothing intelligible said
}

public struct CommandModeRouter: Sendable {
    public init() {}
    public func route(instruction: String) -> CommandModeAction
}
```

Normalization before matching: lowercase, strip surrounding whitespace, drop
trailing punctuation (`.`, `!`, `?`, `…`), collapse internal whitespace runs.
Empty/whitespace-only input → `.empty`. A normalized instruction that matches a
phrase in the deterministic table (exact normalized equality) → `.deterministic`.
Otherwise → `.rewrite(prompt: CommandModePrompts.rewriteInstruction(original))`.

**Worked example — the "make this a list" case.** The owner-named example
"make this a list" is **not** in the deterministic table, so it falls through to
`.rewrite` and is handled by the provider (it is a rewrite, not an offline edit).
"scratch that" *is* in the table and runs offline. This split is the whole point:
deterministic phrases run offline; richer instructions become provider rewrites.
`CommandModeRouterTests` asserts `route("make this a list") == .rewrite(...)`.

The router is a **pure function over a string** — no I/O, no actor hops. This is
the entire "intent" surface, and it is exhaustively unit-testable.

### 4.2 New Core unit: `DeterministicCommand` + `DeterministicTextEdit` (pure)

`Sources/MacParakeetCore/Services/CommandMode/DeterministicTextEdit.swift`

```swift
public enum DeterministicCommand: Sendable, Equatable, CaseIterable {
    case clearSelection      // "scratch that" family — see deletion note below
    case uppercase
    case lowercase
    case titleCase
    case trim
}

public enum DeterministicTextEdit {
    /// Pure transform of the captured selection for the case/trim commands.
    /// `clearSelection` is NOT handled here (it deletes rather than rewrites —
    /// see §4.4); callers must not route clearSelection through `apply`.
    public static func apply(_ command: DeterministicCommand, to text: String) -> String
}
```

Phrase table (normalized → command), matched as exact normalized equality so we
never accidentally swallow a real rewrite request:

| Command | Trigger phrases (normalized) | Effect on selection |
|---|---|---|
| `clearSelection` | `scratch that`, `delete that`, `remove that`, `undo that` | **delete** the selected text (deletion path, §4.4 — *not* an empty-string paste) |
| `uppercase` | `uppercase that`, `make it uppercase`, `all caps`, `make it all caps` | `.uppercased()` |
| `lowercase` | `lowercase that`, `make it lowercase` | `.lowercased()` |
| `titleCase` | `title case that`, `capitalize that`, `title case` | capitalize each word |
| `trim` | `trim that`, `trim whitespace`, `trim it` | trim ends + collapse internal runs to single spaces |

Notes:
- "scratch that" = **delete the selection**, *not* the host app's native Cmd+Z.
  App-independent and deterministic; the user has explicitly selected the
  regretted text.
- The phrase table is a small closed set. Anything outside it falls through to the
  LLM rewrite path, so the offline list can grow later without changing the
  routing contract.

### 4.3 New Core unit: `CommandModePrompts` (pure)

`Sources/MacParakeetCore/Services/CommandMode/CommandModePrompts.swift`

```swift
public enum CommandModePrompts {
    /// Wrap a spoken instruction into a transform prompt for `transformStream`.
    public static func rewriteInstruction(_ instruction: String) -> String
}
```

Produces a directive of the shape: *"Apply this instruction to the text:
\"{instruction}\". Return only the edited text — no preamble, no explanation, no
quotes. Preserve the original meaning and language unless the instruction says
otherwise."* The selected text is passed as `transformStream(text:prompt:)`'s
`text` argument (the existing transform contract), so the instruction and the
content stay cleanly separated.

### 4.4 New Core unit: `CommandModeExecutor` (actor)

`Sources/MacParakeetCore/Services/CommandMode/CommandModeExecutor.swift`

Mirrors `TransformExecutor`'s structure and safety (run-to-completion on replace,
restore-on-abandon, cooperative cancellation) but takes the **already-transcribed
instruction** and the **already-captured selection** as input (mic + STT and
selection capture happen in the GUI coordinator, see §4.6).

```swift
public struct CommandModeResult: Sendable {
    public let inputText: String
    public let outputText: String          // "" for clearSelection
    public let applied: CommandModeAppliedKind
    public let replacePath: SelectionReplacementPath
    public let totalElapsedMs: Int
    public let llmElapsedMs: Int            // 0 for deterministic
    public let captureTag: String
    public let target: SelectionCaptureTarget?
}

public enum CommandModeAppliedKind: Sendable, Equatable {
    case deterministic(DeterministicCommand)
    case rewrite
}

public enum CommandModeProgress: Sendable, Equatable {
    case routing
    case deterministicApplied(DeterministicCommand)
    case llmStarted
    case llmStreaming(String)
    case pasting
    case done(SelectionReplacementPath, CommandModeAppliedKind)
    case failed(String)
}

public actor CommandModeExecutor {
    public init(
        captureService: SelectionCaptureService = SelectionCaptureService(),
        replacementService: SelectionReplacementService = SelectionReplacementService(),
        llmServiceProvider: @Sendable () -> LLMServiceProtocol?,
        router: CommandModeRouter = CommandModeRouter()
    )

    public func run(
        instruction: String,
        captured: SelectionCaptureResult,
        onProgress: @escaping @Sendable (CommandModeProgress) -> Void
    ) async throws -> CommandModeResult
}
```

Behavior:
1. Validate `captured` has non-empty text (else `.emptySelection`, restoring the
   clipboard first).
2. `route(instruction)`:
   - `.empty` → restore clipboard via `restoreClipboardCaptureIfCurrent`, then
     throw `.emptyInstruction`.
   - `.deterministic(.clearSelection)` → **deletion path** (see below). No LLM.
   - `.deterministic(otherCmd)` → `DeterministicTextEdit.apply(...)`; **no LLM
     call** (works with no provider). Emit `.deterministicApplied`.
   - `.rewrite(prompt)` → require a provider (`llmServiceProvider()` non-nil, else
     restore + `.llmNotConfigured`); stream `transformStream(text:prompt:)` to
     accumulate.
3. Apply:
   - case/trim → `replace(with: edited, mode: .pasteIntoCurrentFocus)`.
   - rewrite → `replace(with: accumulated, mode: .pasteIntoCurrentFocus)`.
   - **clearSelection deletion path** — do **not** paste an empty string (a
     `setString("") + Cmd+V` no-ops in several apps and writes "" onto the user's
     clipboard). Instead: for an `.ax` capture, set
     `kAXSelectedTextAttribute` to `""` directly via the replacement service's AX
     path; for a `.clipboard` capture, post a single **forward-delete/Delete**
     keystroke to remove the still-selected text. The replacement service grows a
     small `deleteSelection(in:)` entry point for this; it never touches the
     pasteboard for clearSelection.
4. Return `CommandModeResult`.

Errors mirror `TransformExecutorError`: `.emptySelection`, `.emptyInstruction`,
`.captureFailed`, `.llmNotConfigured`, `.llmFailed`, `.replacementFailed`,
`.cancelled`. **Restore-on-abandon fires on every failure/cancel path**, using the
same `SelectionCaptureService` instance that produced `captured` (the coordinator
injects one shared instance into the executor — `restoreClipboardCaptureIfCurrent`
is snapshot/changeCount-driven and must see the capture it took).

**Entitlement gating decision.** Command Mode records the mic and transcribes —
the operation `DictationService` gates via `EntitlementsChecking.assertCanTranscribe`.
Command Mode is **ungated**, consistent with Transforms (which also transcribes
nothing but rewrites and is ungated) and with the free/GPL public build being
always-unlocked. We deliberately model on `TransformExecutor` (no entitlement
call), not `DictationService`. The retained licensing plumbing is untouched (per
CLAUDE.md it is intentional, not dead code); we simply don't invoke it here.

**`@Sendable` provider closure.** `init` declares
`llmServiceProvider: @Sendable () -> LLMServiceProtocol?`. The existing shared
binding in `AppDelegate` (the one `TransformsCoordinator` consumes) is currently
un-annotated; the implementer must **re-declare it `@Sendable`** at the AppDelegate
site (both captures — `LLMConfigStore` is `@unchecked Sendable`, `LLMService` is
`Sendable` — so the annotation is sound) rather than reuse the binding as-is, or
it won't compile under Swift 6 strict concurrency when passed to the actor init.

### 4.5 New GUI unit: `CommandModeHotkeyMonitor`

`Sources/MacParakeet/Hotkey/CommandModeHotkeyMonitor.swift`

A small sibling of `TransformsHotkeyRegistry`: one `CGEventTap`, one configurable
`KeyboardShortcut`, but it exposes the **hold gesture** rather than a one-shot:

```swift
public final class CommandModeHotkeyMonitor {
    public var onPressStart: (() -> Void)?   // chord keyDown (debounced)
    public var onPressEnd: (() -> Void)?     // chord keyUp
    public func setShortcut(_ shortcut: KeyboardShortcut?)  // nil = dormant
    @discardableResult public func start() -> Bool
    public func stop()
}
```

Reuses `KeyboardShortcut`, `HotkeyTrigger.relevantModifierBits`, and the
`TransformsHotkeyCollisionChecker` machinery. When the shortcut is `nil`
(unbound), the tap dispatches nothing — the dormant/opt-in state.

### 4.6 New GUI unit: `CommandModeCoordinator` (@MainActor)

`Sources/MacParakeet/App/CommandModeCoordinator.swift` — owned by `AppDelegate`
next to `TransformsCoordinator`.

The coordinator holds a single `activeHold` value identifying the in-flight
gesture: `{ runID: UUID, captured: SelectionCaptureResult, micToken, recording }`.
All teardown is keyed to `activeHold?.runID` so a stale key-up cannot tear down a
newer hold.

**Press-start (chord key-down):**
1. Guard `AppFeatures.commandModeEnabled` and a bound shortcut.
2. **Bidirectional mic/STT lock (§4.7).** Acquire the process-wide single-mic-
   consumer token. If dictation (recording **or** finalizing/`.processing`) or a
   meeting recording holds it, no-op with a brief toast ("Finish dictating
   first"). While a Command Mode hold is active, the dictation and meeting hotkeys
   are suspended so the reverse race can't fire.
3. **Min-hold debounce.** Start the gesture but defer the expensive work behind a
   short startup floor (mirror `HotkeyGestureController` startup-debounce). If
   key-up arrives before the floor elapses (accidental tap), abort: do not capture,
   do not subscribe the mic, do not show the pill.
4. **Capture selection** via the shared `SelectionCaptureService`. `.empty` →
   educational toast, abort (no recording). `.failed` → error toast, abort. On the
   `.clipboard` capture path, **immediately restore the user's clipboard** once the
   selected text is in memory (see §4.8) — do not hold their pasteboard hostage for
   the whole utterance.
5. Start mic capture (a dedicated `AudioProcessor` subscriber on the shared mic
   stream, writing the **same 16 kHz mono WAV** the dictation path produces —
   reuse `DictationService`'s WAV-writing/`AudioProcessor` configuration so the STT
   engines get the format they expect) and show the pill at **"Listening…"**.

**Press-end (chord key-up):**
6. Tear down only if `runID` matches `activeHold`. Stop mic capture → WAV.
7. Pill → **"Transcribing…"**. Transcribe honoring the user's **persisted speech
   engine + language** (ADR-021): call the
   `transcribe(audioPath:job:speechEngine:)` overload with the configured
   `SpeechEnginePreference` (so a Whisper/Korean user's instruction isn't sent to
   Parakeet and garbled). Job kind: `.dictation` (reserved interactive slot); the
   §4.7 lock guarantees no real dictation contends for that slot, including a
   still-finalizing one.
8. Hand `(instruction, captured)` to `CommandModeExecutor.run`. Drive the pill from
   `CommandModeProgress`: deterministic → brief "Done"; rewrite → "Rewriting…"
   → "Done". Errors → failure toast + clipboard restore. Release the §4.7 lock when
   the run reaches a terminal state.

**Edge cases (run-ID keyed):**
- A second **press-start** while a hold is active cancels/replaces the prior hold:
  tear down its mic subscription, restore its clipboard, dismiss its pill, then
  begin the new hold.
- A **press-end with no matching `activeHold`** (lost/duplicated key-up) is a no-op.
- Mic-subscription teardown is keyed to the hold's `runID`, so a stale key-up never
  unsubscribes a newer hold.

Mic ownership: Command Mode gets its **own** `AudioProcessor` over the existing
`SharedMicrophoneStream` (the fan-out pattern dictation and meeting use), but v1's
bidirectional lock guarantees only one consumer is ever live. This keeps the change
additive and leaves the fan-out path ready for a later concurrency upgrade without
re-plumbing.

### 4.7 Bidirectional, session-length mic/STT lock

The dictation hotkey runs on its **own** `CGEventTap` that Command Mode does not
suppress, so a point-in-time key-down check is a TOCTOU race (start Command Mode,
then trigger real dictation mid-utterance → two mic consumers + two jobs on the
single reserved interactive STT slot). v1 closes this:

- A **process-wide single-mic-consumer token** is acquired for the *entire*
  Command Mode hold and released only at the run's terminal state.
- Acquisition fails if dictation is recording **or** finalizing (`.processing`),
  or a meeting recording is active.
- While the token is held by Command Mode, the dictation and meeting **hotkeys are
  suspended** (the reciprocal guard), and the dictation start path checks the same
  token. The exclusion is therefore held and bidirectional, not a momentary check.

### 4.8 Clipboard hygiene over the long hold

ADR-022's clipboard-hijack window is ~LLM duration; a hold-to-talk gesture extends
it to the whole utterance + STT + rewrite (10–30s), during which any user Cmd+V or
clipboard-manager read would see our hijack payload. Mitigation: on the
`.clipboard` capture path the selected text is already in memory after capture, so
the coordinator **restores the user's pasteboard snapshot immediately** (§4.6
step 4). The replacement service re-snapshots and writes its payload only at paste
time (its existing `pasteAndRestore` guard). Net effect: the user's real clipboard
is dirty for milliseconds at capture and milliseconds at paste, never for the whole
utterance. (AX captures never touch the clipboard at all.)

### 4.9 Held-chord contamination of synthetic Cmd+C / Cmd+V

Unlike Transforms (one-shot keyDown — the chord is already physically released by
the time capture runs), Command Mode **holds the chord down** during capture and at
release during paste. macOS OR-merges the held physical modifiers into synthetic
events, so a synthetic Cmd+C posted while e.g. ⌥Space is held becomes ⌘⌥C (wrong
shortcut / no-op). Invariants the implementation must hold (added to the manual
matrix in §9):

- The capture's synthetic **Cmd+C** must post with an explicitly reset modifier
  state — set the `CGEventSource`/event flags to **exactly `.maskCommand`** (clear
  the held chord modifiers) before posting, or defer the Cmd+C until the chord's own
  modifiers are observed cleared. Preferred mitigation: explicit modifier-clear via
  the event flags, not constraining which chords the user may bind.
- The replace's synthetic **Cmd+V** runs **strictly after the chord key-up**
  (press-end), and applies the same modifier-clear. The flow already paste-on-key-up;
  this makes it a stated invariant.

### 4.10 Progress pill reuse

Reuse `TransformSpikeProgressPanelController` / `TransformSpikeProgressViewModel`
with Command-Mode copy. The three visual phases (`working` / `done` / `failed`)
cover what we need; the coordinator supplies the beat label ("Listening…",
"Transcribing…", "Rewriting…"). No net-new pill UI in v1. (A distinct loader is a
documented non-decision.)

## 5. Error & empty UX

Mirrors ADR-022 §"No-selection and error UX". Clipboard is always restored when a
hijack snapshot was taken (and, per §4.8, restored early on the capture path).

| Situation | UX |
|---|---|
| Hotkey held with no selection | Friendly toast: *"Select text first — highlight what you want to change, then hold {hotkey} and speak."* No recording starts. |
| Empty / unintelligible speech | Toast: *"Didn't catch that — try again."* Clipboard restored. Nothing pasted. |
| Rewrite needed but no LLM provider configured | Toast: *"Command Mode rewrites need an LLM provider."* + `[Configure]` → Settings → AI. **Deterministic commands still work** with no provider. |
| LLM error (network, rate limit, timeout) | Toast: *"Command Mode failed — clipboard restored."* |
| Replace/deletion failure (both AX + fallback fail) | Toast with the error; clipboard restored. |
| Dictation/meeting mic already active | Toast: *"Finish dictating first."* No-op. |
| Accidental tap (below min-hold floor) | Silent no-op; no pill, no mic, no capture. |

## 6. Opt-in, flags, privacy

- **`AppFeatures.commandModeEnabled: Bool`** — release gate, mirroring
  `transformsEnabled`. When `false`: no hotkey monitor installed, no Settings row.
  **Channel defaults:** `false` on the Stable DMG, `true` on `main` (same
  release-boundary convention as `transformsEnabled`, honoring CLAUDE.md's Stable-vs-`main`
  rule). The *binding* is the user-facing opt-in, not this flag.
- **Dormant until bound.** Ships with no default Command Mode hotkey. The monitor
  exists but dispatches nothing until the user binds a key in Settings (ADR-022 §5).
- **Provider-pluggable / cloud opt-in unchanged.** Rewrites use whatever provider
  the user already configured (ADR-011). A local provider (Ollama / LM Studio /
  Local CLI) keeps Command Mode fully on-device. Deterministic commands never call
  any provider.
- **No content in telemetry** (§7).

## 7. Telemetry (opt-out, content-free)

Two events defined in `TelemetryEvent`, mirroring ADR-022 §8, with explicit
per-event allowed-field rows (the Worker validates fields, not just event names):

- `command_mode_executed` — allowed fields:
  `[path, deterministic_command, llm_ms, total_ms, app_category]` where `path` ∈
  {`deterministic`, `rewrite`} and `deterministic_command` is the enum name or
  `none`. **No** instruction text, selected text, or output. `app_category` reuses
  the **same frontmost-bundle → category resolver** the Transforms
  `transform_executed` event uses (do not re-derive categorization).
- `command_mode_failed` — allowed fields: `[reason]`, enumerated:
  `empty_selection | empty_instruction | capture_failed | no_provider | llm_failed | replacement_failed | cancelled`.

**Allowlist dependency (two-repo).** Both event names **and** their field rows must
be added to `ALLOWED_EVENTS` / `ALLOWED_FIELDS` in
`macparakeet-website/functions/api/telemetry.ts` *before* they fire in production,
or the Worker drops the whole batch (the authoritative source is that file plus
ADR-022 §8 — not a `memory/` note). Until that deploy lands, the events are defined
but the rollout keeps them unsent — the staged approach ADR-022 used.

## 8. Traceability & versioning

The feature ships as the **first v0.7 scope item** (`commandModeEnabled = true` on
`main`; v0.6 already shipped Transforms). New requirement area `CMD — Voice
Command Mode` in `spec/kernel/requirements.yaml`, each row tagged `version: v0.7`
(matching how `REQ-XFORM` rows carry a version):

- **REQ-CMD-001** (`version: v0.7`) — Voice Command Mode: hold a dedicated hotkey,
  speak an instruction, and the selected text is rewritten in place through the
  configured LLM provider (AX-first capture, clipboard fallback, paste-back
  replacement), honoring the user's persisted STT engine/language.
- **REQ-CMD-002** (`version: v0.7`) — Deterministic offline self-correction:
  "scratch that" family (delete selection) and case/trim text ops execute with no
  LLM, working even when no provider is configured.

`spec/kernel/traceability.md` gets a **`v0.7 Command Mode`** section mapping these
to the new source files and tests. `spec/README.md` names Command Mode as the first
v0.7 scope item; `spec/02-features.md` adds the **F-CMD** block and annotates the
retired F10/F10a blocks *"superseded by ADR-023"*.

## 9. Testing strategy (TDD)

Pure units first (write tests, watch them fail, implement):

- **`CommandModeRouterTests`** — normalization (case, punctuation, whitespace);
  each deterministic phrase → its command; near-misses ("scratch the paragraph")
  fall through to `.rewrite`; **`route("make this a list") == .rewrite`**;
  empty/whitespace → `.empty`.
- **`DeterministicTextEditTests`** — upper/lower/title/trim on representative
  inputs incl. unicode, multi-line, already-cased. (`clearSelection` is a deletion,
  tested at the executor level.)
- **`CommandModePromptsTests`** — the instruction is embedded; output asks for
  "only the edited text".
- **`CommandModeExecutorTests`** (mock `LLMServiceProtocol`, stub capture/replace
  backends):
  - deterministic case/trim path replaces with the edited text and **never** calls
    the LLM (assert mock call count == 0);
  - `clearSelection` **deletes** and **never pastes an empty string nor leaves ""
    on the clipboard** (assert no `setString("")`; AX path sets selected text empty,
    clipboard path posts Delete);
  - rewrite path calls `transformStream` once and replaces with the accumulation;
  - empty selection → `.emptySelection`;
  - empty instruction → `.emptyInstruction`, **and clipboard restore fires on a
    `.clipboard` capture** (explicit case, not just "on each failure path");
  - `.rewrite` with nil provider → `.llmNotConfigured` (+ restore);
  - restore-on-abandon fires on each failure path.
- **Hotkey collision (both directions)** — concrete plumbing, not vague:
  1. The Command Mode bind-time validator collision-checks against **both** the
     reserved app hotkeys **and** the current `.transform` prompt bindings loaded
     from `PromptRepository` (the same `existing: [UUID: KeyboardShortcut]` map
     `TransformsCoordinator` caches — Transform bindings live in the prompt repo,
     not the reserved list).
  2. `AppDelegate.transformReservedHotkeysForTransforms()` appends a
     `TransformShortcutReservedHotkey(name: "Command Mode", trigger: <bound>)` so a
     Transform/dictation/meeting bind is rejected against the Command Mode key.
  3. The reserved entry strings use the real names (`"meeting recording"`, etc.
     from `AppDelegate`), not invented labels.

GUI coordinator wiring is validated manually (per the project's "skip SwiftUI view
tests" rule) plus the F10a de-risk manual matrix (TextEdit, Notes, Slack, Safari
textarea, VS Code, Cursor, Terminal), with an added row per matrix app verifying
**no Cmd+C/Cmd+V modifier contamination while the chord is held** (§4.9).

## 10. File map

New:
- `Sources/MacParakeetCore/Services/CommandMode/CommandModeRouter.swift`
- `Sources/MacParakeetCore/Services/CommandMode/DeterministicTextEdit.swift`
- `Sources/MacParakeetCore/Services/CommandMode/CommandModePrompts.swift`
- `Sources/MacParakeetCore/Services/CommandMode/CommandModeExecutor.swift`
  (defines `CommandModeExecutor`, `CommandModeResult`, `CommandModeAppliedKind`,
  `CommandModeProgress`, `CommandModeExecutorError`)
- `Sources/MacParakeetCore/Services/CommandMode/README.md` (subsystem rules:
  threading, restore-on-abandon, early-clipboard-restore, deletion-not-empty-paste,
  bidirectional mic lock, executor-stays-in-Core invariant)
- `Sources/MacParakeet/Hotkey/CommandModeHotkeyMonitor.swift`
- `Sources/MacParakeet/App/CommandModeCoordinator.swift`
- Settings: a Command Mode hotkey recorder row (reuse `HotkeyRecorderView`).
- Tests: `CommandModeRouterTests`, `DeterministicTextEditTests`,
  `CommandModePromptsTests`, `CommandModeExecutorTests`,
  `CommandModeHotkeyMonitorTests` (collision).

Modified (additive):
- `Sources/MacParakeetCore/AppFeatures.swift` — add `commandModeEnabled` (false on
  Stable, true on `main`).
- `Sources/MacParakeetCore/Services/System/SelectionReplacementService.swift` — add
  a `deleteSelection(in:)` entry point for clearSelection (AX-empty / Delete key).
- `Sources/MacParakeetCore/Services/Telemetry/TelemetryEvent.swift` — add the two
  events + their enums + allowed-field rows.
- `Sources/MacParakeet/AppDelegate.swift` — construct/own/start the coordinator
  next to `TransformsCoordinator`; **re-declare the shared `llmServiceProvider` as
  `@Sendable`**; suspend/resume dictation+meeting hotkeys around an active Command
  Mode hold.
- **Reserved-hotkey lists (two sites):** the `TransformShortcutReservedHotkey`
  array is built in **both** `AppDelegate.swift` (~line 590) and
  `Views/MainWindowView.swift` (~line 270). **Both** must append a
  `TransformShortcutReservedHotkey(name: "Command Mode", trigger: <bound>)` entry so
  the reverse-direction collision check (Transform/dictation/meeting binds rejected
  against the Command Mode key) holds everywhere the editor reads reserved hotkeys.
- Dictation start path — check the shared single-mic-consumer token (§4.7).
- Settings view/view-model — the recorder row + persistence (a `KeyboardShortcut?`
  in app preferences) + collision check against reserved hotkeys **and** the
  `.transform` prompt bindings.
- `spec/kernel/requirements.yaml`, `spec/kernel/traceability.md`,
  `spec/README.md`, `spec/02-features.md` (F-CMD + F10/F10a supersession annotation),
  `CLAUDE.md` "Custom features" list.

## 11. Risks & mitigations

| Risk | Mitigation |
|---|---|
| Held chord contaminates synthetic Cmd+C/Cmd+V (wrong shortcut / no-op). | §4.9: reset event flags to exactly `.maskCommand` before posting; paste strictly after key-up; manual-matrix row per app. |
| Long hold leaves the user's real clipboard dirty for the whole utterance. | §4.8: restore the user's pasteboard immediately after capturing the text into memory; re-write payload only at paste time. |
| "scratch that" empty-string paste no-ops / dirties clipboard. | §4.4 deletion path: AX-set-empty or a Delete keystroke; never an empty-string paste. Executor test enforces it. |
| Mic/STT-slot contention with dictation/meeting (incl. a still-finalizing dictation). | §4.7 bidirectional, session-length lock; acquisition blocked while dictation is recording **or** finalizing; reciprocal hotkey suspension. |
| Wrong STT engine for non-English users. | §4.6 step 7: honor the persisted `SpeechEnginePreference` via `transcribe(...speechEngine:)`. |
| Selection goes stale if focus changes while speaking. | Capture at key-down; `.pasteIntoCurrentFocus` targets the frontmost field at paste time (identical to Transforms' shipped behavior — documented, not newly introduced). |
| Accidental tap churns the mic engine. | §4.6 step 3 min-hold debounce: abort below the startup floor before any mic/capture/pill. |
| Hotkey collision with dictation/meeting/Transforms. | §9 two-direction checks: reserved list **and** the `.transform` prompt-binding map; reciprocal reserved entry. |
| New telemetry events dropped by the Worker. | §7: allowlist event names + field rows before enabling (staged). |
| Cloud cost/privacy on rewrites. | Rewrites use the user's own provider; deterministic baseline is offline; cloud stays explicit opt-in (unchanged). |
| Swift 6 strict-concurrency build break on the provider closure. | §4.4: re-declare `llmServiceProvider` as `@Sendable` at the AppDelegate site. |

## 12. Resolved open questions

- *Hold-to-talk vs toggle?* Hold-to-talk (press-and-hold, release to run).
- *Where does self-correction live?* Unified inside Command Mode (one router).
- *Does "scratch that" use native undo?* No — deletes the selection deterministically.
- *Default binding?* Unbound (opt-in).
- *Concurrency with dictation?* Mutually exclusive in v1, via a bidirectional lock.
- *Which STT engine?* The user's persisted dictation engine/language.
- *Entitlement-gated?* No — ungated like Transforms (public build is unlocked).
