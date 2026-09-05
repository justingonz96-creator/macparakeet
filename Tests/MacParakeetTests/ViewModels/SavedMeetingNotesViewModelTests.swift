import XCTest
@testable import MacParakeetViewModels

@MainActor
final class SavedMeetingNotesViewModelTests: XCTestCase {
    func testConfigureRestoresTextWithoutWriting() async {
        let viewModel = SavedMeetingNotesViewModel()
        var writes: [String] = []

        viewModel.configure(text: "Existing notes") { text in
            writes.append(text)
            return true
        }

        XCTAssertEqual(viewModel.text, "Existing notes")
        XCTAssertEqual(viewModel.wordCount, 2)
        XCTAssertEqual(viewModel.saveState, .saved)
        XCTAssertTrue(writes.isEmpty)
    }

    func testRapidEditsAutosaveOnlyLatestDraft() async {
        let viewModel = SavedMeetingNotesViewModel()
        var writes: [String] = []
        viewModel.configure(text: nil) { text in
            writes.append(text)
            return true
        }

        viewModel.textBinding.wrappedValue = "First"
        viewModel.textBinding.wrappedValue = "First second"

        try? await Task.sleep(for: .milliseconds(800))

        XCTAssertEqual(writes, ["First second"])
        XCTAssertEqual(viewModel.saveState, .saved)
    }

    func testFlushPersistsImmediatelyAndCancelsDebounce() async {
        let viewModel = SavedMeetingNotesViewModel()
        var writes: [String] = []
        viewModel.configure(text: nil) { text in
            writes.append(text)
            return true
        }
        viewModel.textBinding.wrappedValue = "Latest context"

        let flushed = await viewModel.flush()
        XCTAssertTrue(flushed)
        XCTAssertEqual(writes, ["Latest context"])

        try? await Task.sleep(for: .milliseconds(800))
        XCTAssertEqual(writes, ["Latest context"])
    }

    func testFailedSaveKeepsDraftAndRetryPersistsIt() async {
        let viewModel = SavedMeetingNotesViewModel()
        var shouldSucceed = false
        var writes: [String] = []
        viewModel.configure(text: nil) { text in
            writes.append(text)
            return shouldSucceed
        }
        viewModel.textBinding.wrappedValue = "Keep this draft"

        let firstFlush = await viewModel.flush()
        XCTAssertFalse(firstFlush)
        XCTAssertEqual(viewModel.text, "Keep this draft")
        XCTAssertEqual(viewModel.saveState, .failed)

        shouldSucceed = true
        let retried = await viewModel.retry()
        XCTAssertTrue(retried)
        XCTAssertEqual(writes, ["Keep this draft", "Keep this draft"])
        XCTAssertEqual(viewModel.saveState, .saved)
    }

    func testFlushDuringSlowAutosaveDoesNotDuplicateWrite() async {
        let viewModel = SavedMeetingNotesViewModel()
        var writes: [String] = []
        viewModel.configure(text: nil) { text in
            writes.append(text)
            try? await Task.sleep(for: .milliseconds(500))
            return true
        }
        viewModel.textBinding.wrappedValue = "One write"

        try? await Task.sleep(for: .milliseconds(600))
        let flushed = await viewModel.flush()

        XCTAssertTrue(flushed)
        XCTAssertEqual(writes, ["One write"])
        XCTAssertEqual(viewModel.saveState, .saved)
    }

    func testNewEditPersistsAfterOlderInFlightSaveFails() async {
        let viewModel = SavedMeetingNotesViewModel()
        var writes: [String] = []
        viewModel.configure(text: nil) { text in
            writes.append(text)
            if text == "Old draft" {
                try? await Task.sleep(for: .milliseconds(500))
                return false
            }
            return true
        }
        viewModel.textBinding.wrappedValue = "Old draft"
        try? await Task.sleep(for: .milliseconds(600))
        viewModel.textBinding.wrappedValue = "Latest draft"

        let flushed = await viewModel.flush()

        XCTAssertTrue(flushed)
        XCTAssertEqual(writes, ["Old draft", "Latest draft"])
        XCTAssertEqual(viewModel.saveState, .saved)
    }
}
