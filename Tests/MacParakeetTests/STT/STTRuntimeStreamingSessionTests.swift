import Foundation
import XCTest

@testable import MacParakeetCore

final class STTRuntimeStreamingSessionTests: XCTestCase {
    func testPrepareForwardsToEngineAndReportsReady() async throws {
        let mock = StreamingDictationEngineMock()
        await mock.setReady(false)
        let runtime = STTRuntime(makeStreamingEngine: { mock })

        let readyBefore = await runtime.isStreamingDictationReady()
        XCTAssertFalse(readyBefore)

        try await runtime.prepareStreamingDictation(onProgress: nil)

        let prepareCount = await mock.prepareCount
        XCTAssertEqual(prepareCount, 1)
        let readyAfter = await runtime.isStreamingDictationReady()
        XCTAssertTrue(readyAfter)
    }

    func testBeginStreamingSessionThrowsWhenEngineNotReady() async {
        let mock = StreamingDictationEngineMock()
        await mock.setReady(false)
        let runtime = STTRuntime(makeStreamingEngine: { mock })

        do {
            _ = try await runtime.beginStreamingDictationSession()
            XCTFail("Expected a readiness error — live dictation must not start when the model is missing (ADR-021)")
        } catch {
            // Expected: no silent fallback, fail before recording.
        }
    }

    func testBeginStreamingSessionResetsEngineAndReturnsUsableSession() async throws {
        let mock = StreamingDictationEngineMock()
        await mock.setReady(true)
        await mock.setFinalResult(StreamingDictationResult(text: "live text"))
        let runtime = STTRuntime(makeStreamingEngine: { mock })

        let session = try await runtime.beginStreamingDictationSession()

        // A fresh session resets prior decode/buffer state.
        let resetCount = await mock.resetCount
        XCTAssertEqual(resetCount, 1)

        let result = try await session.finish()
        XCTAssertEqual(result.text, "live text")
    }
}
