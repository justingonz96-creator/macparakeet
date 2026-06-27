import Foundation

/// Process-wide, main-actor arbiter ensuring only one microphone consumer is live at
/// a time (v1 mutual exclusion between dictation/meeting and Command Mode). Owned by
/// AppEnvironment; consulted by the dictation start path and CommandModeCoordinator.
@MainActor
public final class MicrophoneArbiter {
    public enum Owner: Sendable, Equatable {
        case dictation
        case meeting
        case commandMode
    }

    public private(set) var currentOwner: Owner?

    public init() {}

    /// Acquire the mic for `owner`. Returns false if a *different* owner holds it.
    @discardableResult
    public func tryAcquire(_ owner: Owner) -> Bool {
        if currentOwner == nil || currentOwner == owner {
            currentOwner = owner
            return true
        }
        return false
    }

    /// Release only if `owner` currently holds the mic.
    public func release(_ owner: Owner) {
        if currentOwner == owner { currentOwner = nil }
    }
}
