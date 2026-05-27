import Foundation

/// Uses an LLM to refine spelled-out numbers in transcript text into digit form.
///
/// Runs as an optional step AFTER the deterministic `NumberNormalizer` — catches
/// the cases rules can't reach (years, decimals, large cardinals, clock times)
/// without changing the rest of the prose.
///
/// **Never throws** except `CancellationError`. All other failure modes return a
/// `RefinementOutcome` with `text == input` and a populated `fallbackReason`.
/// This lets `TranscriptionService` compose the refiner without a try/catch and
/// guarantees Smart mode degrades silently to Deterministic when anything goes
/// wrong (no provider, network error, parse failure, safety-gate rejection).
///
/// Scope: file/meeting transcripts only. `DictationService` reads the same
/// `NumberRefinementMode` preference but never instantiates this actor — Smart
/// collapses to Deterministic in the dictation path because the LLM round-trip
/// would add visible paste latency.
public actor NumberLLMRefiner {

    public typealias ProgressHandler = @Sendable (Int, Int) -> Void

    /// Why the actor returned the deterministic input instead of the LLM reply.
    public enum FallbackReason: String, Sendable {
        case notConfigured
        case callFailed
        case parseFailed
        case safetyGateRejected
        case cancelled
    }

    public struct RefinementOutcome: Sendable {
        public let text: String
        public let usedLLM: Bool
        public let fallbackReason: FallbackReason?
        public let run: LLMRun?
        public let latencyMs: Int
        public let provider: String?
        public let safetyGatePassed: Bool

        public init(
            text: String,
            usedLLM: Bool,
            fallbackReason: FallbackReason?,
            run: LLMRun?,
            latencyMs: Int = 0,
            provider: String? = nil,
            safetyGatePassed: Bool = false
        ) {
            self.text = text
            self.usedLLM = usedLLM
            self.fallbackReason = fallbackReason
            self.run = run
            self.latencyMs = latencyMs
            self.provider = provider
            self.safetyGatePassed = safetyGatePassed
        }
    }

    private let llmService: LLMServiceProtocol
    private let maxCharsPerCall: Int

    public init(llmService: LLMServiceProtocol, maxCharsPerCall: Int = 80_000) {
        self.llmService = llmService
        self.maxCharsPerCall = max(1_000, maxCharsPerCall)
    }

    /// Refine the input transcript. Returns the deterministic input untouched
    /// when anything fails. Re-throws `CancellationError` so structured
    /// concurrency cancellation propagates up to the caller.
    public func refine(
        text: String,
        runSource: LLMRunSource? = nil,
        onProgress: ProgressHandler? = nil
    ) async throws -> RefinementOutcome {
        guard !text.isEmpty else {
            return RefinementOutcome(text: text, usedLLM: false, fallbackReason: nil, run: nil)
        }

        // Escape hatch for very long transcripts: split at paragraph boundaries
        // and refine chunk-by-chunk. Per-chunk failures fall back to that
        // chunk's input, not the whole transcript. Sequential to keep the
        // ordering deterministic and the implementation simple — the typical
        // case (transcripts well under 80K chars) takes the single-call path.
        if text.count > maxCharsPerCall {
            return try await refineByChunks(text: text, runSource: runSource, onProgress: onProgress)
        }

        return try await refineSingleCall(text: text, runSource: runSource)
    }

    // MARK: - Single-call path

    private func refineSingleCall(
        text: String,
        runSource: LLMRunSource?
    ) async throws -> RefinementOutcome {
        let startedAt = Date()
        let result: LLMResult
        do {
            result = try await llmService.transformDetailed(
                text: text,
                prompt: Self.systemPrompt
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let llmError as LLMError where Self.isNotConfigured(llmError) {
            return RefinementOutcome(
                text: text,
                usedLLM: false,
                fallbackReason: .notConfigured,
                run: nil,
                latencyMs: Self.latencyMs(since: startedAt)
            )
        } catch {
            return RefinementOutcome(
                text: text,
                usedLLM: false,
                fallbackReason: .callFailed,
                run: nil,
                latencyMs: Self.latencyMs(since: startedAt)
            )
        }

        let cleaned = Self.cleanReply(result.output)
        guard !cleaned.isEmpty else {
            return RefinementOutcome(
                text: text,
                usedLLM: false,
                fallbackReason: .parseFailed,
                run: nil,
                latencyMs: Self.latencyMs(since: startedAt),
                provider: result.provider
            )
        }

        guard Self.safetyGatePasses(input: text, output: cleaned) else {
            return RefinementOutcome(
                text: text,
                usedLLM: false,
                fallbackReason: .safetyGateRejected,
                run: nil,
                latencyMs: Self.latencyMs(since: startedAt),
                provider: result.provider,
                safetyGatePassed: false
            )
        }

        let run = LLMRun(
            operationID: nil,
            feature: .numberRefinement,
            status: .succeeded,
            source: runSource ?? LLMRunSource(),
            provider: result.provider,
            model: result.model,
            promptTokens: result.usage?.promptTokens,
            completionTokens: result.usage?.completionTokens,
            totalTokens: result.usage?.totalTokens,
            latencyMs: result.latencyMs,
            inputChars: text.count,
            outputChars: cleaned.count,
            stopReason: result.stopReason,
            inputTruncated: false,
            defaultPromptUsed: true,
            messageCount: 2
        )

        return RefinementOutcome(
            text: cleaned,
            usedLLM: true,
            fallbackReason: nil,
            run: run,
            latencyMs: result.latencyMs ?? Self.latencyMs(since: startedAt),
            provider: result.provider,
            safetyGatePassed: true
        )
    }

    // MARK: - Batched (escape-hatch) path

    private func refineByChunks(
        text: String,
        runSource: LLMRunSource?,
        onProgress: ProgressHandler?
    ) async throws -> RefinementOutcome {
        let chunks = Self.splitAtParagraphs(text: text, maxChars: maxCharsPerCall)
        var refinedChunks: [String] = []
        refinedChunks.reserveCapacity(chunks.count)
        let total = chunks.count
        var anySucceeded = false
        var firstRun: LLMRun?
        var lastProvider: String?
        var anyGatePassed = false

        for (i, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            let outcome = try await refineSingleCall(text: chunk, runSource: runSource)
            refinedChunks.append(outcome.text)
            if outcome.usedLLM {
                anySucceeded = true
                if firstRun == nil { firstRun = outcome.run }
                lastProvider = outcome.provider
                anyGatePassed = anyGatePassed || outcome.safetyGatePassed
            }
            onProgress?(i + 1, total)
        }

        // Use paragraph delimiter that matches the splitter's contract.
        let stitched = refinedChunks.joined(separator: "\n\n")
        return RefinementOutcome(
            text: stitched,
            usedLLM: anySucceeded,
            fallbackReason: anySucceeded ? nil : .callFailed,
            run: firstRun,
            latencyMs: 0,
            provider: lastProvider,
            safetyGatePassed: anyGatePassed
        )
    }

    /// Splits `text` at paragraph boundaries (`\n\n`), greedy-packing into
    /// chunks of up to `maxChars`. A single oversized paragraph is
    /// hard-split by character count as a last resort. Always returns at
    /// least one chunk.
    static func splitAtParagraphs(text: String, maxChars: Int) -> [String] {
        let paragraphs = text.components(separatedBy: "\n\n")
        var chunks: [String] = []
        var current = ""

        for paragraph in paragraphs {
            let candidate = current.isEmpty ? paragraph : current + "\n\n" + paragraph
            if candidate.count <= maxChars {
                current = candidate
            } else {
                if !current.isEmpty { chunks.append(current) }
                if paragraph.count > maxChars {
                    var remainder = paragraph
                    while remainder.count > maxChars {
                        let cutIdx = remainder.index(remainder.startIndex, offsetBy: maxChars)
                        chunks.append(String(remainder[..<cutIdx]))
                        remainder = String(remainder[cutIdx...])
                    }
                    current = remainder
                } else {
                    current = paragraph
                }
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks.isEmpty ? [text] : chunks
    }

    // MARK: - Reply cleaning

    /// Trims whitespace, strips a matched code-fence pair, and strips a matched
    /// pair of wrapping quote characters (straight or curly). Returns "" if
    /// nothing usable remains.
    static func cleanReply(_ reply: String) -> String {
        var t = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return t }

        // Strip a single matched ``` fence pair.
        if t.hasPrefix("```") {
            if let firstNewline = t.firstIndex(of: "\n") {
                t = String(t[t.index(after: firstNewline)...])
            } else {
                // ```text without a newline — drop the opening fence.
                t = String(t.dropFirst(3))
            }
            if t.hasSuffix("```") {
                t = String(t.dropLast(3))
            }
            t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Strip a matched pair of wrapping quotes (straight or curly).
        let quotePairs: [(Character, Character)] = [
            ("\"", "\""), ("'", "'"), ("\u{201C}", "\u{201D}"), ("\u{2018}", "\u{2019}"),
        ]
        for (open, close) in quotePairs {
            if t.count >= 2, t.first == open, t.last == close {
                t = String(t.dropFirst().dropLast())
                t = t.trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }

        return t
    }

    // MARK: - Safety gate

    /// `true` when input and output differ only in number content.
    ///
    /// Both sides are tokenized into letter-only words (anything non-letter is
    /// a separator, which splits `twenty-five` into two tokens and drops
    /// digits / punctuation entirely). Known spelled cardinal/ordinal/decimal
    /// words are then removed, and the remaining word multisets are compared.
    /// A small mismatch budget (5% of input tokens, floor 2) absorbs noise
    /// like the LLM normalizing "and" between number components or
    /// substituting curly quotes.
    ///
    /// Worked example: input "next thirty seconds, twenty-five reps" tokenizes
    /// to {next, thirty, seconds, twenty, five, reps}; filtering number words
    /// leaves {next, seconds, reps}. Output "next 30 seconds, 25 reps"
    /// tokenizes to {next, seconds, reps}. Multisets match → passes.
    static func safetyGatePasses(input: String, output: String) -> Bool {
        let inFreq = tokenFrequencies(nonNumberWords(input))
        let outFreq = tokenFrequencies(nonNumberWords(output))

        let allKeys = Set(inFreq.keys).union(outFreq.keys)
        var diffCount = 0
        for key in allKeys {
            diffCount += abs((inFreq[key] ?? 0) - (outFreq[key] ?? 0))
        }

        let inTotalTokens = inFreq.values.reduce(0, +)
        let threshold = max(inTotalTokens / 20, 2)
        return diffCount <= threshold
    }

    /// Returns the lowercased letter-only words in `text` with known
    /// number-related words filtered out. Splits on any non-letter character
    /// (so hyphens in `twenty-five` become token boundaries and digits drop
    /// out entirely).
    static func nonNumberWords(_ text: String) -> [String] {
        let lowered = text.lowercased()
        var tokens: [String] = []
        var current = ""
        for char in lowered {
            if char.isLetter {
                current.append(char)
            } else if !current.isEmpty {
                tokens.append(current)
                current = ""
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens.filter { !Self.numberWords.contains($0) }
    }

    private static func tokenFrequencies(_ tokens: [String]) -> [String: Int] {
        var counts: [String: Int] = [:]
        counts.reserveCapacity(tokens.count)
        for token in tokens { counts[token, default: 0] += 1 }
        return counts
    }

    /// Lexicon of words that count as "number-like" for the safety gate. Kept
    /// narrow on purpose — only words that would be REPLACED by a digit form
    /// when the LLM rewrites the transcript. Common prose words like "and"
    /// or "of" stay in the comparison so adding/removing them around numbers
    /// shows up as drift (but is absorbed by the mismatch budget for typical
    /// cases like `three hundred and twenty` → `320`).
    private static let numberWords: Set<String> = [
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine",
        "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen",
        "seventeen", "eighteen", "nineteen",
        "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety",
        "hundred", "thousand", "million", "billion", "trillion",
        "first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth",
        "eleventh", "twelfth", "thirteenth", "fourteenth", "fifteenth", "sixteenth",
        "seventeenth", "eighteenth", "nineteenth", "twentieth", "thirtieth",
        "fortieth", "fiftieth", "sixtieth", "seventieth", "eightieth", "ninetieth",
        "hundredth", "thousandth", "millionth",
        "half", "quarter", "third",
        "am", "pm", "oh", "point",
    ]

    // MARK: - Error classification

    private static func isNotConfigured(_ error: LLMError) -> Bool {
        if case .notConfigured = error { return true }
        return false
    }

    private static func latencyMs(since start: Date) -> Int {
        Int((Date().timeIntervalSince(start) * 1000).rounded())
    }

    // MARK: - System prompt

    static let systemPrompt = """
        You are a number-formatting assistant. The user will give you a transcript.

        Your only job is to rewrite spelled-out numbers as digits where digit form is the conventional written reading.

        Convert:
        - Years ("nineteen ninety-five" → "1995")
        - Clock times ("ten thirty" → "10:30", "ten thirty AM" → "10:30 AM")
        - Decimals ("two point five" → "2.5")
        - Large cardinals ("three thousand four hundred and twenty-five" → "3,425")
        - Spelled cardinals 10+ in measurement or counting contexts ("forty-five reps" → "45 reps")
        - Phone numbers, addresses, monetary amounts when clearly spelled

        Do NOT change:
        - Idiomatic words ("one of them", "two of a kind") — keep spelled
        - Ordinals in narrative use ("the first time") — keep spelled
        - Any word that isn't a number
        - Punctuation, line breaks, spacing, casing

        Return the rewritten transcript verbatim. No commentary, no explanation, no quotes, no markdown. Just the transcript.
        """
}
