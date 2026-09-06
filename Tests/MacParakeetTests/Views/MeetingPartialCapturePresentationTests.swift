import XCTest
import MacParakeetCore
@testable import MacParakeet

final class MeetingPartialCapturePresentationTests: XCTestCase {
    func testPartialMeetingExplainsCapturedAndElapsedDuration() throws {
        let report = MeetingCaptureReport(
            sourceMode: .microphoneAndSystem,
            sourceAlignment: MeetingSourceAlignment(
                meetingOriginHostTime: 100,
                microphone: track(durationMs: 68_000),
                system: track(durationMs: 68_000)
            ),
            elapsedDurationMs: 2_355_000
        )
        let transcription = Transcription(
            fileName: "Design Review",
            durationMs: report.capturedDurationMs,
            status: .completed,
            sourceType: .meeting,
            meetingCaptureReport: report
        )

        let presentation = try XCTUnwrap(MeetingPartialCapturePresentation.make(for: transcription))

        XCTAssertTrue(presentation.message.contains("1:08"))
        XCTAssertTrue(presentation.message.contains("39:15"))
    }

    func testPartialMeetingDoesNotDescribeTimelinePaddingAsCapturedAudio() throws {
        let report = MeetingCaptureReport(
            sourceMode: .microphoneOnly,
            sourceAlignment: MeetingSourceAlignment(
                meetingOriginHostTime: 100,
                microphone: track(durationMs: 70_000, timelineDurationMs: 100_000),
                system: nil
            ),
            elapsedDurationMs: 100_000
        )
        let transcription = Transcription(
            fileName: "Recovered Review",
            durationMs: report.capturedDurationMs,
            status: .completed,
            sourceType: .meeting,
            meetingCaptureReport: report
        )

        let presentation = try XCTUnwrap(MeetingPartialCapturePresentation.make(for: transcription))

        XCTAssertTrue(presentation.message.contains("1:10"))
        XCTAssertFalse(presentation.message.contains("captured 1:40"))
    }

    func testSilentSystemAudioExplainsThatMicrophoneAudioRemainsSaved() throws {
        let report = MeetingCaptureReport(
            sourceMode: .microphoneAndSystem,
            sourceAlignment: MeetingSourceAlignment(
                meetingOriginHostTime: 100,
                microphone: track(durationMs: 30_000),
                system: track(durationMs: 30_000)
            ),
            elapsedDurationMs: 30_000,
            silentSources: [.system]
        )
        let transcription = Transcription(
            fileName: "Silent System Review",
            durationMs: report.capturedDurationMs,
            status: .completed,
            sourceType: .meeting,
            meetingCaptureReport: report
        )

        let presentation = try XCTUnwrap(
            MeetingPartialCapturePresentation.make(for: transcription)
        )

        XCTAssertTrue(presentation.message.contains("no audible signal"))
        XCTAssertTrue(presentation.message.contains("Microphone audio remains saved"))
    }

    func testRecoveredSilentSystemDoesNotPromiseUnavailableMicrophoneAudio() throws {
        let report = MeetingCaptureReport(
            sourceMode: .microphoneAndSystem,
            sourceAlignment: MeetingSourceAlignment(
                meetingOriginHostTime: 100,
                microphone: nil,
                system: track(durationMs: 30_000)
            ),
            elapsedDurationMs: 30_000,
            silentSources: [.system]
        )
        let transcription = Transcription(
            fileName: "Recovered Silent System",
            durationMs: report.capturedDurationMs,
            status: .completed,
            sourceType: .meeting,
            meetingCaptureReport: report
        )

        let presentation = try XCTUnwrap(MeetingPartialCapturePresentation.make(for: transcription))

        XCTAssertTrue(presentation.message.contains("No microphone audio"))
        XCTAssertTrue(presentation.message.contains("no audible signal"))
        XCTAssertFalse(presentation.message.contains("remains saved"))
    }

    func testSilentSystemDoesNotPromiseMicrophoneTrackWithNoWrittenAudio() throws {
        let report = MeetingCaptureReport(
            sourceMode: .microphoneAndSystem,
            sourceAlignment: MeetingSourceAlignment(
                meetingOriginHostTime: 100,
                microphone: track(durationMs: 0, timelineDurationMs: 30_000),
                system: track(durationMs: 30_000)
            ),
            elapsedDurationMs: 30_000,
            silentSources: [.system]
        )
        let transcription = Transcription(
            fileName: "Empty Microphone Track",
            durationMs: report.capturedDurationMs,
            status: .completed,
            sourceType: .meeting,
            meetingCaptureReport: report
        )

        let presentation = try XCTUnwrap(MeetingPartialCapturePresentation.make(for: transcription))

        XCTAssertTrue(presentation.message.contains("no audible signal"))
        XCTAssertFalse(presentation.message.contains("remains saved"))
    }

    func testPlaybackFallbackExplainsWhyCompleteSourcesProducedPartialPlayback() throws {
        let report = MeetingCaptureReport(
            sourceMode: .microphoneAndSystem,
            sourceAlignment: MeetingSourceAlignment(
                meetingOriginHostTime: 100,
                microphone: track(durationMs: 10_000),
                system: track(durationMs: 10_000)
            ),
            elapsedDurationMs: 10_000,
            playbackFallbackSource: .system
        )
        let transcription = Transcription(
            fileName: "Fallback Review",
            durationMs: report.capturedDurationMs,
            status: .completed,
            sourceType: .meeting,
            meetingCaptureReport: report
        )

        let presentation = try XCTUnwrap(MeetingPartialCapturePresentation.make(for: transcription))

        XCTAssertTrue(presentation.message.contains("only system audio"))
        XCTAssertTrue(presentation.message.contains("combined recording"))
    }

    func testHealthyAndLegacyMeetingsDoNotShowPartialPresentation() {
        let healthyReport = MeetingCaptureReport(
            sourceMode: .microphoneOnly,
            sourceAlignment: MeetingSourceAlignment(
                meetingOriginHostTime: 100,
                microphone: track(durationMs: 10_000),
                system: nil
            ),
            elapsedDurationMs: 10_000
        )

        XCTAssertNil(
            MeetingPartialCapturePresentation.make(
                for: Transcription(
                    fileName: "Healthy",
                    sourceType: .meeting,
                    meetingCaptureReport: healthyReport
                )))
        XCTAssertNil(
            MeetingPartialCapturePresentation.make(
                for: Transcription(
                    fileName: "Legacy",
                    sourceType: .meeting
                )))
    }

    private func track(
        durationMs: Int,
        timelineDurationMs: Int? = nil
    ) -> MeetingSourceAlignment.Track {
        MeetingSourceAlignment.Track(
            firstHostTime: 100,
            lastHostTime: 200,
            startOffsetMs: 0,
            writtenFrameCount: Int64(durationMs * 48),
            timelineFrameCount: timelineDurationMs.map { Int64($0 * 48) },
            sampleRate: 48_000
        )
    }
}
