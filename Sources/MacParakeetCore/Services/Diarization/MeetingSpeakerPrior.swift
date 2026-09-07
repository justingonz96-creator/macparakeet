import Foundation

/// Speaker-count prior for the meeting system track, derived from the
/// calendar attendee snapshot captured when the recording started.
///
/// The prior is always a range, never an exact count: attendees who stay
/// silent or never join are common, and an exact count forces K-Means
/// re-clustering to that number. See ADR-010 (2026-09-06 amendment) and
/// issue #972.
public enum MeetingSpeakerPrior: Equatable, Sendable {
    /// No usable attendee count; the clusterer picks the count itself.
    case unconstrained(reason: UnconstrainedReason)
    /// Exactly one remote attendee: skip clustering and label every system
    /// word as one remote speaker.
    case singleRemoteSpeaker
    /// Bounds handed to the clusterer.
    case bounds(min: Int, max: Int)

    public enum UnconstrainedReason: String, Equatable, Sendable {
        /// No calendar snapshot or an empty attendee list.
        case noAttendeeCount = "no_attendee_count"
        /// Attendee count above `maxAttendeesForBounds`; large invites are a
        /// poor proxy for who actually speaks, and the minimum bound would
        /// force re-clustering to a count the audio cannot support.
        case largeAttendeeCount = "large_attendee_count"
    }

    /// Largest remote attendee count that still yields bounds.
    public static let maxAttendeesForBounds = 8

    /// `remoteAttendeeCount` excludes the user. `nil` or zero means unknown.
    public static func derive(remoteAttendeeCount: Int?) -> MeetingSpeakerPrior {
        guard let count = remoteAttendeeCount, count > 0 else {
            return .unconstrained(reason: .noAttendeeCount)
        }
        if count == 1 {
            return .singleRemoteSpeaker
        }
        guard count <= maxAttendeesForBounds else {
            return .unconstrained(reason: .largeAttendeeCount)
        }
        return .bounds(min: max(1, count - 1), max: count + 1)
    }

    /// Attendees in the snapshot already exclude the current user (see
    /// `CalendarService.convertEvent`). Duplicates by email, then by name,
    /// collapse to one attendee; entries with neither still count.
    public static func derive(from snapshot: MeetingCalendarSnapshot?) -> MeetingSpeakerPrior {
        derive(remoteAttendeeCount: snapshot.map { remoteAttendeeCount(in: $0) })
    }

    static func remoteAttendeeCount(in snapshot: MeetingCalendarSnapshot) -> Int {
        var seenKeys = Set<String>()
        var count = 0
        for attendee in snapshot.attendees {
            let email = attendee.email?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() ?? ""
            let name = attendee.name?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() ?? ""
            let key: String
            if !email.isEmpty {
                key = "email:\(email)"
            } else if !name.isEmpty {
                key = "name:\(name)"
            } else {
                count += 1
                continue
            }
            if seenKeys.insert(key).inserted {
                count += 1
            }
        }
        return count
    }

    /// Constraint to pass to the diarizer, or `nil` when clustering runs
    /// unconstrained or is skipped entirely.
    public var speakerConstraint: SpeakerDiarizationConstraint? {
        switch self {
        case .bounds(let min, let max):
            return .range(min: min, max: max)
        case .unconstrained, .singleRemoteSpeaker:
            return nil
        }
    }

    /// Stable, PII-free label for diagnostics and telemetry.
    public var diagnosticsLabel: String {
        switch self {
        case .unconstrained(let reason):
            return "unconstrained_\(reason.rawValue)"
        case .singleRemoteSpeaker:
            return "single_remote"
        case .bounds(let min, let max):
            return "bounds_\(min)_\(max)"
        }
    }
}
