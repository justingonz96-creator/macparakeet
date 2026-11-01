import Foundation

/// Removes reasoning text that some local models (Qwen 3.x, DeepSeek R1 and
/// others served by Ollama) leak into the visible reply, e.g.
/// `{"decisions": [...]} </think>` or `reasoning… </think>\n{...}`.
/// Complete `<think>…</think>` blocks are dropped; when a stray closing tag
/// remains, the last non-empty part after it is the answer.
enum LLMThinkingTagStripper {
    static func strip(_ reply: String) -> String {
        guard reply.range(of: "think>", options: .caseInsensitive) != nil else { return reply }
        var text = reply.replacingOccurrences(
            of: "<think>[\\s\\S]*?</think>",
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        let parts = text.components(separatedBy: "</think>")
        if parts.count > 1 {
            text = parts.last { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? ""
        }
        return text.replacingOccurrences(of: "<think>", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Cuts a reply that starts with a JSON object or array down to that first
    /// complete value. Local models sometimes repeat the answer or append a
    /// garbled tag after it (`{...} {...}`, `{...} </anth>`).
    static func firstJSONValue(_ reply: String) -> String {
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = text.first, first == "{" || first == "[" else { return text }
        var depth = 0
        var inString = false
        var escaped = false
        for index in text.indices {
            let character = text[index]
            if inString {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
                continue
            }
            switch character {
            case "\"": inString = true
            case "{", "[": depth += 1
            case "}", "]":
                depth -= 1
                if depth == 0 { return String(text[...index]) }
            default: break
            }
        }
        return text
    }
}
