import XCTest
@testable import MacParakeetCore

/// Replies captured from qwen3.8:27b-mlx via Ollama (2026-10-31): 35 of 59
/// caption review batches were rejected because of a leaked `</think>`.
final class LLMThinkingTagStripperTests: XCTestCase {
    private let json = #"{"decisions": [{"pair": 0, "action": "keep"}]}"#

    func testDropsTrailingStrayClosingTag() {
        XCTAssertEqual(LLMThinkingTagStripper.strip(json + " </think>"), json)
    }

    func testKeepsAnswerAfterRepeatedReply() {
        XCTAssertEqual(LLMThinkingTagStripper.strip(json + " </think>  " + json), json)
    }

    func testDropsReasoningBeforeClosingTag() {
        XCTAssertEqual(LLMThinkingTagStripper.strip("Let me check each pair.\n</think>\n" + json), json)
    }

    func testDropsCompleteThinkingBlock() {
        XCTAssertEqual(LLMThinkingTagStripper.strip("<think>pair 0 is fine</think>\n" + json), json)
    }

    func testLeavesOrdinaryRepliesUntouched() {
        XCTAssertEqual(LLMThinkingTagStripper.strip(json), json)
        XCTAssertEqual(LLMThinkingTagStripper.strip("I think so."), "I think so.")
    }

    func testReviewBatchParserAcceptsLeakedTag() {
        guard case .success(let decisions) = ReviewActionParser.parseBatch(json + " </think>") else {
            return XCTFail("leaked </think> should not make the batch malformed")
        }
        XCTAssertEqual(decisions.count, 1)
    }

    func testNumberRefinerReplyDropsLeakedTag() {
        XCTAssertEqual(NumberLLMRefiner.cleanReply("Give me 3, 2, 1. </think>"), "Give me 3, 2, 1.")
    }

    // Remaining qwen3.8 rejects after the tag fix: a repeated answer and a
    // garbled trailing tag.
    func testReviewBatchParserTakesFirstOfRepeatedAnswers() {
        guard case .success(let decisions) = ReviewActionParser.parseBatch(json + " " + json) else {
            return XCTFail("a repeated answer should parse as the first one")
        }
        XCTAssertEqual(decisions.count, 1)
    }

    func testFirstJSONValueDropsGarbledTrailingTag() {
        XCTAssertEqual(LLMThinkingTagStripper.firstJSONValue(json + " </anth>"), json)
    }

    func testFirstJSONValueRespectsBracesInsideStrings() {
        let tricky = #"{"text": "a } b", "n": [1, {"x": "]"}]} trailing"#
        XCTAssertEqual(LLMThinkingTagStripper.firstJSONValue(tricky), #"{"text": "a } b", "n": [1, {"x": "]"}]}"#)
    }
}
