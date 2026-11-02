import XCTest
@testable import MacParakeetCore

final class SubtitleTranslatorTests: XCTestCase {
    private func cues(_ texts: [String]) -> [CaptionFileCue] {
        texts.enumerated().map { CaptionFileCue(index: $0.offset + 1, startMs: $0.offset * 2_000, endMs: $0.offset * 2_000 + 1_500, lines: [$0.element]) }
    }

    private func reply(_ lines: [Int: String]) -> String {
        let items = lines.keys.sorted().map { #"{"id":\#($0),"text":"\#(lines[$0]!)"}"# }
        return #"{"lines":[\#(items.joined(separator: ","))]}"#
    }

    func testTranslatesEveryLineAndKeepsTiming() async {
        let english = cues(["What's going on, Echelon?", "Welcome to upper body 20."])
        let llm = TranslatorScriptedLLM([reply([1: "Was geht, Echelon?", 2: "Willkommen zu Upper Body 20."])])
        let translator = SubtitleTranslator(llmService: llm, protectedTerms: ["Echelon"])
        let result = await translator.translate(cues: english, to: .de)
        XCTAssertEqual(result.cues.map(\.text), ["Was geht, Echelon?", "Willkommen zu Upper Body 20."])
        XCTAssertEqual(result.cues.map(\.startMs), english.map(\.startMs))
        XCTAssertEqual(result.cues.map(\.endMs), english.map(\.endMs))
        XCTAssertTrue(result.untranslatedCues.isEmpty)
    }

    /// A reply that translates the brand name is rejected and asked again.
    func testTranslatedBrandNameIsRetried() async {
        let english = cues(["Welcome to Echelon Reflect."])
        let llm = TranslatorScriptedLLM([
            reply([1: "Willkommen bei Echelon Reflektieren."]),
            reply([1: "Willkommen bei Echelon Reflect."]),
        ])
        let translator = SubtitleTranslator(llmService: llm, protectedTerms: ["Echelon", "Echelon Reflect"])
        let result = await translator.translate(cues: english, to: .de)
        XCTAssertEqual(result.cues.first?.text, "Willkommen bei Echelon Reflect.")
        XCTAssertTrue(result.missingTerms.isEmpty)
    }

    /// Missing or merged lines are rejected; after retries the window is split
    /// so the lines that can be translated still are, and the rest stay English.
    func testWindowMissingALineIsSplitAndOnlyTheFailingLineStaysEnglish() async {
        let english = cues(["One.", "Two."])
        let llm = TranslatorScriptedLLM([
            reply([1: "Eins."]), reply([1: "Eins."]),   // whole window: line 2 missing twice
            reply([1: "Eins."]),                        // first half alone
            "not json", "not json",                     // second half fails twice
        ])
        let translator = SubtitleTranslator(llmService: llm, protectedTerms: [])
        let result = await translator.translate(cues: english, to: .de)
        XCTAssertEqual(result.cues.map(\.text), ["Eins.", "Two."])
        XCTAssertEqual(result.untranslatedCues, [2])
    }

    func testOverlongLineGetsAShortenPass() async {
        let long = String(repeating: "lang ", count: 20).trimmingCharacters(in: .whitespaces)
        let english = cues(["Keep going."])
        let llm = TranslatorScriptedLLM([reply([1: long]), reply([1: "Weiter so."])])
        let translator = SubtitleTranslator(llmService: llm, protectedTerms: [])
        let result = await translator.translate(cues: english, to: .de)
        XCTAssertEqual(result.cues.first?.text, "Weiter so.")
        XCTAssertTrue(llm.prompts.last?.contains("Shorten") == true)
    }

    func testPromptCarriesStyleAndProtectedTerms() {
        let translator = SubtitleTranslator(llmService: TranslatorScriptedLLM([]), protectedTerms: ["Echelon", "Echelon Reflect"])
        let german = translator.systemPrompt(language: .de, config: .echelon)
        XCTAssertTrue(german.contains("\"du\""))
        XCTAssertTrue(german.contains("Echelon Reflect, Echelon"))
        XCTAssertTrue(translator.systemPrompt(language: .es, config: .echelon).contains("\"tú\""))
    }

    func testProtectedTermMatchingIsWholeWord() {
        let translator = SubtitleTranslator(llmService: TranslatorScriptedLLM([]), protectedTerms: ["Row", "RPM"])
        XCTAssertEqual(translator.missingProtectedTerms(english: "Grab your rowing handle", translation: "Greif den Griff"), [])
        XCTAssertEqual(translator.missingProtectedTerms(english: "Keep 90 RPM", translation: "Halte 90 U/min"), ["RPM"])
    }
}

private final class TranslatorScriptedLLM: LLMServiceProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [String]
    private(set) var prompts: [String] = []

    init(_ replies: [String]) { self.replies = replies }

    func transform(text: String, prompt: String) async throws -> String {
        lock.lock(); defer { lock.unlock() }
        prompts.append(text)
        return replies.isEmpty ? "{}" : replies.removeFirst()
    }

    func generatePromptResult(transcript: String, systemPrompt: String?) async throws -> String { "" }
    func chat(question: String, transcript: String, userNotes: String?, history: [ChatMessage], source: TelemetryChatSource, conversationID: UUID) async throws -> String { "" }
    func formatTranscript(transcript: String, promptTemplate: String, source: TelemetryFormatterSource, defaultPromptUsed: Bool) async throws -> String { "" }
    func generatePromptResultStream(transcript: String, systemPrompt: String?) -> AsyncThrowingStream<String, Error> { AsyncThrowingStream { $0.finish() } }
    func chatStream(question: String, transcript: String, userNotes: String?, history: [ChatMessage], source: TelemetryChatSource, conversationID: UUID) -> AsyncThrowingStream<String, Error> { AsyncThrowingStream { $0.finish() } }
    func transformStream(text: String, prompt: String) -> AsyncThrowingStream<String, Error> { AsyncThrowingStream { $0.finish() } }
    func generatePromptResultDetailed(transcript: String, systemPrompt: String?) async throws -> LLMResult { LLMResult(output: "", provider: "test", model: "test", latencyMs: 0) }
    func chatDetailed(question: String, transcript: String, userNotes: String?, history: [ChatMessage], source: TelemetryChatSource, conversationID: UUID) async throws -> LLMResult { LLMResult(output: "", provider: "test", model: "test", latencyMs: 0) }
    func transformDetailed(text: String, prompt: String) async throws -> LLMResult {
        LLMResult(output: try await transform(text: text, prompt: prompt), provider: "test", model: "test", latencyMs: 0)
    }
    func formatTranscriptDetailed(transcript: String, promptTemplate: String, source: TelemetryFormatterSource, defaultPromptUsed: Bool) async throws -> LLMFormatterResult {
        LLMFormatterResult(
            result: LLMResult(output: "", provider: "test", model: "test", latencyMs: 0),
            operationID: "test", inputChars: 0, outputChars: 0, inputTruncated: false,
            defaultPromptUsed: defaultPromptUsed, messageCount: 0
        )
    }
}
