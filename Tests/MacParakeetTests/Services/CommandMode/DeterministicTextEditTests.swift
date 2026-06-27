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

    func testApplyToEmptyStringIsNoop() {
        for command in DeterministicCommand.allCases where command != .clearSelection {
            XCTAssertEqual(DeterministicTextEdit.apply(command, to: ""), "", "\(command) on empty should return empty")
        }
    }
}
