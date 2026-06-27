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
