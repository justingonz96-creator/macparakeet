import Foundation
import os

/// Languages the caption translator writes, with the voice an Echelon
/// instructor would use in each.
public enum SubtitleLanguage: String, CaseIterable, Sendable {
    case de
    case es

    public var englishName: String {
        switch self {
        case .de: "German"
        case .es: "Spanish"
        }
    }

    var styleRules: String {
        switch self {
        case .de:
            "Address the rider informally with \"du\" (never \"Sie\"). Sound like a German fitness instructor coaching live: short, energetic, natural spoken German."
        case .es:
            "Address the rider informally with \"tú\" (never \"usted\"). Use neutral Latin American Spanish and sound like a fitness instructor coaching live: short, energetic, natural spoken Spanish."
        }
    }
}

/// Translates finished English caption cues into another language with a
/// local or remote LLM, keeping every cue's timing.
///
/// Cues go to the model in numbered windows with the preceding lines (and
/// their translations) as context, so terminology and tone stay consistent.
/// The model may move words between neighbouring lines so the target
/// language reads naturally, but must return exactly the same line ids.
/// A window that comes back malformed, missing lines or dropping a protected
/// term is asked again, then split in half; lines still failing stay in
/// English and are reported. Lines over the cue budget get one "shorten"
/// pass.
public struct SubtitleTranslator: Sendable {
    public typealias ProgressHandler = @Sendable (_ completed: Int, _ total: Int) -> Void

    public struct Result: Sendable {
        public let cues: [CaptionFileCue]
        /// Cue numbers left in English because translation kept failing.
        public let untranslatedCues: [Int]
        /// Protected terms that appear in an English cue but not in its translation.
        public let missingTerms: [(cue: Int, term: String)]
    }

    let llmService: LLMServiceProtocol
    let protectedTerms: [String]
    let windowSize: Int
    let contextLines: Int

    private static let log = Logger(subsystem: "com.macparakeet.core", category: "SubtitleTranslator")

    public init(
        llmService: LLMServiceProtocol,
        protectedTerms: [String],
        windowSize: Int = 20,
        contextLines: Int = 6
    ) {
        self.llmService = llmService
        // Longest first so "Echelon Reflect" is listed before "Echelon".
        self.protectedTerms = Array(Set(protectedTerms.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }))
            .sorted { $0.count > $1.count }
        self.windowSize = max(1, windowSize)
        self.contextLines = max(0, contextLines)
    }

    public func translate(
        cues: [CaptionFileCue],
        to language: SubtitleLanguage,
        config: SubtitleExportConfig = .echelon,
        onProgress: ProgressHandler? = nil
    ) async -> Result {
        var translated: [Int: String] = [:]   // cue position → text
        var untranslated: [Int] = []
        let windows = stride(from: 0, to: cues.count, by: windowSize).map { $0..<min($0 + windowSize, cues.count) }

        for (done, window) in windows.enumerated() {
            // English stays for any line whose every attempt fails.
            let lines = await translateRange(window, cues: cues, translated: translated, language: language, config: config)
            for position in window {
                // `lines` maps to `String?`: a nil value means every attempt failed.
                if let text = lines[position] ?? nil {
                    translated[position] = text
                } else {
                    untranslated.append(cues[position].index)
                }
            }
            onProgress?(done + 1, windows.count)
        }

        let tooLong = translated.filter { $0.value.count > config.maxCharsPerLine }.keys.sorted()
        if !tooLong.isEmpty {
            let shortened = await shorten(tooLong, cues: cues, translated: translated, language: language, config: config)
            for (position, text) in shortened { translated[position] = text }
        }

        var output: [CaptionFileCue] = []
        var missing: [(cue: Int, term: String)] = []
        for (position, cue) in cues.enumerated() {
            let text = translated[position] ?? cue.text
            if translated[position] != nil {
                for term in missingProtectedTerms(english: cue.text, translation: text) {
                    missing.append((cue.index, term))
                }
            }
            let wrapped = ExportService.wrapSubtitleTextStatic(text, config: config)
            output.append(CaptionFileCue(
                index: cue.index, startMs: cue.startMs, endMs: cue.endMs,
                lines: wrapped.components(separatedBy: "\n")
            ))
        }
        return Result(cues: output, untranslatedCues: untranslated, missingTerms: missing)
    }

    // MARK: - Windows

    /// Translates the cues in `range`; nil for lines that could not be translated.
    private func translateRange(
        _ range: Range<Int>,
        cues: [CaptionFileCue],
        translated: [Int: String],
        language: SubtitleLanguage,
        config: SubtitleExportConfig
    ) async -> [Int: String?] {
        for attempt in 1...2 {
            if let lines = await requestWindow(range, cues: cues, translated: translated, language: language, config: config) {
                return lines.mapValues { Optional($0) }
            }
            Self.log.warning("subtitle_translate_window_retry range=\(range.lowerBound)-\(range.upperBound) attempt=\(attempt)")
        }
        guard range.count > 1 else { return [range.lowerBound: nil] }
        let middle = range.lowerBound + range.count / 2
        var result = await translateRange(range.lowerBound..<middle, cues: cues, translated: translated, language: language, config: config)
        var withFirstHalf = translated
        for (position, text) in result { if let text { withFirstHalf[position] = text } }
        let second = await translateRange(middle..<range.upperBound, cues: cues, translated: withFirstHalf, language: language, config: config)
        result.merge(second) { first, _ in first }
        return result
    }

    private func requestWindow(
        _ range: Range<Int>,
        cues: [CaptionFileCue],
        translated: [Int: String],
        language: SubtitleLanguage,
        config: SubtitleExportConfig
    ) async -> [Int: String]? {
        var text = ""
        let contextStart = max(0, range.lowerBound - contextLines)
        if contextStart < range.lowerBound {
            text += "Already translated (context only, do not output):\n"
            for position in contextStart..<range.lowerBound {
                text += "- \(cues[position].text) => \(translated[position] ?? cues[position].text)\n"
            }
            text += "\n"
        }
        text += "Translate these lines:\n"
        for position in range {
            text += "\(position + 1): \(cues[position].text)\n"
        }
        if range.upperBound < cues.count {
            text += "\nThe class continues (context only, do not output): \(cues[range.upperBound].text)\n"
        }

        let response: String
        do {
            response = try await llmService.transform(text: text, prompt: systemPrompt(language: language, config: config))
        } catch {
            Self.log.warning("subtitle_translate_llm_threw range=\(range.lowerBound)-\(range.upperBound) error=\(String(describing: error), privacy: .public)")
            return nil
        }
        guard let lines = Self.parseLines(response), Set(lines.keys) == Set(range.map { $0 + 1 }) else {
            Self.log.warning("subtitle_translate_bad_reply range=\(range.lowerBound)-\(range.upperBound) reply=\(String(response.prefix(300)), privacy: .public)")
            return nil
        }
        var result: [Int: String] = [:]
        for position in range {
            let line = lines[position + 1]!.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, missingProtectedTerms(english: cues[position].text, translation: line).isEmpty else {
                Self.log.warning("subtitle_translate_line_rejected cue=\(position + 1)")
                return nil
            }
            result[position] = line
        }
        return result
    }

    private func shorten(
        _ positions: [Int],
        cues: [CaptionFileCue],
        translated: [Int: String],
        language: SubtitleLanguage,
        config: SubtitleExportConfig
    ) async -> [Int: String] {
        var text = "Shorten each \(language.englishName) caption to at most \(config.maxCharsPerLine) characters. "
        text += "Keep the meaning and the coaching cue; drop filler first. Return the same ids.\n\n"
        for position in positions {
            text += "\(position + 1): \(translated[position]!)   (English: \(cues[position].text))\n"
        }
        guard let response = try? await llmService.transform(text: text, prompt: systemPrompt(language: language, config: config)),
              let lines = Self.parseLines(response)
        else { return [:] }
        var result: [Int: String] = [:]
        for position in positions {
            guard let line = lines[position + 1]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !line.isEmpty,
                  line.count < translated[position]!.count,
                  missingProtectedTerms(english: cues[position].text, translation: line).isEmpty
            else { continue }
            result[position] = line
        }
        return result
    }

    // MARK: - Prompt and parsing

    func systemPrompt(language: SubtitleLanguage, config: SubtitleExportConfig) -> String {
        var prompt = """
        You translate English closed captions from Echelon fitness classes into \(language.englishName).
        The lines are consecutive pieces of one instructor's live speech; each line is shown on screen at a fixed time.

        Rules:
        - \(language.styleRules)
        - Translate meaning, not words. Fitness slang and idioms become what a native instructor would say, never a literal translation.
        - Keep numbers as digits (reps, seconds, cadence, resistance).
        - Return exactly one translation for every numbered line, with the same numbers. Never merge, drop or add lines.
        - You may move a few words between neighbouring lines so the sentence reads naturally, but each line must still cover roughly the same part of the speech.
        - Keep each line short: at most \(config.maxCharsPerLine) characters if at all possible.
        - Reply with JSON only: {"lines":[{"id":1,"text":"..."}]}
        """
        if !protectedTerms.isEmpty {
            prompt += "\n- Never translate or change these names; copy them exactly: \(protectedTerms.joined(separator: ", "))."
        }
        return prompt
    }

    static func parseLines(_ response: String) -> [Int: String]? {
        let json = LLMThinkingTagStripper.firstJSONValue(
            LLMThinkingTagStripper.strip(response)
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
        )
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let lines = object["lines"] as? [[String: Any]]
        else { return nil }
        var result: [Int: String] = [:]
        for line in lines {
            guard let text = line["text"] as? String else { return nil }
            let id = (line["id"] as? Int) ?? (line["id"] as? String).flatMap(Int.init)
            guard let id, result[id] == nil else { return nil }
            result[id] = text
        }
        return result
    }

    /// Protected terms present in the English line (whole words, any case)
    /// but absent from the translation (exact spelling required).
    func missingProtectedTerms(english: String, translation: String) -> [String] {
        var remainingEnglish = english
        var missing: [String] = []
        for term in protectedTerms {
            guard Self.containsWord(term, in: remainingEnglish, caseInsensitive: true) else { continue }
            remainingEnglish = remainingEnglish.replacingOccurrences(of: term, with: " ", options: .caseInsensitive)
            if !Self.containsWord(term, in: translation, caseInsensitive: false) {
                missing.append(term)
            }
        }
        return missing
    }

    static func containsWord(_ term: String, in text: String, caseInsensitive: Bool) -> Bool {
        let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: term) + "(?![\\p{L}\\p{N}])"
        let options: String.CompareOptions = caseInsensitive ? [.regularExpression, .caseInsensitive] : [.regularExpression]
        return text.range(of: pattern, options: options) != nil
    }
}
