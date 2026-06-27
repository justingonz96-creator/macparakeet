# Nemotron European-Language STT Engine — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add NVIDIA Nemotron 3.5 ASR Streaming Multilingual 0.6B (via FluidAudio 0.15.4, CoreML/ANE) as a third optional, opt-in STT engine for European/Latin-script audio (EN/ES/FR/IT/PT/DE), built behind a disabled feature flag and never shipped until its license clears.

**Architecture:** Mirror the existing `WhisperEngine` optional-engine template. A new `NemotronEngine` actor wraps FluidAudio's `StreamingNemotronMultilingualAsrManager`, driven in a feed-whole-file-then-finish pattern to fit Echo's batch transcription contract (ADR-016). A third `SpeechEnginePreference.nemotron` case routes through the existing `STTRuntime`/`STTScheduler`; the scheduler needs no structural change. Every user-facing surface (and the runtime model download) is gated behind a new `AppFeatures.nemotronEnabled = false`.

**Tech Stack:** Swift 6, FluidAudio 0.15.4 (CoreML/ANE), GRDB, SwiftUI, XCTest, swift-argument-parser.

**Spec:** [ADR-023](../../spec/adr/023-nemotron-european-stt.md). Read it before starting.

---

## Pre-Flight (read once before Task 1)

**Baseline.** From the repo root, run `swift test` and confirm a green baseline before any change. Record the pass count.

**Flag-off testing strategy.** `AppFeatures.nemotronEnabled` is a compile-time `let false`. Tests therefore target:
1. **Flag-independent logic** — the enum case, language catalog, selection language-carry, language normalization, CLI `resolveSpeechEngine`, telemetry model-kind, and `NemotronEngine`'s pure token→word mapping all work regardless of the flag.
2. **Flag-off gating behavior** — that flag-gated surfaces (CLI `--engine nemotron`, any download trigger) are correctly refused/hidden while the flag is `false` (the shipping state).

We do **not** write tests that require the flag to be `true`, and we never download the real model in unit tests (mock/stub, exactly as the Whisper path is tested).

**FluidAudio-verify discipline.** FluidAudio is pre-1.0 and moves fast. The Nemotron API in this plan is transcribed from source at tag `v0.15.4` (commit `b9d43724`). Phase 0 pins the exact resolved version; Task 2.x includes explicit "verify the signature against the resolved package" steps. If a signature differs from what's shown here, adapt the call and note it — the *shape* of the integration (load → setLanguage → process(samples:) → finishWithTokenTimings → reset) is stable; exact argument labels may drift.

**Commits.** One commit per task (or per tightly-related step group), as the steps indicate. Keep the tree green at every commit.

---

## File Structure

**New files:**
- `Sources/MacParakeetCore/STT/NemotronEngine.swift` — actor wrapping FluidAudio's `StreamingNemotronMultilingualAsrManager`; batch-over-streaming; token→word timing; conforms to `STTTranscribing`.
- `Sources/MacParakeetCore/NemotronLanguageCatalog.swift` — the 6-language European allowlist + canonicalization (parallel to `WhisperLanguageCatalog`, but closed to EN/ES/FR/IT/PT/DE).
- `Tests/MacParakeetTests/STT/NemotronEngineTests.swift` — token→word mapping + model-folder resolution.
- `Tests/MacParakeetTests/STT/NemotronLanguageCatalogTests.swift` — only the 6 codes accepted.

**Modified files (with primary responsibility):**
- `Package.swift` — FluidAudio 0.14.5 → 0.15.4.
- `Sources/MacParakeetCore/AppFeatures.swift` — `nemotronEnabled` flag.
- `Sources/MacParakeetCore/SpeechEnginePreference.swift` — `.nemotron` case, `displayName`, `alternative`, selection language-carry, Nemotron default-language key + accessors, `normalizeNemotronLanguage`.
- `Sources/MacParakeetCore/Services/AppPaths.swift` — `nemotronModelsDir`.
- `Sources/MacParakeetCore/STT/STTRuntime.swift` — `.nemotron` routing/warm-up/isReady/switch/teardown/telemetry.
- `Sources/MacParakeetCore/Services/Telemetry/TelemetryEvent.swift` — `TelemetryModelKind.nemotronSTT`.
- `Sources/MacParakeetCore/Services/Capture/LiveChunkTranscriber.swift` — pinned-engine guard.
- `Sources/CLI/Commands/{TranscribeCommand,ModelsCommand,ConfigCommand}.swift` + `Sources/CLI/CHANGELOG.md`.
- `Sources/MacParakeet/Views/Settings/{SettingsView,SettingsStatusRules,Components/...}.swift`, `Sources/MacParakeetViewModels/{SettingsViewModel,TranscriptionViewModel}.swift`, `Sources/MacParakeet/Views/Transcription/TranscriptResultView.swift` — all flag-gated UI.
- Various test files updated for the grown enum.
- Docs: `spec/06-stt-engine.md`, `spec/README.md`, `spec/02-features.md`, `Sources/MacParakeetCore/STT/README.md`.

---

# Phase 0 — Keystone: FluidAudio 0.14.5 → 0.15.4

Lands and verifies on its own, before any Nemotron code. The bump is source-compatible for every FluidAudio symbol Echo uses; the only risk is behavioral drift in Parakeet.

### Task 0.1: Bump FluidAudio and re-resolve

**Files:**
- Modify: `Package.swift:11` (the FluidAudio dependency line)

- [ ] **Step 1: Edit the dependency pin**

In `Package.swift`, change:

```swift
    .package(url: "https://github.com/FluidInference/FluidAudio", .upToNextMinor(from: "0.14.5")),
```

to:

```swift
    .package(url: "https://github.com/FluidInference/FluidAudio", .upToNextMinor(from: "0.15.4")),
```

- [ ] **Step 2: Re-resolve and confirm the version**

Run: `swift package resolve && grep -A4 '"identity" : "fluidaudio"' Package.resolved`
Expected: `"version" : "0.15.4"` (or a higher 0.15.x patch).

- [ ] **Step 3: Build the core library against the new package**

Run: `swift build --target MacParakeetCore`
Expected: builds with no errors. (If a FluidAudio symbol the app uses changed unexpectedly, fix the call site per the compiler error — the verified delta says none should, but adapt if the resolved patch differs.)

- [ ] **Step 4: Run the full suite for regression**

Run: `swift test`
Expected: PASS, same count as the Pre-Flight baseline.

- [ ] **Step 5: Behavioral drift check (manual, non-blocking record)**

Run the STT-focused tests explicitly and note any output/timing changes:
Run: `swift test --filter STT`
Expected: PASS. Record in the commit body if any assertion needed adjusting due to v3 decoder changes (none expected; this is a watch-item from ADR-023 §12).

- [ ] **Step 6: Commit**

```bash
git add Package.swift Package.resolved
git commit -m "build(deps): bump FluidAudio 0.14.5 -> 0.15.4 (keystone for Nemotron)"
```

---

# Phase 1 — Foundation: flag, language catalog, engine enum

No engine yet. Pure, fully unit-testable logic. After this phase the project still builds and ships identically (flag off, no new engine reachable).

### Task 1.1: Add the `nemotronEnabled` feature flag

**Files:**
- Modify: `Sources/MacParakeetCore/AppFeatures.swift` (append a new static let after `transformsEnabled`)

- [ ] **Step 1: Add the flag with a gated-surface doc comment**

In `Sources/MacParakeetCore/AppFeatures.swift`, inside `enum AppFeatures`, after the `transformsEnabled` declaration, add:

```swift
    /// Nemotron European STT engine (ADR-023). When `false`:
    /// - the Settings Nemotron engine tile + language card + model-download row are hidden
    /// - no default-engine/meeting-pin resolution may select Nemotron
    /// - the CLI `transcribe --engine nemotron` value is rejected at runtime
    /// - NO code path may fetch the FluidInference CoreML artifact
    /// - no Nemotron telemetry is emitted
    ///
    /// The engine, runtime routing, and CLI parsing are built regardless; flipping
    /// this flag is a no-data operation. MUST stay `false` in release builds until
    /// the ADR-023 §8 license gate clears (the downloaded artifact is currently
    /// eval-licensed, has no LICENSE file, and is access-gated).
    public static let nemotronEnabled: Bool = false
```

- [ ] **Step 2: Build**

Run: `swift build --target MacParakeetCore`
Expected: builds.

- [ ] **Step 3: Commit**

```bash
git add Sources/MacParakeetCore/AppFeatures.swift
git commit -m "feat(stt): add disabled AppFeatures.nemotronEnabled flag (ADR-023)"
```

### Task 1.2: `NemotronLanguageCatalog` (European-only allowlist)

**Files:**
- Create: `Sources/MacParakeetCore/NemotronLanguageCatalog.swift`
- Test: `Tests/MacParakeetTests/STT/NemotronLanguageCatalogTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/MacParakeetTests/STT/NemotronLanguageCatalogTests.swift`:

```swift
import XCTest
@testable import MacParakeetCore

final class NemotronLanguageCatalogTests: XCTestCase {
    func testAcceptsTheSixEuropeanCodes() {
        for code in ["en", "es", "fr", "it", "pt", "de"] {
            XCTAssertEqual(NemotronLanguageCatalog.canonicalCode(for: code), code)
        }
    }

    func testCollapsesRegionAliases() {
        XCTAssertEqual(NemotronLanguageCatalog.canonicalCode(for: "es-ES"), "es")
        XCTAssertEqual(NemotronLanguageCatalog.canonicalCode(for: "pt-BR"), "pt")
        XCTAssertEqual(NemotronLanguageCatalog.canonicalCode(for: "EN_us"), "en")
    }

    func testRejectsNonEuropeanAndAuto() {
        XCTAssertNil(NemotronLanguageCatalog.canonicalCode(for: "ko"))
        XCTAssertNil(NemotronLanguageCatalog.canonicalCode(for: "ja"))
        XCTAssertNil(NemotronLanguageCatalog.canonicalCode(for: "zh"))
        XCTAssertNil(NemotronLanguageCatalog.canonicalCode(for: "auto"))
        XCTAssertNil(NemotronLanguageCatalog.canonicalCode(for: nil))
        XCTAssertNil(NemotronLanguageCatalog.canonicalCode(for: ""))
    }

    func testDisplayLabels() {
        XCTAssertEqual(NemotronLanguageCatalog.displayLabel(forCode: "fr"), "French")
        XCTAssertNil(NemotronLanguageCatalog.displayLabel(forCode: "ko"))
    }

    func testSupportedCodesAreExactlySix() {
        XCTAssertEqual(Set(NemotronLanguageCatalog.supportedCodes), ["en", "es", "fr", "it", "pt", "de"])
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter NemotronLanguageCatalogTests`
Expected: FAIL — `cannot find 'NemotronLanguageCatalog' in scope`.

- [ ] **Step 3: Create the catalog**

Create `Sources/MacParakeetCore/NemotronLanguageCatalog.swift`:

```swift
import Foundation

/// The closed set of languages Echo's Nemotron engine offers — exactly the
/// Latin-script-pruned build FluidAudio ships (en/es/fr/it/pt/de). Deliberately
/// NOT `WhisperLanguageCatalog`, which accepts ~99 languages: pinning a language
/// the pruned model cannot produce (e.g. Korean) must be rejected, not accepted.
///
/// "auto"/nil is intentionally NOT a member here — the engine always downloads
/// the `latin/` subtree (see `NemotronEngine`), and a nil hint means
/// auto-detect *within* the Latin set at inference time. See ADR-023 §4.
public enum NemotronLanguageCatalog {
    private static let labelsByCode: [String: String] = [
        "en": "English",
        "es": "Spanish",
        "fr": "French",
        "it": "Italian",
        "pt": "Portuguese",
        "de": "German",
    ]

    /// The six canonical codes, sorted for stable UI ordering.
    public static let supportedCodes: [String] = ["en", "es", "fr", "it", "pt", "de"]

    /// Normalize a possibly region-styled code (`es-ES`, `EN_us`) to its canonical
    /// two-letter form, or `nil` if it is not one of the six European languages
    /// (including `nil`, empty, and "auto").
    public static func canonicalCode(for language: String?) -> String? {
        guard let language else { return nil }
        let trimmed = language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }
        // Take the primary subtag before any region separator.
        let primary = trimmed.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? trimmed
        return labelsByCode[primary] != nil ? primary : nil
    }

    /// Human-readable language name, or `nil` for an unsupported code.
    public static func displayLabel(forCode code: String) -> String? {
        labelsByCode[canonicalCode(for: code) ?? ""]
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter NemotronLanguageCatalogTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/MacParakeetCore/NemotronLanguageCatalog.swift Tests/MacParakeetTests/STT/NemotronLanguageCatalogTests.swift
git commit -m "feat(stt): add NemotronLanguageCatalog (European-only allowlist)"
```

### Task 1.3: Add `.nemotron` to `SpeechEnginePreference`

**Files:**
- Modify: `Sources/MacParakeetCore/SpeechEnginePreference.swift` (enum case + `displayName` + `alternative` + keys + `normalizeNemotronLanguage`)
- Test: `Tests/MacParakeetTests/STT/SpeechEnginePreferenceTests.swift`

- [ ] **Step 1: Write the failing tests**

In `Tests/MacParakeetTests/STT/SpeechEnginePreferenceTests.swift`, add these methods to the existing test class:

```swift
    func testNemotronDisplayNameAndRawValue() {
        XCTAssertEqual(SpeechEnginePreference.nemotron.rawValue, "nemotron")
        XCTAssertEqual(SpeechEnginePreference.nemotron.displayName, "Nemotron")
        XCTAssertTrue(SpeechEnginePreference.allCases.contains(.nemotron))
    }

    func testAlternativeStaysBinaryWithNemotronMappingToParakeet() {
        XCTAssertEqual(SpeechEnginePreference.parakeet.alternative, .whisper)
        XCTAssertEqual(SpeechEnginePreference.whisper.alternative, .parakeet)
        // New: nemotron's "other engine" is the default, so existing
        // parakeet<->whisper retranscribe behavior is unchanged.
        XCTAssertEqual(SpeechEnginePreference.nemotron.alternative, .parakeet)
    }

    func testNemotronSelectionCarriesEuropeanLanguageOnly() {
        XCTAssertEqual(
            SpeechEngineSelection(engine: .nemotron, language: "fr-FR").language, "fr")
        // Non-European pins are dropped (cannot be honored by the pruned model).
        XCTAssertNil(SpeechEngineSelection(engine: .nemotron, language: "ko").language)
        // Parakeet still never carries a language.
        XCTAssertNil(SpeechEngineSelection(engine: .parakeet, language: "en").language)
    }

    func testNemotronDefaultLanguageRoundTrips() {
        let defaults = UserDefaults(suiteName: "nemotron-lang-test")!
        defaults.removePersistentDomain(forName: "nemotron-lang-test")
        SpeechEnginePreference.saveNemotronDefaultLanguage("de-DE", defaults: defaults)
        XCTAssertEqual(SpeechEnginePreference.nemotronDefaultLanguage(defaults: defaults), "de")
        SpeechEnginePreference.saveNemotronDefaultLanguage("ko", defaults: defaults) // rejected
        XCTAssertNil(SpeechEnginePreference.nemotronDefaultLanguage(defaults: defaults))
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter SpeechEnginePreferenceTests`
Expected: FAIL — `type 'SpeechEnginePreference' has no member 'nemotron'`.

- [ ] **Step 3: Add the enum case and `displayName`**

In `SpeechEnginePreference.swift`, change the enum head (line ~3):

```swift
public enum SpeechEnginePreference: String, CaseIterable, Codable, Sendable {
    case parakeet
    case whisper
    case nemotron
```

In `displayName` (the switch around line 22), add the case:

```swift
        case .nemotron:
            "Nemotron"
```

- [ ] **Step 4: Keep `alternative` binary**

In `alternative` (switch around line 30), add the `.nemotron` arm so the toggle stays two-engine:

```swift
        case .nemotron:
            .parakeet
```

- [ ] **Step 5: Add Nemotron default-language key + accessors + normalization**

Near the other key constants (after `whisperOptimizedVariantsKey`, line ~17) add:

```swift
    public static let nemotronDefaultLanguageKey = "nemotronDefaultLanguage"
```

After the `saveWhisperDefaultLanguage` function (line ~61), add:

```swift
    public static func nemotronDefaultLanguage(defaults: UserDefaults = .standard) -> String? {
        normalizeNemotronLanguage(defaults.string(forKey: nemotronDefaultLanguageKey))
    }

    public static func saveNemotronDefaultLanguage(_ language: String?, defaults: UserDefaults = .standard) {
        guard let normalized = normalizeNemotronLanguage(language) else {
            defaults.removeObject(forKey: nemotronDefaultLanguageKey)
            return
        }
        defaults.set(normalized, forKey: nemotronDefaultLanguageKey)
    }

    /// Nemotron honors only the six European codes (NemotronLanguageCatalog).
    /// Distinct from `normalizeLanguage`, which delegates to the ~99-language
    /// Whisper catalog and would wrongly accept e.g. "ko".
    public static func normalizeNemotronLanguage(_ language: String?) -> String? {
        NemotronLanguageCatalog.canonicalCode(for: language)
    }
```

- [ ] **Step 6: Carry the language for `.nemotron` in `SpeechEngineSelection`**

Replace the `SpeechEngineSelection.init` body (line ~187-190) with an engine switch:

```swift
    public init(engine: SpeechEnginePreference, language: String? = nil) {
        self.engine = engine
        switch engine {
        case .whisper:
            self.language = SpeechEnginePreference.normalizeLanguage(language)
        case .nemotron:
            self.language = SpeechEnginePreference.normalizeNemotronLanguage(language)
        case .parakeet:
            self.language = nil
        }
    }
```

And update `SpeechEngineSelection.current` (line ~192-198) to read the Nemotron default when the engine is Nemotron:

```swift
    public static func current(defaults: UserDefaults = .standard) -> SpeechEngineSelection {
        let engine = SpeechEnginePreference.current(defaults: defaults)
        let language: String?
        switch engine {
        case .whisper:
            language = SpeechEnginePreference.whisperDefaultLanguage(defaults: defaults)
        case .nemotron:
            language = SpeechEnginePreference.nemotronDefaultLanguage(defaults: defaults)
        case .parakeet:
            language = nil
        }
        return SpeechEngineSelection(engine: engine, language: language)
    }
```

- [ ] **Step 7: Run to verify it passes**

Run: `swift test --filter SpeechEnginePreferenceTests`
Expected: PASS (existing + 4 new).

- [ ] **Step 8: Build everything to surface non-exhaustive switches**

Run: `swift build`
Expected: **compile errors** in files with exhaustive `switch` over `SpeechEnginePreference` that don't yet handle `.nemotron` (STTRuntime, SettingsStatusRules, SettingsViewModel, TranscriptionViewModel, TranscriptResultView, CLI). This is expected — Phases 3–5 fix them. **Do not commit a broken build.** If you want a green commit here, temporarily it's fine to proceed directly into Phase 3 before committing; otherwise add the `.nemotron` arms now per Phases 3–5 and commit once. Recommended: commit this enum change together with Phase 3 Task 3.1 (the Core switches) so Core stays buildable.

> Note: the enum change cannot be committed green on its own because Swift exhaustive switches break. Treat Tasks 1.3 + 3.1 as one green commit (Core compiles). UI/CLI switches (Phases 4–5) can lag only if their targets aren't built; since `swift build` builds all targets, plan to land 1.3 → 3.1 → 4.x → 5.x before the next full `swift build` passes. Use `swift build --target MacParakeetCore` to checkpoint Core independently.

---

# Phase 2 — `NemotronEngine` wrapper + storage path

### Task 2.1: Add `AppPaths.nemotronModelsDir`

**Files:**
- Modify: `Sources/MacParakeetCore/Services/AppPaths.swift` (add dir + include in `ensureDirectories`)

- [ ] **Step 1: Add the directory accessor**

In `AppPaths.swift`, after `whisperModelsDir` (line ~51), add:

```swift
    public static var nemotronModelsDir: String { "\(appSupportDir)/models/stt/nemotron" }
```

- [ ] **Step 2: Include it in `ensureDirectories()`**

In the `ensureDirectories()` directory list (around line 86, alongside `whisperModelsDir`), add `nemotronModelsDir` to the array of paths that get created.

- [ ] **Step 3: Build + quick check**

Run: `swift build --target MacParakeetCore`
Expected: builds.

- [ ] **Step 4: Commit (folded into Task 2.2's commit is fine, or commit now)**

```bash
git add Sources/MacParakeetCore/Services/AppPaths.swift
git commit -m "feat(stt): add AppPaths.nemotronModelsDir"
```

### Task 2.2: `NemotronEngine` — token→word mapping (pure, TDD first)

The riskiest logic (token grouping) is a pure static function we test without the model.

**Files:**
- Create: `Sources/MacParakeetCore/STT/NemotronEngine.swift`
- Test: `Tests/MacParakeetTests/STT/NemotronEngineTests.swift`

- [ ] **Step 1: Write the failing test for token→word grouping**

Create `Tests/MacParakeetTests/STT/NemotronEngineTests.swift`:

```swift
import XCTest
import FluidAudio
@testable import MacParakeetCore

final class NemotronEngineTests: XCTestCase {
    private func tt(_ token: String, _ start: Double, _ end: Double) -> TokenTiming {
        TokenTiming(token: token, tokenId: 0, startTime: start, endTime: end, confidence: 1.0)
    }

    func testGroupsSubwordTokensIntoWordsByBoundaryMarker() {
        // "▁Bon" + "jour" -> "Bonjour"; "▁le" + "▁monde" -> "le", "monde"
        let timings = [
            tt("\u{2581}Bon", 0.0, 0.08),
            tt("jour", 0.08, 0.16),
            tt("\u{2581}le", 0.20, 0.28),
            tt("\u{2581}monde", 0.30, 0.40),
        ]
        let words = NemotronEngine.mapTokenTimings(timings)
        XCTAssertEqual(words.map(\.word), ["Bonjour", "le", "monde"])
        XCTAssertEqual(words[0].startMs, 0)
        XCTAssertEqual(words[0].endMs, 160)   // end of the second sub-word token
        XCTAssertEqual(words[1].startMs, 200)
        XCTAssertEqual(words[2].endMs, 400)
    }

    func testConfidenceIsSentinelOne() {
        let words = NemotronEngine.mapTokenTimings([tt("\u{2581}Hola", 0.0, 0.1)])
        XCTAssertEqual(words.first?.confidence, 1.0)
    }

    func testEmptyTimingsProduceNoWords() {
        XCTAssertTrue(NemotronEngine.mapTokenTimings([]).isEmpty)
    }

    func testLeadingTokenWithoutMarkerStillStartsAWord() {
        // Defensive: a stream that doesn't begin with ▁ should not drop text.
        let words = NemotronEngine.mapTokenTimings([tt("Ciao", 0.0, 0.1)])
        XCTAssertEqual(words.map(\.word), ["Ciao"])
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter NemotronEngineTests`
Expected: FAIL — `cannot find 'NemotronEngine' in scope`.

> If `TokenTiming(token:tokenId:startTime:endTime:confidence:)` does not compile, open the resolved FluidAudio source (`AsrTypes.swift`) and match the real memberwise initializer; adjust the `tt` helper accordingly. This is the one place the test depends on FluidAudio's public type.

- [ ] **Step 3: Create `NemotronEngine` with the pure mapper + the engine skeleton**

Create `Sources/MacParakeetCore/STT/NemotronEngine.swift`:

```swift
import FluidAudio
import Foundation
import OSLog

/// Optional, opt-in STT engine for European/Latin-script audio (ADR-023).
/// Wraps FluidAudio's `StreamingNemotronMultilingualAsrManager`, driven in a
/// feed-whole-file-then-finish pattern so it satisfies Echo's batch contract.
/// Mirrors `WhisperEngine`'s structure (serialized via `AsyncPermit`).
public actor NemotronEngine: STTTranscribing {
    private let logger = Logger(subsystem: "com.macparakeet.core", category: "NemotronEngine")

    /// Always fetch the Latin-script-pruned subtree, regardless of the user's
    /// language pin — passing "auto" to FluidAudio would download the heavy
    /// 13k-token multilingual model. See ADR-023 §4.
    public static let downloadRoutingLanguage = "en"
    /// Batch default chunk tier. Confirm the published `latin/<chunkMs>ms`
    /// subdirectory exists on Hugging Face at implementation time (ADR-023 open items).
    public static let defaultChunkMs = 2240
    public static let variantLabel = "nemotron-european"

    private let defaultLanguage: String?   // canonical European code, or nil = auto-within-latin
    private let downloadBase: URL
    private let chunkMs: Int
    private let transcriptionPermit = AsyncPermit()

    private var manager: StreamingNemotronMultilingualAsrManager?
    private var isLoaded = false

    public init(
        language: String? = nil,
        downloadBase: URL? = nil,
        chunkMs: Int = NemotronEngine.defaultChunkMs
    ) {
        self.defaultLanguage = SpeechEnginePreference.normalizeNemotronLanguage(language)
        self.downloadBase = downloadBase ?? Self.defaultDownloadBase
        self.chunkMs = chunkMs
    }

    public static var defaultDownloadBase: URL {
        URL(fileURLWithPath: AppPaths.nemotronModelsDir, isDirectory: true)
    }

    /// Local folder for the pruned `latin/<chunkMs>ms` variant, or nil if absent.
    /// FluidAudio lands files under `<downloadBase>/<repoFolder>/latin/<chunkMs>ms/`.
    /// Confirm `repoFolder` ("nemotron-multilingual") against the resolved package.
    public static func localModelFolder(
        downloadBase: URL = NemotronEngine.defaultDownloadBase,
        chunkMs: Int = NemotronEngine.defaultChunkMs
    ) -> URL? {
        let dir = downloadBase
            .appendingPathComponent("nemotron-multilingual", isDirectory: true)
            .appendingPathComponent("latin", isDirectory: true)
            .appendingPathComponent("\(chunkMs)ms", isDirectory: true)
        return FileManager.default.fileExists(atPath: dir.path) ? dir : nil
    }

    public static func isModelDownloaded(
        downloadBase: URL = NemotronEngine.defaultDownloadBase,
        chunkMs: Int = NemotronEngine.defaultChunkMs
    ) -> Bool {
        localModelFolder(downloadBase: downloadBase, chunkMs: chunkMs) != nil
    }

    /// Group per-sub-word `TokenTiming`s into word-level `TimestampedWord`s by the
    /// SentencePiece word-boundary marker (▁). Timing is encoder-frame-coarse and
    /// confidence is FluidAudio's hardcoded 1.0 placeholder (ADR-023 §5) — we pass
    /// it through as a sentinel, not a real probability. Pure + testable.
    public static func mapTokenTimings(_ timings: [TokenTiming]) -> [TimestampedWord] {
        let marker = "\u{2581}"
        var words: [TimestampedWord] = []
        var current: (text: String, start: Int, end: Int)?

        func flush() {
            if let c = current, !c.text.isEmpty {
                words.append(TimestampedWord(
                    word: c.text, startMs: c.start, endMs: max(c.start, c.end), confidence: 1.0))
            }
            current = nil
        }

        for t in timings {
            let startsWord = t.token.hasPrefix(marker)
            let clean = t.token.replacingOccurrences(of: marker, with: "")
            let startMs = Int((max(0, t.startTime) * 1_000).rounded())
            let endMs = Int((max(0, t.endTime) * 1_000).rounded())
            if startsWord || current == nil {
                flush()
                current = (clean, startMs, endMs)
            } else {
                current?.text += clean
                current?.end = endMs
            }
        }
        flush()
        return words
    }

    public func isReady() -> Bool { isLoaded && manager != nil }

    public func transcribe(
        audioPath: String,
        job: STTJobKind,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> STTResult {
        try await transcriptionPermit.wait()
        defer { transcriptionPermit.signal() }
        try Task.checkCancellation()
        do {
            try await prepareLocked(onProgress: nil)
            guard let manager else { throw STTError.modelNotLoaded }

            if let defaultLanguage { await manager.setLanguage(defaultLanguage) }
            onProgress?(0, 100)
            let samples = try AudioConverter().resampleAudioFile(URL(fileURLWithPath: audioPath))
            _ = try await manager.process(samples: samples)
            let (text, timings) = try await manager.finishWithTokenTimings()
            let detected = await manager.detectedLanguage()
            await manager.reset()
            onProgress?(100, 100)

            return STTResult(
                text: text,
                words: Self.mapTokenTimings(timings),
                segments: nil,
                language: detected ?? defaultLanguage,
                engine: .nemotron,
                engineVariant: Self.variantLabel
            )
        } catch {
            throw Self.mapError(error)
        }
    }

    public func prepare(onProgress: (@Sendable (String) -> Void)? = nil) async throws {
        try await transcriptionPermit.wait()
        defer { transcriptionPermit.signal() }
        try Task.checkCancellation()
        try await prepareLocked(onProgress: onProgress)
    }

    private func prepareLocked(onProgress: (@Sendable (String) -> Void)? = nil) async throws {
        if isLoaded, manager != nil { return }
        guard let dir = Self.localModelFolder(downloadBase: downloadBase, chunkMs: chunkMs) else {
            throw STTError.engineStartFailed(
                "Nemotron model is not downloaded. Run `macparakeet-cli models download nemotron-european` first.")
        }
        do {
            try AppPaths.ensureDirectories()
            onProgress?("Loading Nemotron model on Neural Engine...")
            let m = StreamingNemotronMultilingualAsrManager()
            try await m.loadModels(from: dir)
            manager = m
            isLoaded = true
            onProgress?("Ready")
        } catch {
            isLoaded = false
            manager = nil
            throw Self.mapError(error)
        }
    }

    public func unload() async {
        do { try await transcriptionPermit.wait() } catch { return }
        defer { transcriptionPermit.signal() }
        guard !Task.isCancelled else { return }
        if let manager { await manager.cleanup() }
        manager = nil
        isLoaded = false
    }

    public static func downloadModel(
        downloadBase: URL = NemotronEngine.defaultDownloadBase,
        chunkMs: Int = NemotronEngine.defaultChunkMs,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> URL {
        try AppPaths.ensureDirectories()
        return try await StreamingNemotronMultilingualAsrManager.downloadVariant(
            languageCode: downloadRoutingLanguage,
            chunkMs: chunkMs,
            to: downloadBase,
            progressHandler: { progress in
                let total = max(Int(progress.totalUnitCount), 1)
                let completed = max(0, Int(progress.completedUnitCount))
                onProgress?(completed, total)
            }
        )
    }

    private static func mapError(_ error: Error) -> STTError {
        if error is CancellationError { return .transcriptionFailed("cancelled") }
        if let sttError = error as? STTError { return sttError }
        return .transcriptionFailed(error.localizedDescription)
    }
}
```

> **Verify against the resolved package (do not skip):** the `StreamingNemotronMultilingualAsrManager` calls (`loadModels(from:)`, `setLanguage(_:)`, `process(samples:)`, `finishWithTokenTimings()`, `detectedLanguage()`, `reset()`, `cleanup()`, `downloadVariant(languageCode:chunkMs:to:progressHandler:)`), the `AudioConverter().resampleAudioFile(_:)` call, the `repoFolder` name ("nemotron-multilingual"), and the `DownloadUtils.ProgressHandler` shape are transcribed from v0.15.4 source. Open the resolved sources under `.build/checkouts/FluidAudio/Sources/FluidAudio/` and confirm each signature; adapt labels if the resolved patch differs. If `cancelled` mapping needs to rethrow `CancellationError` to honor scheduler cancellation, match `WhisperEngine.mapTranscriptionError`'s behavior.

- [ ] **Step 4: Run the pure-mapper tests**

Run: `swift test --filter NemotronEngineTests`
Expected: PASS (4 tests). (These exercise only `mapTokenTimings`, which needs no model.)

- [ ] **Step 5: Build core**

Run: `swift build --target MacParakeetCore`
Expected: builds (Core still has the broken exhaustive switches if Task 3.1 isn't done — sequence 2.2 before 3.1's build checkpoint, or land them together).

- [ ] **Step 6: Commit (with Phase 3 once Core compiles green)**

```bash
git add Sources/MacParakeetCore/STT/NemotronEngine.swift Tests/MacParakeetTests/STT/NemotronEngineTests.swift
git commit -m "feat(stt): add NemotronEngine wrapper + token->word timing mapping"
```

---

# Phase 3 — Runtime routing, telemetry, meeting guard

### Task 3.1: Route `.nemotron` through `STTRuntime`

**Files:**
- Modify: `Sources/MacParakeetCore/STT/STTRuntime.swift` (all `.nemotron` arms + `nemotronEngine` field + helpers)

- [ ] **Step 1: Add the engine field + init param**

In `STTRuntime`, alongside `whisperEngine` (line ~59) add:

```swift
    private var nemotronEngine: NemotronEngine?
```

(No new init param is required — `NemotronEngine` reads its language from the selection per-call, like the Whisper transcribe path. If you mirror `whisperModelVariant`, add a `nemotronChunkMs` stored property defaulting to `NemotronEngine.defaultChunkMs`.)

- [ ] **Step 2: Add the transcribe dispatch arm**

In the `transcribe(...speechEngine selection:...)` switch (line ~103):

```swift
        case .nemotron:
            return try await transcribeWithNemotron(
                audioPath: audioPath, language: selection.language, onProgress: onProgress)
```

Add the helper near `transcribeWithWhisper` (line ~111):

```swift
    private func transcribeWithNemotron(
        audioPath: String,
        language: String?,
        onProgress: (@Sendable (Int, Int) -> Void)?
    ) async throws -> STTResult {
        let engine = nemotronEngine ?? NemotronEngine(language: language)
        nemotronEngine = engine
        return try await engine.transcribe(audioPath: audioPath, job: .fileTranscription, onProgress: onProgress)
    }
```

- [ ] **Step 3: Add warm-up, isReady, switch load/unload, currentSelection, telemetry arms**

In the warm-up switch (line ~207) add:

```swift
            case .nemotron:
                let engine = nemotronEngine ?? NemotronEngine()
                nemotronEngine = engine
                try await engine.prepare(onProgress: nil)
```

In `isReady()` (line ~331), before the Parakeet fallthrough, add:

```swift
        if speechEngine == .nemotron {
            return await nemotronEngine?.isReady() ?? false
        }
```

In `performSpeechEngineSwitch` LOAD switch (line ~427) add:

```swift
        case .nemotron:
            let engine = nemotronEngine ?? NemotronEngine(
                language: SpeechEnginePreference.nemotronDefaultLanguage())
            try await engine.prepare(onProgress: onProgress)
            preparedNemotron = engine
```

(Declare `var preparedNemotron: NemotronEngine?` next to `preparedWhisper` at the top of the function, and after the load switch add `if let preparedNemotron { nemotronEngine = preparedNemotron }`.)

In the UNLOAD switch (line ~446) add:

```swift
        case .nemotron where preference != .nemotron:
            onProgress?("Releasing Nemotron model...")
            await unloadNemotron()
```

Add the teardown helper near `unloadWhisper` (line ~488):

```swift
    private func unloadNemotron() async {
        let engine = nemotronEngine
        nemotronEngine = nil
        await engine?.unload()
    }
```

Call it from `shutdown()` (line ~343, alongside `unloadWhisper()`): add `await unloadNemotron()`.

In `currentSpeechEngineSelection()` (line ~459) replace the whisper-only language ternary with an engine switch that also reads `nemotronDefaultLanguage()` for `.nemotron`.

In `telemetryModelKind(for:)` (line ~692) add `case .nemotron: .nemotronSTT` (the enum value is added in Task 3.2). In `telemetryEngineVariant(for:)` (line ~701) add `case .nemotron: NemotronEngine.variantLabel`.

In `clearModelCache()` (line ~355), alongside the whisper dir removal, add:

```swift
        try? FileManager.default.removeItem(atPath: AppPaths.nemotronModelsDir)
```

- [ ] **Step 4: Build core**

Run: `swift build --target MacParakeetCore`
Expected: builds (depends on Task 3.2's telemetry enum value — do 3.2 first or together).

### Task 3.2: Add the telemetry model-kind

**Files:**
- Modify: `Sources/MacParakeetCore/Services/Telemetry/TelemetryEvent.swift` (`TelemetryModelKind` enum, line ~163)
- Test: `Tests/MacParakeetTests/TelemetryServiceTests.swift`

- [ ] **Step 1: Write the failing test**

In `TelemetryServiceTests.swift`, add:

```swift
    func testNemotronModelKindRawValue() {
        XCTAssertEqual(TelemetryModelKind.nemotronSTT.rawValue, "nemotron_stt")
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter TelemetryServiceTests`
Expected: FAIL — no member `nemotronSTT`.

- [ ] **Step 3: Add the enum case**

In `TelemetryEvent.swift`, in `enum TelemetryModelKind` (line ~163), add:

```swift
    case nemotronSTT = "nemotron_stt"
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter TelemetryServiceTests`
Expected: PASS.

### Task 3.3: Meeting pinned-engine guard

**Files:**
- Modify: `Sources/MacParakeetCore/Services/Capture/LiveChunkTranscriber.swift:146`

- [ ] **Step 1: Inspect the guard**

Read `LiveChunkTranscriber.swift` around line 138–150. The non-routed fallback throws for any pinned engine `!= SpeechEngineSelection(engine: .parakeet)`. Confirm meeting work always reaches the **routed** transcriber branch (line ~138) so a Nemotron-pinned meeting never hits the throw.

- [ ] **Step 2: If the routed branch is guaranteed, leave a clarifying comment**

If routing is guaranteed (it is for the scheduler path), add a one-line comment noting Whisper/Nemotron meetings always use the routed branch, so the fallback's parakeet-only assumption is intentional. If NOT guaranteed, widen the guard to accept `.nemotron` (and `.whisper`, which already works) by routing through the engine rather than throwing. No behavior change is expected while the flag is off (Nemotron is never pinned), so this is a correctness guard for flip-on.

- [ ] **Step 3: Build + full suite (Core + tests should now be green)**

Run: `swift build && swift test`
Expected: PASS. Core, runtime, telemetry all compile with `.nemotron`.

- [ ] **Step 4: Commit Phase 1.3 + Phase 2 + Phase 3 as the first green engine commit**

```bash
git add Sources/MacParakeetCore Tests/MacParakeetTests/STT Tests/MacParakeetTests/TelemetryServiceTests.swift
git commit -m "feat(stt): route .nemotron through STTRuntime + telemetry (engine off by flag)"
```

> If you committed Tasks 1.3/2.2 earlier on a broken build, instead squash by committing here once `swift build && swift test` is green. Never leave a committed broken build on the branch.

---

# Phase 4 — CLI surface

### Task 4.1: `transcribe --engine nemotron --language`

**Files:**
- Modify: `Sources/CLI/Commands/TranscribeCommand.swift` (enum line ~30, `resolveSpeechEngine` line ~138, run() construction line ~230, help lines ~67/70, cleanup line ~341)
- Test: `Tests/CLITests/TranscribeCommandTests.swift`

- [ ] **Step 1: Write the failing tests**

In `TranscribeCommandTests.swift`, add:

```swift
    func testResolveNemotronEngineCarriesEuropeanLanguage() {
        let sel = TranscribeCommand.resolveSpeechEngine(
            .nemotron, storedEngine: nil, storedLanguage: nil, explicitLanguage: "fr-FR")
        XCTAssertEqual(sel.engine, .nemotron)
        XCTAssertEqual(sel.language, "fr")
    }

    func testResolveNemotronDropsNonEuropeanLanguage() {
        let sel = TranscribeCommand.resolveSpeechEngine(
            .nemotron, storedEngine: nil, storedLanguage: nil, explicitLanguage: "ko")
        XCTAssertEqual(sel.engine, .nemotron)
        XCTAssertNil(sel.language)
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter TranscribeCommandTests`
Expected: FAIL — no `.nemotron` on `TranscribeSpeechEngine`.

- [ ] **Step 3: Add the CLI engine case + resolver arm**

In `TranscribeCommand.swift`, the `TranscribeSpeechEngine` enum (line ~30):

```swift
    case nemotron
```

In `resolveSpeechEngine` (switch ~146):

```swift
        case .nemotron:
            preference = .nemotron
            language = explicitLanguage
```

(The `SpeechEngineSelection` init already restricts the Nemotron language to the European set, so passing `explicitLanguage` straight through is correct — "ko" becomes nil.)

- [ ] **Step 4: Construct the engine in `run()` + cleanup**

In the run() construction switch (line ~230):

```swift
            case .nemotron:
                let createdNemotronEngine = NemotronEngine(language: speechEngine.language)
                nemotronEngine = createdNemotronEngine
                sttTranscriber = createdNemotronEngine
```

Declare `var nemotronEngine: NemotronEngine?` next to `whisperEngine` (line ~192) and add `await nemotronEngine?.unload()` next to the whisper cleanup (line ~341).

- [ ] **Step 5: Gate at runtime behind the flag**

Immediately after resolving `speechEngine` (after line ~205), add the flag check so the shipping CLI refuses Nemotron:

```swift
            if speechEngine.engine == .nemotron && !AppFeatures.nemotronEnabled {
                printErr("The Nemotron engine is not available in this build.")
                throw ExitCode.failure
            }
```

- [ ] **Step 6: Update help text**

`--engine` help (line ~67): `"Speech engine: app-default, parakeet, whisper, nemotron. Default: parakeet; app-default follows the saved GUI preference."`
`--language` help (line ~70): `"Language hint for Whisper (any Whisper code) or Nemotron (European: en/es/fr/it/pt/de). Parakeet ignores this flag."`

- [ ] **Step 7: Add a flag-off rejection test**

In `TranscribeCommandTests.swift`, add a test asserting that running `transcribe --engine nemotron <file>` exits non-zero while `AppFeatures.nemotronEnabled == false` (follow the existing pattern in this file for invoking the command and capturing exit/stderr; if the suite has no command-invocation harness, assert the guard predicate `(engine == .nemotron && !AppFeatures.nemotronEnabled)` via a small extracted helper instead).

- [ ] **Step 8: Run tests**

Run: `swift test --filter TranscribeCommandTests`
Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add Sources/CLI/Commands/TranscribeCommand.swift Tests/CLITests/TranscribeCommandTests.swift
git commit -m "feat(cli): transcribe --engine nemotron (rejected at runtime while flag off)"
```

### Task 4.2: `models` + `config` learn Nemotron

**Files:**
- Modify: `Sources/CLI/Commands/ModelsCommand.swift` (download id ~231, selectable models ~344, resolve ~377, status ~242-323, clear ~225)
- Modify: `Sources/CLI/Commands/ConfigCommand.swift` (parse error ~249, supportedKeys ~46, read ~160, write ~191)
- Test: `Tests/CLITests/ModelLifecycleCommandTests.swift`, `Tests/CLITests/ConfigCommandTests.swift`

- [ ] **Step 1: Write failing tests**

In `ConfigCommandTests.swift`:

```swift
    func testParseSpeechEngineAcceptsNemotron() {
        XCTAssertEqual(try ConfigCommand.parseSpeechEngine("nemotron"), .nemotron)
    }
```

In `ModelLifecycleCommandTests.swift`, add a test asserting `models download nemotron-european` resolves to the Nemotron path (mirror the existing `resolveWhisperDownloadModel` test shape, using whatever resolver you add — see Step 3).

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter ConfigCommandTests && swift test --filter ModelLifecycleCommandTests`
Expected: FAIL.

- [ ] **Step 3: Implement**

`ConfigCommand.parseSpeechEngine` already uses `SpeechEnginePreference(rawValue:)`, so `"nemotron"` parses once the enum case exists; just update the error string (line ~249) to `"Use parakeet, whisper, or nemotron"` and the discussion/help (lines ~27-28) to `parakeet|whisper|nemotron`. If a Nemotron default-language config key is desired, add `nemotron-language` to `supportedKeys` (line ~46), read (line ~160), write (line ~191) with a `parseNemotronLanguage` helper validating via `NemotronLanguageCatalog`.

`ModelsCommand`:
- Download (line ~231): add a resolver branch accepting `nemotron-european` / `nemotron-*` that calls `NemotronEngine.downloadModel`. Gate the actual download behind `AppFeatures.nemotronEnabled` (refuse with a clear message while off, mirroring the CLI transcribe gate) so the CLI never fetches the eval-licensed artifact in a shipped build.
- `loadSelectableSpeechModels` (line ~344): append a Nemotron `SelectableSpeechModel` **only when `AppFeatures.nemotronEnabled`** (id `nemotron-european`, engine `nemotron`, installed via `NemotronEngine.isModelDownloaded()`).
- `resolveSelectableSpeechModel` (line ~377): map `nemotron`/`nemotron-` ids to engine `.nemotron`.
- Status (lines ~242-323): add nemotron fields only when the flag is on, or omit (status is informational; minimal change is acceptable).
- Clear (line ~225): also `removeItem(atPath: AppPaths.nemotronModelsDir)`.

- [ ] **Step 4: Run to verify they pass**

Run: `swift test --filter ConfigCommandTests && swift test --filter ModelLifecycleCommandTests`
Expected: PASS.

- [ ] **Step 5: Update the CLI CHANGELOG**

In `Sources/CLI/CHANGELOG.md`, add an entry under a new unreleased/next version noting: `transcribe --engine nemotron --language <eu-code>` and `models download nemotron-european` added; gated off by default (`AppFeatures.nemotronEnabled`), rejected at runtime while disabled; European languages only (en/es/fr/it/pt/de).

- [ ] **Step 6: Commit**

```bash
git add Sources/CLI Tests/CLITests
git commit -m "feat(cli): models/config learn Nemotron (gated); CHANGELOG"
```

---

# Phase 5 — Settings UI (all flag-gated)

ViewModels are testable; Views are not (test ViewModels, per spec/09-testing). Everything here is wrapped in `if AppFeatures.nemotronEnabled`, so the shipped UI is unchanged.

### Task 5.1: Exhaustive view-layer switches

**Files:**
- Modify: `Sources/MacParakeet/Views/Settings/SettingsStatusRules.swift:25`
- Modify: `Sources/MacParakeetViewModels/SettingsViewModel.swift:1630` (`initialSpeechEngineSwitchDetail`)
- Modify: `Sources/MacParakeetViewModels/TranscriptionViewModel.swift:705` (`subline`)
- Modify: `Sources/MacParakeet/Views/Transcription/TranscriptResultView.swift` (`engineAttributionLabel:824`, `EngineOptionCard.iconName:2973`, `.subtitle:2980`, `.languageDetail:2989`)
- Test: `Tests/MacParakeetTests/Views/Settings/SettingsStatusRulesTests.swift`, `Tests/MacParakeetTests/ViewModels/TranscriptionViewModelTests.swift`

- [ ] **Step 1: Add `.nemotron` arms to each exhaustive switch (build-driven)**

Run `swift build` and fix each non-exhaustive-switch error with the obvious arm:
- `SettingsStatusRules.localModelsCardStatus`: add a `.nemotron` case returning a new `nemotronModelStatus` parameter (add the param; update call sites + tests).
- `SettingsViewModel.initialSpeechEngineSwitchDetail`: `case .nemotron: "Preparing Nemotron..."`.
- `TranscriptionViewModel.subline` (the `.transcribing` engine switch): `case .nemotron: "Nemotron is transcribing…"` (match the existing Whisper string style).
- `TranscriptResultView.engineAttributionLabel`: `case .nemotron: "Nemotron"`.
- `EngineOptionCard.iconName`: `case .nemotron: "waveform"` (pick an SF Symbol distinct from Parakeet's `bolt.fill` and Whisper's `globe`).
- `EngineOptionCard.subtitle`: `case .nemotron: "European languages"`.
- `EngineOptionCard.languageDetail`: change the `guard selection.engine == .whisper` to also allow `.nemotron` so its language shows.

> These arms must exist even when the flag is off, because they run on historical saved rows (`engineAttributionLabel`) and on always-compiled switches.

- [ ] **Step 2: Update affected tests**

In `SettingsStatusRulesTests.swift`, add the new `nemotronModelStatus` argument to existing `localModelsCardStatus` call sites and a `.nemotron` active-engine case. In `TranscriptionViewModelTests.swift`, keep the 5 binary-`alternative` assertions green (unchanged) and add a `.nemotron`-primary case asserting `alternative == .parakeet`.

- [ ] **Step 3: Build + run**

Run: `swift build && swift test --filter SettingsStatusRulesTests && swift test --filter TranscriptionViewModelTests`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add Sources/MacParakeet Sources/MacParakeetViewModels Tests/MacParakeetTests
git commit -m "feat(ui): .nemotron arms in engine-display switches"
```

### Task 5.2: SettingsViewModel Nemotron state (flag-gated)

**Files:**
- Modify: `Sources/MacParakeetViewModels/SettingsViewModel.swift` (mirror whisper status/select plumbing, gated by flag)
- Test: `Tests/MacParakeetTests/ViewModels/SettingsViewModelTests.swift`

- [ ] **Step 1: Add gated Nemotron status + selection plumbing**

Mirror the Whisper plumbing (`displayedWhisperModelStatus`, `applySpeechEngineChange`, model-status checks) with a Nemotron analog, each guarded so it is inert when `AppFeatures.nemotronEnabled == false`. `selectEngine(.nemotron)` flows into `applySpeechEngineChange` exactly like Whisper. Use `NemotronEngine.isModelDownloaded()` for the model-status source.

- [ ] **Step 2: Tests (flag-off behavior)**

In `SettingsViewModelTests.swift`, assert that with the flag off, the engine option list / selectable engines does not include Nemotron and that `speechEnginePreference` never resolves to `.nemotron`. (Do not write flag-on tests — the flag is a compile-time constant.)

- [ ] **Step 3: Build + run**

Run: `swift test --filter SettingsViewModelTests`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add Sources/MacParakeetViewModels/SettingsViewModel.swift Tests/MacParakeetTests/ViewModels/SettingsViewModelTests.swift
git commit -m "feat(ui): SettingsViewModel Nemotron status (flag-gated, inert when off)"
```

### Task 5.3: Settings engine tile + language card (flag-gated, 3-up layout)

**Files:**
- Modify: `Sources/MacParakeet/Views/Settings/SettingsView.swift` (`engineSelectorCard` ~1654, add `engineNemotronLanguageCard`, compose at ~380)

- [ ] **Step 1: Add the third tile, gated, with a layout that fits three**

In `engineSelectorCard`, the two `EngineOptionTile`s currently sit in one `HStack` (line ~1666). Three equal tiles will be cramped at Settings width. Change the container to wrap (e.g. a `LazyVGrid` with adaptive columns, or stack the Nemotron tile on its own row) and add, **gated**:

```swift
                if AppFeatures.nemotronEnabled {
                    EngineOptionTile(
                        icon: "waveform",
                        name: "Nemotron",
                        tagline: "Lighter European engine",
                        strengths: [
                            "English, Spanish, French, Italian, Portuguese, German",
                            "Smaller download than Whisper",
                            "Runs on the Neural Engine"
                        ],
                        helpText: "A lighter local engine for European languages. Smaller than the Whisper download; English, Spanish, French, Italian, Portuguese, and German.",
                        modelStatus: displayedNemotronModelStatus,
                        isSelected: viewModel.speechEnginePreference == .nemotron,
                        isBusy: viewModel.speechEngineSwitching,
                        unavailableReason: engineSwitchUnavailableReason(for: .nemotron),
                        onSelect: { selectEngine(.nemotron) }
                    )
                }
```

Add `displayedNemotronModelStatus` mirroring `displayedWhisperModelStatus`, and a Nemotron download banner mirroring `whisperDownloadBannerState` (both gated). `engineSwitchUnavailableReason(for:)` already takes a `SpeechEnginePreference` and needs no change.

- [ ] **Step 2: Add the Nemotron language card**

Add a `@ViewBuilder var engineNemotronLanguageCard` mirroring `engineLanguageCard` but gated `if AppFeatures.nemotronEnabled && viewModel.speechEnginePreference == .nemotron`, offering a `LanguagePickerButton`/picker bound to a `nemotronDefaultLanguage` view-model property limited to `NemotronLanguageCatalog.supportedCodes` (no tuning card — Nemotron has no tuning knobs). Compose it next to `engineLanguageCard` at line ~380.

- [ ] **Step 3: Build the app target**

Run: `swift build --target MacParakeet`
Expected: builds.

- [ ] **Step 4: Manual visual check (with flag temporarily on, locally only)**

Temporarily set `nemotronEnabled = true` **locally, do not commit**, run `scripts/dev/run_app.sh`, open Settings → Speech Recognition, confirm three tiles lay out cleanly and the Nemotron language card appears when selected. Revert the flag to `false`.

- [ ] **Step 5: Commit (flag stays false)**

```bash
git add Sources/MacParakeet/Views/Settings/SettingsView.swift
git commit -m "feat(ui): flag-gated Nemotron engine tile + language card"
```

---

# Phase 6 — Docs, traceability, final verification

### Task 6.1: Update specs and READMEs

**Files:**
- Modify: `spec/06-stt-engine.md` (add a Nemotron engine subsection after the WhisperKit table)
- Modify: `spec/README.md`, `spec/02-features.md` (progress note: ADR-023 Nemotron engine, flag-gated)
- Modify: `Sources/MacParakeetCore/STT/README.md` (note the third engine + that the scheduler is unchanged; routing in `STTRuntime`)
- Modify: `spec/kernel/requirements.yaml` + `spec/kernel/traceability.md` if a requirement ID is warranted for this user-visible (eventual) behavior

- [ ] **Step 1: Add the Nemotron engine subsection to `spec/06-stt-engine.md`**

Mirror the WhisperKit table: model = Nemotron 3.5 ASR Streaming Multilingual 0.6B (Latin-pruned), runtime FluidAudio CoreML/ANE, output = text + derived word timing (coarse, synthetic confidence), languages = EN/ES/FR/IT/PT/DE, selection explicit + flag-gated, status = built but disabled (ADR-023 §8 license gate).

- [ ] **Step 2: Add the STT README note**

In `Sources/MacParakeetCore/STT/README.md`, under "Engine routing", note `.nemotron` is dispatched by `STTRuntime` like `.whisper`, European-only, flag-gated, and that the scheduler is unchanged.

- [ ] **Step 3: Cross-reference + traceability**

Add ADR-023 to the ADR index table in `CLAUDE.md` (and `spec/README.md`'s ADR list). Add a requirement ID if the kernel tracks user-visible engine behavior; update `traceability.md` source/test mappings for the new files.

- [ ] **Step 4: Commit**

```bash
git add spec Sources/MacParakeetCore/STT/README.md CLAUDE.md
git commit -m "docs(stt): document Nemotron engine (flag-gated) across specs + READMEs"
```

### Task 6.2: Full verification

- [ ] **Step 1: Full deterministic suite**

Run: `swift test`
Expected: PASS — baseline count + all new tests; no regressions.

- [ ] **Step 2: STT-focused subset**

Run: `swift test --filter STT && swift test --filter Nemotron`
Expected: PASS.

- [ ] **Step 3: Build all targets (no broken switches anywhere)**

Run: `swift build`
Expected: builds with zero warnings introduced for non-exhaustive switches.

- [ ] **Step 4: Confirm the flag is off and nothing fetches the model**

Run: `grep -n 'nemotronEnabled' Sources/MacParakeetCore/AppFeatures.swift`
Expected: `public static let nemotronEnabled: Bool = false`.
Manually confirm (read) that every download/selection path is reached only under `AppFeatures.nemotronEnabled` or the CLI runtime gate.

- [ ] **Step 5: Launch the dev app (flag off — regression check)**

Run: `scripts/dev/run_app.sh`
Expected: app launches; Settings → Speech Recognition shows exactly the existing two engines (Parakeet + Whisper); no Nemotron surface; existing dictation/transcription unaffected.

- [ ] **Step 6: Archive the plan**

Move this plan to `plans/completed/` once all tasks are checked and merged.

---

## Self-Review (completed during authoring)

- **Spec coverage:** ADR-023 §1 (enum) → Task 1.3; §2 (batch) → Task 2.2; §3 (NemotronEngine) → 2.2; §4 (European-only/`latin` routing + catalog) → 1.2/2.2; §5 (timing) → 2.2; §6 (routing/selection language/alternative/meeting guard) → 1.3/3.1/3.3; §7 (flag) → 1.1 + gating throughout; §8 (license gate) → flag default false + CLI/models runtime gates (the human checklist is non-code); §9 (attribution) → deferred to flip-on, noted in 6.1; §10 (CLI) → 4.1/4.2; §11 (storage/telemetry/onboarding) → 2.1/3.2 (+ onboarding confirmed needs no change, ADR-023 §11); §12 (bump) → Phase 0. Covered.
- **Placeholder scan:** the FluidAudio "verify against resolved package" steps are real verification actions with concrete starting code, not placeholders; license-gate human steps live in ADR-023 §8 by design.
- **Type consistency:** `mapTokenTimings`, `localModelFolder`, `isModelDownloaded`, `downloadModel`, `variantLabel`, `nemotronDefaultLanguage`/`saveNemotronDefaultLanguage`, `normalizeNemotronLanguage`, `nemotronModelsDir`, `TelemetryModelKind.nemotronSTT`, `displayedNemotronModelStatus` are named consistently across tasks.
