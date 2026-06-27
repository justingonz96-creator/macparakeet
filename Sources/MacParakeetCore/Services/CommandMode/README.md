# CommandMode

> Hold a dedicated hotkey, speak an instruction, release — selected text is
> rewritten in place. Deterministic self-correction (delete, case, trim) works
> offline with no provider configured; all other instructions route to the
> user's LLM provider.

## Entry point

`CommandModeCoordinator` (`@MainActor`) — the only object that drives the
end-to-end flow. It wires `CommandModeHotkeyMonitor` → `MicrophoneArbiter` →
`AudioRecorder` → `STTScheduler` → `CommandModeRouter` → `CommandModeExecutor`,
and handles UI state (progress pill visibility) and clipboard restore on every
exit path. App code does not interact with the executor or router directly.

## What's here

- `CommandModeRouter.swift` — pure `CommandModeRouter` enum. Classifies a
  transcribed instruction into `.deterministic(DeterministicCommand)` or
  `.rewrite(systemPrompt:userPrompt:)`. The deterministic branch is a closed
  phrase table (lowercase-normalized match); everything outside it is a rewrite.
  No I/O, no LLM, exhaustively testable.
- `DeterministicTextEdit.swift` — executes the offline commands:
  - `deleteSelection` — see **Deletion-not-empty-paste** below.
  - `applyCase(_:to:)` — uppercases, lowercases, or title-cases the selection.
  - `applyTrim(to:)` — strips leading/trailing whitespace.
- `CommandModeExecutor.swift` — `actor`. Owns the full per-invocation
  lifecycle: capture → optional LLM stream → replacement. Receives an
  `onProgress` closure (`@Sendable`) for pill updates; the coordinator bridges
  back to `@MainActor`. Returns a `CommandModeResult` or throws; **always**
  restores the clipboard on any non-success exit (see **Clipboard invariants**
  below).
- `CommandModePrompts.swift` — builds the LLM system/user prompt pair for
  rewrite commands.
- `MicrophoneArbiter.swift` — process-wide single-mic-consumer token. Command
  Mode is the only owner; dictation/meeting only read the token (see **Mic
  mutual exclusion** below).

## Cross-references

- ADR-023 — locked design; this folder is the implementation.
- ADR-022 — Transforms; Command Mode reuses `SelectionCaptureService`,
  `SelectionReplacementService`, and the floating progress pill but runs through
  its own executor so the shipped Transforms path is not disturbed.
- ADR-016 — centralized STT scheduler; Command Mode transcribes the spoken
  instruction through the reserved interactive slot via
  `sttScheduler.transcribe(audioPath:job:speechEngine:)`.
- ADR-015 — concurrent dictation + meeting; the `MicrophoneArbiter` enforces
  the mutual exclusion contract in both directions (Command Mode ↔ dictation,
  Command Mode ↔ meeting).
- ADR-011 — BYO LLM provider; rewrite commands use whatever the user configured.
- `docs/superpowers/specs/2026-06-27-command-mode-voice-trigger-design.md` —
  detailed design, flow diagrams, and the §4.8–§4.9 clipboard and modifier
  invariants.

## What to know before editing

### Threading

`CommandModeExecutor` is an **`actor`** — all internal state is
actor-isolated. The `onProgress` closure it receives from the coordinator is
`@Sendable` and called from within actor context; the coordinator's closure
implementation hops back to `@MainActor` (`Task { @MainActor in … }`) to drive
UI updates. Never call actor-isolated executor methods directly from `@MainActor`
synchronous code — always `await`.

`CommandModeCoordinator` is `@MainActor`. It is the only object that drives
the full flow and the only object that updates pill visibility state. The hotkey
monitor delivers events on a background CGEventTap thread; the coordinator
marshals those events onto `@MainActor` before starting or stopping the flow.

### Clipboard invariants

**The executor must restore the clipboard on every non-success path.** This
includes LLM failure, STT failure, selection-capture failure, user cancellation,
and thrown errors in any intermediate step. The coordinator's cleanup path also
calls restore so there is no gap between the executor throwing and the
coordinator receiving the error.

**Early restore after clipboard-fallback capture.** When AX selection capture
fails and the coordinator falls back to `Cmd+C`, the user's real clipboard is
replaced with the selected text for the duration of the hold. To minimize how
long the clipboard is hijacked, the coordinator restores the user's original
clipboard immediately after the selection text is in memory — before the user
has finished speaking their instruction. The clipboard is dirty again only
during the brief paste-back at key-up. This early restore is the §4.8 invariant
from the design doc. Do not remove it or defer it to after the LLM call; that
would hold the user's clipboard hostage for the entire utterance.

### Deletion-not-empty-paste

"Scratch that" and its recognized variants **delete** the selected text. They
do not paste an empty string. An empty-string paste (`Cmd+V ""`) is a no-op in
some apps and leaves a dirty clipboard artifact; it is also not the correct
semantic in apps with rich undo stacks.

The deletion implementation uses one of two paths depending on how the
selection was captured:
- **AX capture** (`SelectionCaptureService.getSelectedText` succeeded via AX):
  set `kAXSelectedTextAttribute` to `""` via `SelectionReplacementService.deleteSelection`.
- **Clipboard-fallback capture**: post a single Delete keystroke via
  `SelectionReplacementService.deleteSelection`.

The `deleteSelection` entry point in `SelectionReplacementService` encapsulates
both branches. Call it; do not re-implement the choice at call sites.

### Held-chord safety

The Command Mode hotkey is **physically held** during the entire gesture (hold
key-down → speak → release). The synthetic `Cmd+C` used for clipboard-fallback
capture and the `Cmd+V` used for paste-back both post with an explicitly reset
modifier state (`CGEventSource(stateID: .privateState)`). Without this reset,
macOS OR-merges the physically held modifiers into the injected keystroke — for
example, if the hotkey is `Option+Space`, the synthetic `Cmd+C` becomes
`Cmd+Option+C` and captures nothing. The `.privateState` source isolates the
injected event from the physical keyboard state. This invariant applies to
every synthetic key event posted while the Command Mode hotkey chord is held.
Never remove the `privateState` source from these posts.

### Mic mutual exclusion

Command Mode is the **only** feature that acquires the `MicrophoneArbiter`
token. The exclusion is bidirectional and non-symmetric:

- **Forward direction (Command Mode → dictation/meeting):** The coordinator
  checks `dictationCoordinator.isRecording` and `meetingRecordingService.isActive`
  before acquiring the token; if either is live, Command Mode is refused.
- **Reverse direction (dictation/meeting → Command Mode):** The dictation start
  path and meeting recording start path each call `arbiter.currentOwner` and
  abort if it is `.commandMode`.

`MicrophoneArbiter` itself does not acquire on behalf of dictation or meeting
recording — those features use the shared `SharedMicrophoneStream` directly.
Do **not** make dictation or meeting acquire the arbiter token. ADR-015 requires
that dictation and meeting recording can run concurrently; having both acquire
the same exclusive token would break that. The arbiter guards Command Mode
against the other two, not the other two against each other.

### Deterministic-first / privacy

The `CommandModeRouter` classifies the transcribed instruction offline, in
memory, with no network or LLM call. Deterministic commands (delete selection,
case transforms, trim) are applied immediately with no provider required. A user
with no LLM provider configured can still use self-correction.

Rewrite commands (everything not matched by the phrase table) require a
configured provider. If no provider is configured, the executor fails with a
`noProvider` error and the coordinator surfaces a clear inline message.

The router is a pure function — its classification logic has no side effects,
no I/O, and no external dependencies. Keep it that way.

## How to verify a change

- `swift test --filter CommandMode` — router classification, deterministic edits,
  executor lifecycle, arbiter token semantics, hotkey monitor state machine,
  and Settings ViewModel Command Mode settings; covers all files in this folder.
- `swift test --filter SelectionDeletion` — AX-set and Delete-keystroke deletion
  paths for the "scratch that" family.
- `swift test` — full suite; Command Mode changes ripple into Settings and
  telemetry tests.
- Manual smoke (requires Accessibility permission):
  1. Bind a Command Mode hotkey in Settings.
  2. Select text in Notes, hold the hotkey, say "scratch that", release.
     Expect: text deleted, clipboard unchanged after release.
  3. Select text in Notes, hold the hotkey, say "make this uppercase", release.
     Expect: text replaced with all-caps, clipboard unchanged.
  4. Select text in Notes, hold the hotkey, say "make this a numbered list",
     release. Expect: LLM rewrite applied, clipboard unchanged.
  5. Hold the hotkey without selecting text. Expect: no-op or clear error toast.
  6. Start a dictation, then try to hold the Command Mode hotkey.
     Expect: Command Mode is refused while dictation is live.
