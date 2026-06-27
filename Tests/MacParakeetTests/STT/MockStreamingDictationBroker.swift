import Foundation
@testable import MacParakeetCore

/// Test double for `StreamingDictationBrokering` (ADR-023). Hands out sessions
/// backed by a test-scriptable `StreamingDictationEngineMock` (`engine`), and
/// records begin/end/prepare so flow tests can assert the lease lifecycle.
public actor MockStreamingDictationBroker: StreamingDictationBrokering {
    public let engine = StreamingDictationEngineMock()
    public var ready = true
    public var beginError: Error?
    public var prepareError: Error?

    public private(set) var prepareCount = 0
    public private(set) var beginCount = 0
    public private(set) var endCount = 0

    public init() {}

    public func setReady(_ value: Bool) { ready = value }
    public func setBeginError(_ error: Error?) { beginError = error }
    public func setPrepareError(_ error: Error?) { prepareError = error }

    public func prepareStreamingDictation(onProgress: (@Sendable (String) -> Void)?) async throws {
        prepareCount += 1
        onProgress?("Preparing live dictation…")
        if let prepareError { throw prepareError }
        ready = true
    }

    public func isStreamingDictationReady() async -> Bool { ready }

    public func beginStreamingDictation() async throws -> StreamingDictationSession {
        beginCount += 1
        if let beginError { throw beginError }
        guard ready else { throw STTError.modelNotLoaded }
        return StreamingDictationSession(engine: engine)
    }

    public func endStreamingDictation() async {
        endCount += 1
    }
}
