import XCTest
@testable import MacParakeetCore

final class MeetingMicHealthMonitorTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    func testMicMissingRequiresContinuousSystemConfirmation() {
        var monitor = MeetingMicHealthMonitor(config: .init(
            systemActiveConfirmationSeconds: 3.0,
            systemGapSeconds: 4.0
        ))

        XCTAssertEqual(
            monitor.ingest(systemSignal: .init(isNonSilent: true), now: start),
            []
        )
        XCTAssertEqual(
            monitor.ingest(systemSignal: .init(isNonSilent: true), now: start.addingTimeInterval(2.9)),
            []
        )

        XCTAssertEqual(
            monitor.ingest(systemSignal: .init(isNonSilent: true), now: start.addingTimeInterval(3.0)),
            [.stallSuspected(signature: .micMissing, elapsedMs: 3_000)]
        )
    }

    func testSystemSilenceResetsConfirmationWindow() {
        var monitor = MeetingMicHealthMonitor(config: .init(
            systemActiveConfirmationSeconds: 3.0,
            systemGapSeconds: 4.0
        ))

        XCTAssertEqual(monitor.ingest(systemSignal: .init(isNonSilent: true), now: start), [])
        XCTAssertEqual(
            monitor.ingest(systemSignal: .init(isNonSilent: false), now: start.addingTimeInterval(2.5)),
            []
        )
        XCTAssertEqual(
            monitor.ingest(systemSignal: .init(isNonSilent: true), now: start.addingTimeInterval(5.0)),
            []
        )
        XCTAssertEqual(
            monitor.ingest(systemSignal: .init(isNonSilent: true), now: start.addingTimeInterval(7.9)),
            []
        )
        XCTAssertEqual(
            monitor.ingest(systemSignal: .init(isNonSilent: true), now: start.addingTimeInterval(8.0)),
            [.stallSuspected(signature: .micMissing, elapsedMs: 3_000)]
        )
    }

    func testSystemAudioGapResetsConfirmationWindow() {
        var monitor = MeetingMicHealthMonitor(config: .init(
            systemActiveConfirmationSeconds: 3.0,
            systemGapSeconds: 2.0
        ))

        XCTAssertEqual(monitor.ingest(systemSignal: .init(isNonSilent: true), now: start), [])
        XCTAssertEqual(
            monitor.ingest(systemSignal: .init(isNonSilent: true), now: start.addingTimeInterval(2.5)),
            []
        )
        XCTAssertEqual(
            monitor.ingest(systemSignal: .init(isNonSilent: true), now: start.addingTimeInterval(3.5)),
            []
        )
        XCTAssertEqual(
            monitor.ingest(systemSignal: .init(isNonSilent: true), now: start.addingTimeInterval(4.5)),
            []
        )
        XCTAssertEqual(
            monitor.ingest(systemSignal: .init(isNonSilent: true), now: start.addingTimeInterval(5.5)),
            [.stallSuspected(signature: .micMissing, elapsedMs: 3_000)]
        )
    }

    func testSystemAudioGapPreventsSilentMicFalsePositive() {
        var monitor = MeetingMicHealthMonitor(config: .init(
            systemActiveConfirmationSeconds: 3.0,
            systemGapSeconds: 2.0
        ))

        XCTAssertEqual(monitor.ingest(systemSignal: .init(isNonSilent: true), now: start), [])
        XCTAssertEqual(
            monitor.ingest(micSignal: .init(isNonSilent: false), now: start.addingTimeInterval(2.5)),
            []
        )
    }

    func testMicSilentFiresWhileSilentMicBuffersContinueArriving() {
        var monitor = MeetingMicHealthMonitor(config: .init(systemActiveConfirmationSeconds: 3.0))

        for offset in [0.0, 1.0, 2.0] {
            XCTAssertEqual(
                monitor.ingest(
                    micSignal: .init(isNonSilent: false),
                    systemSignal: .init(isNonSilent: true),
                    now: start.addingTimeInterval(offset)
                ),
                []
            )
        }

        XCTAssertEqual(
            monitor.ingest(
                micSignal: .init(isNonSilent: false),
                systemSignal: .init(isNonSilent: true),
                now: start.addingTimeInterval(3.0)
            ),
            [.stallSuspected(signature: .micSilent, elapsedMs: 3_000)]
        )
    }

    func testMicSilentElapsedStartsAtSystemConfirmationWindow() {
        var monitor = MeetingMicHealthMonitor(config: .init(
            systemActiveConfirmationSeconds: 3.0,
            micGapSeconds: 10.0
        ))

        XCTAssertEqual(monitor.ingest(micSignal: .init(isNonSilent: false), now: start), [])

        for offset in [10.0, 11.0, 12.0] {
            XCTAssertEqual(
                monitor.ingest(
                    micSignal: .init(isNonSilent: false),
                    systemSignal: .init(isNonSilent: true),
                    now: start.addingTimeInterval(offset)
                ),
                []
            )
        }

        XCTAssertEqual(
            monitor.ingest(
                micSignal: .init(isNonSilent: false),
                systemSignal: .init(isNonSilent: true),
                now: start.addingTimeInterval(13.0)
            ),
            [.stallSuspected(signature: .micSilent, elapsedMs: 3_000)]
        )
    }

    func testMicGapElapsedStartsAtSystemConfirmationWindow() {
        var monitor = MeetingMicHealthMonitor(config: .init(
            systemActiveConfirmationSeconds: 3.0,
            micGapSeconds: 1.0
        ))

        XCTAssertEqual(monitor.ingest(micSignal: .init(isNonSilent: true), now: start), [])

        for offset in [10.0, 11.0, 12.0] {
            XCTAssertEqual(
                monitor.ingest(systemSignal: .init(isNonSilent: true), now: start.addingTimeInterval(offset)),
                []
            )
        }

        XCTAssertEqual(
            monitor.ingest(systemSignal: .init(isNonSilent: true), now: start.addingTimeInterval(13.0)),
            [.stallSuspected(signature: .micGap, elapsedMs: 3_000)]
        )
    }

    func testMicGapFiresAtBoundaryAfterLastMicBuffer() {
        var monitor = MeetingMicHealthMonitor(config: .init(
            systemActiveConfirmationSeconds: 0,
            micGapSeconds: 1.0
        ))

        XCTAssertEqual(
            monitor.ingest(
                micSignal: .init(isNonSilent: true),
                systemSignal: .init(isNonSilent: true),
                now: start
            ),
            []
        )
        XCTAssertEqual(
            monitor.ingest(systemSignal: .init(isNonSilent: true), now: start.addingTimeInterval(0.99)),
            []
        )
        XCTAssertEqual(
            monitor.ingest(systemSignal: .init(isNonSilent: true), now: start.addingTimeInterval(1.0)),
            [.stallSuspected(signature: .micGap, elapsedMs: 1_000)]
        )
    }

    func testEmitsOneStallUntilMicRecovers() {
        var monitor = MeetingMicHealthMonitor(config: .init(systemActiveConfirmationSeconds: 0))

        XCTAssertEqual(
            monitor.ingest(systemSignal: .init(isNonSilent: true), now: start),
            [.stallSuspected(signature: .micMissing, elapsedMs: 0)]
        )
        XCTAssertEqual(
            monitor.ingest(systemSignal: .init(isNonSilent: true), now: start.addingTimeInterval(10)),
            []
        )
        XCTAssertEqual(
            monitor.ingest(micSignal: .init(isNonSilent: true), now: start.addingTimeInterval(10.1)),
            [.recovered]
        )
        XCTAssertEqual(
            monitor.ingest(systemSignal: .init(isNonSilent: true), now: start.addingTimeInterval(11.2)),
            [.stallSuspected(signature: .micGap, elapsedMs: 1_100)]
        )
    }

    func testSilentSystemAudioDoesNotTripWatchdog() {
        var monitor = MeetingMicHealthMonitor(config: .init(systemActiveConfirmationSeconds: 0))

        XCTAssertEqual(
            monitor.ingest(
                micSignal: .init(isNonSilent: false),
                systemSignal: .init(isNonSilent: false),
                now: start
            ),
            []
        )
        XCTAssertEqual(
            monitor.ingest(micSignal: .init(isNonSilent: false), now: start.addingTimeInterval(5)),
            []
        )
    }
}
