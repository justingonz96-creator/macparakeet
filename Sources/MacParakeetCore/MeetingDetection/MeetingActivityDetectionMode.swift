import Foundation

public enum MeetingActivityDetectionMode: String, Codable, Sendable, Equatable, CaseIterable {
    case off
    case prompt
    case autoStart
}
