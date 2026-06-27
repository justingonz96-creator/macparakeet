import AVFoundation
import XCTest

@testable import MacParakeetCore

final class AudioRecorderStreamingSinkTests: XCTestCase {
    /// The live streaming sink forwards exactly the 16 kHz mono Float32 samples
    /// that are written to the dictation WAV (ADR-023 §6) — so the extraction
    /// must read channel 0 for the full frame length, in order.
    func testMonoFloatSamplesExtractsChannelZeroSamples() throws {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )!
        let expected: [Float] = [0.0, 0.25, -0.5, 0.75, -1.0]
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(expected.count))!
        buffer.frameLength = AVAudioFrameCount(expected.count)
        for (index, value) in expected.enumerated() {
            buffer.floatChannelData![0][index] = value
        }

        let samples = AudioRecorder.monoFloatSamples(from: buffer)

        XCTAssertEqual(samples, expected)
    }

    func testMonoFloatSamplesIsEmptyForZeroFrames() throws {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16)!
        buffer.frameLength = 0

        XCTAssertTrue(AudioRecorder.monoFloatSamples(from: buffer).isEmpty)
    }
}
