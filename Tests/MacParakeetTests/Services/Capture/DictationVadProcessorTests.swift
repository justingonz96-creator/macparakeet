import XCTest
@testable import MacParakeetCore

final class DictationVadProcessorTests: XCTestCase {
    func testPassthroughEmitsNothingAndReportsLoadedDiagnostics() {
        let processor = PassthroughDictationVadProcessor()
        var emitted: [[Float]] = []
        processor.accept(samples: [0.1, 0.2, 0.3]) { emitted.append($0) }
        XCTAssertTrue(emitted.isEmpty, "passthrough never emits VAD chunks")
        XCTAssertEqual(processor.diagnostics.processorName, "passthrough")
        XCTAssertTrue(processor.diagnostics.loaded)
        XCTAssertEqual(processor.diagnostics.chunksEmitted, 0)
    }
}

extension DictationVadProcessorTests {
    /// Feed a contiguous ramp in ~1486-sample buffers; the emitted 4096-chunks
    /// must reconstruct the input exactly, in order, with no dropped/duplicated
    /// samples across buffer boundaries, and no chunk may exceed 4096.
    func testStreamingChunkingIsByteExactAcrossBufferBoundaries() {
        let processor = StreamingDictationVadProcessor()
        let bufferSize = 1486
        let bufferCount = 9 // 9 * 1486 = 13374 samples -> 3 full 4096 chunks + 1086 leftover
        var input: [Float] = []
        input.reserveCapacity(bufferSize * bufferCount)
        for i in 0..<(bufferSize * bufferCount) { input.append(Float(i)) }

        var emitted: [[Float]] = []
        var cursor = 0
        for _ in 0..<bufferCount {
            let buffer = Array(input[cursor..<(cursor + bufferSize)])
            cursor += bufferSize
            processor.accept(samples: buffer) { emitted.append($0) }
        }

        XCTAssertEqual(emitted.count, 3, "13374 samples -> 3 complete 4096 chunks")
        for chunk in emitted {
            XCTAssertEqual(chunk.count, 4096, "VAD chunk must be exactly 4096 samples")
        }
        XCTAssertLessThanOrEqual(
            emitted.map(\.count).max() ?? 0, 4096,
            "must never emit a chunk larger than 4096"
        )
        let reconstructed = emitted.flatMap { $0 }
        XCTAssertEqual(reconstructed, Array(input.prefix(reconstructed.count)),
                       "emitted chunks reconstruct the input contiguously")
        XCTAssertEqual(reconstructed.count, 3 * 4096)
        XCTAssertEqual(processor.diagnostics.chunksEmitted, 3)
        XCTAssertEqual(processor.diagnostics.samplesAccumulated, bufferSize * bufferCount)
    }

    func testStreamingLeftoverTailIsRetainedNotEmitted() {
        let processor = StreamingDictationVadProcessor()
        var emitted: [[Float]] = []
        // 4096 + 100 leftover -> exactly one chunk emitted, 100 retained.
        let input = (0..<4196).map { Float($0) }
        processor.accept(samples: input) { emitted.append($0) }
        XCTAssertEqual(emitted.count, 1)
        XCTAssertEqual(emitted[0].count, 4096)
        // Next 3996 samples complete the second chunk using the retained 100.
        let more = (4196..<8192).map { Float($0) }
        processor.accept(samples: more) { emitted.append($0) }
        XCTAssertEqual(emitted.count, 2)
        XCTAssertEqual(emitted[1], (4096..<8192).map { Float($0) })
    }

    func testResetClearsAccumulatorAndDiagnostics() {
        let processor = StreamingDictationVadProcessor()
        processor.accept(samples: (0..<2000).map { Float($0) }) { _ in }
        processor.reset()
        var emitted: [[Float]] = []
        // After reset the retained 2000 samples are gone, so 2096 new samples
        // are not yet a full chunk.
        processor.accept(samples: (0..<2096).map { Float($0) }) { emitted.append($0) }
        XCTAssertTrue(emitted.isEmpty)
        XCTAssertEqual(processor.diagnostics.chunksEmitted, 0)
        XCTAssertEqual(processor.diagnostics.samplesAccumulated, 2096)
    }
}
