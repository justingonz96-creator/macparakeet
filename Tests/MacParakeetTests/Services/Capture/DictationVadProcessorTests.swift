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
