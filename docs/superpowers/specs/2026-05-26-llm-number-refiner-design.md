# LLM-based Hybrid Number Refiner — Design Spec

> **Status:** PROPOSAL — pending plan and implementation.
> **Branch:** `feat/llm-number-refiner`
> **Date:** 2026-05-26
> **Author:** Claude (brainstormed with Justin)

## Why we're doing this

The Vocabulary > Numbers toggle today is one boolean. When on, the app runs
`NumberNormalizer` — a deterministic 17-pass regex normalizer (see
`Sources/MacParakeetCore/TextProcessing/NumberNormalizer.swift`) — over the
deterministic-cleaned transcript. The rules cover the common cases ("twenty-five"
→ "25", "next thirty seconds" → "next 30 seconds") and PR #4 just added
period-separated countdowns. But the broader pattern — context-sensitive number
normalization — wants an LLM:

- Large cardinals beyond 999 ("three thousand four hundred and twenty-five" → "3,425")
- Years ("nineteen ninety-five" → "1995")
- Clock times ("ten thirty AM" → "10:30 AM")
- Decimals ("two point five seconds" → "2.5 seconds")
- Ambiguous singletons that depend on context (the LLM can tell "I bought one" from "I did one rep")

Writing more regex passes for each of these is a losing game. We add an opt-in
LLM refinement step that runs *after* the deterministic pipeline, and we expose
the choice as a three-state setting so users who want neither, deterministic-only,
or rules+LLM all have a clean answer.

## Locked decisions (from brainstorming)

1. **Scope**: Smart applies only to file/meeting transcripts (`TranscriptionService`).
   `DictationService` keeps deterministic-only behavior — Smart collapses to
   Deterministic in the dictation path because dictation latency is felt by the
   user before paste, and a 500ms–2s LLM round-trip is not acceptable there.
2. **Fallback**: silent fallback to Deterministic on any failure (no provider,
   call error, parse failure, safety-gate rejection). Telemetry records the reason.
3. **Prompt shape**: whole-transcript, single LLM call, strict "only change number
   forms" instructions, with a post-call safety gate.
4. **UI placement**: the Numbers card moves from the Vocabulary tab to the AI tab,
   right under AI Formatter and above AI Subtitle Refinement. It joins the cluster
   of AI-driven transcript polish steps.
5. **Migration**: old `numberNormalizationEnabled = true` migrates to `.deterministic`;
   `false` or absent migrates to `.off`. Nobody jumps to `.smart` automatically.
6. **ADR-004 respected**: the deterministic `TextProcessingPipeline` stays LLM-free.
   The new LLM step sits *outside* the pipeline, at the same composition seam as
   the existing AI Formatter.

## Architecture

```
TranscriptionService.completeTranscription
  ├── textRefinementService.refine(rawText, normalizeNumbers: mode != .off)
  │       └── deterministic 5-step pipeline (incl. NumberNormalizer when on)
  ├── NumberLLMRefiner.refine(text: baseText)                         ← NEW (Smart only)
  │       ├── guard: provider configured else return input, .notConfigured
  │       ├── llmService.transformDetailed(...)
  │       ├── parse + clean reply
  │       ├── safety gate (non-number skeleton comparison)
  │       └── return RefinementOutcome { text, usedLLM, fallbackReason, run }
  └── formatTranscriptIfNeeded(smartText, ...)                        ← existing AI Formatter
          └── llmService.formatTranscriptDetailed(...)
```

`DictationService.completeDictation` keeps the same shape but never invokes
`NumberLLMRefiner` — the closure it receives is just the mode bool ("any
normalization at all?"), not the full enum.

## Components

### New file: `Sources/MacParakeetCore/Services/NumberLLMRefiner.swift`

A public actor that mirrors `SubtitleLLMRefiner`'s shape. Single responsibility:
take some text, ask the configured LLM to rewrite spelled numbers as digits,
return the result with metadata about whether the LLM was used and why it
may have fallen back.

```swift
public actor NumberLLMRefiner {
    public typealias ProgressHandler = @Sendable (Int, Int) -> Void

    public enum FallbackReason: String, Sendable {
        case notConfigured
        case callFailed
        case parseFailed
        case safetyGateRejected
        case cancelled
    }

    public struct RefinementOutcome: Sendable {
        public let text: String
        public let usedLLM: Bool
        public let fallbackReason: FallbackReason?
        public let run: LLMRun?    // present only when usedLLM == true
    }

    public init(llmService: LLMServiceProtocol, maxCharsPerCall: Int = 80_000)

    /// Never throws (except `CancellationError`, which is re-raised so structured
    /// concurrency cancellation propagates). All other failure paths return a
    /// usable `RefinementOutcome` with the deterministic input passed through.
    public func refine(
        text: String,
        runSource: LLMRunSource? = nil,
        onProgress: ProgressHandler? = nil
    ) async throws -> RefinementOutcome
}
```

Internal flow inside `refine`:

1. **Configured check**: if no LLM provider is set up, return input text + `.notConfigured`.
2. **Single-call path** (most cases): `llmService.transformDetailed(text:prompt:)`
   with the system prompt below. Wrapped in `do/catch` — any error other than
   `CancellationError` returns input text + `.callFailed`.
3. **Reply parsing**: trim whitespace, strip wrapping quote characters, reject if empty.
4. **Safety gate**: compute non-number skeletons (strip `[0-9]` and ASCII
   punctuation `.,!?;:'"()[]-`, collapse whitespace, lowercase). Compare
   skeletons via simple character-count delta. If `abs(input - output) /
   max(input, 1) > 0.02`, reject → `.safetyGateRejected`.
5. **Batched path** (escape hatch): if `text.count > maxCharsPerCall`, split at
   paragraph boundaries, refine each chunk independently, stitch results back.
   `onProgress` reports `(completed, total)` per chunk. Per-chunk failures fall
   back to the chunk's input text, not the whole transcript.

### New enum: `NumberRefinementMode` in `Sources/MacParakeetCore/AppRuntimePreferences.swift`

```swift
public enum NumberRefinementMode: String, CaseIterable, Hashable, Sendable, Equatable {
    case off
    case deterministic
    case smart

    public var displayTitle: String { ... }   // "Off" / "Deterministic" / "Smart"
    public var detail: String { ... }         // The two-line card description
}
```

Co-located with `MeetingAudioSourceMode` and `YouTubeAudioQuality` because they
follow the same pattern (`String`-backed enum with `displayTitle` and `detail`).

### Modified: `AppRuntimePreferencesProtocol`

```swift
public protocol AppRuntimePreferencesProtocol: Sendable {
    // ... existing ...
    var numberRefinementMode: NumberRefinementMode { get }
}
```

`UserDefaultsAppRuntimePreferences` gets:

- A new `numberRefinementModeKey = "numberRefinementMode"` constant.
- A new computed `numberRefinementMode` property reading from defaults.
- A one-shot migration that runs the first time the new property is read:
  if `numberRefinementMode` key is absent AND the legacy
  `numberNormalizationEnabled` key exists, translate (`true → .deterministic`,
  `false → .off`), write the new key, remove the old key.

Migration runs at most once per install — the presence of the new key blocks
re-migration on subsequent reads.

### Modified: `AppEnvironment`

- `numberNormalizationClosure: () -> Bool` becomes
  `numberRefinementModeClosure: () -> NumberRefinementMode`.
- A new `numberLLMRefiner = NumberLLMRefiner(llmService: llmService)` is constructed.
- `TranscriptionService.init` receives both the new closure and the refiner.
- `DictationService.init` receives only the closure (no refiner — Smart collapses
  to Deterministic in dictation).

### Modified: `TranscriptionService`

- Field rename: `shouldNormalizeNumbers: () -> Bool` →
  `numberRefinementMode: () -> NumberRefinementMode`.
- New optional field: `numberLLMRefiner: NumberLLMRefiner?` (optional so CLI and
  tests can omit it without standing up a full actor).
- In `completeTranscription` (around line 1341): translate the mode to a bool
  for `textRefinementService.refine(normalizeNumbers:)`, then between the
  deterministic refinement and the AI Formatter, conditionally invoke the
  refiner when `mode == .smart && numberLLMRefiner != nil`. Record the
  optional `LLMRun` via `llmRunRecorder` alongside the formatter's run.

### Modified: `DictationService`

- Field rename: `shouldNormalizeNumbers: () -> Bool` →
  `numberRefinementMode: () -> NumberRefinementMode`.
- At the existing call site (line 633): pass `numberRefinementMode() != .off`
  to `textRefinementService.refine(normalizeNumbers:)`. No other behavioral
  change — Smart collapses to Deterministic implicitly because we never plumb
  the refiner in.

### Modified: `LLMRunFeature`

A new enum case `.numberRefinement` for the run-history database. Existing
cases (`.formatterDictation`, `.formatterTranscription`, etc.) are untouched.

## Prompt design

### System prompt

```
You are a number-formatting assistant. The user will give you a transcript.

Your only job is to rewrite spelled-out numbers as digits where digit form is
the conventional written reading.

Convert:
- Years ("nineteen ninety-five" → "1995")
- Clock times ("ten thirty" → "10:30", "ten thirty AM" → "10:30 AM")
- Decimals ("two point five" → "2.5")
- Large cardinals ("three thousand four hundred and twenty-five" → "3,425")
- Spelled cardinals 10+ in measurement / counting contexts ("forty-five reps" → "45 reps")
- Phone numbers, addresses, monetary amounts when clearly spelled

Do NOT change:
- Idiomatic words ("one of them", "two of a kind") — keep spelled
- Ordinals in narrative use ("the first time") — keep spelled
- Any word that isn't a number
- Punctuation, line breaks, spacing, casing

Return the rewritten transcript verbatim. No commentary, no explanation, no
quotes, no markdown. Just the transcript.
```

### User message

The deterministic-cleaned transcript, raw. No `[CUE N]` wrapping (unlike
`SubtitleLLMRefiner`) — single-call rewrite doesn't need positional anchors.

### Safety gate

```
inputSkeleton  = stripDigitsAndPunctuation(input).lowercased().collapsed()
outputSkeleton = stripDigitsAndPunctuation(output).lowercased().collapsed()

let delta = abs(inputSkeleton.count - outputSkeleton.count)
let threshold = max(input.count / 50, 5)   // ~2% of input, floor at 5 chars
guard delta <= threshold else { reject }
```

The 2% threshold (floor 5 chars) covers tiny noise (curly-quote
normalization, stray-space collapsing) without letting in real paraphrasing.
We start with this value and tune it based on real-world fallback rate.

`stripDigitsAndPunctuation` removes `[0-9]` and the ASCII set `.,!?;:'"()[]-`.
We deliberately do NOT strip Unicode-fancy punctuation — if the model
substitutes a curly quote for a straight one, the skeleton lengths still match
because both characters survive the strip.

`collapsed()` replaces all runs of whitespace (including newlines) with a single space.

## Fallback flow

The actor's `refine` method always produces a usable result. The decision tree:

| Outcome | `usedLLM` | `fallbackReason`     | Returned text                |
|---------|-----------|----------------------|------------------------------|
| Happy   | true      | nil                  | LLM reply                    |
| No provider | false | `.notConfigured`     | Input (passed through)       |
| LLM threw   | false | `.callFailed`        | Input                        |
| Empty/garbage reply | false | `.parseFailed` | Input                  |
| Skeleton drift exceeded | false | `.safetyGateRejected` | Input             |
| Cancelled   | n/a   | `.cancelled` (re-thrown) | `CancellationError` propagates |

`CancellationError` is the one exception we re-throw, so the surrounding
`Task` group / structured-concurrency surface can collapse cleanly. The
calling `TranscriptionService` already handles `CancellationError`
propagation for its other LLM steps.

## Telemetry

Two new events on `Telemetry`:

```swift
case .numberRefinerUsed(
    provider: String,
    inputChars: Int,
    outputChars: Int,
    latencyMs: Int,
    safetyGatePassed: Bool
)

case .numberRefinerFallback(
    reason: String,          // raw value of FallbackReason
    provider: String?,       // nil when reason == .notConfigured
    errorType: String?       // populated when reason == .callFailed
)
```

`safetyGatePassed == true` implies the LLM reply was kept; `false` implies
the deterministic input was kept (and `numberRefinerFallback` also fired with
`reason: .safetyGateRejected`).

Which event fires per outcome:

| Outcome | `numberRefinerUsed` | `numberRefinerFallback` |
|---|---|---|
| Happy path (LLM kept) | ✓ `safetyGatePassed: true` | — |
| Safety gate rejected | ✓ `safetyGatePassed: false` | ✓ `reason: .safetyGateRejected` |
| LLM call failed | — | ✓ `reason: .callFailed` |
| Provider not configured | — | ✓ `reason: .notConfigured` |
| Parse failed | — | ✓ `reason: .parseFailed` |
| Cancelled | — | — (cancellation re-thrown without telemetry) |

No transcript content in either event — same hygiene rule as every other LLM
telemetry event.

Successful Smart runs (gate passed) record an `LLMRun` row in the database
via `LLMRunRecorder`, with `feature = .numberRefinement`. This shows up in
the user-visible "AI runs" history alongside formatter runs.

Failed-and-fell-back paths do NOT record an `LLMRun` (mirrors how the AI
Formatter handles its own failures — failed calls aren't user-visible history).

## Settings UI

### AI tab — new "Number Formatting" card

Inserted in `SettingsView.aiTabContent` between the AI Provider card (which
embeds AI Formatter) and the AI Subtitle Refinement card:

```
+----------------------------------------------------+
| ✨ Number Formatting                                |
| How spelled-out numbers get converted to digits.   |
+----------------------------------------------------+
|  [⊘ Off]      [# Deterministic]     [✦ Smart]      |
|  No changes   Rule-based            Rules + AI     |
|  ...          ...                   ...            |
+----------------------------------------------------+
|  Examples for [selected mode]:                     |
|    "next thirty seconds" → "next 30 seconds"       |
|    ...                                             |
+----------------------------------------------------+
|  ⓘ Smart needs an AI provider. Set one up above.   |  ← only when smart && no provider
+----------------------------------------------------+
```

Three mode cards visually mirror the Raw/Clean cards at the top of the
Vocabulary tab (`VocabularyView.modeCard(...)`). Selected card shows the
accent checkmark.

| Card | Icon | Title | Subtitle | Detail |
|------|------|-------|----------|--------|
| 1 | `circle.slash` | Off | No changes | Numbers stay exactly as the speech engine wrote them. |
| 2 | `number` | Deterministic | Rule-based | Fast on-device rules convert spelled numbers to digits ("twenty-five" → "25"). No AI needed. |
| 3 | `sparkles` | Smart | Rules + AI | Runs the rules, then your AI provider polishes harder cases (years, decimals, large numbers). Falls back to Deterministic if your AI provider isn't set up. |

Examples panel adapts to the selected mode. For Smart, includes year /
decimal / clock examples that Deterministic can't handle.

Smart-but-no-provider hint: amber `info.circle` row with copy "Smart needs an
AI provider. Without one, Smart behaves like Deterministic." Clickable target
scrolls to the AI Provider card above.

### Vocabulary tab — breadcrumb

The old Numbers card in `VocabularyView` is removed. In its place (bottom of
the Clean Pipeline area), a one-line signpost:

```
📊 Number formatting moved → AI tab → Open
```

Tapping "Open" routes to `SettingsTab.ai` and scrolls to the new card.

**Open question** (revisit after first hands-on build): should this row be
permanent, or hide after N launches? Defer the decision; ship it as a
permanent row for v1.

## Migration

`UserDefaultsAppRuntimePreferences.numberRefinementMode` getter:

```swift
public var numberRefinementMode: NumberRefinementMode {
    // If new key is set, use it.
    if let raw = defaults.string(forKey: Self.numberRefinementModeKey),
       let mode = NumberRefinementMode(rawValue: raw) {
        return mode
    }

    // Migration: legacy key absent or new key absent.
    let legacy = defaults.object(forKey: Self.numberNormalizationEnabledKey) as? Bool
    let migrated: NumberRefinementMode = (legacy == true) ? .deterministic : .off
    defaults.set(migrated.rawValue, forKey: Self.numberRefinementModeKey)
    defaults.removeObject(forKey: Self.numberNormalizationEnabledKey)
    return migrated
}
```

After the migration runs once, the legacy key is gone and the getter takes
the fast path on subsequent calls.

The legacy `numberNormalizationEnabledKey` constant stays in the source as a
private value just for the migration to reference — we delete it in a later
cleanup pass once all installs have migrated. (Roughly one minor release of
soak time.)

## Testing strategy

### New file: `Tests/MacParakeetTests/NumberLLMRefinerTests.swift`

**Pure-logic tests:**

1. Safety gate `passes` for in/out pairs that differ only by digit substitution.
2. Safety gate `rejects` when output adds commentary or removes whole sentences.
3. Safety gate `passes` within tolerance for curly-quote vs straight-quote drift.
4. Reply parser strips markdown fences and wrapping quotes.
5. Reply parser rejects empty / whitespace-only replies.

**Service-level tests (mock `LLMServiceProtocol`):**

1. Happy path → `usedLLM == true`, output == mock reply.
2. Mock throws `.notConfigured` → `.notConfigured` fallback, output == input.
3. Mock throws network error → `.callFailed` fallback, output == input.
4. Mock returns paraphrased text → `.safetyGateRejected` fallback, output == input.
5. Task cancellation → re-throws `CancellationError`.

**Migration tests** (in `AppRuntimePreferencesTests.swift`):

1. Legacy `numberNormalizationEnabled = true` → `.deterministic`, legacy key removed.
2. Legacy `false` → `.off`, legacy key removed.
3. Legacy key absent → `.off`, no exception.
4. New key already set → migration skipped, returns new value.

### Integration tests in `TranscriptionServiceTests`

1. Mode `.smart` + mock LLM returning polished text → `cleanTranscript` contains the polished version, `LLMRun` recorded.
2. Mode `.smart` + no LLM service → falls back to deterministic, no `LLMRun`.
3. Mode `.deterministic` → existing behavior unchanged.
4. Mode `.off` → no normalization, raw spelled numbers preserved.

### Not tested (per `spec/09-testing.md`):

- SwiftUI view code for the new card (View tests aren't done in this codebase).
- Actual LLM responses (we never hit a real provider in CI).
- The Vocabulary breadcrumb's tap-routing logic at the view layer.

### CLI smoke

`macparakeet-cli transcribe` already honors the persisted preferences. A new
worked example in `docs/cli-testing.md` shows the Smart path end-to-end against
a configured local provider, with expected before/after on a known fixture.

## Out of scope

- Streaming the LLM reply token-by-token (not needed for non-interactive
  transcription completion; we already wait for the formatter).
- Per-language number conventions (Smart implicitly handles English via the
  system prompt; multilingual transcripts get whatever the LLM does, which is
  fine for v1).
- Per-prompt user customization of the system prompt (deferred; users who want
  fully custom number behavior can use the AI Formatter with a custom prompt).
- Tracking which deterministic rule each digit came from (the safety gate
  treats digits as opaque; we don't need finer attribution).

## Files touched (preview — exact set landed by the implementation plan)

**New:**
- `Sources/MacParakeetCore/Services/NumberLLMRefiner.swift`
- `Tests/MacParakeetTests/NumberLLMRefinerTests.swift`

**Modified:**
- `Sources/MacParakeetCore/AppRuntimePreferences.swift` (new enum + getter + migration)
- `Sources/MacParakeetCore/Services/TranscriptionService.swift` (compose refiner)
- `Sources/MacParakeetCore/Services/Dictation/DictationService.swift` (closure rename)
- `Sources/MacParakeetCore/Models/LLMRun.swift` (new `LLMRunFeature` enum case `.numberRefinement`)
- `Sources/MacParakeetCore/Services/Telemetry/TelemetryEvent.swift` (two new event cases)
- `Sources/MacParakeet/App/AppEnvironment.swift` (build the refiner, inject closures)
- `Sources/MacParakeet/Views/Settings/SettingsView.swift` (insert new card in AI tab)
- `Sources/MacParakeet/Views/Settings/LLMSettingsView.swift` (or new
  `NumberFormattingCard.swift` peer file — implementation plan picks)
- `Sources/MacParakeet/Views/Vocabulary/VocabularyView.swift` (remove Numbers card, add breadcrumb)
- `Sources/MacParakeetViewModels/SettingsViewModel.swift` (new published property)
- `Tests/MacParakeetTests/AppRuntimePreferencesTests.swift` (migration)
- `Tests/MacParakeetTests/Services/TranscriptionServiceTests.swift` (smart path)
- `docs/cli-testing.md` (new worked example)

## ADRs referenced

- **ADR-004**: deterministic text processing pipeline. Respected — the new
  step lives outside `TextProcessingPipeline` at the same seam as the AI
  Formatter.
- **ADR-011**: LLM via cloud API keys + optional local providers. Respected
  — Smart uses whatever provider the user has configured via the existing
  resolver chain.

## Open questions (post-first-build)

1. **Vocabulary breadcrumb permanence**: keep forever, or hide after N launches?
2. **Safety-gate threshold tuning**: 2% may be too tight or too loose. Real-world
   fallback-rate telemetry will tell us.
3. **Large-transcript batching**: the actor has the escape hatch but nobody
   exercises it until we see a transcript > 80K chars in practice. Verify the
   stitching logic doesn't drop boundary-numbers when we do.
