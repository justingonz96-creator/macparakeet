import XCTest
@testable import MacParakeetCore

/// Integration tests for the `DictationService` live streaming branch (ADR-023).
/// All streaming dependencies are mocked — the real CoreML model is never run.
final class LiveDictationFlowTests: XCTestCase {
    private func makeService(
        mockAudio: MockAudioProcessor,
        mockSTT: MockSTTClient,
        broker: MockStreamingDictationBroker?,
        liveEnabled: Bool
    ) throws -> DictationService {
        let dbManager = try DatabaseManager()
        let dictationRepo = DictationRepository(dbQueue: dbManager.dbQueue)
        return DictationService(
            audioProcessor: mockAudio,
            sttTranscriber: mockSTT,
            dictationRepo: dictationRepo,
            liveDictationEnabled: { liveEnabled },
            streamingBroker: broker
        )
    }

    func testLiveDictationFinalTextFlowsThroughPipelineAndDoesNotCallBatch() async throws {
        let mockAudio = MockAudioProcessor()
        let mockSTT = MockSTTClient()
        let broker = MockStreamingDictationBroker()
        await broker.engine.setFinalResult(StreamingDictationResult(text: "hello world"))
        let service = try makeService(mockAudio: mockAudio, mockSTT: mockSTT, broker: broker, liveEnabled: true)

        try await service.startRecording()

        let beginCount = await broker.beginCount
        XCTAssertEqual(beginCount, 1, "Live session must be opened on start")
        let sinkInstalled = await mockAudio.streamingSinkInstalled
        XCTAssertTrue(sinkInstalled, "Streaming sink must be installed before capture")

        let result = try await service.stopRecording()

        XCTAssertEqual(result.dictation.rawTranscript, "hello world")
        XCTAssertEqual(result.dictation.engine, "parakeet")
        XCTAssertEqual(result.dictation.engineVariant, "unified")

        let endCount = await broker.endCount
        XCTAssertEqual(endCount, 1, "Lease must be released on stop")
        let batchCalls = await mockSTT.transcribeCallCount
        XCTAssertEqual(batchCalls, 0, "Streaming must not invoke the batch engine")
        let sinkClearedAfterStop = await mockAudio.streamingSinkInstalled
        XCTAssertFalse(sinkClearedAfterStop, "Sink must be cleared on stop")
    }

    func testLiveDictationStartThrowsWhenModelNotReadyAndDoesNotCapture() async throws {
        let mockAudio = MockAudioProcessor()
        let mockSTT = MockSTTClient()
        let broker = MockStreamingDictationBroker()
        await broker.setReady(false)  // begin throws .modelNotLoaded
        let service = try makeService(mockAudio: mockAudio, mockSTT: mockSTT, broker: broker, liveEnabled: true)

        do {
            try await service.startRecording()
            XCTFail("Start must throw when the streaming model is not ready (ADR-021)")
        } catch {
            // Expected: readiness gate.
        }

        let state = await service.state
        guard case .idle = state else {
            return XCTFail("State must stay idle when the gate fails, got \(state)")
        }
        let startCaptureCalled = await mockAudio.startCaptureCalled
        XCTAssertFalse(startCaptureCalled, "No audio may be captured when the gate fails")
        let batchCalls = await mockSTT.transcribeCallCount
        XCTAssertEqual(batchCalls, 0, "No silent fallback to the batch engine")
    }

    func testStreamingFinishFailureDoesNotFallBackToBatch() async throws {
        let mockAudio = MockAudioProcessor()
        let mockSTT = MockSTTClient()
        let broker = MockStreamingDictationBroker()
        await broker.engine.setFinishError(STTError.transcriptionFailed("boom"))
        let service = try makeService(mockAudio: mockAudio, mockSTT: mockSTT, broker: broker, liveEnabled: true)

        try await service.startRecording()
        do {
            _ = try await service.stopRecording()
            XCTFail("A streaming finish() failure must surface, not silently fall back to the batch engine")
        } catch {
            // Expected: the failure is propagated (ADR-021 / ADR-023 §7).
        }

        let batchCalls = await mockSTT.transcribeCallCount
        XCTAssertEqual(batchCalls, 0, "Batch engine must NOT run when streaming finish() fails — no silent fallback")
        let endCount = await broker.endCount
        XCTAssertEqual(endCount, 1, "Lease must still be released on a finish() failure")
    }

    func testCancelEndsStreamingSessionAndResetsEngine() async throws {
        let mockAudio = MockAudioProcessor()
        let mockSTT = MockSTTClient()
        let broker = MockStreamingDictationBroker()
        let service = try makeService(mockAudio: mockAudio, mockSTT: mockSTT, broker: broker, liveEnabled: true)

        try await service.startRecording()
        await service.cancelRecording()

        let resetCount = await broker.engine.resetCount
        XCTAssertEqual(resetCount, 1, "Cancel must reset the streaming engine, discarding partials")
        let endCount = await broker.endCount
        XCTAssertEqual(endCount, 1, "Cancel must release the lease")
        let sinkCleared = await mockAudio.streamingSinkInstalled
        XCTAssertFalse(sinkCleared, "Cancel must clear the sink")
    }

    func testStreamingPartialSurfacesThroughSessionAccessor() async throws {
        let mockAudio = MockAudioProcessor()
        let mockSTT = MockSTTClient()
        let broker = MockStreamingDictationBroker()
        await broker.engine.setScriptedPartials(["hello"])
        await broker.engine.setFinalResult(StreamingDictationResult(text: "hello"))
        let service = try makeService(mockAudio: mockAudio, mockSTT: mockSTT, broker: broker, liveEnabled: true)
        let session = await DictationServiceSession(service: service)

        try await service.startRecording()
        // Drive the mic sink as the recorder would: sink → append → process →
        // partial callback → the service's partial box.
        await mockAudio.emitStreamingSamples([0.1, 0.2])

        var partial = ""
        for _ in 0..<200 {
            partial = await session.streamingPartialTranscript
            if !partial.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(partial, "hello", "Live partial must surface through the session accessor the overlay reads")

        // After stop, the partial box is cleared.
        _ = try await service.stopRecording()
        let afterStop = await session.streamingPartialTranscript
        XCTAssertTrue(afterStop.isEmpty, "Partial must be cleared after stop")
    }

    func testFeatureClosureOffUsesBatchPathAndNeverOpensSession() async throws {
        let mockAudio = MockAudioProcessor()
        let mockSTT = MockSTTClient()
        await mockSTT.configure(result: STTResult(text: "batched text"))
        let broker = MockStreamingDictationBroker()
        let service = try makeService(mockAudio: mockAudio, mockSTT: mockSTT, broker: broker, liveEnabled: false)

        try await service.startRecording()
        let result = try await service.stopRecording()

        let beginCount = await broker.beginCount
        XCTAssertEqual(beginCount, 0, "Streaming session must never open when the toggle is off")
        let batchCalls = await mockSTT.transcribeCallCount
        XCTAssertEqual(batchCalls, 1, "Batch path must run when live dictation is off")
        XCTAssertEqual(result.dictation.rawTranscript, "batched text")
    }
}
