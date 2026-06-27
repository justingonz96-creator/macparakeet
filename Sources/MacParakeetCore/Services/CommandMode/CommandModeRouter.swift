import Foundation

public enum CommandModeAction: Sendable, Equatable {
    case deterministic(DeterministicCommand)
    case rewrite(prompt: String)
    case empty
}

/// Pure classifier: spoken instruction → deterministic offline command, provider
/// rewrite, or empty. Exact normalized-phrase matching keeps real rewrite requests
/// from being swallowed by the offline table.
public struct CommandModeRouter: Sendable {
    public init() {}

    private static let phraseTable: [String: DeterministicCommand] = [
        "scratch that": .clearSelection,
        "delete that": .clearSelection,
        "remove that": .clearSelection,
        "undo that": .clearSelection,
        "uppercase that": .uppercase,
        "make it uppercase": .uppercase,
        "all caps": .uppercase,
        "make it all caps": .uppercase,
        "lowercase that": .lowercase,
        "make it lowercase": .lowercase,
        "title case that": .titleCase,
        "title case": .titleCase,
        "capitalize that": .titleCase,
        "trim that": .trim,
        "trim whitespace": .trim,
        "trim it": .trim,
    ]

    public func route(instruction: String) -> CommandModeAction {
        let normalized = Self.normalize(instruction)
        if normalized.isEmpty { return .empty }
        if let command = Self.phraseTable[normalized] {
            return .deterministic(command)
        }
        return .rewrite(prompt: CommandModePrompts.rewriteInstruction(instruction))
    }

    /// Lowercase, trim, drop trailing punctuation, collapse internal whitespace.
    static func normalize(_ raw: String) -> String {
        let lowered = raw.lowercased()
        let collapsed = lowered.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let trailingPunctuation = CharacterSet(charactersIn: ".!?…,")
        var scalars = Array(collapsed.unicodeScalars)
        while let last = scalars.last, trailingPunctuation.contains(last) || CharacterSet.whitespaces.contains(last) {
            scalars.removeLast()
        }
        return String(String.UnicodeScalarView(scalars))
    }
}
