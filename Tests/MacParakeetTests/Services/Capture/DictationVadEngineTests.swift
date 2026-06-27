import XCTest
import FluidAudio
@testable import MacParakeetCore

// MARK: - Mock

/// A test double for VadManager. Uses `async` on isAvailable and makeStreamState
/// to match the protocol (non-async VadManager properties satisfy async protocol
/// requirements via async-widening).
private actor MockVadManager: VadManagerProviding {
    enum Behavior { case available, throwsOnProcess, neverLoads }
    private let behavior: Behavior
    private(set) var processCalls = 0
    init(_ behavior: Behavior) { self.behavior = behavior }

    var isAvailable: Bool { behavior != .neverLoads }

    func makeStreamState() async -> VadStreamState { VadStreamState.initial() }

    func processStreamingChunk(_ chunk: [Float], state: VadStreamState) async throws -> VadStreamResult {
        processCalls += 1
        if behavior == .throwsOnProcess { throw VadError.modelProcessingFailed("mock") }
        // Emit a speechStart on first call so callers can assert event flow.
        let event = VadStreamEvent(kind: .speechStart, sampleIndex: 0, time: nil)
        var next = state
        next.processedSamples += chunk.count
        return VadStreamResult(state: next, event: event, probability: 0.99)
    }
}

// MARK: - Tests

final class DictationVadEngineTests: XCTestCase {

    func testWarmUpMakesEngineAvailableAndProcessReturnsEvent() async {
        let mock = MockVadManager(.available)
        let engine = DictationVadEngine(makeManager: { mock })
        await engine.warmUpIfNeeded()
        let available = await engine.isAvailable
        XCTAssertTrue(available)

        var state = await engine.makeStreamState()
        XCTAssertNotNil(state)
        var s = state!
        let outer = await engine.process(chunk: [Float](repeating: 0, count: 4096), state: &s)
        // Double-optional: outer nil == unavailable/error; inner nil == no event.
        XCTAssertNotNil(outer, "outer should not be nil when manager is available")
        XCTAssertNotNil(outer!, "inner should not be nil — mock emits speechStart")
        XCTAssertEqual(outer!!.kind, .speechStart)
    }

    func testUnavailableManagerKeepsEngineUnavailable() async {
        let mock = MockVadManager(.neverLoads)
        let engine = DictationVadEngine(makeManager: { mock })
        await engine.warmUpIfNeeded()
        let available = await engine.isAvailable
        XCTAssertFalse(available)
        let state = await engine.makeStreamState()
        XCTAssertNil(state, "no stream state when manager is unavailable")
    }

    func testProcessErrorYieldsOuterNilFallbackSignal() async {
        let mock = MockVadManager(.throwsOnProcess)
        let engine = DictationVadEngine(makeManager: { mock })
        await engine.warmUpIfNeeded()
        var s = (await engine.makeStreamState())!
        let outer = await engine.process(chunk: [Float](repeating: 0, count: 4096), state: &s)
        XCTAssertNil(outer, "process error -> outer nil -> recorder falls back to RMS")
    }

    func testWarmUpIsSingleFlight() async {
        actor Counter { var n = 0; func bump() { n += 1 }; func get() -> Int { n } }
        let counter = Counter()
        let engine = DictationVadEngine(makeManager: {
            await counter.bump()
            return MockVadManager(.available)
        })
        async let a: Void = engine.warmUpIfNeeded()
        async let b: Void = engine.warmUpIfNeeded()
        _ = await (a, b)
        await engine.warmUpIfNeeded()
        let n = await counter.get()
        XCTAssertEqual(n, 1, "manager built exactly once across concurrent + repeat warm-ups")
    }

    /// A build that THROWS marks the engine permanently failed (`loadFailed`),
    /// covering the `catch` block. A second `warmUpIfNeeded()` must NOT re-attempt
    /// the build — `loadFailed` is sticky, so the attempt count stays at 1.
    func testBuildThrowsMarksLoadFailedPermanently() async {
        struct BuildFailure: Error {}
        actor Counter { var n = 0; func bump() { n += 1 }; func get() -> Int { n } }
        let counter = Counter()
        let engine = DictationVadEngine(makeManager: {
            await counter.bump()
            throw BuildFailure()
        })

        await engine.warmUpIfNeeded()
        let availableAfterFailure = await engine.isAvailable
        XCTAssertFalse(availableAfterFailure, "a throwing build leaves the engine unavailable")

        // Second warm-up must short-circuit on loadFailed, not re-invoke makeManager.
        await engine.warmUpIfNeeded()
        let attempts = await counter.get()
        XCTAssertEqual(attempts, 1, "loadFailed is permanent — makeManager is not retried")
    }

    /// `process` on a never-warmed engine takes the `guard let manager` fallback
    /// and returns outer `nil` so the recorder uses the RMS gate.
    func testProcessBeforeWarmUpReturnsOuterNil() async {
        let mock = MockVadManager(.available)
        let engine = DictationVadEngine(makeManager: { mock })
        // Deliberately skip warmUpIfNeeded().
        var s = VadStreamState.initial()
        let outer = await engine.process(chunk: [Float](repeating: 0, count: 4096), state: &s)
        XCTAssertNil(outer, "no manager yet -> outer nil -> RMS fallback")
    }
}
