import Foundation
@testable import MacParakeetCore

/// Scriptable test double for `StreamingDictationEngine` (ADR-023). Lets flow
/// tests drive partial emission, the final result, readiness, and failure
/// without touching the real CoreML streaming model.
public actor StreamingDictationEngineMock: StreamingDictationEngine {
    // Scripting
    public var ready: Bool = true
    public var scriptedPartials: [String] = []
    public var finalResult: StreamingDictationResult = StreamingDictationResult(text: "")
    public var prepareError: Error?
    public var finishError: Error?

    // Observability
    public private(set) var prepareCount = 0
    public private(set) var appendCount = 0
    public private(set) var appendedSampleCounts: [Int] = []
    public private(set) var processCount = 0
    public private(set) var finishCount = 0
    public private(set) var resetCount = 0
    public private(set) var cleanupCount = 0

    private var callback: (@Sendable (String) -> Void)?
    private var emitIndex = 0

    public init() {}

    public func setReady(_ value: Bool) { ready = value }
    public func setScriptedPartials(_ partials: [String]) { scriptedPartials = partials }
    public func setFinalResult(_ result: StreamingDictationResult) { finalResult = result }
    public func setPrepareError(_ error: Error?) { prepareError = error }
    public func setFinishError(_ error: Error?) { finishError = error }

    public func prepare(onProgress: (@Sendable (String) -> Void)?) async throws {
        prepareCount += 1
        onProgress?("Preparing live dictation…")
        if let prepareError { throw prepareError }
        ready = true
    }

    public func isReady() async -> Bool { ready }

    public func setPartialTranscriptCallback(_ callback: @escaping @Sendable (String) -> Void) async {
        self.callback = callback
    }

    public func appendAudio(samples: [Float]) async throws {
        appendCount += 1
        appendedSampleCounts.append(samples.count)
    }

    public func processBufferedAudio() async throws {
        processCount += 1
        guard emitIndex < scriptedPartials.count else { return }
        callback?(scriptedPartials[emitIndex])
        emitIndex += 1
    }

    public func finish() async throws -> StreamingDictationResult {
        finishCount += 1
        if let finishError { throw finishError }
        return finalResult
    }

    public func reset() async throws {
        resetCount += 1
        emitIndex = 0
    }

    public func cleanup() async {
        cleanupCount += 1
    }
}
