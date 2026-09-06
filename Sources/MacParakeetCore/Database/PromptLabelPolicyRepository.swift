import Foundation
import GRDB

public protocol PromptLabelPolicyRepositoryProtocol: Sendable {
    func fetchPolicies(promptId: UUID) throws -> [PromptLabelPolicy]
    func fetchPolicies(promptIds: Set<UUID>) throws -> [PromptLabelPolicy]
    func replaceTargetLabels(promptId: UUID, labelIds: Set<UUID>) throws
}

public extension PromptLabelPolicyRepositoryProtocol {
    func fetchPolicies(promptIds: Set<UUID>) throws -> [PromptLabelPolicy] {
        try promptIds.flatMap { try fetchPolicies(promptId: $0) }
    }
}

public final class PromptLabelPolicyRepository: PromptLabelPolicyRepositoryProtocol, @unchecked Sendable {
    private let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    public func fetchPolicies(promptId: UUID) throws -> [PromptLabelPolicy] {
        try dbQueue.read { db in
            try PromptLabelPolicy
                .filter(PromptLabelPolicy.Columns.promptId == promptId)
                .order(PromptLabelPolicy.Columns.scopeKind.asc, PromptLabelPolicy.Columns.createdAt.asc)
                .fetchAll(db)
        }
    }

    public func fetchPolicies(promptIds: Set<UUID>) throws -> [PromptLabelPolicy] {
        guard !promptIds.isEmpty else { return [] }
        return try dbQueue.read { db in
            try PromptLabelPolicy
                .filter(promptIds.contains(PromptLabelPolicy.Columns.promptId))
                .order(
                    PromptLabelPolicy.Columns.promptId.asc,
                    PromptLabelPolicy.Columns.scopeKind.asc,
                    PromptLabelPolicy.Columns.createdAt.asc
                )
                .fetchAll(db)
        }
    }

    /// Replaces the simple Prompt Manager targeting model atomically. No rows
    /// means "all transcriptions". A non-empty selection writes an unavailable
    /// fallback plus one available rule per selected label.
    public func replaceTargetLabels(promptId: UUID, labelIds: Set<UUID>) throws {
        try dbQueue.write { db in
            _ = try PromptLabelPolicy
                .filter(PromptLabelPolicy.Columns.promptId == promptId)
                .deleteAll(db)

            guard !labelIds.isEmpty else { return }
            let now = Date()
            try PromptLabelPolicy(
                promptId: promptId,
                scopeKind: .all,
                isAvailable: false,
                createdAt: now,
                updatedAt: now
            ).insert(db)
            for labelId in labelIds.sorted(by: { $0.uuidString < $1.uuidString }) {
                try PromptLabelPolicy(
                    promptId: promptId,
                    scopeKind: .label,
                    labelId: labelId,
                    isAvailable: true,
                    createdAt: now,
                    updatedAt: now
                ).insert(db)
            }
        }
    }
}
