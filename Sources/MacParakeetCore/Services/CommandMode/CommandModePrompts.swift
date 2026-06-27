import Foundation

/// Builds the LLM directive for a spoken Command Mode instruction. The selected
/// text is passed separately as `transformStream(text:)`; this is only the prompt.
public enum CommandModePrompts {
    public static func rewriteInstruction(_ instruction: String) -> String {
        """
        Apply this instruction to the text: "\(instruction)". \
        Return only the edited text — no preamble, no explanation, no quotes. \
        Preserve the original meaning and language unless the instruction says otherwise.
        """
    }
}
