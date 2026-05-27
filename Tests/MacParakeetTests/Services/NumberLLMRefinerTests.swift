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

    /// Fixture suite locking the safety gate's behavior across realistic
    /// LLM outputs. Update this when the threshold changes — it's the
    /// guardrail telling future-us whether a tuning change has the
    /// expected effect on actual LLM-shaped responses.
    ///
    /// Threshold today: 5% of input tokens (floor 2). Each fixture asserts
    /// whether `safetyGatePasses` should return `true` (LLM reply is kept)
    /// or `false` (reply is discarded and deterministic input is used).
    func testSafetyGateFixtureSuite() {
        struct Fixture {
            let label: String
            let input: String
            let output: String
            let shouldPass: Bool
        }
        let fixtures: [Fixture] = [
            // MARK: should PASS — clean number-form rewrites

            .init(label: "pure digit substitution",
                  input: "next thirty seconds for forty-five reps",
                  output: "next 30 seconds for 45 reps",
                  shouldPass: true),

            .init(label: "year normalization",
                  input: "the meeting in nineteen ninety-five was important to us",
                  output: "the meeting in 1995 was important to us",
                  shouldPass: true),

            .init(label: "clock time with am",
                  input: "the call is scheduled for ten thirty AM tomorrow",
                  output: "the call is scheduled for 10:30 AM tomorrow",
                  shouldPass: true),

            .init(label: "decimal expansion",
                  input: "the timer rang after two point five seconds had passed",
                  output: "the timer rang after 2.5 seconds had passed",
                  shouldPass: true),

            .init(label: "large cardinal with thousands",
                  input: "the budget came to three thousand four hundred and twenty five dollars",
                  output: "the budget came to 3,425 dollars",
                  shouldPass: true),

            .init(label: "multiple number forms in one sentence",
                  input: "in nineteen ninety-five we ran for thirty seconds doing forty-five reps",
                  output: "in 1995 we ran for 30 seconds doing 45 reps",
                  shouldPass: true),

            .init(label: "curly quote substitution",
                  input: "she said \"twenty-five reps\" before stopping for a brief moment",
                  output: "she said \u{201C}25 reps\u{201D} before stopping for a brief moment",
                  shouldPass: true),

            .init(label: "sentence-split rewording stays equivalent",
                  input: "thirty seconds, then forty-five reps to finish the set strong",
                  output: "30 seconds. Then 45 reps to finish the set strong",
                  shouldPass: true),

            .init(label: "dropped redundant adverb",
                  input: "we ran for thirty seconds approximately to warm up the group",
                  output: "we ran for 30 seconds to warm up the group",
                  shouldPass: true),

            // MARK: should REJECT — paraphrasing or content drift

            .init(label: "added commentary at end",
                  input: "next thirty seconds",
                  output: "next 30 seconds — note that this is an approximate timing for the warmup phase",
                  shouldPass: false),

            .init(label: "dropped half the sentence",
                  input: "we ran for thirty seconds and then jogged for two minutes and finished with fifteen squats",
                  output: "we ran for 30 seconds",
                  shouldPass: false),

            .init(label: "synonym/paraphrase rewrite",
                  input: "he ran for thirty seconds during the cooldown phase of the workout",
                  output: "he jogged briefly during the cooldown phase of the workout for about half a minute",
                  shouldPass: false),

            .init(label: "added explanatory parenthetical",
                  input: "thirty seconds",
                  output: "30 seconds (which corresponds to roughly half a minute in real time)",
                  shouldPass: false),

            .init(label: "completely different content",
                  input: "we did forty-five reps today",
                  output: "the weather is nice today and birds are singing",
                  shouldPass: false),
        ]

        for fixture in fixtures {
            let actual = NumberLLMRefiner.safetyGatePasses(
                input: fixture.input, output: fixture.output
            )
            XCTAssertEqual(
                actual,
                fixture.shouldPass,
                """
                Fixture '\(fixture.label)' expected \(fixture.shouldPass ? "PASS" : "REJECT") but got \(actual ? "PASS" : "REJECT").
                Input:  '\(fixture.input)'
                Output: '\(fixture.output)'
                """
            )
        }
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

    // MARK: - Batched (escape-hatch) path

    /// Builds an input long enough to force the chunked path into exactly
    /// three chunks (one per paragraph). With maxCharsPerCall = 1000 and
    /// each paragraph at ~600 chars, the greedy packer can't fit any two
    /// paragraphs into one chunk, so each lands in its own chunk.
    private func threeParagraphInput() -> String {
        let para1 = String(repeating: "first paragraph text with thirty seconds repeated. ", count: 12)
        let para2 = String(repeating: "second paragraph mentions forty-five reps repeated. ", count: 12)
        let para3 = String(repeating: "third paragraph notes nineteen ninety-five repeated. ", count: 12)
        return [para1, para2, para3].joined(separator: "\n\n")
    }

    func testRefineByChunksStitchesAllRefinedChunks() async throws {
        // Use FlexibleLLM so each chunk's reply is the chunk text with
        // spelled numbers swapped to digits. Safety gate should pass on
        // each chunk and stitching should produce the joined refined text.
        let llm = DigitSubstitutingLLM()
        let refiner = NumberLLMRefiner(llmService: llm, maxCharsPerCall: 1000)
        let input = threeParagraphInput()

        let outcome = try await refiner.refine(text: input)

        XCTAssertTrue(outcome.usedLLM)
        XCTAssertNil(outcome.fallbackReason)
        XCTAssertTrue(outcome.safetyGatePassed)
        XCTAssertGreaterThanOrEqual(llm.callCount, 2, "Should have split into at least 2 chunks")
        // Result has no spelled number words left.
        XCTAssertFalse(outcome.text.contains("thirty"))
        XCTAssertFalse(outcome.text.contains("forty-five"))
        XCTAssertFalse(outcome.text.contains("nineteen ninety-five"))
        // Result still contains the prose content of every chunk.
        XCTAssertTrue(outcome.text.contains("first paragraph"))
        XCTAssertTrue(outcome.text.contains("second paragraph"))
        XCTAssertTrue(outcome.text.contains("third paragraph"))
    }

    func testRefineByChunksFiresProgressForEveryChunk() async throws {
        let llm = DigitSubstitutingLLM()
        let refiner = NumberLLMRefiner(llmService: llm, maxCharsPerCall: 1000)
        let input = threeParagraphInput()

        let progress = ProgressRecorder()
        _ = try await refiner.refine(text: input, onProgress: { done, total in
            progress.record(done: done, total: total)
        })

        let snapshots = progress.snapshot()
        XCTAssertGreaterThanOrEqual(snapshots.count, 2)
        // Last snapshot reports done == total.
        XCTAssertEqual(snapshots.last?.done, snapshots.last?.total)
        // Done strictly increases.
        let dones = snapshots.map(\.done)
        XCTAssertEqual(dones, dones.sorted())
    }

    func testRefineByChunksFallsBackPerChunkWithoutPoisoningNeighbors() async throws {
        // FailOnNthCallLLM throws on the second LLM call, succeeds on the others.
        // The middle chunk falls back to its input; chunks 1 and 3 get refined.
        let llm = FailOnNthCallLLM(failingCall: 2)
        let refiner = NumberLLMRefiner(llmService: llm, maxCharsPerCall: 1000)
        let input = threeParagraphInput()

        let outcome = try await refiner.refine(text: input)

        // Some chunks succeeded → usedLLM is true overall.
        XCTAssertTrue(outcome.usedLLM)
        XCTAssertNil(outcome.fallbackReason)
        // Refined paragraphs 1 and 3 have no spelled "thirty"/"nineteen ninety-five".
        XCTAssertFalse(outcome.text.contains("thirty seconds"))
        XCTAssertFalse(outcome.text.contains("nineteen ninety-five"))
        // Middle paragraph fell back to its input — "forty-five" is still present.
        XCTAssertTrue(outcome.text.contains("forty-five reps"))
    }

    func testRefineByChunksMarksFallbackWhenEveryChunkFails() async throws {
        let llm = AlwaysThrowingLLM(error: URLError(.notConnectedToInternet))
        let refiner = NumberLLMRefiner(llmService: llm, maxCharsPerCall: 1000)
        let input = threeParagraphInput()

        let outcome = try await refiner.refine(text: input)

        XCTAssertFalse(outcome.usedLLM)
        XCTAssertEqual(outcome.fallbackReason, .callFailed)
        // Stitched text equals the joined input chunks (some structure normalization
        // is fine — we just assert the original content survived).
        XCTAssertTrue(outcome.text.contains("first paragraph"))
        XCTAssertTrue(outcome.text.contains("second paragraph"))
        XCTAssertTrue(outcome.text.contains("third paragraph"))
        XCTAssertTrue(outcome.text.contains("thirty seconds"))  // unchanged spelled forms
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

/// Returns the input text with the spelled-number words `thirty`,
/// `forty-five`, and `nineteen ninety-five` rewritten as `30`, `45`, `1995`.
/// Lets batched-path tests assert per-chunk refinement worked.
private final class DigitSubstitutingLLM: LLMServiceProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var callCount = 0

    func transformDetailed(text: String, prompt: String) async throws -> LLMResult {
        lock.lock(); callCount += 1; lock.unlock()
        let replaced = text
            .replacingOccurrences(of: "thirty seconds", with: "30 seconds")
            .replacingOccurrences(of: "forty-five reps", with: "45 reps")
            .replacingOccurrences(of: "nineteen ninety-five", with: "1995")
        return LLMResult(output: replaced, provider: "test", model: "test", latencyMs: 1)
    }

    func transform(text: String, prompt: String) async throws -> String { try await transformDetailed(text: text, prompt: prompt).output }
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

/// Succeeds on every call EXCEPT the Nth, which throws. Used to verify the
/// batched path treats per-chunk failures independently — neighbors keep
/// their refined output, the failing chunk falls back to its input.
private final class FailOnNthCallLLM: LLMServiceProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var callCount = 0
    let failingCall: Int

    init(failingCall: Int) { self.failingCall = failingCall }

    func transformDetailed(text: String, prompt: String) async throws -> LLMResult {
        lock.lock(); callCount += 1; let n = callCount; lock.unlock()
        if n == failingCall { throw URLError(.notConnectedToInternet) }
        let replaced = text
            .replacingOccurrences(of: "thirty seconds", with: "30 seconds")
            .replacingOccurrences(of: "forty-five reps", with: "45 reps")
            .replacingOccurrences(of: "nineteen ninety-five", with: "1995")
        return LLMResult(output: replaced, provider: "test", model: "test", latencyMs: 1)
    }

    func transform(text: String, prompt: String) async throws -> String { try await transformDetailed(text: text, prompt: prompt).output }
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

/// Always throws the same error. Used to verify the batched path returns
/// `.callFailed` when no chunks succeed.
private typealias AlwaysThrowingLLM = ThrowingLLM

/// Records (done, total) progress snapshots across the batched path.
private final class ProgressRecorder: @unchecked Sendable {
    struct Snapshot { let done: Int; let total: Int }
    private let lock = NSLock()
    private var snapshots: [Snapshot] = []

    func record(done: Int, total: Int) {
        lock.lock(); defer { lock.unlock() }
        snapshots.append(Snapshot(done: done, total: total))
    }

    func snapshot() -> [Snapshot] {
        lock.lock(); defer { lock.unlock() }
        return snapshots
    }
}
