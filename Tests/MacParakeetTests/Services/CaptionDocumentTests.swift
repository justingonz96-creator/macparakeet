import XCTest
@testable import MacParakeetCore

final class CaptionDocumentTests: XCTestCase {
    private func document(_ cues: [(Int, Int, String)]) -> CaptionDocument {
        CaptionDocument(
            transcriptionID: UUID(),
            language: .en,
            cues: cues.map { CaptionDocumentCue(startMs: $0.0, endMs: $0.1, text: $0.2) }
        )
    }

    func testWritesSRTAndVTTThatTheCheckerReadsBack() {
        let doc = document([(1_001, 3_370, "Legs are moving because your\n4-minute warm-up starts right now."), (3_371, 6_006, "Grab those handlebars.")])
        XCTAssertTrue(doc.srt().hasPrefix("1\n00:00:01,001 --> 00:00:03,370\nLegs are moving because your\n4-minute warm-up starts right now.\n\n2\n"))
        XCTAssertTrue(doc.vtt().hasPrefix("WEBVTT\n\n00:00:01.001 --> 00:00:03.370\n"))
        XCTAssertEqual(CaptionQualityChecker.parse(doc.srt()), doc.fileCues)
        XCTAssertEqual(CaptionQualityChecker.parse(doc.vtt()), doc.fileCues)
    }

    func testNudgeMovesWholeFramesAndStopsAtNeighbours() {
        var doc = document([(0, 1_000, "One"), (1_001, 2_000, "Two")])
        let first = doc.cues[0].id
        doc.nudge(cue: first, edge: .end, frames: -3)
        XCTAssertEqual(doc.cues[0].endMs, 900)   // 3 frames at 29.97 fps ≈ 100 ms
        doc.nudge(cue: first, edge: .end, frames: 30)
        XCTAssertEqual(doc.cues[0].endMs, 1_000, "cannot run into the next caption")
        doc.nudge(cue: doc.cues[1].id, edge: .start, frames: -30)
        XCTAssertEqual(doc.cues[1].startMs, 1_001, "cannot start before the previous caption ends")
    }

    func testSplitAndMergeKeepTextAndTiming() {
        var doc = document([(0, 4_000, "Turn the fan on high in 20 seconds."), (4_001, 6_000, "Here we go.")])
        let newID = doc.split(cue: doc.cues[0].id)
        XCTAssertNotNil(newID)
        XCTAssertEqual(doc.cues.count, 3)
        XCTAssertEqual(doc.cues[0].startMs, 0)
        XCTAssertEqual(doc.cues[1].endMs, 4_000)
        XCTAssertEqual(doc.cues[0].endMs + 1, doc.cues[1].startMs)
        XCTAssertEqual((doc.cues[0].lines + doc.cues[1].lines).joined(separator: " "), "Turn the fan on high in 20 seconds.")

        doc.mergeWithNext(cue: doc.cues[0].id)
        XCTAssertEqual(doc.cues.count, 2)
        XCTAssertEqual(doc.cues[0].lines.joined(separator: " "), "Turn the fan on high in 20 seconds.")
        XCTAssertEqual(doc.cues[0].endMs, 4_000)
    }

    func testEditedTextIsWrappedToTheEchelonLayout() {
        var doc = document([(0, 4_000, "x")])
        doc.setText("Serby Ray, time to put in the work. Let's do it. We're in it together.", forCue: doc.cues[0].id)
        XCTAssertEqual(doc.cues[0].lines.count, 2)
        doc.setText("My own\nline break", forCue: doc.cues[0].id)
        XCTAssertEqual(doc.cues[0].lines, ["My own", "line break"])
    }

    func testStoreRoundTripsAndListsLanguages() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("captions-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CaptionDocumentStore(root: root)
        var doc = document([(0, 1_000, "Hello")])
        doc.language = .de
        doc.isDraft = true
        try store.save(doc)
        XCTAssertEqual(store.load(doc.transcriptionID, language: .de)?.cues, doc.cues)
        XCTAssertEqual(store.load(doc.transcriptionID, language: .de)?.isDraft, true)
        XCTAssertEqual(store.languages(for: doc.transcriptionID), [.de])
        XCTAssertNil(store.load(doc.transcriptionID, language: .en))
    }

    /// Real confidences from Marc Penna Fusion 30 (2026-10-31).
    func testUnsureWordsFlagMisheardNamesNotCommonWords() {
        let words = [
            WordTimestamp(word: "Back", startMs: 0, endMs: 100, confidence: 0.97),
            WordTimestamp(word: "in", startMs: 100, endMs: 200, confidence: 0.40),      // common word in loud music
            WordTimestamp(word: "the", startMs: 200, endMs: 300, confidence: 0.99),
            WordTimestamp(word: "saddle,", startMs: 300, endMs: 400, confidence: 0.98),
            WordTimestamp(word: "Ameliz.", startMs: 400, endMs: 500, confidence: 0.71),  // misheard rider name
            WordTimestamp(word: "I", startMs: 500, endMs: 600, confidence: 0.82),
            WordTimestamp(word: "pressque", startMs: 600, endMs: 700, confidence: 0.49), // not a word
            WordTimestamp(word: "Echelon", startMs: 700, endMs: 800, confidence: 0.70),  // protected name
        ]
        let unsure = UnsureWordDetector.unsureWords(in: words, protectedTerms: ["Echelon"]).map(\.word)
        XCTAssertEqual(unsure, ["Ameliz.", "pressque"])
    }
}
