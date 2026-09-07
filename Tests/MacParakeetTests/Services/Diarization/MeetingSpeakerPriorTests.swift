import XCTest
@testable import MacParakeetCore

final class MeetingSpeakerPriorTests: XCTestCase {

    func testNoAttendeeCountIsUnconstrained() {
        XCTAssertEqual(
            MeetingSpeakerPrior.derive(remoteAttendeeCount: nil),
            .unconstrained(reason: .noAttendeeCount)
        )
        XCTAssertEqual(
            MeetingSpeakerPrior.derive(remoteAttendeeCount: 0),
            .unconstrained(reason: .noAttendeeCount)
        )
        XCTAssertEqual(
            MeetingSpeakerPrior.derive(from: nil),
            .unconstrained(reason: .noAttendeeCount)
        )
        XCTAssertNil(MeetingSpeakerPrior.derive(remoteAttendeeCount: nil).speakerConstraint)
        XCTAssertEqual(
            MeetingSpeakerPrior.derive(remoteAttendeeCount: nil).diagnosticsLabel,
            "unconstrained_no_attendee_count"
        )
    }

    func testSingleRemoteAttendeeSkipsClustering() {
        let prior = MeetingSpeakerPrior.derive(remoteAttendeeCount: 1)

        XCTAssertEqual(prior, .singleRemoteSpeaker)
        XCTAssertNil(prior.speakerConstraint)
        XCTAssertEqual(prior.diagnosticsLabel, "single_remote")
    }

    func testTwoAttendeesYieldBoundsWithFloorOfOne() {
        let prior = MeetingSpeakerPrior.derive(remoteAttendeeCount: 2)

        XCTAssertEqual(prior, .bounds(min: 1, max: 3))
        XCTAssertEqual(prior.speakerConstraint, .range(min: 1, max: 3))
        XCTAssertEqual(prior.diagnosticsLabel, "bounds_1_3")
    }

    func testFiveAttendeesYieldOneOfSlackEachSide() {
        let prior = MeetingSpeakerPrior.derive(remoteAttendeeCount: 5)

        XCTAssertEqual(prior, .bounds(min: 4, max: 6))
        XCTAssertEqual(prior.speakerConstraint, .range(min: 4, max: 6))
    }

    func testBoundsAreNeverAnExactCount() {
        for count in 2...MeetingSpeakerPrior.maxAttendeesForBounds {
            guard case .bounds(let min, let max) = MeetingSpeakerPrior.derive(remoteAttendeeCount: count) else {
                return XCTFail("expected bounds for \(count) attendees")
            }
            XCTAssertLessThan(min, max)
            XCTAssertEqual(min, count - 1)
            XCTAssertEqual(max, count + 1)
        }
    }

    func testLargeInvitesFallBackToUnconstrained() {
        let prior = MeetingSpeakerPrior.derive(
            remoteAttendeeCount: MeetingSpeakerPrior.maxAttendeesForBounds + 1
        )

        XCTAssertEqual(prior, .unconstrained(reason: .largeAttendeeCount))
        XCTAssertNil(prior.speakerConstraint)
        XCTAssertEqual(prior.diagnosticsLabel, "unconstrained_large_attendee_count")
    }

    func testSnapshotAttendeesAreDedupedByEmailThenName() {
        let snapshot = makeSnapshot(attendees: [
            MeetingCalendarPerson(name: "Ada", email: "ada@example.com"),
            MeetingCalendarPerson(name: "Ada Lovelace", email: "ADA@example.com "),
            MeetingCalendarPerson(name: "Grace", email: nil),
            MeetingCalendarPerson(name: " grace ", email: nil),
            MeetingCalendarPerson(name: nil, email: nil),
        ])

        XCTAssertEqual(MeetingSpeakerPrior.remoteAttendeeCount(in: snapshot), 3)
        XCTAssertEqual(MeetingSpeakerPrior.derive(from: snapshot), .bounds(min: 2, max: 4))
    }

    func testSnapshotWithoutAttendeesIsUnconstrained() {
        let snapshot = makeSnapshot(attendees: [])

        XCTAssertEqual(
            MeetingSpeakerPrior.derive(from: snapshot),
            .unconstrained(reason: .noAttendeeCount)
        )
    }

    func testSnapshotWithOneAttendeeIsSingleRemoteSpeaker() {
        let snapshot = makeSnapshot(attendees: [
            MeetingCalendarPerson(name: "Ada", email: "ada@example.com"),
        ])

        XCTAssertEqual(MeetingSpeakerPrior.derive(from: snapshot), .singleRemoteSpeaker)
    }

    private func makeSnapshot(attendees: [MeetingCalendarPerson]) -> MeetingCalendarSnapshot {
        MeetingCalendarSnapshot(
            confidence: .confirmed,
            eventIdentifier: "event",
            title: "Sync",
            scheduledStartAt: Date(timeIntervalSince1970: 1_700_000_000),
            scheduledEndAt: Date(timeIntervalSince1970: 1_700_003_600),
            attendees: attendees
        )
    }
}
