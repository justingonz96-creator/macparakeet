# Speaker Correction Submission

> Status: ACTIVE - acceptance boundary for speaker correction editors.

## Purpose

Let an editor retain pending input when the view model cannot accept a speaker
change yet. Submission acceptance is separate from asynchronous persistence.

## Producers And Consumers

`MacParakeetViewModels.TranscriptionViewModel` exposes
`applySpeakerCorrection(_:) -> Bool` and `renameSpeaker(id:to:) -> Bool` on the
main actor. `TranscriptResultView` uses the result when committing a rename or
transferring its draft to another editing context. Other callers may discard
the return value.

## Stable Semantics

- `false` means a correction was refused because attribution is loading or a
  previous correction is saving. The caller retains the draft and may retry
  after that state clears. Refusal must not replace the automatic attribution.
- `true` means the call was accepted or required no action. It does not mean a
  database write succeeded. A missing correction target/service, a blank name,
  or an unchanged or missing legacy speaker can be a no-op.
- Accepted commands through `applySpeakerCorrection` set
  `isApplyingSpeakerCorrection` before returning and complete asynchronously.
  Legacy renames update the in-memory speaker optimistically and persist
  separately. Existing identity, revision, and generation checks keep stale
  completions from replacing newer state.
- Asynchronous failures use the existing error and rollback paths. Callers do
  not treat acceptance as a durable-save receipt.
- On submission or handoff, an editor transfers or clears an active draft
  only after acceptance. A refused handoff preserves its text and editing
  context; later events from an old context must not finish or cancel the
  current draft. Explicit cancellation, such as Escape, discards the draft.

## Non-stable Details

Error wording, focus scheduling, rendering context identifiers, and persistence
timing are implementation details. Tests protect ownership and refusal, not a
fixed completion delay.

## Versioning And Compatibility

Ordinary statement-style callers remain compatible because these methods are
`@discardableResult`. Callers storing a method reference with a `Void` return
type must adapt to the Boolean signature. This Swift API change does not change
the CLI JSON schema or stored correction format.

## Tests That Enforce This

- `TranscriptionSpeakerCorrectionViewModelTests` covers loading/busy refusal,
  accepted retry, stale completion and failure behavior.
- `SpeakerRenameStateTests` covers draft ownership, refused handoff and stale
  editing contexts.

## When This Changes

Update this contract and the focused view-model/editor tests when submission
acceptance, refusal, or draft ownership changes. Review consumers of both public
methods when changing their signatures or return semantics.
