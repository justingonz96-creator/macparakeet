import GRDB
import XCTest
@testable import MacParakeet
@testable import MacParakeetCore
@testable import MacParakeetViewModels

private actor SpeakerContextFormattingGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isReleased = false

    func wait() async {
        guard !isReleased else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        isReleased = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
final class TranscriptSpeakerContextTests: XCTestCase {
    func testCorrectionRefreshesCachedChatAndPromptContextWithoutReplacingCanonicalRow() async throws {
        let fixture = try makeFixture()
        let viewModel = fixture.viewModel
        try await waitUntil { viewModel.speakerAttribution != nil }
        let revision = viewModel.currentTranscriptionRevision
        let loader = TranscriptRichContextLoader()
        var chatContext = ""
        await loader.schedule(
            transcription: try XCTUnwrap(viewModel.effectiveCurrentTranscription),
            mode: .richTranscript,
            contentRevision: revision,
            speakerCorrectionRevision: viewModel.speakerAttribution?.correctionRevision
        ) { _, text in chatContext = text }.value
        XCTAssertTrue(chatContext.contains("Speaker 1:"))

        viewModel.renameSpeaker(id: "S1", to: "Alice")
        try await waitUntil { viewModel.speakerAttribution?.correctionRevision == 1 }
        XCTAssertEqual(viewModel.currentTranscriptionRevision, revision)
        XCTAssertEqual(try fixture.repository.fetch(id: fixture.transcription.id)?.speakers?.first?.label, "Speaker 1")

        await loader.schedule(
            transcription: try XCTUnwrap(viewModel.effectiveCurrentTranscription),
            mode: .richTranscript,
            contentRevision: revision,
            speakerCorrectionRevision: viewModel.speakerAttribution?.correctionRevision
        ) { _, text in chatContext = text }.value
        XCTAssertTrue(chatContext.contains("Alice:"))
        XCTAssertFalse(chatContext.contains("Speaker 1:"))
        var promptContext = ""
        let action = try XCTUnwrap(loader.startPromptAction(
            transcription: try XCTUnwrap(viewModel.effectiveCurrentTranscription),
            mode: .richTranscript,
            contentRevision: revision,
            speakerCorrectionRevision: viewModel.speakerAttribution?.correctionRevision,
            isCurrent: { $0.speakerCorrectionRevision == viewModel.speakerAttribution?.correctionRevision },
            onStale: { XCTFail("The corrected snapshot should remain current") },
            action: { promptContext = $0 }
        ))
        await action.value
        XCTAssertEqual(promptContext, chatContext)

        viewModel.undoSpeakerCorrection()
        try await waitUntil { viewModel.speakerAttribution?.correctionRevision == 2 }
        let undone = await loader.prepare(
            transcription: try XCTUnwrap(viewModel.effectiveCurrentTranscription),
            mode: .richTranscript,
            contentRevision: revision,
            speakerCorrectionRevision: viewModel.speakerAttribution?.correctionRevision
        )
        XCTAssertTrue(try XCTUnwrap(undone).text.contains("Speaker 1:"))
    }

    func testLoadingStoredCorrectionsInvalidatesCachedAutomaticContext() async throws {
        let fixture = try makeFixture()
        let loader = TranscriptRichContextLoader()
        let baseline = await loader.prepare(
            transcription: fixture.transcription,
            mode: .richTranscript,
            contentRevision: 1,
            speakerCorrectionRevision: nil
        )
        XCTAssertTrue(try XCTUnwrap(baseline).text.contains("Speaker 1:"))
        _ = try await fixture.service.apply(
            transcriptionId: fixture.transcription.id,
            command: .rename(speakerID: "S1", label: "Alice"),
            expectedFingerprint: SpeakerAttributionResolver.fingerprint(for: fixture.transcription),
            expectedRevision: 0
        )
        let stored = try fixture.reader.resolve(transcription: fixture.transcription)
        let loaded = await loader.prepare(
            transcription: stored.effectiveTranscription,
            mode: .richTranscript,
            contentRevision: 1,
            speakerCorrectionRevision: stored.correctionRevision
        )
        XCTAssertTrue(try XCTUnwrap(loaded).text.contains("Alice:"))
    }

    func testSpeakerChangeDuringPreparationCannotSubmitStaleContext() async throws {
        let started = expectation(description: "Formatting started")
        let gate = SpeakerContextFormattingGate()
        let loader = TranscriptRichContextLoader { transcription, mode in
            started.fulfill()
            await gate.wait()
            return TranscriptAIContextFormatter.format(transcription: transcription, mode: mode)
        }
        var speakerRevision: Int? = 0
        var stale = false
        let action = try XCTUnwrap(loader.startPromptAction(
            transcription: makeTranscription(),
            mode: .richTranscript,
            contentRevision: 1,
            speakerCorrectionRevision: speakerRevision,
            isCurrent: { $0.speakerCorrectionRevision == speakerRevision },
            onStale: { stale = true },
            action: { _ in XCTFail("Old speaker attribution must never be submitted") }
        ))
        await fulfillment(of: [started], timeout: 2)
        speakerRevision = 1
        await gate.release()
        await action.value
        XCTAssertTrue(stale)
    }

    func testViewModelRefreshPreservesCorrectionProvenanceWithConfiguredArtifactStore() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let fixture = try makeFixture(folder: folder)
        let viewModel = fixture.viewModel
        try await waitUntil { viewModel.speakerAttribution != nil }
        let segment = try XCTUnwrap(viewModel.speakerAttribution?.editableSegments.first)
        let manualID = "user:\(UUID().uuidString)"
        viewModel.applySpeakerCorrection(.add(
            speaker: ManualSpeaker(id: manualID, label: "Alice"),
            assigning: [.init(anchorTranscriptSegmentIDs: segment.anchorTranscriptSegmentIDs, wordRange: segment.wordRange)]
        ))
        let manifest = folder.appendingPathComponent(MeetingArtifactStore.manifestFileName)
        try await waitUntil { FileManager.default.fileExists(atPath: manifest.path) }
        let transcript = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: folder.appendingPathComponent(MeetingArtifactStore.transcriptFileName))
        ) as? [String: Any])
        XCTAssertEqual(transcript["speakerCorrectionsApplied"] as? Bool, true)
        XCTAssertEqual(transcript["speakerCorrectionRevision"] as? Int, 1)
        let words = try XCTUnwrap(transcript["wordTimestamps"] as? [[String: Any]])
        XCTAssertEqual(words.compactMap { $0["speakerId"] as? String }, [manualID, manualID])
        let markdown = try String(contentsOf: folder.appendingPathComponent(MeetingArtifactStore.markdownFileName))
        XCTAssertTrue(markdown.contains("speakerCorrectionsApplied: true"))
        XCTAssertTrue(markdown.contains("speakerCorrectionRevision: 1"))
        XCTAssertTrue(markdown.contains("Alice"))
        XCTAssertEqual(try fixture.repository.fetch(id: fixture.transcription.id)?.wordTimestamps, fixture.transcription.wordTimestamps)
    }

    private func makeFixture(folder: URL? = nil) throws -> (
        viewModel: TranscriptionViewModel, transcription: Transcription,
        repository: TranscriptionRepository, reader: SpeakerAttributionReadService,
        service: SpeakerCorrectionService
    ) {
        let manager = try DatabaseManager()
        let repository = TranscriptionRepository(dbQueue: manager.dbQueue)
        let reader = SpeakerAttributionReadService(dbQueue: manager.dbQueue)
        let service = SpeakerCorrectionService(dbQueue: manager.dbQueue)
        var transcription = makeTranscription()
        transcription.meetingArtifactFolderPath = folder?.path
        try repository.save(transcription)
        let viewModel = TranscriptionViewModel(meetingArtifactStore: MeetingArtifactStore(speakerAttributionReader: reader))
        viewModel.configure(
            transcriptionService: MockTranscriptionService(),
            transcriptionRepo: repository,
            promptResultRepo: PromptResultRepository(dbQueue: manager.dbQueue),
            speakerAttributionReader: reader,
            speakerCorrectionService: service
        )
        viewModel.currentTranscription = transcription
        return (viewModel, transcription, repository, reader, service)
    }

    private func makeTranscription() -> Transcription {
        let words = [
            WordTimestamp(word: "Hello", startMs: 0, endMs: 400, confidence: 1, speakerId: "S1"),
            WordTimestamp(word: "there.", startMs: 450, endMs: 800, confidence: 1, speakerId: "S1"),
        ]
        let speakers = [SpeakerInfo(id: "S1", label: "Speaker 1")]
        return Transcription(
            fileName: "Meeting", rawTranscript: "Hello there.", wordTimestamps: words,
            speakerCount: 1, speakers: speakers,
            transcriptSegments: TranscriptSegmenter.materializeSegments(words: words, speakers: speakers),
            status: .completed, sourceType: .meeting
        )
    }

    private func waitUntil(condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(3)
        while !condition() {
            guard clock.now < deadline else {
                XCTFail("Timed out waiting for speaker projection or artifact")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
