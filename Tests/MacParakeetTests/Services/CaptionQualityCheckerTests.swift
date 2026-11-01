import XCTest
@testable import MacParakeetCore

final class CaptionQualityCheckerTests: XCTestCase {
    private func srt(_ cues: [(String, String, String)]) -> String {
        cues.enumerated().map { "\($0.offset + 1)\n\($0.element.0) --> \($0.element.1)\n\($0.element.2)" }
            .joined(separator: "\n\n")
    }

    func testParsesSRTAndWebVTT() {
        let cues = CaptionQualityChecker.parse(srt([("00:00:01,000", "00:00:03,500", "Hello there.\nSecond line.")]))
        XCTAssertEqual(cues, [CaptionFileCue(index: 1, startMs: 1_000, endMs: 3_500, lines: ["Hello there.", "Second line."])])

        let vtt = "WEBVTT\n\n00:01.000 --> 00:02.250 align:center\nShort hours form\n\n01:00:00.000 --> 01:00:01.000\nLong form"
        let parsed = CaptionQualityChecker.parse(vtt)
        XCTAssertEqual(parsed.map(\.startMs), [1_000, 3_600_000])
        XCTAssertEqual(parsed.first?.endMs, 2_250)
    }

    func testCleanEchelonCaptionsPass() {
        let report = CaptionQualityChecker.check(text: srt([
            ("00:00:01,001", "00:00:05,005", "Legs are moving because your\n4-minute warm-up starts right now."),
            ("00:00:05,005", "00:00:07,007", "Grab those handlebars."),
        ]))
        XCTAssertTrue(report.passed)
        XCTAssertEqual(report.issues, [])
    }

    func testEchelonRuleBreaksAreErrors() {
        let long = String(repeating: "a", count: 66)
        let report = CaptionQualityChecker.check(text: srt([
            ("00:00:01,001", "00:00:03,003", "\(long)"),
            ("00:00:02,002", "00:00:04,004", "one\ntwo\nthree"),
            ("00:00:05,005", "00:00:05,005", "zero length"),
        ]))
        XCTAssertFalse(report.passed)
        XCTAssertEqual(Set(report.issues.filter { $0.severity == .error }.map(\.kind)),
                       [.lineTooLong, .overlap, .tooManyLines, .badTiming])
    }

    func testReviewFlags() {
        let report = CaptionQualityChecker.check(text: srt([
            ("00:00:01,001", "00:00:01,401", "Quick"),
            ("00:00:02,002", "00:00:03,003", "This sentence is far too long to read in one second."),
            ("00:00:04,004", "00:00:06,006", "Getting stronger bitch I'm on the spot"),
            // 7017 ms is ~10 ms from the nearest 29.97 fps frame (> a quarter frame).
            ("00:00:07,017", "00:00:09,009", "Off the frame grid"),
        ]))
        XCTAssertTrue(report.passed, "review items alone do not fail a file")
        XCTAssertEqual(report.issues.map(\.kind), [.flashCue, .veryFast, .profanity, .offFrame])
    }

    func testRealCoachingRepeatsAreNotLoopsButLongRunsAre() {
        let coaching = "Come down slow, slow, slow, slow, slow, slow, slow. Beautiful."
        let loop = Array(repeating: "the top,", count: 12).joined(separator: " ")
        let report = CaptionQualityChecker.check(text: srt([
            ("00:00:01,001", "00:00:04,004", coaching),
            ("00:00:05,005", "00:00:09,009", loop),
        ]))
        let loops = report.issues.filter { $0.kind == .repeatLoop }
        XCTAssertEqual(loops.map(\.cue), [2])
        XCTAssertTrue(loops[0].message.contains("\"the top\" repeats 12 times"))
    }
}
