import XCTest
import FluidAudio
@testable import MacParakeetCore

final class NemotronEngineTests: XCTestCase {
    private func tt(_ token: String, _ start: Double, _ end: Double) -> TokenTiming {
        TokenTiming(token: token, tokenId: 0, startTime: start, endTime: end, confidence: 1.0)
    }

    func testGroupsSubwordTokensIntoWordsByBoundaryMarker() {
        // "▁Bon" + "jour" -> "Bonjour"; "▁le" + "▁monde" -> "le", "monde"
        let timings = [
            tt("\u{2581}Bon", 0.0, 0.08),
            tt("jour", 0.08, 0.16),
            tt("\u{2581}le", 0.20, 0.28),
            tt("\u{2581}monde", 0.30, 0.40),
        ]
        let words = NemotronEngine.mapTokenTimings(timings)
        XCTAssertEqual(words.map(\.word), ["Bonjour", "le", "monde"])
        XCTAssertEqual(words[0].startMs, 0)
        XCTAssertEqual(words[0].endMs, 160)   // end of the second sub-word token
        XCTAssertEqual(words[1].startMs, 200)
        XCTAssertEqual(words[2].endMs, 400)
    }

    func testConfidenceIsSentinelOne() {
        let words = NemotronEngine.mapTokenTimings([tt("\u{2581}Hola", 0.0, 0.1)])
        XCTAssertEqual(words.first?.confidence, 1.0)
    }

    func testEmptyTimingsProduceNoWords() {
        XCTAssertTrue(NemotronEngine.mapTokenTimings([]).isEmpty)
    }

    func testLeadingTokenWithoutMarkerStillStartsAWord() {
        // Defensive: a stream that doesn't begin with ▁ should not drop text.
        let words = NemotronEngine.mapTokenTimings([tt("Ciao", 0.0, 0.1)])
        XCTAssertEqual(words.map(\.word), ["Ciao"])
    }
}
