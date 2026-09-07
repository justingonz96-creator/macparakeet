import XCTest
import FluidAudio
@testable import MacParakeetCore

/// FluidAudio 0.15.6 runs an encoder prediction while loading the Nemotron
/// English models (`encoderProducesNonZeroOutput`), so model preparation is
/// Neural Engine inference and must wait for the macOS 14 gate like every
/// transcription call.
final class NemotronEnglishEngineLoadGatingTests: XCTestCase {

    private actor Probe {
        var holderActive = false
        var loaderObservations: [Bool] = []

        func setHolderActive(_ value: Bool) { holderActive = value }
        func recordLoad() { loaderObservations.append(holderActive) }
    }

    func testPrepareWaitsForAnInFlightInferenceOnASerializingGate() async throws {
        let gate = ANEInferenceGate(serializationRequired: true)
        let probe = Probe()
        let engine = NemotronEnglishEngine(
            inferenceGate: gate,
            managerLoader: { _, _, _ in await probe.recordLoad() }
        )

        let holder = Task {
            try await gate.withExclusiveAccess {
                await probe.setHolderActive(true)
                try await Task.sleep(for: .milliseconds(300))
                await probe.setHolderActive(false)
            }
        }
        // Let the holder acquire the permit before preparation starts.
        try await Task.sleep(for: .milliseconds(50))

        try await engine.prepare()
        try await holder.value

        let observations = await probe.loaderObservations
        XCTAssertEqual(observations.count, 2, "both lane managers load")
        XCTAssertEqual(observations, [false, false], "loads ran only after the holder released the gate")
        let ready = await engine.isReady()
        XCTAssertTrue(ready)
    }

    func testPrepareDoesNotWaitWhenSerializationIsNotRequired() async throws {
        let gate = ANEInferenceGate(serializationRequired: false)
        let probe = Probe()
        let engine = NemotronEnglishEngine(
            inferenceGate: gate,
            managerLoader: { _, _, _ in await probe.recordLoad() }
        )

        let holder = Task {
            try await gate.withExclusiveAccess {
                await probe.setHolderActive(true)
                try await Task.sleep(for: .milliseconds(300))
                await probe.setHolderActive(false)
            }
        }
        try await Task.sleep(for: .milliseconds(50))

        try await engine.prepare()
        try await holder.value

        let observations = await probe.loaderObservations
        XCTAssertEqual(observations, [true, true], "macOS 15+ keeps loads concurrent with inference")
    }

    func testLoaderFailurePropagatesAndLeavesEngineNotReady() async {
        let engine = NemotronEnglishEngine(
            inferenceGate: ANEInferenceGate(serializationRequired: true),
            managerLoader: { _, _, _ in throw ASRError.modelLoadFailed }
        )

        do {
            try await engine.prepare()
            XCTFail("expected the loader error")
        } catch {
            // Mapped by the engine's error mapper.
        }
        let ready = await engine.isReady()
        XCTAssertFalse(ready)
    }
}
