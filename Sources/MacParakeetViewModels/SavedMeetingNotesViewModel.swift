import Foundation
import SwiftUI

/// Always-editable notes state for a saved meeting.
///
/// Edits are persisted after a short idle window. `flush()` lets navigation and
/// LLM actions wait for the latest draft so downstream consumers never observe
/// stale notes.
@MainActor
@Observable
public final class SavedMeetingNotesViewModel {
    public enum SaveState: Equatable, Sendable {
        case saved
        case saving
        case failed
    }

    public static let debounceInterval: Duration = .milliseconds(500)

    public private(set) var text = ""
    public private(set) var wordCount = 0
    public private(set) var saveState: SaveState = .saved

    public var textBinding: Binding<String> {
        Binding(
            get: { [weak self] in self?.text ?? "" },
            set: { [weak self] newValue in self?.applyEdit(newValue) }
        )
    }

    private var persist: ((String) async -> Bool)?
    private var debounceTask: Task<Void, Never>?
    private var inFlightTask: Task<Bool, Never>?
    private var inFlightToken: UUID?
    private var inFlightRevision: Int?
    private var configurationToken = UUID()
    private var revision = 0
    private var savedRevision = 0

    public init() {}

    public func configure(
        text: String?,
        persist: @escaping (String) async -> Bool
    ) {
        debounceTask?.cancel()
        debounceTask = nil
        inFlightTask?.cancel()
        inFlightTask = nil
        inFlightToken = nil
        inFlightRevision = nil
        configurationToken = UUID()
        self.persist = persist
        self.text = text ?? ""
        wordCount = Self.wordCount(for: self.text)
        revision = 0
        savedRevision = 0
        saveState = .saved
    }

    /// Cancels the idle timer and waits until the latest draft is persisted.
    /// Returns `false` when persistence fails so callers can keep the user on
    /// the current screen instead of invoking an LLM with stale context.
    @discardableResult
    public func flush() async -> Bool {
        debounceTask?.cancel()
        debounceTask = nil
        while revision != savedRevision {
            guard await persistCurrentRevision() else { return false }
        }
        return true
    }

    @discardableResult
    public func retry() async -> Bool {
        await flush()
    }

    public func cancelPendingSave() {
        debounceTask?.cancel()
        debounceTask = nil
    }

    private func applyEdit(_ newValue: String) {
        text = newValue
        wordCount = Self.wordCount(for: newValue)
        revision += 1
        saveState = .saving
        scheduleDebounce()
    }

    private func scheduleDebounce() {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.debounceInterval)
            guard !Task.isCancelled, let self else { return }
            _ = await self.persistCurrentRevision()
        }
    }

    private func persistCurrentRevision() async -> Bool {
        if let inFlightTask {
            let awaitedRevision = inFlightRevision
            let saved = await inFlightTask.value
            if awaitedRevision != revision {
                return await persistCurrentRevision()
            }
            return saved
        }
        guard let persist else {
            saveState = .failed
            return false
        }
        let savingRevision = revision
        let savingText = text
        let token = UUID()
        let activeConfigurationToken = configurationToken
        saveState = .saving
        let task = Task { @MainActor [weak self] in
            let saved = await persist(savingText)
            guard let self, self.configurationToken == activeConfigurationToken else { return saved }
            if saved {
                self.savedRevision = max(self.savedRevision, savingRevision)
                if self.revision == savingRevision {
                    self.saveState = .saved
                }
            } else if self.revision == savingRevision {
                self.saveState = .failed
            }
            if self.inFlightToken == token {
                self.inFlightTask = nil
                self.inFlightToken = nil
                self.inFlightRevision = nil
            }
            return saved
        }
        inFlightToken = token
        inFlightRevision = savingRevision
        inFlightTask = task
        return await task.value
    }

    private static func wordCount(for text: String) -> Int {
        var count = 0
        var inWord = false
        for character in text {
            if character.isWhitespace {
                inWord = false
            } else if !inWord {
                inWord = true
                count += 1
            }
        }
        return count
    }
}
