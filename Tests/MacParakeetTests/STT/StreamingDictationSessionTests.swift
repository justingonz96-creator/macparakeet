import Foundation
import XCTest

@testable import MacParakeetCore

/// Thread-safe sink for partial-transcript callbacks (the callback is
/// `@Sendable` and fires synchronously from inside the engine actor).
private final class PartialBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ value: String) { lock.lock(); items.append(value); lock.unlock() }
    func all() -> [String] { lock.lock(); defer { lock.unlock() }; return items }
}

final class StreamingDictationSessionTests: XCTestCase {
    func testSessionForwardsSamplesEmitsPartialsAndReturnsFinalResult() async throws {
        let mock = StreamingDictationEngineMock()
        await mock.setScriptedPartials(["hello", "hello world"])
        await mock.setFinalResult(
            StreamingDictationResult(
                text: "hello world",
                words: [TimestampedWord(word: "hello", startMs: 0, endMs: 500, confidence: 0.9)]
            )
        )

        let session = StreamingDictationSession(engine: mock)
        let box = PartialBox()
        await session.start { box.add($0) }

        try await session.append(samples: [0.1, 0.2])
        try await session.append(samples: [0.3, 0.4])
        let result = try await session.finish()

        XCTAssertEqual(result.text, "hello world")
        XCTAssertEqual(result.words.count, 1)
        XCTAssertEqual(box.all(), ["hello", "hello world"])

        let appendCount = await mock.appendCount
        XCTAssertEqual(appendCount, 2)
        let finishCount = await mock.finishCount
        XCTAssertEqual(finishCount, 1)
    }

    func testAppendAfterFinishIsIgnored() async throws {
        let mock = StreamingDictationEngineMock()
        let session = StreamingDictationSession(engine: mock)

        _ = try await session.finish()
        try await session.append(samples: [0.1])

        let appendCount = await mock.appendCount
        XCTAssertEqual(appendCount, 0, "Buffers after finish() must not reach the engine")
    }

    func testCancelResetsEngineAndBlocksFurtherAppends() async throws {
        let mock = StreamingDictationEngineMock()
        let session = StreamingDictationSession(engine: mock)

        await session.cancel()
        try await session.append(samples: [0.1])

        let resetCount = await mock.resetCount
        XCTAssertEqual(resetCount, 1)
        let appendCount = await mock.appendCount
        XCTAssertEqual(appendCount, 0)
    }
}
