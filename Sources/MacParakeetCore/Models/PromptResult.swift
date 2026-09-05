import Foundation
import GRDB

public struct PromptResult: Codable, Identifiable, Sendable {
    public var id: UUID
    public var transcriptionId: UUID
    public var promptName: String
    public var promptContent: String
    public var extraInstructions: String?
    public var content: String
    /// Exact effective notes supplied to the LLM for this result, after blank
    /// normalization and the prompt-context word cap. Nil means no notes were
    /// sent. Editing canonical meeting notes never changes this receipt.
    public var userNotesSnapshot: String?
    /// Snapshot of the per-prompt automatic meeting-notes preference used for
    /// this generation. This remains meaningful when no notes existed, so a
    /// later regeneration can apply the same preference to newly added notes.
    public var includeMeetingNotesSnapshot: Bool
    /// Effective generation settings actually sent to the provider for this
    /// result. Nil means the historical provider-default behavior.
    public var inferenceSettingsSnapshot: PromptInferenceSettings?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        transcriptionId: UUID,
        promptName: String,
        promptContent: String,
        extraInstructions: String? = nil,
        content: String,
        userNotesSnapshot: String? = nil,
        includeMeetingNotesSnapshot: Bool = false,
        inferenceSettingsSnapshot: PromptInferenceSettings? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.transcriptionId = transcriptionId
        self.promptName = promptName
        self.promptContent = promptContent
        self.extraInstructions = extraInstructions
        self.content = content
        self.userNotesSnapshot = userNotesSnapshot
        self.includeMeetingNotesSnapshot = includeMeetingNotesSnapshot
        self.inferenceSettingsSnapshot = inferenceSettingsSnapshot?.normalized
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

extension PromptResult: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "summaries"

    public enum Columns: String, ColumnExpression {
        case id, transcriptionId, promptName, promptContent, extraInstructions, content
        case userNotesSnapshot, includeMeetingNotesSnapshot, inferenceSettingsSnapshot, createdAt, updatedAt
    }
}
