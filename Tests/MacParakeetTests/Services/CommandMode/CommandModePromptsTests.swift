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
