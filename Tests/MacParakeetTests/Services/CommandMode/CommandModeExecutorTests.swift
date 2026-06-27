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

    func testEmptyStringClipboardCaptureRestoresOnEmptySelection() async {
        let capture = FakeCommandModeCaptureBackend()
        let executor = makeExecutor(replacement: FakeCommandModeReplacementBackend(), capture: capture)
        await assertThrows(executor, instruction: "uppercase that", captured: clipboardCapture("")) {
            guard case .emptySelection = $0 else { return false }; return true
        }
        XCTAssertEqual(capture.restoreCount, 1, "clipboard must be restored when an empty-string clipboard capture is rejected")
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
