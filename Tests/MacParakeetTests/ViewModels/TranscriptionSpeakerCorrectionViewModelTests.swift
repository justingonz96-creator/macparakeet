import XCTest
@testable import MacParakeetCore
@testable import MacParakeetViewModels

private final class StubSpeakerAttributionReader: SpeakerAttributionReading, @unchecked Sendable {
    private let lock = NSLock()
    private let projection: SpeakerAttributionProjection
    private(set) var requestedIDs: [UUID] = []

    init(projection: SpeakerAttributionProjection) {
        self.projection = projection
    }

    func resolve(transcriptionId: UUID) throws -> SpeakerAttributionProjection? {
        lock.lock()
        requestedIDs.append(transcriptionId)
        lock.unlock()
        return projection
    }

    func resolve(transcription _: Transcription) throws -> SpeakerAttributionProjection {
        projection
    }
}

private actor StubSpeakerCorrectionService: SpeakerCorrectionServicing {
    struct ApplyCall: Sendable {
        let transcriptionID: UUID
        let command: SpeakerCorrectionCommand
        let fingerprint: TranscriptFingerprint
        let revision: Int
    }

    private(set) var applyCalls: [ApplyCall] = []
    private(set) var undoCount = 0
    private(set) var redoCount = 0
    let result: SpeakerCorrectionResult
    let applyError: SpeakerCorrectionServiceError?

    init(result: SpeakerCorrectionResult, applyError: SpeakerCorrectionServiceError? = nil) {
        self.result = result
        self.applyError = applyError
    }

    func apply(
        transcriptionId: UUID,
        command: SpeakerCorrectionCommand,
        expectedFingerprint: TranscriptFingerprint,
        expectedRevision: Int
    ) async throws -> SpeakerCorrectionResult {
        if let applyError { throw applyError }
        applyCalls.append(
            ApplyCall(
                transcriptionID: transcriptionId,
                command: command,
                fingerprint: expectedFingerprint,
                revision: expectedRevision
            )
        )
        return result
    }

    func undo(
        transcriptionId _: UUID,
        expectedFingerprint _: TranscriptFingerprint,
        expectedRevision _: Int
    ) async throws -> SpeakerCorrectionResult {
        undoCount += 1
        return result
    }

    func redo(
        transcriptionId _: UUID,
        expectedFingerprint _: TranscriptFingerprint,
        expectedRevision _: Int
    ) async throws -> SpeakerCorrectionResult {
        redoCount += 1
        return result
    }
}

@MainActor
final class TranscriptionSpeakerCorrectionViewModelTests: XCTestCase {
    func testLoadingPublishesEffectiveAttributionAndHistoryAvailability() async throws {
        let transcription = makeTranscription()
        let attribution = SpeakerAttributionResolver.resolve(transcription: transcription)
        let reader = StubSpeakerAttributionReader(
            projection: SpeakerAttributionProjection(
                automaticTranscription: transcription,
                attribution: attribution,
                correctionsApplied: true,
                canUndo: true,
                canRedo: true
            )
        )
        let viewModel = TranscriptionViewModel()
        viewModel.configure(
            transcriptionService: MockTranscriptionService(),
            transcriptionRepo: MockTranscriptionRepository(),
            speakerAttributionReader: reader
        )

        viewModel.currentTranscription = transcription

        try await waitUntil { viewModel.speakerAttribution != nil }
        XCTAssertEqual(reader.requestedIDs, [transcription.id])
        XCTAssertTrue(viewModel.speakerCorrectionsApplied)
        XCTAssertTrue(viewModel.canUndoSpeakerCorrection)
        XCTAssertTrue(viewModel.canRedoSpeakerCorrection)
        XCTAssertEqual(viewModel.effectiveCurrentTranscription?.wordTimestamps, attribution.words)
    }

    func testApplyingCorrectionUsesLoadedOptimisticVersionAndPublishesResult() async throws {
        let transcription = makeTranscription()
        let attribution = SpeakerAttributionResolver.resolve(transcription: transcription)
        let reader = StubSpeakerAttributionReader(
            projection: SpeakerAttributionProjection(
                automaticTranscription: transcription,
                attribution: attribution,
                correctionsApplied: false
            )
        )
        let service = StubSpeakerCorrectionService(
            result: SpeakerCorrectionResult(
                attribution: attribution,
                revision: 1,
                canUndo: true,
                canRedo: false
            )
        )
        let viewModel = TranscriptionViewModel()
        viewModel.configure(
            transcriptionService: MockTranscriptionService(),
            transcriptionRepo: MockTranscriptionRepository(),
            speakerAttributionReader: reader,
            speakerCorrectionService: service
        )
        viewModel.currentTranscription = transcription
        try await waitUntil { viewModel.speakerAttribution != nil }

        let command = SpeakerCorrectionCommand.rename(speakerID: "S1", label: "Alice")
        viewModel.applySpeakerCorrection(command)

        try await waitUntil { !viewModel.isApplyingSpeakerCorrection && viewModel.canUndoSpeakerCorrection }
        let calls = await service.applyCalls
        let call = try XCTUnwrap(calls.first)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(call.transcriptionID, transcription.id)
        XCTAssertEqual(call.command, command)
        XCTAssertEqual(call.fingerprint, attribution.fingerprint)
        XCTAssertEqual(call.revision, attribution.correctionRevision)
        XCTAssertTrue(viewModel.speakerCorrectionsApplied)
        XCTAssertFalse(viewModel.canRedoSpeakerCorrection)
    }

    func testUndoPublishesRedoAvailability() async throws {
        let transcription = makeTranscription()
        let attribution = SpeakerAttributionResolver.resolve(transcription: transcription)
        let reader = StubSpeakerAttributionReader(
            projection: SpeakerAttributionProjection(
                automaticTranscription: transcription,
                attribution: attribution,
                correctionsApplied: true,
                canUndo: true
            )
        )
        let service = StubSpeakerCorrectionService(
            result: SpeakerCorrectionResult(
                attribution: attribution,
                revision: 2,
                canUndo: false,
                canRedo: true
            )
        )
        let viewModel = TranscriptionViewModel()
        viewModel.configure(
            transcriptionService: MockTranscriptionService(),
            transcriptionRepo: MockTranscriptionRepository(),
            speakerAttributionReader: reader,
            speakerCorrectionService: service
        )
        viewModel.currentTranscription = transcription
        try await waitUntil { viewModel.speakerAttribution != nil }

        viewModel.undoSpeakerCorrection()

        try await waitUntil { !viewModel.isApplyingSpeakerCorrection && viewModel.canRedoSpeakerCorrection }
        let undoCount = await service.undoCount
        XCTAssertEqual(undoCount, 1)
        XCTAssertFalse(viewModel.canUndoSpeakerCorrection)
        XCTAssertFalse(viewModel.speakerCorrectionsApplied)
    }

    func testConflictReloadsAttributionAndReportsActionableError() async throws {
        let transcription = makeTranscription()
        let attribution = SpeakerAttributionResolver.resolve(transcription: transcription)
        let reader = StubSpeakerAttributionReader(
            projection: SpeakerAttributionProjection(
                automaticTranscription: transcription,
                attribution: attribution,
                correctionsApplied: false
            )
        )
        let service = StubSpeakerCorrectionService(
            result: SpeakerCorrectionResult(
                attribution: attribution,
                revision: 0,
                canUndo: false,
                canRedo: false
            ),
            applyError: SpeakerCorrectionServiceError.conflict
        )
        let viewModel = TranscriptionViewModel()
        viewModel.configure(
            transcriptionService: MockTranscriptionService(),
            transcriptionRepo: MockTranscriptionRepository(),
            speakerAttributionReader: reader,
            speakerCorrectionService: service
        )
        viewModel.currentTranscription = transcription
        try await waitUntil { reader.requestedIDs.count == 1 && viewModel.speakerAttribution != nil }

        viewModel.applySpeakerCorrection(.rename(speakerID: "S1", label: "Alice"))

        try await waitUntil { reader.requestedIDs.count == 2 && !viewModel.isApplyingSpeakerCorrection }
        XCTAssertEqual(
            viewModel.errorMessage,
            "Speaker changes were updated elsewhere. Review and try again."
        )
    }

    private func makeTranscription() -> Transcription {
        let words = [
            WordTimestamp(word: "hello", startMs: 0, endMs: 400, confidence: 0.9, speakerId: "S1"),
            WordTimestamp(word: "there", startMs: 450, endMs: 800, confidence: 0.9, speakerId: "S1"),
        ]
        return Transcription(
            fileName: "meeting.wav",
            rawTranscript: "hello there",
            wordTimestamps: words,
            speakerCount: 1,
            speakers: [SpeakerInfo(id: "S1", label: "Speaker 1")],
            diarizationSegments: [.init(speakerId: "S1", startMs: 0, endMs: 800)],
            transcriptSegments: [
                TranscriptSegmentRecord(
                    startMs: 0,
                    endMs: 800,
                    speakerId: "S1",
                    speakerLabel: "Speaker 1",
                    text: "hello there",
                    wordRange: .init(startIndex: 0, endIndexExclusive: 2)
                )
            ],
            status: .completed,
            sourceType: .meeting
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !condition() {
            if clock.now >= deadline {
                XCTFail("Timed out waiting for condition")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
