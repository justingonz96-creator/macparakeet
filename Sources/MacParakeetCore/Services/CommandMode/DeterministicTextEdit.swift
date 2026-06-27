import Foundation

/// Offline, deterministic edits applied to a captured selection in Command Mode.
/// No LLM, no I/O — pure string transforms. `clearSelection` is a deletion handled
/// by `CommandModeExecutor` (it must not be pasted as an empty string).
public enum DeterministicCommand: String, Sendable, Equatable, CaseIterable {
    case clearSelection
    case uppercase
    case lowercase
    case titleCase
    case trim
}

/// Namespace for deterministic text transforms. Not instantiable.
public enum DeterministicTextEdit {
    /// Pure transform of the selection for the case/trim commands. Returns "" for
    /// `clearSelection` (the executor routes that to a deletion path instead of a paste).
    public static func apply(_ command: DeterministicCommand, to text: String) -> String {
        switch command {
        case .clearSelection:
            return ""
        case .uppercase:
            return text.uppercased()
        case .lowercase:
            return text.lowercased()
        case .titleCase:
            // Swift's .capitalized treats every ICU word boundary (apostrophe, hyphen,
            // digit) as a boundary, so proper nouns like "iOS"/"YouTube" down-case to
            // "Ios"/"Youtube". Acceptable at this scope; a smarter titlecaser can be
            // substituted here without changing the public API.
            return text.capitalized
        case .trim:
            return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
    }
}
