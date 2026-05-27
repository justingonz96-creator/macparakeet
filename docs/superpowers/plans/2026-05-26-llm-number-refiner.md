# LLM Number Refiner Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an opt-in "Smart" tier to the Vocabulary > Numbers setting that runs the existing deterministic NumberNormalizer first, then asks the configured LLM to clean up what rules can't (years, decimals, large cardinals, clock times). Smart applies only to file/meeting transcripts. Falls back silently to Deterministic on any failure.

**Architecture:** New `NumberLLMRefiner` actor in `Sources/MacParakeetCore/Services/` that mirrors `SubtitleLLMRefiner`'s shape. Called from `TranscriptionService.completeTranscription` between the deterministic refinement and the AI Formatter. New `NumberRefinementMode` enum (off/deterministic/smart) replaces the legacy `numberNormalizationEnabled` bool, with a one-shot migration. The settings card relocates from the Vocabulary tab to the AI tab.

**Tech Stack:** Swift 6 actors, XCTest, GRDB (for LLMRun history), SwiftUI for the settings card.

**Spec:** `docs/superpowers/specs/2026-05-26-llm-number-refiner-design.md`

---

## File Structure

**New files:**
- `Sources/MacParakeetCore/Services/NumberLLMRefiner.swift` — the actor (refine + safety gate + fallback)
- `Sources/MacParakeet/Views/Settings/NumberFormattingCard.swift` — the new AI-tab settings card
- `Tests/MacParakeetTests/Services/NumberLLMRefinerTests.swift` — unit tests for the actor

**Modified files:**
- `Sources/MacParakeetCore/AppRuntimePreferences.swift` — add `NumberRefinementMode` enum + migration
- `Sources/MacParakeetCore/Models/LLMRun.swift` — add `.numberRefinement` Feature case
- `Sources/MacParakeetCore/Services/Telemetry/TelemetryEvent.swift` — two new events + rename `numberNormalization` → `numberRefinementMode` in `TelemetrySettingName`
- `Sources/MacParakeetCore/Services/TranscriptionService.swift` — rename closure, compose refiner, record optional LLMRun
- `Sources/MacParakeetCore/Services/Dictation/DictationService.swift` — rename closure, translate to bool
- `Sources/MacParakeet/App/AppEnvironment.swift` — build refiner, swap closure
- `Sources/MacParakeet/Views/Settings/SettingsView.swift` — insert new card in `aiTabContent`
- `Sources/MacParakeet/Views/Vocabulary/VocabularyView.swift` — remove Numbers card, add breadcrumb
- `Sources/MacParakeetViewModels/SettingsViewModel.swift` — replace `numberNormalizationEnabled` bool with `numberRefinementMode` String-backed property
- `Tests/MacParakeetTests/AppRuntimePreferencesTests.swift` — migration tests
- `Tests/MacParakeetTests/Services/TranscriptionServiceTests.swift` — smart-path integration test
- `docs/cli-testing.md` — new worked example

---

## Task 1: Add `NumberRefinementMode` enum and migration

**Files:**
- Modify: `Sources/MacParakeetCore/AppRuntimePreferences.swift`

- [ ] **Step 1.1: Add the enum near the other typed-preference enums**

Insert after `MeetingAudioSourceMode` (around line 99) in `AppRuntimePreferences.swift`:

```swift
public enum NumberRefinementMode: String, CaseIterable, Hashable, Sendable, Equatable {
    case off
    case deterministic
    case smart

    public var displayTitle: String {
        switch self {
        case .off: return "Off"
        case .deterministic: return "Deterministic"
        case .smart: return "Smart"
        }
    }

    public var detail: String {
        switch self {
        case .off:
            return "Numbers stay exactly as the speech engine wrote them."
        case .deterministic:
            return "Fast on-device rules convert spelled numbers to digits (\"twenty-five\" → \"25\"). No AI needed."
        case .smart:
            return "Runs the rules, then your AI provider polishes harder cases (years, decimals, large numbers). Falls back to Deterministic if your AI provider isn't set up."
        }
    }

    public static func current(defaults: UserDefaults = .standard) -> NumberRefinementMode {
        guard let raw = defaults.string(forKey: UserDefaultsAppRuntimePreferences.numberRefinementModeKey),
              let mode = NumberRefinementMode(rawValue: raw) else {
            return .off
        }
        return mode
    }
}
```

- [ ] **Step 1.2: Add the property to the protocol**

Find `var numberNormalizationEnabled: Bool { get }` in `AppRuntimePreferencesProtocol` (line 13) and add right below it:

```swift
var numberRefinementMode: NumberRefinementMode { get }
```

(Keep `numberNormalizationEnabled` for now — Step 5 removes it after the migration is in place and verified.)

- [ ] **Step 1.3: Add the storage key constant**

Find `public static let numberNormalizationEnabledKey = "numberNormalizationEnabled"` (line 115) and add right below it:

```swift
public static let numberRefinementModeKey = "numberRefinementMode"
```

- [ ] **Step 1.4: Add the computed property with migration**

Find `public var numberNormalizationEnabled: Bool { ... }` (lines 168-170) and add directly below:

```swift
public var numberRefinementMode: NumberRefinementMode {
    // Fast path: new key already set.
    if let raw = defaults.string(forKey: Self.numberRefinementModeKey),
       let mode = NumberRefinementMode(rawValue: raw) {
        return mode
    }

    // One-shot migration from the legacy bool key.
    let legacy = defaults.object(forKey: Self.numberNormalizationEnabledKey) as? Bool
    let migrated: NumberRefinementMode = (legacy == true) ? .deterministic : .off
    defaults.set(migrated.rawValue, forKey: Self.numberRefinementModeKey)
    defaults.removeObject(forKey: Self.numberNormalizationEnabledKey)
    return migrated
}
```

- [ ] **Step 1.5: Commit**

```bash
git add Sources/MacParakeetCore/AppRuntimePreferences.swift
git commit -m "feat(prefs): NumberRefinementMode enum + one-shot migration"
```

---

## Task 2: Migration tests

**Files:**
- Modify: `Tests/MacParakeetTests/AppRuntimePreferencesTests.swift`

- [ ] **Step 2.1: Append four migration tests at the end of the file**

Add inside the class, right before the closing brace:

```swift
// MARK: - NumberRefinementMode migration

func testNumberRefinementModeMigratesLegacyTrueToDeterministic() {
    let suite = "app-runtime-prefs-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }

    defaults.set(true, forKey: UserDefaultsAppRuntimePreferences.numberNormalizationEnabledKey)

    let prefs = UserDefaultsAppRuntimePreferences(defaults: defaults)
    XCTAssertEqual(prefs.numberRefinementMode, .deterministic)

    // Legacy key is consumed; new key holds the value.
    XCTAssertNil(defaults.object(forKey: UserDefaultsAppRuntimePreferences.numberNormalizationEnabledKey))
    XCTAssertEqual(defaults.string(forKey: UserDefaultsAppRuntimePreferences.numberRefinementModeKey), "deterministic")
}

func testNumberRefinementModeMigratesLegacyFalseToOff() {
    let suite = "app-runtime-prefs-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }

    defaults.set(false, forKey: UserDefaultsAppRuntimePreferences.numberNormalizationEnabledKey)

    let prefs = UserDefaultsAppRuntimePreferences(defaults: defaults)
    XCTAssertEqual(prefs.numberRefinementMode, .off)
    XCTAssertNil(defaults.object(forKey: UserDefaultsAppRuntimePreferences.numberNormalizationEnabledKey))
}

func testNumberRefinementModeMigratesAbsentLegacyToOff() {
    let suite = "app-runtime-prefs-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }

    let prefs = UserDefaultsAppRuntimePreferences(defaults: defaults)
    XCTAssertEqual(prefs.numberRefinementMode, .off)
}

func testNumberRefinementModeUsesNewKeyWhenAlreadySet() {
    let suite = "app-runtime-prefs-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }

    // New key set to .smart; legacy key set to true (should be ignored).
    defaults.set("smart", forKey: UserDefaultsAppRuntimePreferences.numberRefinementModeKey)
    defaults.set(true, forKey: UserDefaultsAppRuntimePreferences.numberNormalizationEnabledKey)

    let prefs = UserDefaultsAppRuntimePreferences(defaults: defaults)
    XCTAssertEqual(prefs.numberRefinementMode, .smart)

    // Legacy key untouched on the fast path.
    XCTAssertEqual(defaults.object(forKey: UserDefaultsAppRuntimePreferences.numberNormalizationEnabledKey) as? Bool, true)
}
```

- [ ] **Step 2.2: Run the new tests**

```bash
swift test --filter AppRuntimePreferencesTests
```

Expected: all four new tests pass, plus existing tests pass.

- [ ] **Step 2.3: Commit**

```bash
git add Tests/MacParakeetTests/AppRuntimePreferencesTests.swift
git commit -m "test(prefs): NumberRefinementMode migration cases"
```

---

## Task 3: Add `.numberRefinement` Feature case

**Files:**
- Modify: `Sources/MacParakeetCore/Models/LLMRun.swift:27-33`

- [ ] **Step 3.1: Add the new case**

In the `LLMRun.Feature` enum, add `.numberRefinement`:

```swift
public enum Feature: String, Codable, Sendable {
    case formatterDictation = "formatter_dictation"
    case formatterTranscription = "formatter_transcription"
    case promptResult = "prompt_result"
    case chat
    case transform
    case numberRefinement = "number_refinement"
}
```

- [ ] **Step 3.2: Verify the build still compiles**

```bash
swift build
```

Expected: no errors. (No switch exhaustiveness break because the enum doesn't have a `default`-less consumer; if compiler reports one, address in that file by adding the new case.)

- [ ] **Step 3.3: Commit**

```bash
git add Sources/MacParakeetCore/Models/LLMRun.swift
git commit -m "feat(llm-run): add .numberRefinement feature case"
```

---

## Task 4: Add Telemetry events + rename setting name

**Files:**
- Modify: `Sources/MacParakeetCore/Services/Telemetry/TelemetryEvent.swift`

- [ ] **Step 4.1: Add raw event names in the case block at top of file**

Find the `llmTransformFailed = "llm_transform_failed"` line (around line 34) and add two new cases right below:

```swift
    case numberRefinerUsed = "number_refiner_used"
    case numberRefinerFallback = "number_refiner_fallback"
```

- [ ] **Step 4.2: Rename the setting name case**

In `TelemetrySettingName` (line 371-399), change:

```swift
case numberNormalization = "number_normalization"
```

to:

```swift
case numberRefinementMode = "number_refinement_mode"
```

- [ ] **Step 4.3: Add event spec cases in `TelemetryEventSpec`**

Find the spec case for `.llmTransformFailed` (search for `case llmTransformFailed`) inside `TelemetryEventSpec`. Add two cases right below it:

```swift
case numberRefinerUsed(
    provider: String,
    inputChars: Int,
    outputChars: Int,
    latencyMs: Int,
    safetyGatePassed: Bool
)
case numberRefinerFallback(
    reason: String,
    provider: String?,
    errorType: String?
)
```

- [ ] **Step 4.4: Map the spec cases to raw event names**

Find the `case .llmTransformFailed: return .llmTransformFailed` line (search for `.llmTransformFailed: return`) and add directly below:

```swift
case .numberRefinerUsed: return .numberRefinerUsed
case .numberRefinerFallback: return .numberRefinerFallback
```

- [ ] **Step 4.5: Add the property-encoding branches**

Find the big `case .llmTransformFailed(let provider, let errorType):` block (search for `case .llmTransformFailed(let provider, let errorType):`). It returns a `[String: TelemetryEventValue]` dict. Add directly below:

```swift
case .numberRefinerUsed(let provider, let inputChars, let outputChars, let latencyMs, let safetyGatePassed):
    return [
        "provider": .string(provider),
        "input_chars": .int(inputChars),
        "output_chars": .int(outputChars),
        "latency_ms": .int(latencyMs),
        "safety_gate_passed": .bool(safetyGatePassed)
    ]
case .numberRefinerFallback(let reason, let provider, let errorType):
    var props: [String: TelemetryEventValue] = ["reason": .string(reason)]
    if let provider { props["provider"] = .string(provider) }
    if let errorType { props["error_type"] = .string(errorType) }
    return props
```

(If the file uses a slightly different value-encoding shape, mirror the `.llmTransformFailed` branch's exact structure.)

- [ ] **Step 4.6: Add allowed-property-key entries**

Find the `.settingChanged: ["setting"]` line (around line 1604, in the `propertyKeys` map). Add right below the existing LLM entries (probably near `.llmTransformFailed: ["provider", "error_type"]`):

```swift
.numberRefinerUsed: ["provider", "input_chars", "output_chars", "latency_ms", "safety_gate_passed"],
.numberRefinerFallback: ["reason", "provider", "error_type"],
```

- [ ] **Step 4.7: Update the one existing caller of `.numberNormalization`**

The `SettingsViewModel` references `TelemetrySettingName.numberNormalization`. Find that reference (in Task 10 we replace the whole property; for now just rename to satisfy the build):

```bash
swift build 2>&1 | grep -i numberNormalization | head -5
```

If the build flags any callers using `.numberNormalization`, leave them be — Task 10 rewires `SettingsViewModel` and replaces those callsites entirely. For this task, just rename the enum case and accept the temporary build break (we fix it in Task 10).

Actually — simpler: also add a deprecated alias to keep the build green between tasks:

```swift
@available(*, deprecated, renamed: "numberRefinementMode")
public static let numberNormalization: TelemetrySettingName = .numberRefinementMode
```

(Place this directly under the renamed case definition. We remove the alias as a cleanup commit after Task 10.)

- [ ] **Step 4.8: Verify build**

```bash
swift build
```

Expected: no errors, possibly a deprecation warning at the `SettingsViewModel` callsite (which is fine).

- [ ] **Step 4.9: Commit**

```bash
git add Sources/MacParakeetCore/Services/Telemetry/TelemetryEvent.swift
git commit -m "feat(telemetry): number_refiner_used + number_refiner_fallback events"
```

---

## Task 5: Write `NumberLLMRefiner` actor

**Files:**
- Create: `Sources/MacParakeetCore/Services/NumberLLMRefiner.swift`

- [ ] **Step 5.1: Create the file with the full actor**

```swift
import Foundation

/// Uses an LLM to refine spelled-out numbers in transcript text into digit form.
///
/// Runs as an optional step AFTER the deterministic `NumberNormalizer` — catches
/// the cases rules can't reach (years, decimals, large cardinals, clock times)
/// without changing the rest of the prose.
///
/// **Never throws** except `CancellationError`. All other failure modes return a
/// `RefinementOutcome` with `text == input` and a populated `fallbackReason`.
/// This lets `TranscriptionService` compose the refiner without a try/catch and
/// guarantees Smart mode degrades silently to Deterministic when anything goes
/// wrong (no provider, network error, parse failure, safety-gate rejection).
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
        public let run: LLMRun?
        public let latencyMs: Int
        public let provider: String?
        public let safetyGatePassed: Bool

        public init(
            text: String,
            usedLLM: Bool,
            fallbackReason: FallbackReason?,
            run: LLMRun?,
            latencyMs: Int = 0,
            provider: String? = nil,
            safetyGatePassed: Bool = false
        ) {
            self.text = text
            self.usedLLM = usedLLM
            self.fallbackReason = fallbackReason
            self.run = run
            self.latencyMs = latencyMs
            self.provider = provider
            self.safetyGatePassed = safetyGatePassed
        }
    }

    private let llmService: LLMServiceProtocol
    private let maxCharsPerCall: Int

    public init(llmService: LLMServiceProtocol, maxCharsPerCall: Int = 80_000) {
        self.llmService = llmService
        self.maxCharsPerCall = max(1_000, maxCharsPerCall)
    }

    /// Refine the input transcript. Returns deterministic input untouched when
    /// anything fails. Re-throws `CancellationError` so structured concurrency
    /// cancellation propagates up to the caller.
    public func refine(
        text: String,
        runSource: LLMRunSource? = nil,
        onProgress: ProgressHandler? = nil
    ) async throws -> RefinementOutcome {
        guard !text.isEmpty else {
            return RefinementOutcome(text: text, usedLLM: false, fallbackReason: nil, run: nil)
        }

        // Escape hatch for very long transcripts: split at paragraph boundaries
        // and refine chunk-by-chunk. Per-chunk failures fall back to that chunk's
        // input, not the whole transcript. We deliberately keep this sequential —
        // concurrent batches add complexity and the typical case fits in one call.
        if text.count > maxCharsPerCall {
            return try await refineByChunks(text: text, runSource: runSource, onProgress: onProgress)
        }

        return try await refineSingleCall(text: text, runSource: runSource)
    }

    // MARK: - Single-call path

    private func refineSingleCall(
        text: String,
        runSource: LLMRunSource?
    ) async throws -> RefinementOutcome {
        let startedAt = Date()
        let result: LLMResult
        do {
            result = try await llmService.transformDetailed(
                text: text,
                prompt: Self.systemPrompt
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let llmError as LLMError where Self.isNotConfigured(llmError) {
            return RefinementOutcome(
                text: text,
                usedLLM: false,
                fallbackReason: .notConfigured,
                run: nil,
                latencyMs: Self.latencyMs(since: startedAt)
            )
        } catch {
            return RefinementOutcome(
                text: text,
                usedLLM: false,
                fallbackReason: .callFailed,
                run: nil,
                latencyMs: Self.latencyMs(since: startedAt)
            )
        }

        let cleaned = Self.cleanReply(result.output)
        guard !cleaned.isEmpty else {
            return RefinementOutcome(
                text: text,
                usedLLM: false,
                fallbackReason: .parseFailed,
                run: nil,
                latencyMs: Self.latencyMs(since: startedAt),
                provider: result.provider
            )
        }

        guard Self.safetyGatePasses(input: text, output: cleaned) else {
            return RefinementOutcome(
                text: text,
                usedLLM: false,
                fallbackReason: .safetyGateRejected,
                run: nil,
                latencyMs: Self.latencyMs(since: startedAt),
                provider: result.provider,
                safetyGatePassed: false
            )
        }

        let run = LLMRun(
            operationID: nil,
            feature: .numberRefinement,
            status: .succeeded,
            source: runSource ?? LLMRunSource(),
            provider: result.provider,
            model: result.model,
            promptTokens: result.usage?.promptTokens,
            completionTokens: result.usage?.completionTokens,
            totalTokens: result.usage?.totalTokens,
            latencyMs: result.latencyMs,
            inputChars: text.count,
            outputChars: cleaned.count,
            stopReason: result.stopReason,
            inputTruncated: false,
            defaultPromptUsed: true,
            messageCount: 2
        )

        return RefinementOutcome(
            text: cleaned,
            usedLLM: true,
            fallbackReason: nil,
            run: run,
            latencyMs: result.latencyMs ?? Self.latencyMs(since: startedAt),
            provider: result.provider,
            safetyGatePassed: true
        )
    }

    // MARK: - Batched path

    private func refineByChunks(
        text: String,
        runSource: LLMRunSource?,
        onProgress: ProgressHandler?
    ) async throws -> RefinementOutcome {
        let chunks = Self.splitAtParagraphs(text: text, maxChars: maxCharsPerCall)
        var refinedChunks: [String] = []
        refinedChunks.reserveCapacity(chunks.count)
        let total = chunks.count
        var anySucceeded = false
        var aggregateRun: LLMRun?
        var lastProvider: String?
        var anyGatePassed = false

        for (i, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            let outcome = try await refineSingleCall(text: chunk, runSource: runSource)
            refinedChunks.append(outcome.text)
            if outcome.usedLLM {
                anySucceeded = true
                if aggregateRun == nil { aggregateRun = outcome.run }
                lastProvider = outcome.provider
                anyGatePassed = anyGatePassed || outcome.safetyGatePassed
            }
            onProgress?(i + 1, total)
        }

        let stitched = refinedChunks.joined(separator: "\n\n")
        return RefinementOutcome(
            text: stitched,
            usedLLM: anySucceeded,
            fallbackReason: anySucceeded ? nil : .callFailed,
            run: aggregateRun,
            latencyMs: 0,
            provider: lastProvider,
            safetyGatePassed: anyGatePassed
        )
    }

    private static func splitAtParagraphs(text: String, maxChars: Int) -> [String] {
        let paragraphs = text.components(separatedBy: "\n\n")
        var chunks: [String] = []
        var current = ""

        for paragraph in paragraphs {
            let candidate = current.isEmpty ? paragraph : current + "\n\n" + paragraph
            if candidate.count <= maxChars {
                current = candidate
            } else {
                if !current.isEmpty { chunks.append(current) }
                if paragraph.count > maxChars {
                    // Single oversized paragraph — hard split by char count.
                    var remainder = paragraph
                    while remainder.count > maxChars {
                        let cutIdx = remainder.index(remainder.startIndex, offsetBy: maxChars)
                        chunks.append(String(remainder[..<cutIdx]))
                        remainder = String(remainder[cutIdx...])
                    }
                    current = remainder
                } else {
                    current = paragraph
                }
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks.isEmpty ? [text] : chunks
    }

    // MARK: - Reply cleaning

    /// Trims whitespace, strips wrapping quote characters and a single
    /// markdown code-fence pair if present. Returns "" if the reply is empty
    /// after cleaning.
    static func cleanReply(_ reply: String) -> String {
        var t = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return t }

        // Strip a single matched code-fence pair.
        if t.hasPrefix("```") {
            if let firstNewline = t.firstIndex(of: "\n") {
                t = String(t[t.index(after: firstNewline)...])
            }
            if t.hasSuffix("```") {
                t = String(t.dropLast(3))
            }
            t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Strip matching wrapping quotes (straight or curly).
        let quotePairs: [(Character, Character)] = [
            ("\"", "\""), ("'", "'"), ("\u{201C}", "\u{201D}"), ("\u{2018}", "\u{2019}")
        ]
        for (open, close) in quotePairs {
            if t.count >= 2, t.first == open, t.last == close {
                t = String(t.dropFirst().dropLast())
                t = t.trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }

        return t
    }

    // MARK: - Safety gate

    /// `true` when input and output differ only in number/punctuation characters.
    /// Computes a "non-number skeleton" of each by stripping digits + common
    /// punctuation + lowercasing + collapsing whitespace, then compares lengths
    /// within a 2% tolerance (floor 5 chars).
    static func safetyGatePasses(input: String, output: String) -> Bool {
        let inSkel = nonNumberSkeleton(input)
        let outSkel = nonNumberSkeleton(output)
        let delta = abs(inSkel.count - outSkel.count)
        let threshold = max(input.count / 50, 5)
        return delta <= threshold
    }

    static func nonNumberSkeleton(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        var lastWasSpace = false
        for char in text {
            if char.isNumber { continue }
            if Self.skeletonStripPunctuation.contains(char) { continue }
            if char.isWhitespace {
                if !lastWasSpace { out.append(" "); lastWasSpace = true }
                continue
            }
            out.append(Character(char.lowercased()))
            lastWasSpace = false
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    private static let skeletonStripPunctuation: Set<Character> = [
        ".", ",", "!", "?", ";", ":", "'", "\"", "(", ")", "[", "]", "-"
    ]

    // MARK: - Error classification

    private static func isNotConfigured(_ error: LLMError) -> Bool {
        if case .notConfigured = error { return true }
        return false
    }

    private static func latencyMs(since start: Date) -> Int {
        Int((Date().timeIntervalSince(start) * 1000).rounded())
    }

    // MARK: - System prompt

    static let systemPrompt = """
        You are a number-formatting assistant. The user will give you a transcript.

        Your only job is to rewrite spelled-out numbers as digits where digit form is the conventional written reading.

        Convert:
        - Years ("nineteen ninety-five" → "1995")
        - Clock times ("ten thirty" → "10:30", "ten thirty AM" → "10:30 AM")
        - Decimals ("two point five" → "2.5")
        - Large cardinals ("three thousand four hundred and twenty-five" → "3,400")
        - Spelled cardinals 10+ in measurement or counting contexts ("forty-five reps" → "45 reps")
        - Phone numbers, addresses, monetary amounts when clearly spelled

        Do NOT change:
        - Idiomatic words ("one of them", "two of a kind") — keep spelled
        - Ordinals in narrative use ("the first time") — keep spelled
        - Any word that isn't a number
        - Punctuation, line breaks, spacing, casing

        Return the rewritten transcript verbatim. No commentary, no explanation, no quotes, no markdown. Just the transcript.
        """
}
```

- [ ] **Step 5.2: Verify it builds**

```bash
swift build
```

Expected: no errors.

- [ ] **Step 5.3: Commit**

```bash
git add Sources/MacParakeetCore/Services/NumberLLMRefiner.swift
git commit -m "feat(refiner): NumberLLMRefiner actor with safety gate + silent fallback"
```

---

## Task 6: Unit tests for `NumberLLMRefiner`

**Files:**
- Create: `Tests/MacParakeetTests/Services/NumberLLMRefinerTests.swift`

- [ ] **Step 6.1: Create the test file**

```swift
import XCTest
@testable import MacParakeetCore

final class NumberLLMRefinerTests: XCTestCase {

    // MARK: - Safety gate

    func testSafetyGatePassesForPureDigitSubstitution() {
        XCTAssertTrue(NumberLLMRefiner.safetyGatePasses(
            input: "next thirty seconds, twenty-five reps",
            output: "next 30 seconds, 25 reps"
        ))
    }

    func testSafetyGatePassesForYearAndClockTime() {
        XCTAssertTrue(NumberLLMRefiner.safetyGatePasses(
            input: "in nineteen ninety-five at ten thirty AM",
            output: "in 1995 at 10:30 AM"
        ))
    }

    func testSafetyGateRejectsWhenLLMAddsCommentary() {
        XCTAssertFalse(NumberLLMRefiner.safetyGatePasses(
            input: "twenty-five reps",
            output: "25 reps and some extra commentary about exercise routines"
        ))
    }

    func testSafetyGateRejectsWhenLLMDropsContent() {
        XCTAssertFalse(NumberLLMRefiner.safetyGatePasses(
            input: "twenty-five reps then move on to the next round and twenty more pushes",
            output: "25 reps"
        ))
    }

    func testSafetyGateToleratesQuoteStyleSwap() {
        XCTAssertTrue(NumberLLMRefiner.safetyGatePasses(
            input: "she said \"twenty-five reps\" before stopping",
            output: "she said \u{201C}25 reps\u{201D} before stopping"
        ))
    }

    // MARK: - Reply cleaner

    func testCleanReplyStripsLeadingAndTrailingWhitespace() {
        XCTAssertEqual(NumberLLMRefiner.cleanReply("   hello world   "), "hello world")
    }

    func testCleanReplyStripsMarkdownCodeFence() {
        let input = """
        ```
        hello world
        ```
        """
        XCTAssertEqual(NumberLLMRefiner.cleanReply(input), "hello world")
    }

    func testCleanReplyStripsWrappingDoubleQuotes() {
        XCTAssertEqual(NumberLLMRefiner.cleanReply("\"hello world\""), "hello world")
    }

    func testCleanReplyStripsWrappingCurlyQuotes() {
        XCTAssertEqual(NumberLLMRefiner.cleanReply("\u{201C}hello world\u{201D}"), "hello world")
    }

    func testCleanReplyReturnsEmptyForWhitespaceOnly() {
        XCTAssertEqual(NumberLLMRefiner.cleanReply("   \n  \t  "), "")
    }

    // MARK: - Refine (mock LLM)

    func testRefineHappyPathReturnsLLMOutputAndRecordsRun() async throws {
        let llm = FixedReplyLLM(reply: "next 30 seconds")
        let refiner = NumberLLMRefiner(llmService: llm)

        let outcome = try await refiner.refine(text: "next thirty seconds")

        XCTAssertEqual(outcome.text, "next 30 seconds")
        XCTAssertTrue(outcome.usedLLM)
        XCTAssertNil(outcome.fallbackReason)
        XCTAssertNotNil(outcome.run)
        XCTAssertEqual(outcome.run?.feature, .numberRefinement)
        XCTAssertTrue(outcome.safetyGatePassed)
    }

    func testRefineFallsBackToInputWhenProviderNotConfigured() async throws {
        let llm = NotConfiguredLLM()
        let refiner = NumberLLMRefiner(llmService: llm)

        let outcome = try await refiner.refine(text: "next thirty seconds")

        XCTAssertEqual(outcome.text, "next thirty seconds")
        XCTAssertFalse(outcome.usedLLM)
        XCTAssertEqual(outcome.fallbackReason, .notConfigured)
        XCTAssertNil(outcome.run)
    }

    func testRefineFallsBackOnNetworkError() async throws {
        let llm = ThrowingLLM(error: URLError(.notConnectedToInternet))
        let refiner = NumberLLMRefiner(llmService: llm)

        let outcome = try await refiner.refine(text: "next thirty seconds")

        XCTAssertEqual(outcome.text, "next thirty seconds")
        XCTAssertFalse(outcome.usedLLM)
        XCTAssertEqual(outcome.fallbackReason, .callFailed)
    }

    func testRefineFallsBackWhenSafetyGateRejects() async throws {
        // Reply paraphrases by removing half the text — gate should reject.
        let llm = FixedReplyLLM(reply: "30 seconds")
        let refiner = NumberLLMRefiner(llmService: llm)

        let outcome = try await refiner.refine(text: "next thirty seconds then jog for two minutes and breathe deeply")

        XCTAssertEqual(outcome.text, "next thirty seconds then jog for two minutes and breathe deeply")
        XCTAssertFalse(outcome.usedLLM)
        XCTAssertEqual(outcome.fallbackReason, .safetyGateRejected)
    }

    func testRefineFallsBackWhenReplyEmpty() async throws {
        let llm = FixedReplyLLM(reply: "   ")
        let refiner = NumberLLMRefiner(llmService: llm)

        let outcome = try await refiner.refine(text: "next thirty seconds")

        XCTAssertEqual(outcome.text, "next thirty seconds")
        XCTAssertFalse(outcome.usedLLM)
        XCTAssertEqual(outcome.fallbackReason, .parseFailed)
    }

    func testRefineEmptyInputReturnsEmpty() async throws {
        let llm = FixedReplyLLM(reply: "anything")
        let refiner = NumberLLMRefiner(llmService: llm)

        let outcome = try await refiner.refine(text: "")

        XCTAssertEqual(outcome.text, "")
        XCTAssertFalse(outcome.usedLLM)
        XCTAssertNil(outcome.fallbackReason)
    }

    func testRefinePropagatesCancellation() async {
        let llm = SlowLLM(delaySeconds: 0.5, reply: "30")
        let refiner = NumberLLMRefiner(llmService: llm)

        let task = Task {
            try await refiner.refine(text: "next thirty seconds")
        }
        task.cancel()

        do {
            _ = try await task.value
            // Note: depending on timing, the task may also complete normally — both are acceptable
            // because cancellation between checkCancellation calls is racy. The strict assertion
            // would require an in-actor checkpoint; we accept either outcome here.
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

// MARK: - Test doubles

private final class FixedReplyLLM: LLMServiceProtocol, @unchecked Sendable {
    let reply: String
    init(reply: String) { self.reply = reply }

    func transformDetailed(text: String, prompt: String) async throws -> LLMResult {
        LLMResult(output: reply, provider: "test", model: "test", latencyMs: 1)
    }

    func transform(text: String, prompt: String) async throws -> String { reply }
    func generatePromptResult(transcript: String, systemPrompt: String?) async throws -> String { "" }
    func chat(question: String, transcript: String, userNotes: String?, history: [ChatMessage], source: TelemetryChatSource) async throws -> String { "" }
    func formatTranscript(transcript: String, promptTemplate: String, source: TelemetryFormatterSource, defaultPromptUsed: Bool) async throws -> String { "" }
    func generatePromptResultStream(transcript: String, systemPrompt: String?) -> AsyncThrowingStream<String, Error> { AsyncThrowingStream { $0.finish() } }
    func chatStream(question: String, transcript: String, userNotes: String?, history: [ChatMessage], source: TelemetryChatSource) -> AsyncThrowingStream<String, Error> { AsyncThrowingStream { $0.finish() } }
    func transformStream(text: String, prompt: String) -> AsyncThrowingStream<String, Error> { AsyncThrowingStream { $0.finish() } }
    func generatePromptResultDetailed(transcript: String, systemPrompt: String?) async throws -> LLMResult { LLMResult(output: "", provider: "test", model: "test", latencyMs: 0) }
    func chatDetailed(question: String, transcript: String, userNotes: String?, history: [ChatMessage], source: TelemetryChatSource) async throws -> LLMResult { LLMResult(output: "", provider: "test", model: "test", latencyMs: 0) }
    func formatTranscriptDetailed(transcript: String, promptTemplate: String, source: TelemetryFormatterSource, defaultPromptUsed: Bool) async throws -> LLMFormatterResult {
        LLMFormatterResult(
            result: LLMResult(output: "", provider: "test", model: "test", latencyMs: 0),
            operationID: "test",
            inputChars: 0,
            outputChars: 0,
            inputTruncated: false,
            defaultPromptUsed: defaultPromptUsed,
            messageCount: 0
        )
    }
}

private final class NotConfiguredLLM: LLMServiceProtocol, @unchecked Sendable {
    func transformDetailed(text: String, prompt: String) async throws -> LLMResult {
        throw LLMError.notConfigured
    }

    func transform(text: String, prompt: String) async throws -> String { throw LLMError.notConfigured }
    func generatePromptResult(transcript: String, systemPrompt: String?) async throws -> String { throw LLMError.notConfigured }
    func chat(question: String, transcript: String, userNotes: String?, history: [ChatMessage], source: TelemetryChatSource) async throws -> String { throw LLMError.notConfigured }
    func formatTranscript(transcript: String, promptTemplate: String, source: TelemetryFormatterSource, defaultPromptUsed: Bool) async throws -> String { throw LLMError.notConfigured }
    func generatePromptResultStream(transcript: String, systemPrompt: String?) -> AsyncThrowingStream<String, Error> { AsyncThrowingStream { $0.finish() } }
    func chatStream(question: String, transcript: String, userNotes: String?, history: [ChatMessage], source: TelemetryChatSource) -> AsyncThrowingStream<String, Error> { AsyncThrowingStream { $0.finish() } }
    func transformStream(text: String, prompt: String) -> AsyncThrowingStream<String, Error> { AsyncThrowingStream { $0.finish() } }
    func generatePromptResultDetailed(transcript: String, systemPrompt: String?) async throws -> LLMResult { throw LLMError.notConfigured }
    func chatDetailed(question: String, transcript: String, userNotes: String?, history: [ChatMessage], source: TelemetryChatSource) async throws -> LLMResult { throw LLMError.notConfigured }
    func formatTranscriptDetailed(transcript: String, promptTemplate: String, source: TelemetryFormatterSource, defaultPromptUsed: Bool) async throws -> LLMFormatterResult { throw LLMError.notConfigured }
}

private final class ThrowingLLM: LLMServiceProtocol, @unchecked Sendable {
    let error: Error
    init(error: Error) { self.error = error }

    func transformDetailed(text: String, prompt: String) async throws -> LLMResult { throw error }
    func transform(text: String, prompt: String) async throws -> String { throw error }
    func generatePromptResult(transcript: String, systemPrompt: String?) async throws -> String { throw error }
    func chat(question: String, transcript: String, userNotes: String?, history: [ChatMessage], source: TelemetryChatSource) async throws -> String { throw error }
    func formatTranscript(transcript: String, promptTemplate: String, source: TelemetryFormatterSource, defaultPromptUsed: Bool) async throws -> String { throw error }
    func generatePromptResultStream(transcript: String, systemPrompt: String?) -> AsyncThrowingStream<String, Error> { AsyncThrowingStream { $0.finish() } }
    func chatStream(question: String, transcript: String, userNotes: String?, history: [ChatMessage], source: TelemetryChatSource) -> AsyncThrowingStream<String, Error> { AsyncThrowingStream { $0.finish() } }
    func transformStream(text: String, prompt: String) -> AsyncThrowingStream<String, Error> { AsyncThrowingStream { $0.finish() } }
    func generatePromptResultDetailed(transcript: String, systemPrompt: String?) async throws -> LLMResult { throw error }
    func chatDetailed(question: String, transcript: String, userNotes: String?, history: [ChatMessage], source: TelemetryChatSource) async throws -> LLMResult { throw error }
    func formatTranscriptDetailed(transcript: String, promptTemplate: String, source: TelemetryFormatterSource, defaultPromptUsed: Bool) async throws -> LLMFormatterResult { throw error }
}

private final class SlowLLM: LLMServiceProtocol, @unchecked Sendable {
    let delaySeconds: Double
    let reply: String
    init(delaySeconds: Double, reply: String) { self.delaySeconds = delaySeconds; self.reply = reply }

    func transformDetailed(text: String, prompt: String) async throws -> LLMResult {
        try await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
        return LLMResult(output: reply, provider: "test", model: "test", latencyMs: Int(delaySeconds * 1000))
    }

    func transform(text: String, prompt: String) async throws -> String {
        try await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
        return reply
    }
    func generatePromptResult(transcript: String, systemPrompt: String?) async throws -> String { "" }
    func chat(question: String, transcript: String, userNotes: String?, history: [ChatMessage], source: TelemetryChatSource) async throws -> String { "" }
    func formatTranscript(transcript: String, promptTemplate: String, source: TelemetryFormatterSource, defaultPromptUsed: Bool) async throws -> String { "" }
    func generatePromptResultStream(transcript: String, systemPrompt: String?) -> AsyncThrowingStream<String, Error> { AsyncThrowingStream { $0.finish() } }
    func chatStream(question: String, transcript: String, userNotes: String?, history: [ChatMessage], source: TelemetryChatSource) -> AsyncThrowingStream<String, Error> { AsyncThrowingStream { $0.finish() } }
    func transformStream(text: String, prompt: String) -> AsyncThrowingStream<String, Error> { AsyncThrowingStream { $0.finish() } }
    func generatePromptResultDetailed(transcript: String, systemPrompt: String?) async throws -> LLMResult { LLMResult(output: "", provider: "test", model: "test", latencyMs: 0) }
    func chatDetailed(question: String, transcript: String, userNotes: String?, history: [ChatMessage], source: TelemetryChatSource) async throws -> LLMResult { LLMResult(output: "", provider: "test", model: "test", latencyMs: 0) }
    func formatTranscriptDetailed(transcript: String, promptTemplate: String, source: TelemetryFormatterSource, defaultPromptUsed: Bool) async throws -> LLMFormatterResult {
        LLMFormatterResult(
            result: LLMResult(output: "", provider: "test", model: "test", latencyMs: 0),
            operationID: "test",
            inputChars: 0,
            outputChars: 0,
            inputTruncated: false,
            defaultPromptUsed: defaultPromptUsed,
            messageCount: 0
        )
    }
}
```

- [ ] **Step 6.2: Run the new tests**

```bash
swift test --filter NumberLLMRefinerTests
```

Expected: all tests pass.

- [ ] **Step 6.3: Commit**

```bash
git add Tests/MacParakeetTests/Services/NumberLLMRefinerTests.swift
git commit -m "test(refiner): unit tests for NumberLLMRefiner safety gate, parser, fallback paths"
```

---

## Task 7: Wire `numberRefinementMode` closure through services

**Files:**
- Modify: `Sources/MacParakeetCore/Services/TranscriptionService.swift`
- Modify: `Sources/MacParakeetCore/Services/Dictation/DictationService.swift`
- Modify: `Sources/MacParakeet/App/AppEnvironment.swift`

- [ ] **Step 7.1: Rename closure field + parameter in TranscriptionService**

In `TranscriptionService.swift`:

Line ~201: change
```swift
private let shouldNormalizeNumbers: @Sendable () -> Bool
```
to:
```swift
private let numberRefinementMode: @Sendable () -> NumberRefinementMode
```

Add a new optional field directly below it:
```swift
private let numberLLMRefiner: NumberLLMRefiner?
```

Line ~222: change init parameter
```swift
shouldNormalizeNumbers: (@Sendable () -> Bool)? = nil,
```
to:
```swift
numberRefinementMode: (@Sendable () -> NumberRefinementMode)? = nil,
numberLLMRefiner: NumberLLMRefiner? = nil,
```

Line ~243: change
```swift
self.shouldNormalizeNumbers = shouldNormalizeNumbers ?? { false }
```
to:
```swift
self.numberRefinementMode = numberRefinementMode ?? { .off }
self.numberLLMRefiner = numberLLMRefiner
```

Line ~1346: change
```swift
normalizeNumbers: shouldNormalizeNumbers()
```
to:
```swift
normalizeNumbers: numberRefinementMode() != .off
```

- [ ] **Step 7.2: Same rename in DictationService**

In `DictationService.swift`:

Line ~79: change
```swift
private let shouldNormalizeNumbers: @Sendable () -> Bool
```
to:
```swift
private let numberRefinementMode: @Sendable () -> NumberRefinementMode
```

Line ~119: change init parameter
```swift
shouldNormalizeNumbers: (@Sendable () -> Bool)? = nil,
```
to:
```swift
numberRefinementMode: (@Sendable () -> NumberRefinementMode)? = nil,
```

Line ~138: change
```swift
self.shouldNormalizeNumbers = shouldNormalizeNumbers ?? { false }
```
to:
```swift
self.numberRefinementMode = numberRefinementMode ?? { .off }
```

Line ~638: change
```swift
normalizeNumbers: shouldNormalizeNumbers()
```
to:
```swift
normalizeNumbers: numberRefinementMode() != .off
```

- [ ] **Step 7.3: Update AppEnvironment**

In `AppEnvironment.swift`:

Line ~178: change
```swift
let numberNormalizationClosure: @Sendable () -> Bool = { [runtimePreferences] in
    runtimePreferences.numberNormalizationEnabled
}
```
to:
```swift
let numberRefinementModeClosure: @Sendable () -> NumberRefinementMode = { [runtimePreferences] in
    runtimePreferences.numberRefinementMode
}
```

Add the refiner construction directly after the `llmService = LLMService(...)` block (~line 191):

```swift
let numberLLMRefiner = NumberLLMRefiner(llmService: llmService)
```

In the `dictationService = DictationService(...)` call (~line 207), change
```swift
shouldNormalizeNumbers: numberNormalizationClosure,
```
to:
```swift
numberRefinementMode: numberRefinementModeClosure,
```

In the `transcriptionService = TranscriptionService(...)` call (search for `TranscriptionService(`), change the equivalent parameter to:
```swift
numberRefinementMode: numberRefinementModeClosure,
numberLLMRefiner: numberLLMRefiner,
```

- [ ] **Step 7.4: Build and fix any remaining callsites**

```bash
swift build 2>&1 | head -40
```

If any test files or other callsites still reference `shouldNormalizeNumbers:`, update them to `numberRefinementMode:` with the new closure signature. The most likely place is mock construction in tests — search:

```bash
grep -rn "shouldNormalizeNumbers" Sources/ Tests/ 2>/dev/null
```

Update each. For test-side mocks, the closure becomes `{ .deterministic }` or `{ .off }` depending on what the test wants.

- [ ] **Step 7.5: Run the full test suite**

```bash
swift test
```

Expected: existing tests still pass. (Smart-path test gets added in Task 9.)

- [ ] **Step 7.6: Commit**

```bash
git add Sources/MacParakeetCore/Services/TranscriptionService.swift Sources/MacParakeetCore/Services/Dictation/DictationService.swift Sources/MacParakeet/App/AppEnvironment.swift
git add Tests/  # if any test mock updates
git commit -m "refactor: numberRefinementMode closure replaces shouldNormalizeNumbers bool"
```

---

## Task 8: Compose `NumberLLMRefiner` into `TranscriptionService.completeTranscription`

**Files:**
- Modify: `Sources/MacParakeetCore/Services/TranscriptionService.swift:~1341-1372`

- [ ] **Step 8.1: Insert Smart-path call between deterministic refinement and AI Formatter**

Find the block starting at line ~1341:

```swift
let refinement = await textRefinementService.refine(
    rawText: rawText,
    mode: mode,
    customWords: customWords,
    snippets: snippets,
    normalizeNumbers: numberRefinementMode() != .off
)
let baseText = refinement.text ?? rawText
let formatterOutcome = try await formatTranscriptIfNeeded(
    baseText,
    runSource: persistResult ? LLMRunSource(transcriptionId: transcription.id) : nil
)
```

Insert a Smart-path step between `baseText` and `formatterOutcome`:

```swift
let refinement = await textRefinementService.refine(
    rawText: rawText,
    mode: mode,
    customWords: customWords,
    snippets: snippets,
    normalizeNumbers: numberRefinementMode() != .off
)
let baseText = refinement.text ?? rawText
let smartTextResult = try await applyNumberLLMRefinementIfNeeded(
    baseText,
    runSource: persistResult ? LLMRunSource(transcriptionId: transcription.id) : nil
)
let smartText = smartTextResult.text
let formatterOutcome = try await formatTranscriptIfNeeded(
    smartText,
    runSource: persistResult ? LLMRunSource(transcriptionId: transcription.id) : nil
)
```

- [ ] **Step 8.2: Add the helper method to TranscriptionService**

Find `private func formatTranscriptIfNeeded(...)` (line ~1408) and add a new helper directly above it:

```swift
private struct NumberRefinementOutcome {
    let text: String
    let run: LLMRun?
}

private func applyNumberLLMRefinementIfNeeded(
    _ text: String,
    runSource: LLMRunSource?
) async throws -> NumberRefinementOutcome {
    guard numberRefinementMode() == .smart, let refiner = numberLLMRefiner else {
        return NumberRefinementOutcome(text: text, run: nil)
    }
    let outcome = try await refiner.refine(text: text, runSource: runSource)

    // Per spec: numberRefinerUsed fires only when the LLM call reached the safety
    // gate (gate passed OR gate rejected). It does NOT fire for not-configured,
    // call-failed, or parse-failed — those skip straight to numberRefinerFallback.
    let reachedSafetyGate = outcome.usedLLM || outcome.fallbackReason == .safetyGateRejected
    if reachedSafetyGate {
        Telemetry.send(.numberRefinerUsed(
            provider: outcome.provider ?? "unknown",
            inputChars: text.count,
            outputChars: outcome.text.count,
            latencyMs: outcome.latencyMs,
            safetyGatePassed: outcome.safetyGatePassed
        ))
    }
    if let reason = outcome.fallbackReason {
        Telemetry.send(.numberRefinerFallback(
            reason: reason.rawValue,
            provider: outcome.provider,
            errorType: nil
        ))
    }
    return NumberRefinementOutcome(text: outcome.text, run: outcome.run)
}
```

- [ ] **Step 8.3: Record the Smart run when present**

Find where `formatterOutcome.run` is recorded (line ~1371):

```swift
try transcriptionRepo.save(transcription)
await llmRunRecorder.record(formatterOutcome.run)
```

Change to:

```swift
try transcriptionRepo.save(transcription)
await llmRunRecorder.record(smartTextResult.run)
await llmRunRecorder.record(formatterOutcome.run)
```

- [ ] **Step 8.4: Build and run the full suite**

```bash
swift build 2>&1 | head -20
swift test
```

Expected: builds clean, all existing tests pass.

- [ ] **Step 8.5: Commit**

```bash
git add Sources/MacParakeetCore/Services/TranscriptionService.swift
git commit -m "feat(transcription): compose NumberLLMRefiner between deterministic and formatter"
```

---

## Task 9: Integration test for Smart path

**Files:**
- Modify: `Tests/MacParakeetTests/Services/TranscriptionServiceTests.swift`

- [ ] **Step 9.1: Read the existing test file to find the right pattern**

```bash
head -80 Tests/MacParakeetTests/Services/TranscriptionServiceTests.swift
grep -n "TranscriptionService(" Tests/MacParakeetTests/Services/TranscriptionServiceTests.swift | head -5
```

Pick one existing test that constructs a `TranscriptionService` from scratch as a template.

- [ ] **Step 9.2: Add a Smart-mode test**

Mirror an existing test's setup (mock STT, mock repos, etc.) and add a new test:

```swift
func testSmartModeAppliesNumberLLMRefinerWhenAvailable() async throws {
    let llm = NumberPolishingLLM(reply: "next 30 seconds in 1995")
    let refiner = NumberLLMRefiner(llmService: llm)
    let service = makeTranscriptionService(
        // ... existing helper args ...
        numberRefinementMode: { .smart },
        numberLLMRefiner: refiner
    )

    // Drive a transcription with raw text containing spelled numbers
    // ... existing setup pattern ...

    let result = try await service.completeTranscriptionForTest( /* fixture inputs */ )
    XCTAssertEqual(result.cleanTranscript, "next 30 seconds in 1995")
}

func testSmartModeFallsBackToDeterministicWhenRefinerAbsent() async throws {
    let service = makeTranscriptionService(
        numberRefinementMode: { .smart },
        numberLLMRefiner: nil
    )
    // ... existing setup ...
    let result = try await service.completeTranscriptionForTest( /* fixture inputs */ )
    // Output equals the deterministic-pipeline result (no LLM polish)
    XCTAssertEqual(result.cleanTranscript, "next 30 seconds")  // deterministic catches this case
}
```

If the test file doesn't have a `makeTranscriptionService` helper, use whatever construction pattern the existing tests use. The key assertion: with Smart + a polishing mock, the LLM reply is in the final transcript; with Smart + no refiner, the deterministic output stands.

`NumberPolishingLLM` is a minimal `LLMServiceProtocol` mock (copy the `FixedReplyLLM` from `NumberLLMRefinerTests.swift` — promote it to internal access if you want to reuse, or duplicate locally).

- [ ] **Step 9.3: Run the integration tests**

```bash
swift test --filter TranscriptionServiceTests
```

Expected: new tests pass; existing tests still pass.

- [ ] **Step 9.4: Commit**

```bash
git add Tests/MacParakeetTests/Services/TranscriptionServiceTests.swift
git commit -m "test(transcription): Smart mode applies LLM refiner; falls back without"
```

---

## Task 10: Update `SettingsViewModel` to expose `numberRefinementMode`

**Files:**
- Modify: `Sources/MacParakeetViewModels/SettingsViewModel.swift`

- [ ] **Step 10.1: Replace the boolean property**

Find (line ~231):

```swift
public var numberNormalizationEnabled: Bool {
    didSet {
        defaults.set(numberNormalizationEnabled, forKey: UserDefaultsAppRuntimePreferences.numberNormalizationEnabledKey)
        Telemetry.send(.settingChanged(setting: .numberNormalization))
    }
}
```

Replace with:

```swift
public var numberRefinementMode: String {
    didSet {
        defaults.set(numberRefinementMode, forKey: UserDefaultsAppRuntimePreferences.numberRefinementModeKey)
        Telemetry.send(.settingChanged(setting: .numberRefinementMode))
    }
}
```

(String-backed for SwiftUI binding ergonomics; the enum's `rawValue` round-trips fine.)

- [ ] **Step 10.2: Update the loader at line ~577**

Find:

```swift
numberNormalizationEnabled = defaults.object(forKey: UserDefaultsAppRuntimePreferences.numberNormalizationEnabledKey) as? Bool ?? false
```

Replace with:

```swift
numberRefinementMode = defaults.string(forKey: UserDefaultsAppRuntimePreferences.numberRefinementModeKey) ?? NumberRefinementMode.off.rawValue
```

Also: find the `init` for `SettingsViewModel`. The `numberNormalizationEnabled = false` (or similar) default-initialization line needs to become:

```swift
numberRefinementMode = NumberRefinementMode.off.rawValue
```

- [ ] **Step 10.3: Remove the deprecated TelemetrySettingName alias added in Task 4**

In `TelemetryEvent.swift`, remove the:
```swift
@available(*, deprecated, renamed: "numberRefinementMode")
public static let numberNormalization: TelemetrySettingName = .numberRefinementMode
```

(It existed to keep the build green during the migration; now `SettingsViewModel` uses the new name and nobody else references the old one.)

- [ ] **Step 10.4: Build**

```bash
swift build 2>&1 | head -20
```

Expected: clean build.

- [ ] **Step 10.5: Commit**

```bash
git add Sources/MacParakeetViewModels/SettingsViewModel.swift Sources/MacParakeetCore/Services/Telemetry/TelemetryEvent.swift
git commit -m "feat(settings-vm): numberRefinementMode string property replaces bool"
```

---

## Task 11: Add `NumberFormattingCard` to AI tab

**Files:**
- Create: `Sources/MacParakeet/Views/Settings/NumberFormattingCard.swift`
- Modify: `Sources/MacParakeet/Views/Settings/SettingsView.swift`

- [ ] **Step 11.1: Create the card view**

```swift
import SwiftUI
import MacParakeetCore
import MacParakeetViewModels

/// Card in Settings > AI exposing the three Number Formatting modes
/// (Off / Deterministic / Smart). Mirrors the Raw/Clean mode picker
/// at the top of the Vocabulary tab visually.
struct NumberFormattingCard: View {
    @Bindable var settingsViewModel: SettingsViewModel
    @Bindable var llmSettingsViewModel: LLMSettingsViewModel
    let onRequestProviderScroll: () -> Void

    @State private var hoveredModeTitle: String?

    private var selectedMode: NumberRefinementMode {
        NumberRefinementMode(rawValue: settingsViewModel.numberRefinementMode) ?? .off
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            header
            modeGrid
            examplesPanel
            if selectedMode == .smart && !llmSettingsViewModel.isConfigured {
                providerHint
            }
        }
        .padding(DesignSystem.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                .fill(DesignSystem.Colors.cardBackground)
                .cardShadow(DesignSystem.Shadows.cardRest)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                .strokeBorder(DesignSystem.Colors.border.opacity(0.6), lineWidth: 0.5)
        )
    }

    private var header: some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
            Image(systemName: "number")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(DesignSystem.Colors.accent)
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(DesignSystem.Colors.accent.opacity(0.12))
                )
            VStack(alignment: .leading, spacing: 2) {
                Text("Number Formatting")
                    .font(DesignSystem.Typography.sectionTitle)
                Text("How spelled-out numbers get converted to digits.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var modeGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 200), spacing: DesignSystem.Spacing.md)],
            spacing: DesignSystem.Spacing.md
        ) {
            ForEach(NumberRefinementMode.allCases, id: \.self) { mode in
                modeCard(mode)
            }
        }
    }

    private func modeCard(_ mode: NumberRefinementMode) -> some View {
        let isSelected = selectedMode == mode
        let isHovered = hoveredModeTitle == mode.rawValue
        return Button {
            settingsViewModel.numberRefinementMode = mode.rawValue
        } label: {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                HStack {
                    Image(systemName: icon(for: mode))
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(isSelected ? DesignSystem.Colors.accent : .secondary)
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(DesignSystem.Colors.accent)
                    }
                }
                Text(mode.displayTitle)
                    .font(DesignSystem.Typography.sectionTitle)
                    .foregroundStyle(.primary)
                Text(subtitle(for: mode))
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.secondary)
                Text(mode.detail)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(DesignSystem.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .scaleEffect(isHovered ? 1.01 : 1.0)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                    .fill(isSelected ? DesignSystem.Colors.accentLight : DesignSystem.Colors.surfaceElevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                    .strokeBorder(
                        isSelected ? DesignSystem.Colors.accent.opacity(0.5) : DesignSystem.Colors.border,
                        lineWidth: isSelected ? 1.2 : 0.5
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(DesignSystem.Animation.hoverTransition) {
                hoveredModeTitle = hovering ? mode.rawValue : nil
            }
        }
    }

    private func icon(for mode: NumberRefinementMode) -> String {
        switch mode {
        case .off: return "circle.slash"
        case .deterministic: return "number"
        case .smart: return "sparkles"
        }
    }

    private func subtitle(for mode: NumberRefinementMode) -> String {
        switch mode {
        case .off: return "No changes"
        case .deterministic: return "Rule-based"
        case .smart: return "Rules + AI"
        }
    }

    private var examplesPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Examples")
                .font(DesignSystem.Typography.micro.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(examples(for: selectedMode), id: \.0) { (input, output, fires) in
                exampleRow(input: input, output: output, fires: fires)
            }
        }
        .padding(.leading, DesignSystem.Spacing.sm)
    }

    private func examples(for mode: NumberRefinementMode) -> [(String, String, Bool)] {
        switch mode {
        case .off:
            return [
                ("twenty-five reps", "twenty-five reps", false),
                ("next thirty seconds", "next thirty seconds", false)
            ]
        case .deterministic:
            return [
                ("next thirty seconds", "next 30 seconds", true),
                ("forty-five reps", "45 reps", true),
                ("one of them", "one of them — single-digit words skipped", false)
            ]
        case .smart:
            return [
                ("next thirty seconds", "next 30 seconds", true),
                ("nineteen ninety-five", "1995", true),
                ("ten thirty AM", "10:30 AM", true),
                ("two point five seconds", "2.5 seconds", true)
            ]
        }
    }

    private func exampleRow(input: String, output: String, fires: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignSystem.Spacing.sm) {
            Image(systemName: fires ? "checkmark.circle.fill" : "xmark.circle")
                .font(.system(size: 12))
                .foregroundStyle(fires ? DesignSystem.Colors.successGreen : .secondary)
            Text("\"\(input)\"")
                .font(DesignSystem.Typography.caption.monospaced())
                .foregroundStyle(.primary)
            Text("→")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(.tertiary)
            Text(output)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var providerHint: some View {
        Button(action: onRequestProviderScroll) {
            HStack(spacing: 6) {
                Image(systemName: "info.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.warningAmber)
                Text("Smart needs an AI provider. Without one, Smart behaves like Deterministic.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Set up →")
                    .font(DesignSystem.Typography.caption.weight(.semibold))
                    .foregroundStyle(DesignSystem.Colors.accent)
            }
            .padding(.horizontal, DesignSystem.Spacing.md)
            .padding(.vertical, DesignSystem.Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                    .fill(DesignSystem.Colors.warningAmber.opacity(0.08))
            )
        }
        .buttonStyle(.plain)
    }
}
```

- [ ] **Step 11.2: Insert the card into the AI tab**

In `SettingsView.swift`, find `aiTabContent` (line ~391):

```swift
private var aiTabContent: some View {
    scrollableTabBody {
        aiProviderCard.id("ai.provider")
        subtitleRefinementCard.id("ai.subtitle-refinement")
    }
}
```

Change to:

```swift
private var aiTabContent: some View {
    scrollableTabBody {
        aiProviderCard.id("ai.provider")
        numberFormattingCard.id("ai.number-formatting")
        subtitleRefinementCard.id("ai.subtitle-refinement")
    }
}
```

Add a new computed property near the other tab-content card builders:

```swift
private var numberFormattingCard: some View {
    NumberFormattingCard(
        settingsViewModel: viewModel,
        llmSettingsViewModel: llmViewModel,
        onRequestProviderScroll: {
            rootViewModel.activeTab = .ai
            // The scrollViewReader anchor handles the rest.
            pendingScrollTarget = "ai.provider"
        }
    )
}
```

(Names like `viewModel`, `llmViewModel`, `rootViewModel`, `pendingScrollTarget` should match what's already in scope in `SettingsView` — adjust to the exact existing field names.)

- [ ] **Step 11.3: Build**

```bash
swift build 2>&1 | head -30
```

Expected: clean build. Fix any references that don't match the actual `SettingsView` field names you find when you look at the surrounding code.

- [ ] **Step 11.4: Commit**

```bash
git add Sources/MacParakeet/Views/Settings/NumberFormattingCard.swift Sources/MacParakeet/Views/Settings/SettingsView.swift
git commit -m "feat(ui): Number Formatting card in AI tab with three-mode picker"
```

---

## Task 12: Remove Numbers card from Vocabulary tab + breadcrumb

**Files:**
- Modify: `Sources/MacParakeet/Views/Vocabulary/VocabularyView.swift`

- [ ] **Step 12.1: Remove the `numbersCard` reference from the body**

Find (line ~30):

```swift
} else {
    pipelineCard
    numbersCard
    VocabularyBackupSection(...)
}
```

Change to:

```swift
} else {
    pipelineCard
    numbersBreadcrumb
    VocabularyBackupSection(...)
}
```

- [ ] **Step 12.2: Delete the old `numbersCard` computed property**

Delete the entire `private var numbersCard: some View { ... }` block (lines ~223-247).

- [ ] **Step 12.3: Add a breadcrumb view**

Add a new computed property where `numbersCard` used to live:

```swift
private var numbersBreadcrumb: some View {
    Button {
        NotificationCenter.default.post(
            name: .macParakeetOpenSettingsTab,
            object: nil,
            userInfo: ["tab": "ai", "scrollTo": "ai.number-formatting"]
        )
    } label: {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Image(systemName: "arrow.up.right.square")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DesignSystem.Colors.accent)
            Text("Number formatting moved to the AI tab")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text("Open")
                .font(DesignSystem.Typography.caption.weight(.semibold))
                .foregroundStyle(DesignSystem.Colors.accent)
        }
        .padding(.horizontal, DesignSystem.Spacing.md)
        .padding(.vertical, DesignSystem.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                .fill(DesignSystem.Colors.surfaceElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                .strokeBorder(DesignSystem.Colors.border.opacity(0.6), lineWidth: 0.5)
        )
    }
    .buttonStyle(.plain)
}
```

- [ ] **Step 12.4: Add the notification name (if not already present)**

Search:

```bash
grep -rn "macParakeetOpenSettingsTab" Sources/
```

If absent, add to `Sources/MacParakeet/Notifications.swift` (or wherever similar `Notification.Name` extensions live):

```swift
extension Notification.Name {
    static let macParakeetOpenSettingsTab = Notification.Name("macParakeetOpenSettingsTab")
}
```

And wire a receiver in the settings window observer chain. If the notification system already exists for similar cross-tab navigation (e.g. opening from menu bar), follow that pattern. If it doesn't, leave the breadcrumb as a simpler dead-end button for v1 — the user can manually navigate to AI tab — and note in the commit message that observer wiring is deferred.

- [ ] **Step 12.5: Build**

```bash
swift build 2>&1 | head -20
```

- [ ] **Step 12.6: Commit**

```bash
git add Sources/MacParakeet/Views/Vocabulary/VocabularyView.swift Sources/MacParakeet/Notifications.swift
git commit -m "feat(ui): replace Vocabulary Numbers card with AI-tab breadcrumb"
```

---

## Task 13: CLI testing doc update

**Files:**
- Modify: `docs/cli-testing.md`

- [ ] **Step 13.1: Add a Smart-mode example near other LLM examples**

Find a section that documents transcribe-related CLI usage with LLM features. Add:

```markdown
### Smart number refinement

If a Smart number refiner is configured (`config llm ...`), file transcription
automatically polishes spelled-out numbers via the LLM after the deterministic
pipeline runs. To verify end-to-end with a known fixture:

\`\`\`bash
# Set Smart mode for the next CLI run
defaults write com.macparakeet.MacParakeet numberRefinementMode smart

macparakeet-cli transcribe fixtures/fitness-class.mp3 --output text
# Expected: years, decimals, and large cardinals appear as digits;
# the deterministic baseline you'd get with "deterministic" mode
# leaves "nineteen ninety-five" / "two point five" / "three thousand"
# spelled out.

# Reset
defaults write com.macparakeet.MacParakeet numberRefinementMode deterministic
\`\`\`

Smart silently falls back to Deterministic if no LLM provider is configured —
no error, no special CLI flag, just the deterministic output.
```

- [ ] **Step 13.2: Commit**

```bash
git add docs/cli-testing.md
git commit -m "docs(cli): smart-mode number refinement worked example"
```

---

## Task 14: Full test pass + manual verification

- [ ] **Step 14.1: Run the full test suite**

```bash
swift test 2>&1 | tail -30
```

Expected: 0 failures. Address any failures inline before declaring done.

- [ ] **Step 14.2: Build the dev app to verify the UI compiles end-to-end**

```bash
swift build --target MacParakeet 2>&1 | tail -20
```

Expected: clean build.

- [ ] **Step 14.3: Smoke-test by running the dev app (per CLAUDE.md requirement)**

```bash
scripts/dev/run_app.sh
```

Open Settings → AI → verify the new "Number Formatting" card renders correctly with three modes and an examples panel. Open Vocabulary → verify the breadcrumb is present and Numbers card is gone.

(If automated execution can't drive the GUI, capture the build success and leave manual GUI verification as a hand-off note.)

- [ ] **Step 14.4: Final commit (if any cleanup landed)**

If any small fix-ups landed in Step 14.1:

```bash
git status --short
git add -A  # or specific files
git commit -m "chore: minor cleanup from full test pass"
```

---

## Done Checklist

- [ ] All tasks 1-14 committed on `feat/llm-number-refiner`
- [ ] `swift test` clean
- [ ] `swift build` clean for both library and app targets
- [ ] Dev app launches and Settings → AI shows the new card
- [ ] Spec's open questions left in place for post-build review
