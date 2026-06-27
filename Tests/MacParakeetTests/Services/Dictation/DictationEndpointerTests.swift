import XCTest
@testable import MacParakeetCore

final class DictationEndpointerTests: XCTestCase {

    /// Fixed clock base so offsets are exact and deterministic.
    private let t0 = Date(timeIntervalSinceReferenceDate: 0)

    // MARK: - RMS fallback parity with today's gate

    /// Today: `level >= 0.03` keeps resetting the timer, so loud audio never
    /// auto-stops no matter how long it runs.
    func testRMSFallback_loudAudioNeverStops() {
        var endpointer = DictationEndpointer(
            config: .init(enabled: true, silenceDuration: 2.0)
        )
        for second in 0...10 {
            let decision = endpointer.evaluate(
                .init(
                    now: t0.addingTimeInterval(Double(second)),
                    elapsed: Double(second),
                    audioLevel: 0.5,            // well above 0.03
                    vadAvailable: false,
                    speechActive: false,
                    vadSilenceElapsed: nil
                )
            )
            XCTAssertEqual(decision, .keepListening, "loud tick \(second) must keep listening")
        }
    }

    /// Today: once `level < 0.03` for `silenceDelay`, it stops. Boundary is
    /// `>=` (inclusive), exactly reproducing the production arithmetic.
    func testRMSFallback_stopsAfterSilenceDuration() {
        var endpointer = DictationEndpointer(
            config: .init(enabled: true, silenceDuration: 2.0)
        )
        // First tick seeds the anchor at t0 (silence already).
        XCTAssertEqual(
            endpointer.evaluate(rmsSilent(at: 0.0)),
            .keepListening
        )
        // 1.0s of silence: not enough.
        XCTAssertEqual(
            endpointer.evaluate(rmsSilent(at: 1.0)),
            .keepListening
        )
        // Just before the threshold: still listening.
        XCTAssertEqual(
            endpointer.evaluate(rmsSilent(at: 1.999)),
            .keepListening
        )
        // Exactly at the threshold (>=): stop.
        XCTAssertEqual(
            endpointer.evaluate(rmsSilent(at: 2.0)),
            .stop(reason: .rmsSilence)
        )
    }

    /// Today: a loud tick mid-silence resets the timer, delaying the stop.
    func testRMSFallback_loudTickResetsSilenceTimer() {
        var endpointer = DictationEndpointer(
            config: .init(enabled: true, silenceDuration: 2.0)
        )
        XCTAssertEqual(endpointer.evaluate(rmsSilent(at: 0.0)), .keepListening)
        XCTAssertEqual(endpointer.evaluate(rmsSilent(at: 1.5)), .keepListening)
        // Loud at 1.6 resets the anchor to 1.6.
        XCTAssertEqual(endpointer.evaluate(rmsLoud(at: 1.6)), .keepListening)
        // 2.0s after start but only 0.4s after reset: keep listening.
        XCTAssertEqual(endpointer.evaluate(rmsSilent(at: 2.0)), .keepListening)
        // 3.6s = 2.0s after the reset: stop.
        XCTAssertEqual(
            endpointer.evaluate(rmsSilent(at: 3.6)),
            .stop(reason: .rmsSilence)
        )
    }

    /// The configured threshold is honored (parity-check that `rmsThreshold`
    /// drives the gate, defaulting to today's 0.03).
    func testRMSFallback_usesConfiguredThreshold() {
        var endpointer = DictationEndpointer(
            config: .init(enabled: true, silenceDuration: 1.0, rmsThreshold: 0.03)
        )
        // 0.029 is below 0.03 → counts as silence.
        XCTAssertEqual(
            endpointer.evaluate(
                .init(now: t0, elapsed: 0, audioLevel: 0.029,
                      vadAvailable: false, speechActive: false, vadSilenceElapsed: nil)
            ),
            .keepListening
        )
        XCTAssertEqual(
            endpointer.evaluate(
                .init(now: t0.addingTimeInterval(1.0), elapsed: 1.0, audioLevel: 0.029,
                      vadAvailable: false, speechActive: false, vadSilenceElapsed: nil)
            ),
            .stop(reason: .rmsSilence)
        )
    }

    // MARK: - VAD-silence stop timing

    func testVAD_stopsAfterSilenceDuration() {
        var endpointer = DictationEndpointer(
            config: .init(enabled: true, silenceDuration: 2.0)
        )
        // Speaking: never stops, regardless of level.
        XCTAssertEqual(
            endpointer.evaluate(vad(at: 0.0, speechActive: true, silenceElapsed: nil)),
            .keepListening
        )
        // Silence began; 1.0s elapsed: not enough.
        XCTAssertEqual(
            endpointer.evaluate(vad(at: 1.0, speechActive: false, silenceElapsed: 1.0)),
            .keepListening
        )
        // 2.0s of VAD silence (>=): stop.
        XCTAssertEqual(
            endpointer.evaluate(vad(at: 2.0, speechActive: false, silenceElapsed: 2.0)),
            .stop(reason: .vadSilence)
        )
    }

    /// VAD says speech is active → never stop even past silenceDuration.
    func testVAD_activeSpeechNeverStops() {
        var endpointer = DictationEndpointer(
            config: .init(enabled: true, silenceDuration: 1.0)
        )
        for second in 0...5 {
            XCTAssertEqual(
                endpointer.evaluate(
                    vad(at: Double(second), speechActive: true, silenceElapsed: 10.0)
                ),
                .keepListening,
                "active-speech tick \(second) must keep listening"
            )
        }
    }

    /// VAD path ignores `audioLevel` entirely (the whole point: noisy room,
    /// high level, but VAD knows it's silence → stop).
    func testVAD_ignoresAudioLevelInNoisyRoom() {
        var endpointer = DictationEndpointer(
            config: .init(enabled: true, silenceDuration: 1.0)
        )
        XCTAssertEqual(
            endpointer.evaluate(
                .init(now: t0.addingTimeInterval(1.0), elapsed: 1.0,
                      audioLevel: 0.9,            // loud fan/music
                      vadAvailable: true,
                      speechActive: false,        // but VAD says no speech
                      vadSilenceElapsed: 1.0)
            ),
            .stop(reason: .vadSilence)
        )
    }

    // MARK: - Disabled (push-to-talk / opt-out) never stops

    func testDisabled_neverStops_RMSPath() {
        var endpointer = DictationEndpointer(
            config: .init(enabled: false, silenceDuration: 0.1)
        )
        for second in 0...10 {
            XCTAssertEqual(
                endpointer.evaluate(rmsSilent(at: Double(second))),
                .keepListening
            )
        }
    }

    func testDisabled_neverStops_VADPath() {
        var endpointer = DictationEndpointer(
            config: .init(enabled: false, silenceDuration: 0.1)
        )
        for second in 0...10 {
            XCTAssertEqual(
                endpointer.evaluate(
                    vad(at: Double(second), speechActive: false, silenceElapsed: 99.0)
                ),
                .keepListening
            )
        }
    }

    // MARK: - One-stop latch

    func testOneStopLatch_RMS() {
        var endpointer = DictationEndpointer(
            config: .init(enabled: true, silenceDuration: 1.0)
        )
        XCTAssertEqual(endpointer.evaluate(rmsSilent(at: 0.0)), .keepListening)
        XCTAssertEqual(
            endpointer.evaluate(rmsSilent(at: 1.0)),
            .stop(reason: .rmsSilence)
        )
        // Every later tick — even more silence — must NOT stop again.
        XCTAssertEqual(endpointer.evaluate(rmsSilent(at: 2.0)), .keepListening)
        XCTAssertEqual(endpointer.evaluate(rmsSilent(at: 5.0)), .keepListening)
    }

    func testOneStopLatch_VAD() {
        var endpointer = DictationEndpointer(
            config: .init(enabled: true, silenceDuration: 1.0)
        )
        XCTAssertEqual(
            endpointer.evaluate(vad(at: 1.0, speechActive: false, silenceElapsed: 1.0)),
            .stop(reason: .vadSilence)
        )
        XCTAssertEqual(
            endpointer.evaluate(vad(at: 2.0, speechActive: false, silenceElapsed: 2.0)),
            .keepListening
        )
    }

    // MARK: - vadAvailable == false routes to RMS

    func testVADUnavailable_usesRMSPath() {
        var endpointer = DictationEndpointer(
            config: .init(enabled: true, silenceDuration: 1.0)
        )
        // vadAvailable == false: speechActive/silenceElapsed must be ignored,
        // and the RMS gate (audioLevel) decides instead.
        XCTAssertEqual(
            endpointer.evaluate(
                .init(now: t0, elapsed: 0, audioLevel: 0.5,    // loud → RMS keeps listening
                      vadAvailable: false,
                      speechActive: false,                     // would stop on VAD path
                      vadSilenceElapsed: 99.0)                 // huge, but ignored
            ),
            .keepListening
        )
        // Now go silent on the RMS path and confirm it stops via .rmsSilence
        // (NOT .vadSilence), proving the VAD fields were ignored.
        XCTAssertEqual(endpointer.evaluate(rmsSilent(at: 0.0)), .keepListening)
        XCTAssertEqual(
            endpointer.evaluate(rmsSilent(at: 1.0)),
            .stop(reason: .rmsSilence)
        )
    }

    // MARK: - Helpers

    private func rmsSilent(at offset: TimeInterval) -> DictationEndpointer.Input {
        .init(
            now: t0.addingTimeInterval(offset),
            elapsed: offset,
            audioLevel: 0.0,
            vadAvailable: false,
            speechActive: false,
            vadSilenceElapsed: nil
        )
    }

    private func rmsLoud(at offset: TimeInterval) -> DictationEndpointer.Input {
        .init(
            now: t0.addingTimeInterval(offset),
            elapsed: offset,
            audioLevel: 0.5,
            vadAvailable: false,
            speechActive: false,
            vadSilenceElapsed: nil
        )
    }

    private func vad(
        at offset: TimeInterval,
        speechActive: Bool,
        silenceElapsed: TimeInterval?
    ) -> DictationEndpointer.Input {
        .init(
            now: t0.addingTimeInterval(offset),
            elapsed: offset,
            audioLevel: 0.0,
            vadAvailable: true,
            speechActive: speechActive,
            vadSilenceElapsed: silenceElapsed
        )
    }
}
