import XCTest
@testable import MacParakeetViewModels

@MainActor
final class SavedMeetingNotesViewModelTests: XCTestCase {
    private let meetingID = UUID()

    func testConfigureRestoresTextWithoutWriting() async {
        let viewModel = SavedMeetingNotesViewModel()
        var writes: [String] = []

        viewModel.configure(meetingID: meetingID, text: "Existing notes") { text in
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
        viewModel.configure(meetingID: meetingID, text: nil) { text in
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
        viewModel.configure(meetingID: meetingID, text: nil) { text in
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
        viewModel.configure(meetingID: meetingID, text: nil) { text in
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
        viewModel.configure(meetingID: meetingID, text: nil) { text in
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
        let oldSaveStarted = expectation(description: "Old save started")
        var releaseOldSave: (() -> Void)?
        viewModel.configure(meetingID: meetingID, text: nil) { text in
            writes.append(text)
            if text == "Old draft" {
                oldSaveStarted.fulfill()
                await withCheckedContinuation { continuation in
                    releaseOldSave = { continuation.resume() }
                }
                return false
            }
            return true
        }
        viewModel.textBinding.wrappedValue = "Old draft"
        let oldFlush = Task { @MainActor in
            await viewModel.flush()
        }
        await fulfillment(of: [oldSaveStarted], timeout: 1)
        viewModel.textBinding.wrappedValue = "Latest draft"
        releaseOldSave?()

        let flushed = await viewModel.flush()
        let oldFlushed = await oldFlush.value

        XCTAssertFalse(oldFlushed)
        XCTAssertTrue(flushed)
        XCTAssertEqual(writes, ["Old draft", "Latest draft"])
        XCTAssertEqual(viewModel.saveState, .saved)
    }

    func testFailedSelectionTransitionPreservesPreviousDraftAndRetryState() async {
        let viewModel = SavedMeetingNotesViewModel()
        let nextMeetingID = UUID()
        viewModel.configure(meetingID: meetingID, text: "Meeting A") { _ in false }
        viewModel.textBinding.wrappedValue = "Unsaved meeting A"
        let transition = viewModel.beginSelectionTransition()

        let configured = await viewModel.completeSelectionTransition(
            transition,
            meetingID: nextMeetingID,
            text: "Meeting B"
        ) { _ in true }

        XCTAssertFalse(configured)
        XCTAssertEqual(viewModel.meetingID, meetingID)
        XCTAssertEqual(viewModel.text, "Unsaved meeting A")
        XCTAssertEqual(viewModel.saveState, .failed)
    }

    func testOlderSelectionTransitionCannotReplaceNewerMeeting() async {
        let viewModel = SavedMeetingNotesViewModel()
        let meetingBID = UUID()
        let meetingCID = UUID()
        var writesByMeeting: [UUID: [String]] = [:]
        viewModel.configure(meetingID: meetingID, text: "Meeting A") { text in
            writesByMeeting[self.meetingID, default: []].append(text)
            try? await Task.sleep(for: .milliseconds(300))
            return true
        }
        viewModel.textBinding.wrappedValue = "Updated A"

        let transitionToB = viewModel.beginSelectionTransition()
        let taskToB = Task { @MainActor in
            await viewModel.completeSelectionTransition(
                transitionToB,
                meetingID: meetingBID,
                text: "Meeting B"
            ) { text in
                writesByMeeting[meetingBID, default: []].append(text)
                return true
            }
        }
        try? await Task.sleep(for: .milliseconds(50))
        let transitionToC = viewModel.beginSelectionTransition()
        let taskToC = Task { @MainActor in
            await viewModel.completeSelectionTransition(
                transitionToC,
                meetingID: meetingCID,
                text: "Meeting C"
            ) { text in
                writesByMeeting[meetingCID, default: []].append(text)
                return true
            }
        }

        let configuredB = await taskToB.value
        let configuredC = await taskToC.value
        XCTAssertFalse(configuredB)
        XCTAssertTrue(configuredC)
        XCTAssertEqual(viewModel.meetingID, meetingCID)
        XCTAssertEqual(viewModel.text, "Meeting C")

        viewModel.textBinding.wrappedValue = "Updated C"
        let flushedC = await viewModel.flush()
        XCTAssertTrue(flushedC)
        XCTAssertEqual(writesByMeeting[meetingID], ["Updated A"])
        XCTAssertNil(writesByMeeting[meetingBID])
        XCTAssertEqual(writesByMeeting[meetingCID], ["Updated C"])
    }
}
