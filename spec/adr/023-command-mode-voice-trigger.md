# ADR-023: Command Mode — Voice Trigger for Transforms + Deterministic Self-Correction

> Status: **Accepted** (implementation pending)
> Date: 2026-06-27
> Related: ADR-022 (Transforms — system-wide rewrites; this resolves its
> "Voice-driven trigger" non-decision), ADR-011 (LLM via cloud + optional local
> providers), ADR-016 (centralized STT runtime + scheduler), ADR-015 (concurrent
> dictation + meeting), ADR-009 (custom hotkeys), ADR-012 (telemetry).
> Design: `docs/superpowers/specs/2026-06-27-command-mode-voice-trigger-design.md`.
> Productizes the exploration in `plans/active/2026-05-voice-command-agent-mode.md`.

## Context

ADR-022 shipped Transforms — system-wide LLM rewrites on selected text, triggered
by a bound hotkey. It explicitly left the **voice-driven trigger** as a
non-decision ("Owned by `2026-05-voice-command-agent-mode.md`. The architecture
here is general enough to be reused if/when that ships, but this ADR makes no
commitment."). The Transforms design doc frames the hotkey path as "the
hotkey-driven half of Command Mode," with the voice variant as a swap on the
trigger layer once the primitive is solid.

The primitive is solid and shipping. Competitors (Wispr "Command Mode", Aqua) have
productized spoken-instruction rewrites. The remaining gap for MacParakeet is just
the voice trigger plus a self-correction layer. This ADR locks that decision.

**Relationship to the removed F10/F10a "Command Mode".** `spec/02-features.md`
carries an older **F10 / F10a "Command Mode"** epic marked **REMOVED** — the
original "select text, speak a natural-language command, edit in place via a
bundled local LLM (Qwen3-8B)" concept, dropped when the bundled-local-LLM path was
abandoned. This ADR **revives that concept on a different foundation**: the
ADR-011 BYO/pluggable provider (local or cloud) instead of a bundled model, plus a
deterministic-first offline router. The retired F10/F10a blocks are annotated
*"superseded by ADR-023"* rather than overwritten, and the feature takes a new
identifier (**F-CMD**, v0.7) so it does not collide with the retired F10 numbering.

## Decision

### 1. Command Mode is a voice trigger over the existing rewrite primitive

Selecting text, **holding a dedicated hotkey**, **speaking an instruction**, and
releasing rewrites the selection in place — reusing the ADR-022 pipeline
(`SelectionCaptureService` → LLM → `SelectionReplacementService`) with the spoken,
transcribed instruction as the prompt instead of a pre-bound `Prompt` row. The
existing `TransformExecutor` is **not** modified; a parallel `CommandModeExecutor`
reuses the same low-level services. Rationale: keep the shipped, exercised
single-prompt path untouched; isolate new behavior in small, testable units.

Command Mode is **ungated** (no `assertCanTranscribe` entitlement check), modeled
on `TransformExecutor` rather than `DictationService`, because the public build is
free/GPL and always-unlocked; the retained licensing plumbing is untouched, simply
not invoked here. The spoken instruction is transcribed **honoring the user's
persisted speech-engine/language preference** (ADR-021) via the
`transcribe(audioPath:job:speechEngine:)` scheduler overload, so a Whisper /
non-English user's instruction is not silently routed to Parakeet and garbled.

### 2. Hold-to-talk on a dedicated, explicit hotkey — no always-listening classification

Dictation vs. command is disambiguated by an **explicit hotkey**, not by
classifying spoken intent in the background. The Command Mode hotkey is separate
from the dictation hotkey and from the per-Transform ⌥-digit keys. A new
`CommandModeHotkeyMonitor` (one `CGEventTap`, one configurable `KeyboardShortcut`)
exposes press-start/press-end so the gesture is hold-to-talk: capture the
selection and start recording on key-down; transcribe and apply on key-up.

Because the chord is **physically held** during the gesture (unlike Transforms'
one-shot keyDown), the synthetic Cmd+C used for clipboard-fallback capture and the
Cmd+V used for paste-back must post with an explicitly reset modifier state
(exactly `.maskCommand`) — otherwise macOS OR-merges the held modifiers into the
injected keystroke (e.g. ⌥Space-held → ⌘⌥C) and capture/paste mis-fire. Paste runs
strictly after key-up. This modifier-clear invariant is part of the locked design.

Explicitly rejected for v1: always-listening intent classification, and
intercepting the live dictation stream to detect commands. Both blur the
dictation/command boundary this app keeps hard.

### 3. Unified deterministic-first router (self-correction without an LLM)

The transcribed instruction passes through one pure `CommandModeRouter`:

- A small **closed set of normalized phrases** maps to **deterministic, offline
  edits** — the "scratch that" family (delete selection) plus case (upper / lower /
  title) and trim. These run with **no LLM call at all** and work even when no
  provider is configured. This is the privacy-friendly baseline.
- Anything else becomes a **rewrite** through the user's configured LLM provider.

Self-correction lives inside Command Mode, not as a separate surface — but the two
named examples are handled differently: **deterministic phrases ("scratch that")
run offline**, while **richer instructions ("make this a list") are not in the
table and fall through to a provider rewrite**. "Scratch that" **deletes** the
selected text — app-independent and deterministic, *not* the host's Cmd+Z, and
*not* an empty-string paste (a `setString("") + Cmd+V` no-ops in some apps and
dirties the clipboard). The deletion path sets `kAXSelectedTextAttribute` to empty
for AX captures, or posts a single Delete keystroke for clipboard-fallback
captures.

### 4. Opt-in: dormant until a hotkey is bound

Consistent with ADR-022 §5 ("no global toggle"), Command Mode is "on" iff the user
binds a hotkey to it in Settings. It ships **unbound** by default. A release gate
`AppFeatures.commandModeEnabled` controls whether the surface exists at all
(mirrors `transformsEnabled`); it defaults to `false` on the Stable DMG and `true`
on `main` (the same release-boundary convention `transformsEnabled` uses), but the
*binding* is the user-facing opt-in.

### 5. BYO-provider, cloud opt-in unchanged

Rewrites use whatever LLM provider the user already configured (ADR-011). A local
provider keeps Command Mode fully on-device; cloud providers remain explicit
opt-in. No first-party LLM. Deterministic commands never contact any provider.

### 6. Concurrency: bidirectional, session-length mic/STT lock in v1

Command Mode acquires the microphone through its own `AudioProcessor` subscriber on
the shared mic stream, guarded by a **process-wide single-mic-consumer token held
for the entire Command Mode hold**. The dictation hotkey runs on its own event tap,
so a point-in-time key-down check would be a TOCTOU race; instead the exclusion is
**held and bidirectional**: acquisition is refused while dictation is recording
**or finalizing** (`.processing`) or a meeting is recording, and while Command Mode
holds the token the dictation and meeting hotkeys are suspended and the dictation
start path checks the same token. Routing Command Mode STT through the reserved
interactive slot is therefore safe (no real dictation — including a still-finalizing
one — can contend for it). Simultaneous mic fan-out is deferred.

### 7. Telemetry: opt-out, content-free, allowlisted before firing

Two events mirror ADR-022 §8: `command_mode_executed` (allowed fields `path`
∈ {deterministic, rewrite}, `deterministic_command`, `llm_ms`, `total_ms`,
`app_category` — the last reusing the Transforms frontmost-bundle→category
resolver) and `command_mode_failed` (`reason`, enumerated). No instruction text, no
selected text, no output. Both the event names **and their field rows** must be
added to `ALLOWED_EVENTS` / `ALLOWED_FIELDS` in
`macparakeet-website/functions/api/telemetry.ts` before they fire in production, or
the Worker drops the whole batch (the authoritative source is that file plus
ADR-022 §8). Staged: defined now, unsent until the website deploy lands.

## Consequences

### Positive

- Ships on top of fully exercised infrastructure (AX capture, paste-back, LLM
  transform stream, mic capture, STT scheduler, progress pill). Net-new code is a
  hold-to-talk monitor, a thin coordinator, a pure router, and a Core executor.
- The "intent" surface is a **pure function over a string** — exhaustively
  testable, no model in the loop for routing.
- A privacy-preserving baseline: the most common self-corrections work offline
  with no provider configured.
- Resolves ADR-022's open "voice-driven trigger" non-decision without disturbing
  the shipped Transforms path.

### Negative / accepted trade-offs

- Mild duplication between `CommandModeExecutor` and `TransformExecutor` (both do
  capture → optional-LLM → replace). Accepted to avoid mutating the shipped
  executor.
- The deterministic phrase set is closed and English-only in v1. Unmatched phrases
  fall through to the LLM, so coverage grows without contract changes; localization
  is future work.
- v1 mutual exclusion with dictation/meeting means no "dictate then immediately
  command" without releasing the mic. Acceptable; fan-out is a later upgrade.
- Selection can go stale if the user clicks into a different field while speaking;
  `.pasteIntoCurrentFocus` targets the frontmost field at paste time, identical to
  Transforms' shipped behavior. Documented, not newly introduced.
- The hold-to-talk gesture introduces two behavioral concerns the one-shot
  Transforms model never had, both **mitigated, not merely accepted**: held-chord
  contamination of synthetic Cmd+C/Cmd+V (mitigated by the §2 modifier-clear
  invariant) and a longer clipboard-hijack window (mitigated by restoring the
  user's clipboard immediately after the selection text is read into memory, so the
  real clipboard is dirty only for milliseconds at capture and at paste, never for
  the whole utterance). Details in the design doc §4.8–§4.9.

### Non-decisions (still open)

- **Agent/tool actions** (press-return-after-dictation, "turn this into todos",
  app automation). Stays in `plans/active/2026-05-voice-command-agent-mode.md`.
- **Simultaneous mic fan-out** with dictation/meeting.
- **A CLI surface for the voice trigger** (the pure router/edits/prompt builder are
  unit-tested; a `command-mode` subcommand is a possible follow-up).
- **A distinct Command Mode loader animation** (v1 reuses the Transforms pill).
- **Localized / expanded deterministic command sets.**

## Alternatives considered

### Alternative A — Generalize `TransformExecutor` to take a "command source"

Fold the voice trigger and deterministic ops into the existing executor (static
prompt | spoken instruction | deterministic edit). Rejected: mutates a shipped,
exercised class ADR-022 graduated with minimal change; the extra branches widen
its responsibility and the blast radius of any regression.

### Alternative B — Bolt Command Mode onto `DictationService`

Reuse the dictation state machine and branch to command handling. Rejected:
couples Command Mode to dictation's history-saving, paste-targeting, and
cancel-window state — exactly the entanglement the "keep dictation vs. command
explicit" requirement warns against.

### Alternative C — Always-listening intent classification

Decide dictation-vs-command from the audio/transcript instead of a hotkey.
Rejected for v1: unpredictable, privacy-heavy, and undermines the explicit mode
boundary. The hotkey is the disambiguator.

### Alternative D — Mid-dictation stream interception for "scratch that"

Scan the live dictation transcript tail for command words and act on them inline.
Rejected for v1: softens the explicit dictation/command boundary and risks acting
on text the user meant literally. Self-correction is a Command Mode instruction on
a selection instead.

## Implementation pointer

Design: `docs/superpowers/specs/2026-06-27-command-mode-voice-trigger-design.md`.
Plan: `plans/active/2026-06-command-mode-voice-trigger.md` (to be written).
Requirements: REQ-CMD-001 (voice trigger), REQ-CMD-002 (deterministic
self-correction) in `spec/kernel/requirements.yaml`.
