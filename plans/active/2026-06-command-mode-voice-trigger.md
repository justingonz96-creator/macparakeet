# Command Mode — Voice Trigger Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a hold-to-talk voice trigger to the Transforms rewrite primitive — select text, hold a dedicated hotkey, speak an instruction, and the selection is rewritten in place — with a deterministic-first router so "scratch that" and case/trim run offline with no LLM.

**Architecture:** Reuse the shipped ADR-022 pipeline (`SelectionCaptureService` → LLM → `SelectionReplacementService`). New code is four pure/actor Core units (`CommandModeRouter`, `DeterministicTextEdit`, `CommandModePrompts`, `CommandModeExecutor`), a process-wide `MicrophoneArbiter`, a hold-gesture event tap (`CommandModeHotkeyMonitor`), and a thin `CommandModeCoordinator`. The existing `TransformExecutor` is untouched.

**Tech Stack:** Swift 6 (strict concurrency), XCTest, GRDB (unaffected), FluidAudio/WhisperKit STT (reused via `STTScheduler`), AppKit AX + pasteboard (reused).

**Spec:** `docs/superpowers/specs/2026-06-27-command-mode-voice-trigger-design.md` · **ADR:** `spec/adr/023-command-mode-voice-trigger.md`

**Conventions:**
- Run focused tests with: `swift test --filter <TestClassName>`
- Full suite: `swift test`
- Test target is `MacParakeetTests`; use `@testable import MacParakeetCore` to reach internal backends.
- Commit after each task with the message shown in its final step.

---

## Task 1: `DeterministicCommand` + `DeterministicTextEdit` (pure)

The offline edits applied to the captured selection. `clearSelection` is a *deletion*
handled at the executor (Task 5); `apply` returns `""` for it for completeness but the
executor never pastes that empty string.

**Files:**
- Create: `Sources/MacParakeetCore/Services/CommandMode/DeterministicTextEdit.swift`
- Test: `Tests/MacParakeetTests/Services/CommandMode/DeterministicTextEditTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import MacParakeetCore

final class DeterministicTextEditTests: XCTestCase {
    func testUppercase() {
        XCTAssertEqual(DeterministicTextEdit.apply(.uppercase, to: "hello world"), "HELLO WORLD")
    }

    func testLowercase() {
        XCTAssertEqual(DeterministicTextEdit.apply(.lowercase, to: "HELLO World"), "hello world")
    }

    func testTitleCase() {
        XCTAssertEqual(DeterministicTextEdit.apply(.titleCase, to: "the quick brown fox"), "The Quick Brown Fox")
    }

    func testTrimCollapsesInternalAndEdgeWhitespace() {
        XCTAssertEqual(DeterministicTextEdit.apply(.trim, to: "  hello   world \n  x "), "hello world x")
    }

    func testClearSelectionReturnsEmpty() {
        XCTAssertEqual(DeterministicTextEdit.apply(.clearSelection, to: "anything"), "")
    }

    func testUppercaseUnicode() {
        XCTAssertEqual(DeterministicTextEdit.apply(.uppercase, to: "café"), "CAFÉ")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter DeterministicTextEditTests`
Expected: FAIL — `DeterministicCommand` / `DeterministicTextEdit` not found.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// Offline, deterministic edits applied to a captured selection in Command Mode.
/// No LLM, no I/O — pure string transforms. `clearSelection` is a deletion handled
/// by `CommandModeExecutor` (it must not be pasted as an empty string).
public enum DeterministicCommand: String, Sendable, Equatable, CaseIterable {
    case clearSelection
    case uppercase
    case lowercase
    case titleCase
    case trim
}

public enum DeterministicTextEdit {
    /// Pure transform of the selection for the case/trim commands. Returns "" for
    /// `clearSelection` (the executor routes that to a deletion path instead of a paste).
    public static func apply(_ command: DeterministicCommand, to text: String) -> String {
        switch command {
        case .clearSelection:
            return ""
        case .uppercase:
            return text.uppercased()
        case .lowercase:
            return text.lowercased()
        case .titleCase:
            return text.capitalized
        case .trim:
            return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter DeterministicTextEditTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/MacParakeetCore/Services/CommandMode/DeterministicTextEdit.swift Tests/MacParakeetTests/Services/CommandMode/DeterministicTextEditTests.swift
git commit -m "feat(command-mode): add deterministic offline text edits"
```

---

## Task 2: `CommandModePrompts` (pure)

Wraps a spoken instruction into a transform prompt for `LLMService.transformStream`.

**Files:**
- Create: `Sources/MacParakeetCore/Services/CommandMode/CommandModePrompts.swift`
- Test: `Tests/MacParakeetTests/Services/CommandMode/CommandModePromptsTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import MacParakeetCore

final class CommandModePromptsTests: XCTestCase {
    func testEmbedsInstruction() {
        let prompt = CommandModePrompts.rewriteInstruction("make this more formal")
        XCTAssertTrue(prompt.contains("make this more formal"))
    }

    func testAsksForOnlyEditedText() {
        let prompt = CommandModePrompts.rewriteInstruction("summarize as bullets")
        XCTAssertTrue(prompt.lowercased().contains("only the edited text"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter CommandModePromptsTests`
Expected: FAIL — `CommandModePrompts` not found.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// Builds the LLM directive for a spoken Command Mode instruction. The selected
/// text is passed separately as `transformStream(text:)`; this is only the prompt.
public enum CommandModePrompts {
    public static func rewriteInstruction(_ instruction: String) -> String {
        """
        Apply this instruction to the text: "\(instruction)". \
        Return only the edited text — no preamble, no explanation, no quotes. \
        Preserve the original meaning and language unless the instruction says otherwise.
        """
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter CommandModePromptsTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/MacParakeetCore/Services/CommandMode/CommandModePrompts.swift Tests/MacParakeetTests/Services/CommandMode/CommandModePromptsTests.swift
git commit -m "feat(command-mode): add rewrite-instruction prompt builder"
```

---

## Task 3: `CommandModeRouter` + `CommandModeAction` (pure)

The entire "intent" surface: a pure function from instruction string → action.

**Files:**
- Create: `Sources/MacParakeetCore/Services/CommandMode/CommandModeRouter.swift`
- Test: `Tests/MacParakeetTests/Services/CommandMode/CommandModeRouterTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import MacParakeetCore

final class CommandModeRouterTests: XCTestCase {
    private let router = CommandModeRouter()

    func testScratchThatFamilyIsDeterministicClear() {
        for phrase in ["scratch that", "Scratch that.", "delete that", "remove that", "undo that"] {
            XCTAssertEqual(router.route(instruction: phrase), .deterministic(.clearSelection), "phrase: \(phrase)")
        }
    }

    func testCaseAndTrimPhrases() {
        XCTAssertEqual(router.route(instruction: "uppercase that"), .deterministic(.uppercase))
        XCTAssertEqual(router.route(instruction: "all caps"), .deterministic(.uppercase))
        XCTAssertEqual(router.route(instruction: "lowercase that"), .deterministic(.lowercase))
        XCTAssertEqual(router.route(instruction: "title case that"), .deterministic(.titleCase))
        XCTAssertEqual(router.route(instruction: "capitalize that"), .deterministic(.titleCase))
        XCTAssertEqual(router.route(instruction: "trim that"), .deterministic(.trim))
    }

    func testNormalizationIgnoresCasePunctuationAndWhitespace() {
        XCTAssertEqual(router.route(instruction: "  SCRATCH   that!! "), .deterministic(.clearSelection))
    }

    func testRicherInstructionFallsThroughToRewrite() {
        // "make this a list" is NOT deterministic — it must become a provider rewrite.
        guard case .rewrite(let prompt) = router.route(instruction: "make this a list") else {
            return XCTFail("expected .rewrite")
        }
        XCTAssertTrue(prompt.contains("make this a list"))
    }

    func testNearMissIsRewriteNotDeterministic() {
        guard case .rewrite = router.route(instruction: "scratch the whole paragraph") else {
            return XCTFail("expected .rewrite for a non-exact phrase")
        }
    }

    func testEmptyOrWhitespaceIsEmpty() {
        XCTAssertEqual(router.route(instruction: ""), .empty)
        XCTAssertEqual(router.route(instruction: "   \n "), .empty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter CommandModeRouterTests`
Expected: FAIL — `CommandModeRouter` / `CommandModeAction` not found.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

public enum CommandModeAction: Sendable, Equatable {
    case deterministic(DeterministicCommand)
    case rewrite(prompt: String)
    case empty
}

/// Pure classifier: spoken instruction → deterministic offline command, provider
/// rewrite, or empty. Exact normalized-phrase matching keeps real rewrite requests
/// from being swallowed by the offline table.
public struct CommandModeRouter: Sendable {
    public init() {}

    private static let phraseTable: [String: DeterministicCommand] = [
        "scratch that": .clearSelection,
        "delete that": .clearSelection,
        "remove that": .clearSelection,
        "undo that": .clearSelection,
        "uppercase that": .uppercase,
        "make it uppercase": .uppercase,
        "all caps": .uppercase,
        "make it all caps": .uppercase,
        "lowercase that": .lowercase,
        "make it lowercase": .lowercase,
        "title case that": .titleCase,
        "title case": .titleCase,
        "capitalize that": .titleCase,
        "trim that": .trim,
        "trim whitespace": .trim,
        "trim it": .trim,
    ]

    public func route(instruction: String) -> CommandModeAction {
        let normalized = Self.normalize(instruction)
        if normalized.isEmpty { return .empty }
        if let command = Self.phraseTable[normalized] {
            return .deterministic(command)
        }
        return .rewrite(prompt: CommandModePrompts.rewriteInstruction(instruction))
    }

    /// Lowercase, trim, drop trailing punctuation, collapse internal whitespace.
    static func normalize(_ raw: String) -> String {
        let lowered = raw.lowercased()
        let collapsed = lowered.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let trailingPunctuation = CharacterSet(charactersIn: ".!?…,")
        var scalars = Array(collapsed.unicodeScalars)
        while let last = scalars.last, trailingPunctuation.contains(last) || CharacterSet.whitespaces.contains(last) {
            scalars.removeLast()
        }
        return String(String.UnicodeScalarView(scalars))
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter CommandModeRouterTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/MacParakeetCore/Services/CommandMode/CommandModeRouter.swift Tests/MacParakeetTests/Services/CommandMode/CommandModeRouterTests.swift
git commit -m "feat(command-mode): add deterministic-first instruction router"
```

---

## Task 4: `SelectionReplacementService.deleteSelection` + backend `postDeleteKey`

"scratch that" must delete the selection without pasting an empty string (a
`setString("") + Cmd+V` no-ops in several apps and dirties the clipboard).

**Files:**
- Modify: `Sources/MacParakeetCore/Services/System/SelectionReplacementService.swift`
  (add `postDeleteKey()` to the `SelectionReplacementBackend` protocol ~line 55, implement
  it in `SystemSelectionReplacementBackend` near `postCmdV` ~line 397, add a public
  `deleteSelection(in:)` method near `replace(with:in:mode:)` ~line 136)
- Test: `Tests/MacParakeetTests/Services/CommandMode/SelectionDeletionTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
import AppKit
@testable import MacParakeetCore

final class SelectionDeletionTests: XCTestCase {
    func testAXCaptureDeletesViaEmptyAXWriteNotPaste() async throws {
        let backend = FakeCommandModeReplacementBackend()
        let service = SelectionReplacementService(backend: backend)
        let captured = SelectionCaptureResult.ax(
            text: "regret",
            element: AXFocusedElement(AXUIElementCreateSystemWide()),
            target: nil
        )
        let path = try await service.deleteSelection(in: captured)
        XCTAssertEqual(path, .ax)
        XCTAssertEqual(backend.axWrites, [""])
        XCTAssertTrue(backend.pasteWrites.isEmpty, "must never paste for a deletion")
        XCTAssertEqual(backend.deleteKeyCount, 0)
    }

    func testClipboardCaptureDeletesViaDeleteKeyNotPaste() async throws {
        let backend = FakeCommandModeReplacementBackend()
        let service = SelectionReplacementService(backend: backend)
        let captured = SelectionCaptureResult.clipboard(
            text: "regret",
            savedClipboard: .none,
            target: nil
        )
        let path = try await service.deleteSelection(in: captured)
        XCTAssertEqual(path, .clipboardPaste)
        XCTAssertEqual(backend.deleteKeyCount, 1)
        XCTAssertTrue(backend.pasteWrites.isEmpty, "must never write '' to the clipboard")
    }

    func testEmptyCaptureThrows() async {
        let service = SelectionReplacementService(backend: FakeCommandModeReplacementBackend())
        do {
            _ = try await service.deleteSelection(in: .empty)
            XCTFail("expected throw")
        } catch {
            // expected
        }
    }
}
```

(`FakeCommandModeReplacementBackend` is created in Task 5, Step 1. If running Task 4
in isolation, create that helper file first — it is shared by Tasks 4 and 5.)

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SelectionDeletionTests`
Expected: FAIL — `deleteSelection` not found / `postDeleteKey` not in backend.

- [ ] **Step 3: Add `postDeleteKey()` to the backend protocol**

In `SelectionReplacementService.swift`, in `protocol SelectionReplacementBackend`, add after `postCmdV()`:

```swift
    @MainActor
    func postDeleteKey() throws
```

- [ ] **Step 4: Implement `postDeleteKey()` in `SystemSelectionReplacementBackend`**

Add next to `postCmdV()` (mirror its structure; keyCode `0x33` is Delete/Backspace,
which deletes the current selection; no modifier flags):

```swift
@MainActor
func postDeleteKey() throws {
    guard AXIsProcessTrusted() else {
        throw SelectionReplacementError.accessibilityNotAuthorized
    }
    guard let source = CGEventSource(stateID: .hidSystemState) else {
        throw SelectionReplacementError.eventSourceUnavailable
    }
    let deleteKeyCode: CGKeyCode = 0x33 // Delete (Backspace) — removes the selection
    guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: deleteKeyCode, keyDown: true),
          let keyUp = CGEvent(keyboardEventSource: source, virtualKey: deleteKeyCode, keyDown: false) else {
        throw SelectionReplacementError.eventPostingFailed
    }
    keyDown.flags = []
    keyUp.flags = []
    keyDown.post(tap: .cghidEventTap)
    keyUp.post(tap: .cghidEventTap)
}
```

- [ ] **Step 5: Add the public `deleteSelection(in:)` method**

Add to `SelectionReplacementService` (next to `replace(...)`):

```swift
/// Delete the captured selection deterministically (for the "scratch that" family).
/// Never pastes an empty string: AX captures set the selected text to "" directly;
/// clipboard-fallback captures post a Delete keystroke to the focused field.
@discardableResult
public func deleteSelection(in context: SelectionCaptureResult) async throws -> SelectionReplacementPath {
    switch context {
    case .ax(_, let focused, _):
        if backend.writeSelectionViaAX("", element: focused.element) {
            return .ax
        }
        try await postDeleteKeyOnMain()
        return .clipboardPaste
    case .clipboard:
        try await postDeleteKeyOnMain()
        return .clipboardPaste
    case .empty, .failed:
        throw SelectionReplacementError.allPathsFailed
    }
}

private func postDeleteKeyOnMain() async throws {
    try await MainActor.run { try backend.postDeleteKey() }
}
```

- [ ] **Step 6: Run test to verify it passes**

Run: `swift test --filter SelectionDeletionTests`
Expected: PASS (3 tests).

- [ ] **Step 7: Commit**

```bash
git add Sources/MacParakeetCore/Services/System/SelectionReplacementService.swift Tests/MacParakeetTests/Services/CommandMode/SelectionDeletionTests.swift Tests/MacParakeetTests/Services/CommandMode/CommandModeTestFakes.swift
git commit -m "feat(command-mode): add deterministic deleteSelection (no empty-string paste)"
```

---

## Task 4B: Neutralize held-chord modifiers in synthetic keystrokes (design §4.9)

Command Mode posts Cmd+C (capture) and Cmd+V/Delete (apply) **while the chord is
physically held**, so macOS can OR-merge the held modifiers into the synthetic event
(⌥Space-held → ⌘⌥C). The mitigation: create the `CGEventSource` with `.privateState`
(which does not inherit the live hardware modifier state) and continue to set
`event.flags` explicitly. This is mostly a behavioral fix verified by the manual matrix
(Task 14), but the source change is a discrete, low-risk edit.

> Shared-path note: `postCmdC` / `postCmdV` are also used by Transforms (one-shot, chord
> already released), so this change must be re-validated against Transforms for
> regressions in Task 14. If `.privateState` proves insufficient in the matrix, the
> documented fallback (§4.9) is to defer the Cmd+C until the chord's modifiers are
> observed cleared (poll `CGEventSource.flagsState(.combinedSessionState)` for the
> chord bits to drop) before posting.

**Files:**
- Modify: `Sources/MacParakeetCore/Services/System/SelectionCaptureService.swift`
  (`SystemSelectionCaptureBackend.postCmdC`, ~line 411)
- Modify: `Sources/MacParakeetCore/Services/System/SelectionReplacementService.swift`
  (`SystemSelectionReplacementBackend.postCmdV` ~line 397 and the new `postDeleteKey`)

- [ ] **Step 1: Switch the event source to `.privateState` in all three posters**

In each of `postCmdC`, `postCmdV`, and `postDeleteKey`, change:

```swift
guard let source = CGEventSource(stateID: .hidSystemState) else {
```

to:

```swift
// .privateState does not carry the live hardware modifier state, so a physically
// held Command Mode chord is not OR-merged into the synthetic keystroke (ADR-023 §2/§4.9).
guard let source = CGEventSource(stateID: .privateState) else {
```

Keep the explicit `keyDown.flags = .maskCommand` / `keyUp.flags = .maskCommand` (and
`[]` for Delete) lines exactly as they are.

- [ ] **Step 2: Build + run the existing capture/replace tests for regressions**

Run: `swift test --filter SelectionCaptureServiceTests` then `swift test --filter SelectionReplacementServiceTests`
Expected: PASS (no behavior change under test — the source ID isn't asserted on; this is
validated for real in the Task 14 manual matrix).

- [ ] **Step 3: Commit**

```bash
git add Sources/MacParakeetCore/Services/System/SelectionCaptureService.swift Sources/MacParakeetCore/Services/System/SelectionReplacementService.swift
git commit -m "fix(command-mode): post synthetic keystrokes from a private event source (held-chord safety)"
```

---

## Task 5: `CommandModeExecutor` + result/progress/error types + shared test fakes

The Core actor that wires route → (deterministic edit | delete | LLM rewrite) → replace,
with restore-on-abandon. Mic + STT + capture happen in the coordinator (Task 11).

**Files:**
- Create: `Sources/MacParakeetCore/Services/CommandMode/CommandModeExecutor.swift`
- Create: `Tests/MacParakeetTests/Services/CommandMode/CommandModeTestFakes.swift` (shared with Task 4)
- Test: `Tests/MacParakeetTests/Services/CommandMode/CommandModeExecutorTests.swift`

- [ ] **Step 1: Create the shared test fakes**

`Tests/MacParakeetTests/Services/CommandMode/CommandModeTestFakes.swift`:

```swift
import AppKit
import Foundation
import os
@testable import MacParakeetCore

/// Records replacement-backend interactions for Command Mode tests.
final class FakeCommandModeReplacementBackend: SelectionReplacementBackend, @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<State>(initialState: State())
    struct State {
        var axWrites: [String] = []
        var pasteWrites: [String] = []
        var deleteKeyCount = 0
        var cmdVCount = 0
        var changeCount = 100
    }

    var axWrites: [String] { lock.withLock { $0.axWrites } }
    var pasteWrites: [String] { lock.withLock { $0.pasteWrites } }
    var deleteKeyCount: Int { lock.withLock { $0.deleteKeyCount } }

    func isAccessibilityTrusted() -> Bool { true }
    func writeSelectionViaAX(_ text: String, element: AXUIElement) -> Bool {
        lock.withLock { $0.axWrites.append(text) }
        return true
    }
    @MainActor func writePasteboardString(_ text: String) -> Bool {
        lock.withLock { $0.pasteWrites.append(text); $0.changeCount += 1 }
        return true
    }
    @MainActor func activateApplication(target: SelectionCaptureTarget) -> Bool { true }
    @MainActor func isFrontmostApplication(target: SelectionCaptureTarget) -> Bool { true }
    @MainActor func postCmdV() throws { lock.withLock { $0.cmdVCount += 1 } }
    @MainActor func postDeleteKey() throws { lock.withLock { $0.deleteKeyCount += 1 } }
    @MainActor func currentChangeCount() -> Int { lock.withLock { $0.changeCount } }
    @MainActor func snapshotPasteboard() -> PasteboardSnapshot { .none }
    @MainActor func restoreSnapshot(_ snapshot: PasteboardSnapshot) {}
}

/// Records clipboard-restore interactions for Command Mode tests.
final class FakeCommandModeCaptureBackend: SelectionCaptureBackend, @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<Int>(initialState: 0)
    var restoreCount: Int { lock.withLock { $0 } }

    func isAccessibilityTrusted() -> Bool { true }
    func focusedElement() -> AXUIElement? { nil }
    func selectedText(of element: AXUIElement) -> String? { nil }
    @MainActor func frontmostApplicationTarget() -> SelectionCaptureTarget? { nil }
    @MainActor func snapshotPasteboard() -> PasteboardSnapshot { .none }
    @MainActor func currentPasteboardString() -> String? { nil }
    @MainActor func currentPasteboardChangeCount() -> Int { 0 }
    @MainActor func postCmdC() throws {}
    @MainActor func restoreSnapshot(_ snapshot: PasteboardSnapshot) {
        lock.withLock { $0 += 1 }
    }
}

/// Mock LLM that counts `transformStream` calls and yields canned tokens or throws.
final class MockCommandModeLLMService: LLMServiceProtocol, @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<Int>(initialState: 0)
    var streamTokens: [String] = ["rewritten"]
    var streamError: Error?
    var callCount: Int { lock.withLock { $0 } }

    func transformStream(text: String, prompt: String) -> AsyncThrowingStream<String, Error> {
        lock.withLock { $0 += 1 }
        let tokens = streamTokens
        let error = streamError
        return AsyncThrowingStream { continuation in
            if let error { continuation.finish(throwing: error); return }
            for token in tokens { continuation.yield(token) }
            continuation.finish()
        }
    }

    // Unused protocol requirements.
    func generatePromptResult(transcript: String, systemPrompt: String?) async throws -> String { "" }
    func chat(question: String, transcript: String, userNotes: String?, history: [ChatMessage], source: TelemetryChatSource) async throws -> String { "" }
    func transform(text: String, prompt: String) async throws -> String { "" }
    func formatTranscript(transcript: String, promptTemplate: String, source: TelemetryFormatterSource, defaultPromptUsed: Bool) async throws -> String { "" }
    func generatePromptResultStream(transcript: String, systemPrompt: String?) -> AsyncThrowingStream<String, Error> { AsyncThrowingStream { $0.finish() } }
    func chatStream(question: String, transcript: String, userNotes: String?, history: [ChatMessage], source: TelemetryChatSource) -> AsyncThrowingStream<String, Error> { AsyncThrowingStream { $0.finish() } }
    func generatePromptResultDetailed(transcript: String, systemPrompt: String?) async throws -> LLMResult { LLMResult(output: "", provider: "mock", model: "mock", latencyMs: 0) }
    func chatDetailed(question: String, transcript: String, userNotes: String?, history: [ChatMessage], source: TelemetryChatSource) async throws -> LLMResult { LLMResult(output: "", provider: "mock", model: "mock", latencyMs: 0) }
    func transformDetailed(text: String, prompt: String) async throws -> LLMResult { LLMResult(output: "", provider: "mock", model: "mock", latencyMs: 0) }
    func formatTranscriptDetailed(transcript: String, promptTemplate: String, source: TelemetryFormatterSource, defaultPromptUsed: Bool) async throws -> LLMFormatterResult {
        LLMFormatterResult(result: LLMResult(output: "", provider: "mock", model: "mock", latencyMs: 0), operationID: "mock", inputChars: 0, outputChars: 0, inputTruncated: false, defaultPromptUsed: defaultPromptUsed, messageCount: 2)
    }
}
```

> Note: verify `LLMServiceProtocol`'s member list against
> `Sources/MacParakeetCore/Services/LLM/LLMService.swift` at implementation time and
> add any stubs the compiler reports missing (the unused set above mirrors
> `MockTransformLLMService`).

- [ ] **Step 2: Write the failing executor test**

`Tests/MacParakeetTests/Services/CommandMode/CommandModeExecutorTests.swift`:

```swift
import XCTest
import AppKit
@testable import MacParakeetCore

final class CommandModeExecutorTests: XCTestCase {
    private func makeExecutor(
        llm: MockCommandModeLLMService? = MockCommandModeLLMService(),
        replacement: FakeCommandModeReplacementBackend,
        capture: FakeCommandModeCaptureBackend
    ) -> CommandModeExecutor {
        CommandModeExecutor(
            captureService: SelectionCaptureService(backend: capture),
            replacementService: SelectionReplacementService(backend: replacement),
            llmServiceProvider: { llm }
        )
    }

    private func clipboardCapture(_ text: String) -> SelectionCaptureResult {
        .clipboard(text: text, savedClipboard: .none, target: nil)
    }

    func testDeterministicCaseNeverCallsLLM() async throws {
        let llm = MockCommandModeLLMService()
        let repl = FakeCommandModeReplacementBackend()
        let executor = makeExecutor(llm: llm, replacement: repl, capture: FakeCommandModeCaptureBackend())
        let result = try await executor.run(instruction: "uppercase that", captured: clipboardCapture("hi there")) { _ in }
        XCTAssertEqual(result.outputText, "HI THERE")
        XCTAssertEqual(result.applied, .deterministic(.uppercase))
        XCTAssertEqual(llm.callCount, 0)
    }

    func testClearSelectionDeletesWithoutPasteOrEmptyClipboard() async throws {
        let llm = MockCommandModeLLMService()
        let repl = FakeCommandModeReplacementBackend()
        let executor = makeExecutor(llm: llm, replacement: repl, capture: FakeCommandModeCaptureBackend())
        let result = try await executor.run(instruction: "scratch that", captured: clipboardCapture("regret")) { _ in }
        XCTAssertEqual(result.outputText, "")
        XCTAssertEqual(result.applied, .deterministic(.clearSelection))
        XCTAssertEqual(repl.deleteKeyCount, 1)
        XCTAssertTrue(repl.pasteWrites.isEmpty)
        XCTAssertEqual(llm.callCount, 0)
    }

    func testRewriteCallsLLMOnce() async throws {
        let llm = MockCommandModeLLMService()
        llm.streamTokens = ["• one", " • two"]
        let executor = makeExecutor(llm: llm, replacement: FakeCommandModeReplacementBackend(), capture: FakeCommandModeCaptureBackend())
        let result = try await executor.run(instruction: "make this a list", captured: clipboardCapture("one two")) { _ in }
        XCTAssertEqual(result.outputText, "• one • two")
        XCTAssertEqual(result.applied, .rewrite)
        XCTAssertEqual(llm.callCount, 1)
    }

    func testEmptySelectionThrows() async {
        let executor = makeExecutor(replacement: FakeCommandModeReplacementBackend(), capture: FakeCommandModeCaptureBackend())
        await assertThrows(executor, instruction: "uppercase that", captured: .empty) {
            guard case .emptySelection = $0 else { return false }; return true
        }
    }

    func testEmptyInstructionThrowsAndRestoresClipboard() async {
        let capture = FakeCommandModeCaptureBackend()
        let executor = makeExecutor(replacement: FakeCommandModeReplacementBackend(), capture: capture)
        await assertThrows(executor, instruction: "   ", captured: clipboardCapture("x")) {
            guard case .emptyInstruction = $0 else { return false }; return true
        }
        XCTAssertEqual(capture.restoreCount, 1, "clipboard must be restored on empty-instruction abort")
    }

    func testRewriteWithNoProviderThrowsAndRestores() async {
        let capture = FakeCommandModeCaptureBackend()
        let executor = makeExecutor(llm: nil, replacement: FakeCommandModeReplacementBackend(), capture: capture)
        await assertThrows(executor, instruction: "make this a list", captured: clipboardCapture("x")) {
            guard case .llmNotConfigured = $0 else { return false }; return true
        }
        XCTAssertEqual(capture.restoreCount, 1)
    }

    // Helper
    private func assertThrows(
        _ executor: CommandModeExecutor,
        instruction: String,
        captured: SelectionCaptureResult,
        _ matches: (CommandModeExecutorError) -> Bool,
        file: StaticString = #file, line: UInt = #line
    ) async {
        do {
            _ = try await executor.run(instruction: instruction, captured: captured) { _ in }
            XCTFail("expected throw", file: file, line: line)
        } catch let error as CommandModeExecutorError {
            XCTAssertTrue(matches(error), "unexpected error: \(error)", file: file, line: line)
        } catch {
            XCTFail("unexpected error type: \(error)", file: file, line: line)
        }
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `swift test --filter CommandModeExecutorTests`
Expected: FAIL — `CommandModeExecutor` not found.

- [ ] **Step 4: Implement the executor**

`Sources/MacParakeetCore/Services/CommandMode/CommandModeExecutor.swift`:

```swift
import Foundation
import OSLog

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

public struct CommandModeResult: Sendable {
    public let inputText: String
    public let outputText: String
    public let applied: CommandModeAppliedKind
    public let replacePath: SelectionReplacementPath
    public let totalElapsedMs: Int
    public let llmElapsedMs: Int
    public let captureTag: String
    public let target: SelectionCaptureTarget?
}

public enum CommandModeExecutorError: Error, LocalizedError, Sendable {
    case emptySelection
    case emptyInstruction
    case llmNotConfigured
    case llmFailed(String)
    case replacementFailed(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .emptySelection:
            return "Select text first — highlight what you want to change, then hold the key and speak."
        case .emptyInstruction:
            return "Didn't catch that — try again."
        case .llmNotConfigured:
            return "Command Mode rewrites need an LLM provider — configure one in Settings."
        case .llmFailed(let detail):
            return "Command Mode failed: \(detail)"
        case .replacementFailed(let detail):
            return "Command Mode couldn't apply the change: \(detail)"
        case .cancelled:
            return "Command Mode cancelled."
        }
    }
}

/// Routes a spoken instruction over a captured selection: deterministic offline edit,
/// deterministic deletion, or provider rewrite — then replaces in place. Mirrors
/// `TransformExecutor`'s restore-on-abandon and run-to-completion-on-replace safety.
public actor CommandModeExecutor {
    private let captureService: SelectionCaptureService
    private let replacementService: SelectionReplacementService
    private let llmServiceProvider: @Sendable () -> LLMServiceProtocol?
    private let router: CommandModeRouter
    private let logger = Logger(subsystem: "com.macparakeet.core", category: "CommandModeExecutor")

    public init(
        captureService: SelectionCaptureService = SelectionCaptureService(),
        replacementService: SelectionReplacementService = SelectionReplacementService(),
        llmServiceProvider: @escaping @Sendable () -> LLMServiceProtocol?,
        router: CommandModeRouter = CommandModeRouter()
    ) {
        self.captureService = captureService
        self.replacementService = replacementService
        self.llmServiceProvider = llmServiceProvider
        self.router = router
    }

    public func run(
        instruction: String,
        captured: SelectionCaptureResult,
        onProgress: @escaping @Sendable (CommandModeProgress) -> Void
    ) async throws -> CommandModeResult {
        let start = ContinuousClock.now

        guard let inputText = captured.capturedText, !inputText.isEmpty else {
            await captureService.restoreClipboardCaptureIfCurrent(captured)
            onProgress(.failed(CommandModeExecutorError.emptySelection.localizedDescription))
            throw CommandModeExecutorError.emptySelection
        }

        onProgress(.routing)
        let action = router.route(instruction: instruction)

        let outputText: String
        let appliedKind: CommandModeAppliedKind
        var llmElapsedMs = 0
        let path: SelectionReplacementPath

        switch action {
        case .empty:
            await captureService.restoreClipboardCaptureIfCurrent(captured)
            onProgress(.failed(CommandModeExecutorError.emptyInstruction.localizedDescription))
            throw CommandModeExecutorError.emptyInstruction

        case .deterministic(.clearSelection):
            appliedKind = .deterministic(.clearSelection)
            onProgress(.deterministicApplied(.clearSelection))
            onProgress(.pasting)
            do {
                path = try await replacementService.deleteSelection(in: captured)
            } catch {
                onProgress(.failed(error.localizedDescription))
                throw CommandModeExecutorError.replacementFailed(error.localizedDescription)
            }
            outputText = ""

        case .deterministic(let command):
            appliedKind = .deterministic(command)
            outputText = DeterministicTextEdit.apply(command, to: inputText)
            onProgress(.deterministicApplied(command))
            onProgress(.pasting)
            do {
                path = try await replacementService.replace(with: outputText, in: captured, mode: .pasteIntoCurrentFocus)
            } catch {
                onProgress(.failed(error.localizedDescription))
                throw CommandModeExecutorError.replacementFailed(error.localizedDescription)
            }

        case .rewrite(let prompt):
            guard let llm = llmServiceProvider() else {
                await captureService.restoreClipboardCaptureIfCurrent(captured)
                onProgress(.failed(CommandModeExecutorError.llmNotConfigured.localizedDescription))
                throw CommandModeExecutorError.llmNotConfigured
            }
            onProgress(.llmStarted)
            let llmStart = ContinuousClock.now
            var accumulated = ""
            do {
                for try await chunk in llm.transformStream(text: inputText, prompt: prompt) {
                    try Task.checkCancellation()
                    accumulated += chunk
                    onProgress(.llmStreaming(accumulated))
                }
            } catch is CancellationError {
                await captureService.restoreClipboardCaptureIfCurrent(captured)
                onProgress(.failed(CommandModeExecutorError.cancelled.localizedDescription))
                throw CommandModeExecutorError.cancelled
            } catch let error as LLMError {
                // LLMError is NOT Equatable — pattern-match, don't use `==` (mirrors TransformExecutor.swift:170).
                await captureService.restoreClipboardCaptureIfCurrent(captured)
                if case .notConfigured = error {
                    onProgress(.failed(CommandModeExecutorError.llmNotConfigured.localizedDescription))
                    throw CommandModeExecutorError.llmNotConfigured
                }
                onProgress(.failed(CommandModeExecutorError.llmFailed(error.localizedDescription).localizedDescription))
                throw CommandModeExecutorError.llmFailed(error.localizedDescription)
            } catch {
                await captureService.restoreClipboardCaptureIfCurrent(captured)
                onProgress(.failed(CommandModeExecutorError.llmFailed(error.localizedDescription).localizedDescription))
                throw CommandModeExecutorError.llmFailed(error.localizedDescription)
            }
            llmElapsedMs = Self.elapsedMs(from: llmStart)
            guard !accumulated.isEmpty else {
                await captureService.restoreClipboardCaptureIfCurrent(captured)
                onProgress(.failed(CommandModeExecutorError.llmFailed("Empty output.").localizedDescription))
                throw CommandModeExecutorError.llmFailed("Empty output.")
            }
            outputText = accumulated
            appliedKind = .rewrite
            onProgress(.pasting)
            do {
                path = try await replacementService.replace(with: outputText, in: captured, mode: .pasteIntoCurrentFocus)
            } catch {
                onProgress(.failed(error.localizedDescription))
                throw CommandModeExecutorError.replacementFailed(error.localizedDescription)
            }
        }

        onProgress(.done(path, appliedKind))
        return CommandModeResult(
            inputText: inputText,
            outputText: outputText,
            applied: appliedKind,
            replacePath: path,
            totalElapsedMs: Self.elapsedMs(from: start),
            llmElapsedMs: llmElapsedMs,
            captureTag: captured.pathTag,
            target: captured.target
        )
    }

    private static func elapsedMs(from start: ContinuousClock.Instant) -> Int {
        let elapsed = ContinuousClock.now - start
        let c = elapsed.components
        return Int(c.seconds) * 1000 + Int(c.attoseconds / 1_000_000_000_000_000)
    }
}
```

> `LLMError` is verified NOT `Equatable` (no `==`); the pattern-match form above is the
> primary, compiling form (matches `TransformExecutor`).

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --filter CommandModeExecutorTests`
Expected: PASS (6 tests).

- [ ] **Step 6: Commit**

```bash
git add Sources/MacParakeetCore/Services/CommandMode/CommandModeExecutor.swift Tests/MacParakeetTests/Services/CommandMode/
git commit -m "feat(command-mode): add CommandModeExecutor (route -> edit/delete/rewrite -> replace)"
```

---

## Task 6: `AppFeatures.commandModeEnabled`

**Files:**
- Modify: `Sources/MacParakeetCore/AppFeatures.swift` (after `transformsEnabled`, ~line 44)

- [ ] **Step 1: Add the flag**

```swift
    /// Command Mode — voice trigger over Transforms (ADR-023). When `true`:
    /// - the Command Mode hotkey recorder appears in Settings
    /// - `CommandModeHotkeyMonitor` installs its event tap on launch (dormant until
    ///   the user binds a key — the binding is the opt-in, this is the release gate)
    ///
    /// When `false`, the Settings row is hidden and no event tap is installed.
    /// Channel convention (mirrors `transformsEnabled`): `false` on the Stable DMG,
    /// `true` on `main`. Set `true` here for `main`.
    public static let commandModeEnabled: Bool = true
```

- [ ] **Step 2: Verify it compiles**

Run: `swift build`
Expected: builds cleanly.

- [ ] **Step 3: Commit**

```bash
git add Sources/MacParakeetCore/AppFeatures.swift
git commit -m "feat(command-mode): add commandModeEnabled release gate"
```

---

## Task 7: Telemetry events

Mirror the Transforms telemetry pattern: a `command_mode_executed` and a
`command_mode_failed` event, content-free.

**Files:**
- Modify: `Sources/MacParakeetCore/Services/Telemetry/TelemetryEvent.swift`
  (event-name enum ~line 47; supporting enums ~line 225; spec cases ~line 525; props
  ~line 1130; `TelemetryImplementedContract.requiredProps` ~line 1596)
- Modify: `Tests/MacParakeetTests/TelemetryServiceTests.swift` (`sampleEvents()` ~line 1251)

- [ ] **Step 1: Add the failing test sample events**

In `TelemetryServiceTests.swift`, inside `sampleEvents()` (next to the transform samples), add:

```swift
.commandModeExecuted(path: .deterministic, deterministicCommand: .clearSelection, llmMs: 0, totalMs: 40, appCategory: .notes),
.commandModeExecuted(path: .rewrite, deterministicCommand: .none, llmMs: 900, totalMs: 1200, appCategory: nil),
.commandModeFailed(reason: .noProvider),
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter TelemetryServiceTests`
Expected: FAIL — `commandModeExecuted` / `commandModeFailed` not found.

- [ ] **Step 3: Add the event names**

In the `TelemetryEventName` enum (with the other `transform_*` names):

```swift
    case commandModeExecuted = "command_mode_executed"
    case commandModeFailed = "command_mode_failed"
```

- [ ] **Step 4: Add supporting enums** (next to `TelemetryTransformFailureReason`):

```swift
public enum TelemetryCommandModePath: String, Sendable, Equatable {
    case deterministic
    case rewrite
}

public enum TelemetryCommandModeDeterministic: String, Sendable, Equatable {
    case none
    case clearSelection = "clear_selection"
    case uppercase
    case lowercase
    case titleCase = "title_case"
    case trim
}

public enum TelemetryCommandModeFailureReason: String, Sendable, Equatable {
    case emptySelection = "empty_selection"
    case emptyInstruction = "empty_instruction"
    case captureFailed = "capture_failed"
    case noProvider = "no_provider"
    case llmFailed = "llm_failed"
    case replacementFailed = "replacement_failed"
    case cancelled
}
```

- [ ] **Step 5: Add the spec cases** (next to `transformExecuted` ~line 525):

```swift
    case commandModeExecuted(
        path: TelemetryCommandModePath,
        deterministicCommand: TelemetryCommandModeDeterministic,
        llmMs: Int,
        totalMs: Int,
        appCategory: TelemetryAppCategory? = nil
    )
    case commandModeFailed(reason: TelemetryCommandModeFailureReason)
```

- [ ] **Step 6: Add the props mapping** (in the `props` switch ~line 1130):

```swift
    case .commandModeExecuted(let path, let det, let llmMs, let totalMs, let appCategory):
        return Self.compactProps(
            ("path", path.rawValue),
            ("deterministic_command", det.rawValue),
            ("llm_ms", "\(llmMs)"),
            ("total_ms", "\(totalMs)"),
            ("app_category", appCategory?.rawValue)
        )
    case .commandModeFailed(let reason):
        return ["reason": reason.rawValue]
```

- [ ] **Step 7: Add the required-props rows** (in `TelemetryImplementedContract.requiredProps`):

```swift
        .commandModeExecuted: ["path", "deterministic_command", "llm_ms", "total_ms"],
        .commandModeFailed: ["reason"],
```

**Also required — the `name` switch is exhaustive and the file will NOT compile without
these arms.** In `TelemetryEventSpec.name` (`TelemetryEvent.swift` ~lines 786–886, next to
the `transformExecuted`/`transformFailed` arms ~815), add:

```swift
    case .commandModeExecuted: return .commandModeExecuted
    case .commandModeFailed: return .commandModeFailed
```

(`TelemetryEventSpec` is the payload enum at `TelemetryEvent.swift:403`; `TelemetryEventName`
is the wire-name enum at line 3. There is no `default` arm in either the `name` or `props`
switch, so both must get the two cases — Step 6 handles `props`, this handles `name`.)

> Steps 3 (names) and 7 (requiredProps) must land **together**: the test
> `testImplementedContractMatchesEventNames` asserts `requiredProps.keys == TelemetryEventName.allCases`,
> so adding a name without its requiredProps row fails at runtime.

- [ ] **Step 8: Run test to verify it passes**

Run: `swift test --filter TelemetryServiceTests`
Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add Sources/MacParakeetCore/Services/Telemetry/TelemetryEvent.swift Tests/MacParakeetTests/TelemetryServiceTests.swift
git commit -m "feat(command-mode): add content-free command_mode telemetry events"
```

> **Out-of-repo follow-up (do not block this plan):** add `command_mode_executed` and
> `command_mode_failed` (and their field rows) to `ALLOWED_EVENTS` / `ALLOWED_FIELDS` in
> `macparakeet-website/functions/api/telemetry.ts` before these fire in production, or the
> Worker drops the batch (ADR-022 §8 / ADR-023 §7).

---

## Task 8: `MicrophoneArbiter` — process-wide single-consumer lock

Closes the TOCTOU race: dictation and Command Mode each consult one arbiter before
grabbing the shared mic.

**Files:**
- Create: `Sources/MacParakeetCore/Services/CommandMode/MicrophoneArbiter.swift`
- Test: `Tests/MacParakeetTests/Services/CommandMode/MicrophoneArbiterTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import MacParakeetCore

@MainActor
final class MicrophoneArbiterTests: XCTestCase {
    func testSecondAcquireIsRejectedUntilRelease() {
        let arbiter = MicrophoneArbiter()
        XCTAssertTrue(arbiter.tryAcquire(.commandMode))
        XCTAssertFalse(arbiter.tryAcquire(.dictation))
        XCTAssertEqual(arbiter.currentOwner, .commandMode)
        arbiter.release(.dictation) // wrong owner — no-op
        XCTAssertEqual(arbiter.currentOwner, .commandMode)
        arbiter.release(.commandMode)
        XCTAssertNil(arbiter.currentOwner)
        XCTAssertTrue(arbiter.tryAcquire(.dictation))
    }

    func testReacquireBySameOwnerSucceeds() {
        let arbiter = MicrophoneArbiter()
        XCTAssertTrue(arbiter.tryAcquire(.dictation))
        XCTAssertTrue(arbiter.tryAcquire(.dictation))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter MicrophoneArbiterTests`
Expected: FAIL — `MicrophoneArbiter` not found.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// Process-wide, main-actor arbiter ensuring only one microphone consumer is live at
/// a time (v1 mutual exclusion between dictation/meeting and Command Mode). Owned by
/// AppEnvironment; consulted by the dictation start path and CommandModeCoordinator.
@MainActor
public final class MicrophoneArbiter {
    public enum Owner: Sendable, Equatable {
        case dictation
        case meeting
        case commandMode
    }

    public private(set) var currentOwner: Owner?

    public init() {}

    /// Acquire the mic for `owner`. Returns false if a *different* owner holds it.
    @discardableResult
    public func tryAcquire(_ owner: Owner) -> Bool {
        if currentOwner == nil || currentOwner == owner {
            currentOwner = owner
            return true
        }
        return false
    }

    /// Release only if `owner` currently holds the mic.
    public func release(_ owner: Owner) {
        if currentOwner == owner { currentOwner = nil }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter MicrophoneArbiterTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/MacParakeetCore/Services/CommandMode/MicrophoneArbiter.swift Tests/MacParakeetTests/Services/CommandMode/MicrophoneArbiterTests.swift
git commit -m "feat(command-mode): add process-wide MicrophoneArbiter"
```

---

## Task 9: `CommandModeHotkeyMonitor` (hold gesture)

A single-chord event tap that fires `onPressStart` (keyDown, debounced) and
`onPressEnd` (keyUp). Mirrors `TransformsHotkeyRegistry` but for a hold gesture.

**Files:**
- Create: `Sources/MacParakeet/Hotkey/CommandModeHotkeyMonitor.swift`
- Test: `Tests/MacParakeetTests/Hotkey/CommandModeHotkeyMonitorTests.swift`

- [ ] **Step 1: Write the failing test** (direct `handleEvent` dispatch, no live tap)

```swift
import XCTest
import AppKit
import MacParakeetCore
@testable import MacParakeet

final class CommandModeHotkeyMonitorTests: XCTestCase {
    func testPressStartAndEndFireForBoundChord() throws {
        let monitor = CommandModeHotkeyMonitor()
        // Option+Space (keyCode 0x31)
        monitor.setShortcut(KeyboardShortcut(modifiers: KeyboardShortcut.ModifierFlag.option.rawValue, keyCode: 0x31, keyLabel: "Space"))

        var starts = 0, ends = 0
        monitor.onPressStart = { starts += 1 }
        monitor.onPressEnd = { ends += 1 }

        let down = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 0x31, keyDown: true))
        down.flags = .maskAlternate
        XCTAssertNil(monitor.handleEvent(type: .keyDown, event: down)) // swallowed
        XCTAssertEqual(starts, 1)
        // Auto-repeat keyDowns must not refire onPressStart.
        XCTAssertNil(monitor.handleEvent(type: .keyDown, event: down))
        XCTAssertEqual(starts, 1)

        let up = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 0x31, keyDown: false))
        up.flags = .maskAlternate
        XCTAssertNil(monitor.handleEvent(type: .keyUp, event: up))
        XCTAssertEqual(ends, 1)
    }

    func testUnboundMonitorIgnoresEvents() throws {
        let monitor = CommandModeHotkeyMonitor()
        var starts = 0
        monitor.onPressStart = { starts += 1 }
        let down = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 0x31, keyDown: true))
        down.flags = .maskAlternate
        XCTAssertNotNil(monitor.handleEvent(type: .keyDown, event: down)) // passed through
        XCTAssertEqual(starts, 0)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter CommandModeHotkeyMonitorTests`
Expected: FAIL — `CommandModeHotkeyMonitor` not found.

- [ ] **Step 3: Write the monitor** (adapt `TransformsHotkeyRegistry`; full event-tap
lifecycle is identical — copy `start()`/`stop()`/the `tapCreate` closure from
`Sources/MacParakeet/Hotkey/TransformsHotkeyRegistry.swift` and substitute this
`handleEvent` + single-shortcut state):

```swift
import Cocoa
import Foundation
import MacParakeetCore
import OSLog

/// Single-chord event tap exposing a hold gesture (press-start on keyDown, press-end
/// on keyUp) for Command Mode. Sibling of `TransformsHotkeyRegistry`; dormant until a
/// shortcut is set. See ADR-023 §2.
public final class CommandModeHotkeyMonitor {
    private static let logger = Logger(subsystem: "com.macparakeet", category: "CommandModeHotkeyMonitor")

    public var onPressStart: (() -> Void)?
    public var onPressEnd: (() -> Void)?

    private var keyCode: UInt16?
    private var modifierBits: UInt64 = 0
    private var isDown = false

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var retainedSelf: Unmanaged<CommandModeHotkeyMonitor>?
    private var installedRunLoop: CFRunLoop?

    public init() {}

    public func setShortcut(_ shortcut: KeyboardShortcut?) {
        guard let shortcut else {
            keyCode = nil
            modifierBits = 0
            isDown = false
            return
        }
        keyCode = shortcut.keyCode
        modifierBits = UInt64(shortcut.modifiers) & HotkeyTrigger.relevantModifierBits
    }

    func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            isDown = false
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard let boundKey = keyCode else { return Unmanaged.passUnretained(event) }

        let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let mods = event.flags.rawValue & HotkeyTrigger.relevantModifierBits

        switch type {
        case .keyDown:
            guard code == boundKey, mods == modifierBits else { return Unmanaged.passUnretained(event) }
            guard !isDown else { return nil } // swallow auto-repeat
            isDown = true
            onPressStart?()
            return nil
        case .keyUp:
            guard code == boundKey, isDown else { return Unmanaged.passUnretained(event) }
            isDown = false
            onPressEnd?()
            return nil
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    // start() / stop() — copy verbatim from TransformsHotkeyRegistry.start()/stop(),
    // replacing `registry.handleEvent` with `monitor.handleEvent` and the Unmanaged
    // refcon type with CommandModeHotkeyMonitor.
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter CommandModeHotkeyMonitorTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/MacParakeet/Hotkey/CommandModeHotkeyMonitor.swift Tests/MacParakeetTests/Hotkey/CommandModeHotkeyMonitorTests.swift
git commit -m "feat(command-mode): add hold-gesture hotkey monitor"
```

---

## Task 10: Settings — Command Mode hotkey persistence + recorder row

Add a `commandModeShortcut: KeyboardShortcut?` preference and a Settings recorder row,
with collision checks against reserved hotkeys **and** the `.transform` prompt bindings.

**Files:**
- Modify: `Sources/MacParakeetViewModels/SettingsViewModel.swift` (add a stored
  `commandModeShortcut` with UserDefaults load/save, mirroring `meetingHotkeyTrigger`;
  define a `commandModeShortcutDefaultsKey`)
- Modify: `Sources/MacParakeet/Views/Settings/SettingsView.swift` (add a Command Mode
  row reusing `ShortcutRecorderField` — the Transforms editor's `KeyboardShortcut?`
  recorder — under the Modes/Transforms area, gated by `AppFeatures.commandModeEnabled`)
- Test: `Tests/MacParakeetTests/ViewModels/SettingsViewModelCommandModeTests.swift`

- [ ] **Step 1: Write the failing persistence test**

```swift
import XCTest
import MacParakeetCore
@testable import MacParakeetViewModels

@MainActor
final class SettingsViewModelCommandModeTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let d = UserDefaults(suiteName: "command-mode-tests-\(UUID().uuidString)")!
        return d
    }

    func testCommandModeShortcutPersistsAndReloads() {
        let defaults = makeDefaults()
        let vm = SettingsViewModel(defaults: defaults) // use the existing test init that takes defaults
        let shortcut = KeyboardShortcut(modifiers: KeyboardShortcut.ModifierFlag.option.rawValue, keyCode: 0x31, keyLabel: "Space")
        vm.commandModeShortcut = shortcut

        let reloaded = SettingsViewModel(defaults: defaults)
        XCTAssertEqual(reloaded.commandModeShortcut, shortcut)
    }

    func testClearingCommandModeShortcutPersistsNil() {
        let defaults = makeDefaults()
        let vm = SettingsViewModel(defaults: defaults)
        vm.commandModeShortcut = KeyboardShortcut(modifiers: KeyboardShortcut.ModifierFlag.option.rawValue, keyCode: 0x31, keyLabel: "Space")
        vm.commandModeShortcut = nil
        let reloaded = SettingsViewModel(defaults: defaults)
        XCTAssertNil(reloaded.commandModeShortcut)
    }
}
```

> Adapt the `SettingsViewModel(defaults:)` initializer call to the real test
> initializer used by the existing `SettingsViewModelTests` (grep that file for how it
> constructs the VM with a custom `UserDefaults`).

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SettingsViewModelCommandModeTests`
Expected: FAIL — `commandModeShortcut` not found.

- [ ] **Step 3: Add the stored property + persistence** to `SettingsViewModel`:

```swift
    public static let commandModeShortcutDefaultsKey = "commandModeShortcut"

    public var commandModeShortcut: KeyboardShortcut? {
        didSet {
            if let encoded = commandModeShortcut?.encodedString() {
                defaults.set(encoded, forKey: Self.commandModeShortcutDefaultsKey)
            } else {
                defaults.removeObject(forKey: Self.commandModeShortcutDefaultsKey)
            }
            NotificationCenter.default.post(name: .macParakeetCommandModeShortcutDidChange, object: nil)
        }
    }
```

Initialize it in `init` (with the other hotkey loads):

```swift
        commandModeShortcut = KeyboardShortcut.decoded(from: defaults.string(forKey: Self.commandModeShortcutDefaultsKey))
```

Add the notification name (where the other `.macParakeet*DidChange` names are defined,
likely `Sources/MacParakeetCore/...` notifications file):

```swift
    public static let macParakeetCommandModeShortcutDidChange = Notification.Name("macParakeetCommandModeShortcutDidChange")
```

- [ ] **Step 4: Add the Settings recorder row** in `SettingsView.swift` (Modes tab,
near the Transforms card), gated by the feature flag.

> **Use `ShortcutRecorderField`, NOT `HotkeyRecorderView`.** `HotkeyRecorderView` binds a
> `HotkeyTrigger` and cannot produce a `KeyboardShortcut`. The Transforms editor records a
> `KeyboardShortcut` via `ShortcutRecorderField` (defined inline in
> `Sources/MacParakeet/Views/Transforms/TransformEditorSheet.swift:237-390`), which binds
> `@Binding var shortcut: TransformShortcut?` (`TransformShortcut` is a typealias for
> `MacParakeetCore.KeyboardShortcut` — `Sources/MacParakeet/Hotkey/TransformsShortcutAlias.swift:7`)
> and builds the shortcut from an `NSEvent` local monitor. It's internal to the `MacParakeet`
> target, so the Command Mode row (also in that target) can reuse it directly.

```swift
if AppFeatures.commandModeEnabled {
    // Mirror the Transforms editor wiring (TransformEditorSheet.swift:107-111).
    ShortcutRecorderField(
        shortcut: $viewModel.commandModeShortcut,
        isRecording: $isRecordingCommandModeShortcut,
        onRecordingStateChanged: onHotkeyRecordingStateChanged
    )
}
```

Validate a recorded candidate exactly as the Transforms editor does (TransformEditorSheet.swift:25,
107-122): run `TransformsHotkeyCollisionChecker.check(candidate:existing:excludingPromptID:nil:reservedHotkeys:)`
against the reserved hotkeys **and** the current `.transform` prompt bindings
(`existing: [UUID: KeyboardShortcut]`). Surface the collision message inline; on collision,
do not persist `viewModel.commandModeShortcut`.

- [ ] **Step 5: Run test + build**

Run: `swift test --filter SettingsViewModelCommandModeTests` then `swift build`
Expected: PASS + clean build.

- [ ] **Step 6: Commit**

```bash
git add Sources/MacParakeetViewModels/SettingsViewModel.swift Sources/MacParakeet/Views/Settings/ Tests/MacParakeetTests/ViewModels/SettingsViewModelCommandModeTests.swift Sources/MacParakeetCore/
git commit -m "feat(command-mode): add Settings hotkey recorder + persistence with collision checks"
```

---

## Task 11: `CommandModeCoordinator` (GUI)

The @MainActor coordinator that owns the hold gesture, mic capture, STT, executor, and
pill. No unit test (SwiftUI/AppKit/mic — verified by the manual matrix in Task 14);
implement against the concrete APIs below.

**Files:**
- Create: `Sources/MacParakeet/App/CommandModeCoordinator.swift`
- Modify: `Sources/MacParakeetCore/Services/System/SelectionCaptureService.swift` — change
  `func restoreClipboardCaptureIfCurrent(_:)` (line 235) to **`public func`**. It is currently
  `internal`; the coordinator lives in the `MacParakeet` GUI target and calls it cross-module
  for the §4.8 early clipboard restore. (The Core executor in Task 5 can call it either way.)

- [ ] **Step 0: Make the early-restore API public**

In `SelectionCaptureService.swift`, change `func restoreClipboardCaptureIfCurrent(`
to `public func restoreClipboardCaptureIfCurrent(`.

- [ ] **Step 1: Implement the coordinator**

Key wiring (use the real APIs confirmed in the spec):
- Holds `activeHold: ActiveHold?` = `{ runID: UUID, captured: SelectionCaptureResult }`.
- A dedicated `AudioProcessor(sharedMicStream:)` subscriber (its own instance over the
  shared stream), or reuse the env `audioProcessor` — but **must** go through the
  `MicrophoneArbiter` so it never double-captures.
- `SelectionCaptureService` (one shared instance) injected into `CommandModeExecutor`.
- Reuse `TransformSpikeProgressPanelController` for the pill (call `show()`, update beat,
  `done(message:)` / `fail(message:)`).

```swift
import AppKit
import Foundation
import MacParakeetCore
import OSLog

@MainActor
final class CommandModeCoordinator {
    private struct ActiveHold { let runID: UUID; var captured: SelectionCaptureResult? }

    private let monitor = CommandModeHotkeyMonitor()
    private let captureService = SelectionCaptureService()
    private let executor: CommandModeExecutor
    private let arbiter: MicrophoneArbiter
    private let audioProcessor: AudioProcessorProtocol
    private let sttScheduler: STTScheduler
    private let panel = TransformSpikeProgressPanelController()
    private let onLLMProviderRequired: () -> Void
    private let suspendOtherHotkeys: (Bool) -> Void
    private let logger = Logger(subsystem: "com.macparakeet", category: "CommandModeCoordinator")

    private var activeHold: ActiveHold?
    private var minHoldElapsed = false

    init(
        llmServiceProvider: @escaping @Sendable () -> LLMServiceProtocol?,
        arbiter: MicrophoneArbiter,
        audioProcessor: AudioProcessorProtocol,
        sttScheduler: STTScheduler,
        currentShortcut: @escaping () -> KeyboardShortcut?,
        onLLMProviderRequired: @escaping () -> Void,
        suspendOtherHotkeys: @escaping (Bool) -> Void
    ) {
        self.executor = CommandModeExecutor(captureService: captureService, llmServiceProvider: llmServiceProvider)
        self.arbiter = arbiter
        self.audioProcessor = audioProcessor
        self.sttScheduler = sttScheduler
        self.onLLMProviderRequired = onLLMProviderRequired
        self.suspendOtherHotkeys = suspendOtherHotkeys
        monitor.onPressStart = { [weak self] in self?.handlePressStart() }
        monitor.onPressEnd = { [weak self] in self?.handlePressEnd() }
        refreshShortcut(currentShortcut())
    }

    func start() {
        guard AppFeatures.commandModeEnabled else { return }
        _ = monitor.start()
    }
    func refreshShortcut(_ shortcut: KeyboardShortcut?) { monitor.setShortcut(shortcut) }

    private func handlePressStart() {
        // Cancel any prior hold (re-press): tear down + restore + dismiss pill.
        if let prior = activeHold { teardown(prior) }

        guard arbiter.tryAcquire(.commandMode) else {
            showToast("Finish dictating first.")
            return
        }
        suspendOtherHotkeys(true)
        let runID = UUID()
        activeHold = ActiveHold(runID: runID, captured: nil)
        minHoldElapsed = false

        // Min-hold debounce: don't capture/record/show pill on an accidental tap.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard let self, self.activeHold?.runID == runID else { return }
            self.minHoldElapsed = true
            await self.beginCaptureAndRecord(runID: runID)
        }
    }

    private func beginCaptureAndRecord(runID: UUID) async {
        let captured = await captureService.captureSelection()
        guard activeHold?.runID == runID else { return }
        switch captured {
        case .empty:
            showToast("Select text first — highlight what you want to change, then hold the key and speak.")
            finishHold(runID); return
        case .failed:
            showToast("Couldn't read the selection."); finishHold(runID); return
        case .ax, .clipboard:
            break
        }
        // Long-hold clipboard hygiene: restore the user's clipboard now (text is in memory).
        await captureService.restoreClipboardCaptureIfCurrent(captured)
        activeHold?.captured = captured
        do {
            try await audioProcessor.startCapture()
            panel.show() // "Listening…"
        } catch {
            showToast("Couldn't start the microphone."); finishHold(runID)
        }
    }

    private func handlePressEnd() {
        guard let hold = activeHold else { return }
        let runID = hold.runID
        // Accidental tap below the debounce floor — never recorded.
        guard minHoldElapsed, let captured = hold.captured else { finishHold(runID); return }

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let wav = try await self.audioProcessor.stopCapture()
                guard self.activeHold?.runID == runID else { return }
                // "Transcribing…" — honor the user's persisted engine/language (ADR-021).
                // SpeechEngineSelection.current() reads the persisted engine + default language
                // from UserDefaults (SpeechEnginePreference.swift:192). Its only initializer is
                // init(engine:language:) — there is no preference:/whisperVariant: form.
                let engine = SpeechEngineSelection.current()
                let stt = try await self.sttScheduler.transcribe(audioPath: wav.path, job: .dictation, speechEngine: engine)
                try? FileManager.default.removeItem(at: wav)
                guard self.activeHold?.runID == runID else { return }
                let result = try await self.executor.run(instruction: stt.text, captured: captured) { progress in
                    Task { @MainActor in self.applyProgress(progress, runID: runID) }
                }
                guard self.activeHold?.runID == runID else { return }
                self.sendExecutedTelemetry(result)
                self.panel.done(message: "Done")
            } catch let error as CommandModeExecutorError {
                self.handleExecutorError(error)
            } catch {
                self.panel.fail(message: "Command Mode failed.")
            }
            self.finishHold(runID)
        }
    }

    // applyProgress(_:runID:), handleExecutorError(_:), sendExecutedTelemetry(_:),
    // showToast(_:), teardown(_:), finishHold(_:) — straightforward:
    //   - finishHold: release arbiter (.commandMode), suspendOtherHotkeys(false), clear activeHold.
    //   - handleExecutorError: map .llmNotConfigured -> onLLMProviderRequired() + toast; others -> panel.fail.
    //   - sendExecutedTelemetry: Telemetry.send(.commandModeExecuted(path:..., deterministicCommand:..., llmMs:..., totalMs:..., appCategory: TelemetryAppCategory(bundleIdentifier: result.target?.bundleIdentifier))).
}
```

> Notes for implementation:
> - `audioProcessor` here is `env.audioProcessor` (the shared instance). The
>   `MicrophoneArbiter` guarantees Command Mode and dictation never record concurrently,
>   so the shared `AudioProcessor` actor only ever has one live session — safe to reuse.
>   If session-state leakage shows up in the manual matrix, switch to giving Command Mode
>   its own `AudioProcessor(sharedMicStream: env.sharedMicStream)` subscriber (the same
>   fan-out pattern dictation + meeting already use); keep it arbiter-gated either way.
> - Map `CommandModeProgress` beats to pill labels in `applyProgress`.

- [ ] **Step 2: Build**

Run: `swift build`
Expected: clean build (no test for this GUI unit).

- [ ] **Step 3: Commit**

```bash
git add Sources/MacParakeet/App/CommandModeCoordinator.swift
git commit -m "feat(command-mode): add CommandModeCoordinator (hold -> capture -> STT -> rewrite)"
```

---

## Task 12: AppDelegate + AppEnvironment wiring

**Files:**
- Modify: `Sources/MacParakeet/App/AppEnvironment.swift` (construct + expose
  `MicrophoneArbiter`)
- Modify: `Sources/MacParakeet/AppDelegate.swift` (construct/own/start the coordinator;
  re-declare the shared `llmServiceProvider` as `@Sendable`; have the dictation start
  path consult the arbiter; add the Command Mode reserved-hotkey entry)
- Modify: `Sources/MacParakeet/Views/MainWindowView.swift` (the second reserved-hotkey
  list — add the same Command Mode entry)

- [ ] **Step 1: Expose a `MicrophoneArbiter` from `AppEnvironment`**

```swift
    let microphoneArbiter = MicrophoneArbiter()
```

- [ ] **Step 2: Read-only bidirectional mic exclusion** (NOT token-acquire by
dictation/meeting — that would break ADR-015 concurrent dictation+meeting, since the
single-owner arbiter can hold only one owner).

Only **Command Mode** ever *holds* the arbiter token (the coordinator's existing
`tryAcquire(.commandMode)`/`release(.commandMode)`). Dictation and meeting are excluded
via **read-only checks**, so their shipped flows need no release logic:

(a) **Forward (Command Mode refuses while dictation/meeting active).** Add an
`isDictationOrMeetingActive: () -> Bool` parameter to `CommandModeCoordinator.init` and,
in `handlePressStart`, guard on it BEFORE acquiring the arbiter:
```swift
guard !isDictationOrMeetingActive() else { showToast("Finish dictating first."); return }
```
The closure (provided by AppDelegate, Step 4) reads `@MainActor` dictation + meeting
state — find the live UI-facing flags (e.g. the dictation overlay/flow coordinator's
"is recording/processing" state and `MeetingRecordingPillViewModel.isRecording`). It is
read-only; it must NOT mutate dictation/meeting state.

(b) **Reverse (dictation/meeting refuse while Command Mode holds).** In the dictation
start path AND the meeting start path (grep where `DictationService.startRecording` /
the meeting recording start is invoked from the app/flow layer), add a one-line
read-only guard — no release needed (Command Mode releases its own token):
```swift
guard env.microphoneArbiter.currentOwner != .commandMode else { return }
```
This covers non-hotkey starts (menu bar, idle-pill click); the hotkey path is also
covered by the `suspend()` in Step 4. Touch ONLY the start guard — do not add
acquire/release to these shipped flows.

- [ ] **Step 3: Re-declare the shared provider `@Sendable`** in `AppDelegate.swift`
(the existing binding around the `TransformsCoordinator` construction):

```swift
let llmServiceProvider: @Sendable () -> LLMServiceProtocol? = { [weak configStore, llmService] in
    guard let configStore else { return nil }
    return (try? configStore.loadConfig()) != nil ? llmService : nil
}
```

- [ ] **Step 4: Construct + start the coordinator** (next to `transforms.start()`):

```swift
if AppFeatures.commandModeEnabled {
    let commandMode = CommandModeCoordinator(
        llmServiceProvider: llmServiceProvider,
        arbiter: env.microphoneArbiter,
        audioProcessor: env.audioProcessor,
        sttScheduler: env.sttScheduler,
        currentShortcut: { [weak self] in self?.settingsViewModel.commandModeShortcut },
        isDictationOrMeetingActive: { [weak self] in
            // Read-only @MainActor check — find the real live flags (dictation flow/overlay
            // "is recording/processing" + MeetingRecordingPillViewModel.isRecording). Must
            // not mutate anything.
            (self?.dictationIsActive ?? false) || (self?.meetingIsRecording ?? false)
        },
        onLLMProviderRequired: { [weak self] in self?.windowCoordinator.openMainWindowToSettings(tab: .ai) },
        suspendOtherHotkeys: { [weak self] suspend in
            // Real mechanism: refcounted AppHotkeyCoordinator.suspend()/.resume()
            // (AppHotkeyCoordinator.swift:472/482). suspend() -> stopAll() stops the
            // dictation, meeting, file- and YouTube-transcription taps; resume() re-arms them.
            if suspend { self?.hotkeyCoordinator?.suspend() }
            else { self?.hotkeyCoordinator?.resume() }
        }
    )
    commandMode.start()
    commandModeCoordinator = commandMode
    // Re-push the shortcut to the monitor when the Settings value changes:
    NotificationCenter.default.addObserver(forName: .macParakeetCommandModeShortcutDidChange, object: nil, queue: .main) { [weak self] _ in
        self?.commandModeCoordinator?.refreshShortcut(self?.settingsViewModel.commandModeShortcut)
    }
}
```

Add the stored property `private var commandModeCoordinator: CommandModeCoordinator?`.

> **Refcount pairing (important):** `suspend()`/`resume()` are refcounted, so every
> `suspendOtherHotkeys(true)` (in `handlePressStart`, after the arbiter is acquired) must be
> matched by exactly one `suspendOtherHotkeys(false)`. Ensure both `finishHold` *and* the
> re-press `teardown(prior)` path call it exactly once (and release the arbiter exactly once)
> — never zero, never twice — or the dictation/meeting hotkeys stay suspended or get
> double-resumed. `suspend()` does NOT stop the Transforms registry tap (managed separately
> by `TransformsCoordinator.suspendHotkeys()`/`resumeHotkeys()`); Command Mode does not need
> to suspend Transforms, so leave that alone.

- [ ] **Step 5: Add the Command Mode reserved-hotkey entry in BOTH sites** —
`transformReservedHotkeysForTransforms()` in `AppDelegate.swift` AND the parallel list
in `MainWindowView.swift` (~line 270):

```swift
if AppFeatures.commandModeEnabled, let cm = settingsViewModel.commandModeShortcut {
    reserved.append(TransformShortcutReservedHotkey(name: "Command Mode", trigger: cm.hotkeyTrigger))
}
```

- [ ] **Step 6: Build + smoke**

Run: `swift build`
Expected: clean build.

- [ ] **Step 7: Commit**

```bash
git add Sources/MacParakeet/
git commit -m "feat(command-mode): wire coordinator, mic arbiter, and collision entries"
```

---

## Task 13: Docs, traceability, and spec hygiene

**Files:**
- Create: `Sources/MacParakeetCore/Services/CommandMode/README.md`
- Modify: `spec/kernel/requirements.yaml` (add `CMD` area + REQ-CMD-001/002, version v0.7)
- Modify: `spec/kernel/traceability.md` (add `v0.7 Command Mode` section)
- Modify: `spec/README.md` (name Command Mode as first v0.7 scope item)
- Modify: `spec/02-features.md` (add an `F-CMD` block; annotate the F10/F10a REMOVED
  blocks at ~line 934 with "superseded by ADR-023")
- Modify: `CLAUDE.md` (add Command Mode to the "Custom features in this fork" list)

- [ ] **Step 1: Write the subsystem README** documenting the invariants: threading
(executor is an actor; coordinator is @MainActor), restore-on-abandon, early clipboard
restore (§4.8), deletion-not-empty-paste for clearSelection, the held-chord
modifier-clear (§4.9), the MicrophoneArbiter mutual-exclusion rule, and the
executor-stays-in-Core rule.

- [ ] **Step 2: Add the requirement IDs** to `requirements.yaml`:

```yaml
#   CMD   - Voice Command Mode

# --- v0.7 Command Mode ---

REQ-CMD-001:
  description: Voice Command Mode — hold a dedicated hotkey, speak an instruction, and the selected text is rewritten in place through the configured LLM provider (AX-first capture, clipboard fallback, paste-back), honoring the persisted STT engine/language
  version: v0.7
  status: implemented

REQ-CMD-002:
  description: Deterministic offline self-correction — "scratch that" family (delete selection) and case/trim text ops execute with no LLM, working even when no provider is configured
  version: v0.7
  status: implemented
```

- [ ] **Step 3: Update traceability + spec/README + 02-features + CLAUDE.md** per the
file list above. Map REQ-CMD-001/002 to the new source files and tests in
`traceability.md`.

- [ ] **Step 4: Commit**

```bash
git add Sources/MacParakeetCore/Services/CommandMode/README.md spec/ CLAUDE.md
git commit -m "docs(command-mode): requirements, traceability, feature + subsystem docs"
```

---

## Task 14: Full verification + manual matrix

- [ ] **Step 1: Run the full suite**

Run: `swift test`
Expected: all tests pass (baseline + new CommandMode tests).

- [ ] **Step 2: Relaunch the dev app**

Run: `scripts/dev/run_app.sh`

- [ ] **Step 3: Bind a Command Mode hotkey** in Settings (e.g. ⌥Space). Confirm the
collision check rejects the dictation/meeting/Transform keys (both directions).

- [ ] **Step 4: Manual matrix** — in each of TextEdit, Notes, Slack, Safari textarea,
VS Code, Cursor, Terminal: select text, hold the key, speak, release. Verify per app:
  - rewrite ("make this more formal") replaces the selection and one Cmd+Z reverts it;
  - "scratch that" deletes the selection (no empty string left on the clipboard — check
    a clipboard manager);
  - "uppercase that" upper-cases offline (works with no provider configured);
  - **no Cmd+C/Cmd+V modifier contamination** while the chord is held (capture/paste
    fire correctly with the modifier still down);
  - the user's clipboard is intact after the command (paste something afterward);
  - empty selection → educational toast, no recording;
  - empty speech → "Didn't catch that", clipboard intact;
  - starting dictation while a Command Mode hold is active is blocked (and vice-versa).

- [ ] **Step 5: Final commit (if any matrix fixes were needed)**

```bash
git add -A
git commit -m "fix(command-mode): manual-matrix fixes"
```

---

## Done criteria

- `swift test` green.
- Command Mode bind → hold → speak → rewrite works across the manual matrix.
- Deterministic "scratch that" + case/trim work offline with no provider.
- Clipboard intact after every path; no empty-string-on-clipboard for "scratch that".
- Dictation ↔ Command Mode mutual exclusion holds both directions.
- Docs/traceability updated; F10/F10a annotated as superseded by ADR-023.
