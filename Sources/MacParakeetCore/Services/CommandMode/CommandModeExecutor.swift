import Foundation
import OSLog

public enum CommandModeAppliedKind: Sendable, Equatable {
    case deterministic(DeterministicCommand)
    case rewrite
}

public enum CommandModeProgress: Sendable, Equatable {
    case routing
    case deterministicApplied(DeterministicCommand)
    case llmStarted
    case llmStreaming(String)
    case pasting
    case done(SelectionReplacementPath, CommandModeAppliedKind)
    case failed(String)
}

public struct CommandModeResult: Sendable {
    public let inputText: String
    public let outputText: String
    public let applied: CommandModeAppliedKind
    public let replacePath: SelectionReplacementPath
    public let totalElapsedMs: Int
    public let llmElapsedMs: Int
    public let captureTag: String
    public let target: SelectionCaptureTarget?
}

public enum CommandModeExecutorError: Error, LocalizedError, Sendable {
    case emptySelection
    case emptyInstruction
    case llmNotConfigured
    case llmFailed(String)
    case replacementFailed(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .emptySelection:
            return "Select text first — highlight what you want to change, then hold the key and speak."
        case .emptyInstruction:
            return "Didn't catch that — try again."
        case .llmNotConfigured:
            return "Command Mode rewrites need an LLM provider — configure one in Settings."
        case .llmFailed(let detail):
            return "Command Mode failed: \(detail)"
        case .replacementFailed(let detail):
            return "Command Mode couldn't apply the change: \(detail)"
        case .cancelled:
            return "Command Mode cancelled."
        }
    }
}

/// Routes a spoken instruction over a captured selection: deterministic offline edit,
/// deterministic deletion, or provider rewrite — then replaces in place. Mirrors
/// `TransformExecutor`'s restore-on-abandon and run-to-completion-on-replace safety.
public actor CommandModeExecutor {
    private let captureService: SelectionCaptureService
    private let replacementService: SelectionReplacementService
    private let llmServiceProvider: @Sendable () -> LLMServiceProtocol?
    private let router: CommandModeRouter
    private let logger = Logger(subsystem: "com.macparakeet.core", category: "CommandModeExecutor")

    public init(
        captureService: SelectionCaptureService = SelectionCaptureService(),
        replacementService: SelectionReplacementService = SelectionReplacementService(),
        llmServiceProvider: @escaping @Sendable () -> LLMServiceProtocol?,
        router: CommandModeRouter = CommandModeRouter()
    ) {
        self.captureService = captureService
        self.replacementService = replacementService
        self.llmServiceProvider = llmServiceProvider
        self.router = router
    }

    public func run(
        instruction: String,
        captured: SelectionCaptureResult,
        onProgress: @escaping @Sendable (CommandModeProgress) -> Void
    ) async throws -> CommandModeResult {
        let start = ContinuousClock.now

        guard let inputText = captured.capturedText, !inputText.isEmpty else {
            await captureService.restoreClipboardCaptureIfCurrent(captured)
            onProgress(.failed(CommandModeExecutorError.emptySelection.localizedDescription))
            throw CommandModeExecutorError.emptySelection
        }

        onProgress(.routing)
        let action = router.route(instruction: instruction)

        let outputText: String
        let appliedKind: CommandModeAppliedKind
        var llmElapsedMs = 0
        let path: SelectionReplacementPath

        switch action {
        case .empty:
            await captureService.restoreClipboardCaptureIfCurrent(captured)
            onProgress(.failed(CommandModeExecutorError.emptyInstruction.localizedDescription))
            throw CommandModeExecutorError.emptyInstruction

        case .deterministic(.clearSelection):
            appliedKind = .deterministic(.clearSelection)
            onProgress(.deterministicApplied(.clearSelection))
            onProgress(.pasting)
            do {
                path = try await replacementService.deleteSelection(in: captured)
            } catch {
                onProgress(.failed(error.localizedDescription))
                throw CommandModeExecutorError.replacementFailed(error.localizedDescription)
            }
            outputText = ""

        case .deterministic(let command):
            appliedKind = .deterministic(command)
            outputText = DeterministicTextEdit.apply(command, to: inputText)
            onProgress(.deterministicApplied(command))
            onProgress(.pasting)
            do {
                path = try await replacementService.replace(with: outputText, in: captured, mode: .pasteIntoCurrentFocus)
            } catch {
                onProgress(.failed(error.localizedDescription))
                throw CommandModeExecutorError.replacementFailed(error.localizedDescription)
            }

        case .rewrite(let prompt):
            guard let llm = llmServiceProvider() else {
                await captureService.restoreClipboardCaptureIfCurrent(captured)
                onProgress(.failed(CommandModeExecutorError.llmNotConfigured.localizedDescription))
                throw CommandModeExecutorError.llmNotConfigured
            }
            onProgress(.llmStarted)
            let llmStart = ContinuousClock.now
            var accumulated = ""
            do {
                for try await chunk in llm.transformStream(text: inputText, prompt: prompt) {
                    try Task.checkCancellation()
                    accumulated += chunk
                    onProgress(.llmStreaming(accumulated))
                }
            } catch is CancellationError {
                await captureService.restoreClipboardCaptureIfCurrent(captured)
                onProgress(.failed(CommandModeExecutorError.cancelled.localizedDescription))
                throw CommandModeExecutorError.cancelled
            } catch let error as LLMError {
                // LLMError is NOT Equatable — pattern-match, don't use `==` (mirrors TransformExecutor.swift:170).
                await captureService.restoreClipboardCaptureIfCurrent(captured)
                if case .notConfigured = error {
                    onProgress(.failed(CommandModeExecutorError.llmNotConfigured.localizedDescription))
                    throw CommandModeExecutorError.llmNotConfigured
                }
                onProgress(.failed(CommandModeExecutorError.llmFailed(error.localizedDescription).localizedDescription))
                throw CommandModeExecutorError.llmFailed(error.localizedDescription)
            } catch {
                await captureService.restoreClipboardCaptureIfCurrent(captured)
                onProgress(.failed(CommandModeExecutorError.llmFailed(error.localizedDescription).localizedDescription))
                throw CommandModeExecutorError.llmFailed(error.localizedDescription)
            }
            llmElapsedMs = Self.elapsedMs(from: llmStart)
            guard !accumulated.isEmpty else {
                await captureService.restoreClipboardCaptureIfCurrent(captured)
                onProgress(.failed(CommandModeExecutorError.llmFailed("Empty output.").localizedDescription))
                throw CommandModeExecutorError.llmFailed("Empty output.")
            }
            outputText = accumulated
            appliedKind = .rewrite
            onProgress(.pasting)
            do {
                path = try await replacementService.replace(with: outputText, in: captured, mode: .pasteIntoCurrentFocus)
            } catch {
                onProgress(.failed(error.localizedDescription))
                throw CommandModeExecutorError.replacementFailed(error.localizedDescription)
            }
        }

        onProgress(.done(path, appliedKind))
        return CommandModeResult(
            inputText: inputText,
            outputText: outputText,
            applied: appliedKind,
            replacePath: path,
            totalElapsedMs: Self.elapsedMs(from: start),
            llmElapsedMs: llmElapsedMs,
            captureTag: captured.pathTag,
            target: captured.target
        )
    }

    private static func elapsedMs(from start: ContinuousClock.Instant) -> Int {
        let elapsed = ContinuousClock.now - start
        let c = elapsed.components
        return Int(c.seconds) * 1000 + Int(c.attoseconds / 1_000_000_000_000_000)
    }
}
