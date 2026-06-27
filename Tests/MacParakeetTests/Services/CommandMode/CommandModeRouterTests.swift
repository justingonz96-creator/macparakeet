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
