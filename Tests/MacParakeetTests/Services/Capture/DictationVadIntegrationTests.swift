import XCTest
import FluidAudio
@testable import MacParakeetCore

final class DictationVadIntegrationTests: XCTestCase {
    /// Offline / unavailable engine: warm-up reports unavailable, so the
    /// recorder builds a passthrough processor and the published snapshot stays
    /// `.unavailable` — the coordinator then uses the RMS gate.
    func testUnavailableEngineKeepsSnapshotUnavailable() async {
        let engine = DictationVadEngine(makeManager: { MockUnavailableManager() })
        await engine.warmUpIfNeeded()
        let available = await engine.isAvailable
        XCTAssertFalse(available)
        // The recorder's gate is `enableVad() && isAvailable && makeStreamState != nil`;
        // with isAvailable false it never allocates a streaming processor.
        let state = await engine.makeStreamState()
        XCTAssertNil(state)
    }

    /// Passthrough processor consumes zero chunks, so an unavailable VAD path
    /// performs no per-chunk work — proving the writer path is untouched.
    func testPassthroughProcessorConsumesNoChunks() {
        let processor = PassthroughDictationVadProcessor()
        var emitted = 0
        for _ in 0..<10 {
            processor.accept(samples: [Float](repeating: 0.1, count: 1486)) { _ in emitted += 1 }
        }
        XCTAssertEqual(emitted, 0)
    }
}

private actor MockUnavailableManager: VadManagerProviding {
    var isAvailable: Bool { get async { false } }
    func makeStreamState() async -> VadStreamState { .initial() }
    func processStreamingChunk(_ chunk: [Float], state: VadStreamState) async throws -> VadStreamResult {
        VadStreamResult(state: state, event: nil, probability: 0)
    }
}
