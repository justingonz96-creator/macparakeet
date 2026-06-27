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
