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
            output: "25 reps and some extra commentary about exercise routines and best practices"
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
            input: "she said \"twenty-five reps\" before stopping for a brief moment",
            output: "she said \u{201C}25 reps\u{201D} before stopping for a brief moment"
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
        // Reply paraphrases by removing most of the text — gate should reject.
        let llm = FixedReplyLLM(reply: "30 seconds")
        let refiner = NumberLLMRefiner(llmService: llm)

        let outcome = try await refiner.refine(
            text: "next thirty seconds then jog for two minutes and breathe deeply throughout the entire warmup"
        )

        XCTAssertEqual(outcome.text, "next thirty seconds then jog for two minutes and breathe deeply throughout the entire warmup")
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

    // MARK: - Paragraph splitter (escape-hatch path)

    func testSplitAtParagraphsHandlesShortText() {
        let chunks = NumberLLMRefiner.splitAtParagraphs(text: "hello world", maxChars: 100)
        XCTAssertEqual(chunks, ["hello world"])
    }

    func testSplitAtParagraphsGreedyPacksWithinBudget() {
        let chunks = NumberLLMRefiner.splitAtParagraphs(
            text: "para one\n\npara two\n\npara three",
            maxChars: 100
        )
        // All three paragraphs fit in one 100-char budget.
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks.first, "para one\n\npara two\n\npara three")
    }

    func testSplitAtParagraphsHardSplitsOversizedParagraph() {
        // First paragraph (10 chars) fits in budget. Second (20 chars) exceeds
        // the 15-char budget AND can't fit anywhere, so it gets hard-split
        // into a 15-char chunk plus a 5-char remainder. Hard-split is the
        // last-resort path; real use never trips it because budgets are
        // ~80K and paragraphs are typically << 1K.
        let chunks = NumberLLMRefiner.splitAtParagraphs(
            text: "0123456789\n\n01234567890123456789",
            maxChars: 15
        )
        XCTAssertEqual(chunks.count, 3)
        XCTAssertEqual(chunks[0], "0123456789")
        XCTAssertEqual(chunks[1], "012345678901234")
        XCTAssertEqual(chunks[2], "56789")
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
