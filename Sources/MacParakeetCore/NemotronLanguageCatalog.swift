import Foundation

/// The closed set of languages Echo's Nemotron engine offers — exactly the
/// Latin-script-pruned build FluidAudio ships (en/es/fr/it/pt/de). Deliberately
/// NOT `WhisperLanguageCatalog`, which accepts ~99 languages: pinning a language
/// the pruned model cannot produce (e.g. Korean) must be rejected, not accepted.
///
/// "auto"/nil is intentionally NOT a member here — the engine always downloads
/// the `latin/` subtree (see `NemotronEngine`), and a nil hint means
/// auto-detect *within* the Latin set at inference time. See ADR-023 §4.
public enum NemotronLanguageCatalog {
    private static let labelsByCode: [String: String] = [
        "en": "English",
        "es": "Spanish",
        "fr": "French",
        "it": "Italian",
        "pt": "Portuguese",
        "de": "German",
    ]

    /// The six canonical codes, in a fixed display order (stable for UI).
    public static let supportedCodes: [String] = ["en", "es", "fr", "it", "pt", "de"]

    /// Normalize a possibly region-styled code (`es-ES`, `EN_us`) to its canonical
    /// two-letter form, or `nil` if it is not one of the six European languages
    /// (including `nil`, empty, and "auto").
    public static func canonicalCode(for language: String?) -> String? {
        guard let language else { return nil }
        let trimmed = language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }
        // Take the primary subtag before any region separator.
        let primary = trimmed.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? trimmed
        return labelsByCode[primary] != nil ? primary : nil
    }

    /// Human-readable language name, or `nil` for an unsupported code.
    public static func displayLabel(forCode code: String) -> String? {
        labelsByCode[canonicalCode(for: code) ?? ""]
    }
}
