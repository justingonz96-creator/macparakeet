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
    private let maxConcurrency: Int

    /// - Parameters:
    ///   - llmService: provider used for refinement calls.
    ///   - maxCharsPerCall: target chunk size (sentences are greedy-packed up to
    ///     this character count). Default 1500 chars — sized so each LLM call
    ///     has a focused, short task (small local models do much better at
    ///     "rewrite this short passage" than "rewrite this whole transcript and
    ///     don't change anything else"). Set higher to reduce LLM call count
    ///     when using a large cloud model.
    ///   - maxConcurrency: how many chunk calls run in flight at once. Matters
    ///     mainly for cloud providers (parallel API calls). Local providers
    ///     usually serialize at the model level anyway, so even 4 concurrent
    ///     calls don't actually run in parallel.
    public init(
        llmService: LLMServiceProtocol,
        maxCharsPerCall: Int = 1_500,
        maxConcurrency: Int = 4
    ) {
        self.llmService = llmService
        self.maxCharsPerCall = max(200, maxCharsPerCall)
        self.maxConcurrency = max(1, maxConcurrency)
    }

    /// Refine the input transcript. Always chunks into small, context-wrapped
    /// pieces so each LLM call has a focused task — small models in particular
    /// do much better on short, well-bounded inputs than on whole transcripts.
    /// Per-chunk safety gates catch local misbehavior without poisoning the
    /// rest of the transcript. Re-throws `CancellationError` so structured
    /// concurrency cancellation propagates up to the caller.
    public func refine(
        text: String,
        runSource: LLMRunSource? = nil,
        onProgress: ProgressHandler? = nil
    ) async throws -> RefinementOutcome {
        guard !text.isEmpty else {
            return RefinementOutcome(text: text, usedLLM: false, fallbackReason: nil, run: nil)
        }
        return try await refineByChunks(text: text, runSource: runSource, onProgress: onProgress)
    }

    // MARK: - Per-chunk LLM call

    /// Refines one chunk. Builds a context-wrapped prompt (BEFORE/CURRENT/AFTER)
    /// so the model can disambiguate boundary phrases (e.g. "nineteen ninety"
    /// + cue break + "five" → 1995) while only modifying the CURRENT block.
    /// The safety gate compares ONLY the CURRENT chunk's input against the
    /// model's output, so misbehavior on context boundaries gets caught.
    ///
    /// Returns an outcome describing what happened to this chunk. `usedLLM`
    /// is true only when the gate passed; on any other path the chunk's
    /// original text is returned with a populated fallback reason.
    private func refineChunk(
        chunk: String,
        contextBefore: String?,
        contextAfter: String?,
        runSource: LLMRunSource?
    ) async throws -> RefinementOutcome {
        let startedAt = Date()
        let prompt = Self.buildContextPrompt(
            chunk: chunk, contextBefore: contextBefore, contextAfter: contextAfter
        )
        let result: LLMResult
        do {
            result = try await llmService.transformDetailed(
                text: prompt,
                prompt: Self.systemPrompt
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let llmError as LLMError where Self.isNotConfigured(llmError) {
            return RefinementOutcome(
                text: chunk, usedLLM: false, fallbackReason: .notConfigured,
                run: nil, latencyMs: Self.latencyMs(since: startedAt)
            )
        } catch {
            return RefinementOutcome(
                text: chunk, usedLLM: false, fallbackReason: .callFailed,
                run: nil, latencyMs: Self.latencyMs(since: startedAt)
            )
        }

        let cleaned = Self.cleanReply(result.output)
        guard !cleaned.isEmpty else {
            return RefinementOutcome(
                text: chunk, usedLLM: false, fallbackReason: .parseFailed,
                run: nil, latencyMs: Self.latencyMs(since: startedAt),
                provider: result.provider
            )
        }

        // Safety gate compares model output to CURRENT chunk only. If the
        // model echoed back BEFORE/CURRENT/AFTER, the word multiset will
        // differ wildly from CURRENT alone → reject.
        guard Self.safetyGatePasses(input: chunk, output: cleaned) else {
            return RefinementOutcome(
                text: chunk, usedLLM: false, fallbackReason: .safetyGateRejected,
                run: nil, latencyMs: Self.latencyMs(since: startedAt),
                provider: result.provider, safetyGatePassed: false
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
            inputChars: chunk.count,
            outputChars: cleaned.count,
            stopReason: result.stopReason,
            inputTruncated: false,
            defaultPromptUsed: true,
            messageCount: 2
        )

        return RefinementOutcome(
            text: cleaned, usedLLM: true, fallbackReason: nil, run: run,
            latencyMs: result.latencyMs ?? Self.latencyMs(since: startedAt),
            provider: result.provider, safetyGatePassed: true
        )
    }

    // MARK: - Chunked driver

    /// Splits the input into sentence-packed chunks, refines each in a small
    /// task group (bounded by `maxConcurrency`), and stitches the results
    /// back. Per-chunk failures isolate — a misbehaving chunk falls back to
    /// its input without affecting neighbors. The stitching uses single
    /// spaces because sentences split with `splitIntoChunks` already carry
    /// their trailing space when needed.
    private func refineByChunks(
        text: String,
        runSource: LLMRunSource?,
        onProgress: ProgressHandler?
    ) async throws -> RefinementOutcome {
        let chunks = Self.splitIntoChunks(text: text, maxChars: maxCharsPerCall)
        let total = chunks.count

        // Single-chunk fast path: skip the task group's overhead. No context
        // blocks because there's nothing before or after.
        if total == 1 {
            let outcome = try await refineChunk(
                chunk: chunks[0],
                contextBefore: nil, contextAfter: nil,
                runSource: runSource
            )
            onProgress?(1, 1)
            return outcome
        }

        // Concurrent per-chunk execution, bounded to `maxConcurrency` in flight.
        // Each chunk gets its immediate neighbors as BEFORE/AFTER context so
        // the model can disambiguate boundary phrases without needing global view.
        var refinedByIndex: [Int: String] = [:]
        var anySucceeded = false
        var firstRun: LLMRun?
        var lastProvider: String?
        var anyGatePassed = false
        var completed = 0

        try await withThrowingTaskGroup(of: (Int, RefinementOutcome).self) { group in
            var nextIndex = 0
            let seedCount = min(maxConcurrency, total)

            while nextIndex < seedCount {
                let i = nextIndex
                group.addTask { [weak self] in
                    guard let self else {
                        return (i, RefinementOutcome(
                            text: chunks[i], usedLLM: false,
                            fallbackReason: .cancelled, run: nil
                        ))
                    }
                    let outcome = try await self.refineChunk(
                        chunk: chunks[i],
                        contextBefore: i > 0 ? chunks[i - 1] : nil,
                        contextAfter: i + 1 < total ? chunks[i + 1] : nil,
                        runSource: runSource
                    )
                    return (i, outcome)
                }
                nextIndex += 1
            }

            while let (i, outcome) = try await group.next() {
                refinedByIndex[i] = outcome.text
                if outcome.usedLLM {
                    anySucceeded = true
                    if firstRun == nil { firstRun = outcome.run }
                    lastProvider = outcome.provider
                    anyGatePassed = anyGatePassed || outcome.safetyGatePassed
                }
                completed += 1
                onProgress?(completed, total)

                if nextIndex < total {
                    let j = nextIndex
                    group.addTask { [weak self] in
                        guard let self else {
                            return (j, RefinementOutcome(
                                text: chunks[j], usedLLM: false,
                                fallbackReason: .cancelled, run: nil
                            ))
                        }
                        let outcome = try await self.refineChunk(
                            chunk: chunks[j],
                            contextBefore: j > 0 ? chunks[j - 1] : nil,
                            contextAfter: j + 1 < total ? chunks[j + 1] : nil,
                            runSource: runSource
                        )
                        return (j, outcome)
                    }
                    nextIndex += 1
                }
            }
        }

        // Stitch in order. splitIntoChunks preserved trailing whitespace on
        // each chunk where the source had it, so simple concatenation
        // reconstructs the original spacing.
        var refinedChunks: [String] = []
        refinedChunks.reserveCapacity(total)
        for i in 0..<total {
            refinedChunks.append(refinedByIndex[i] ?? chunks[i])
        }
        let stitched = refinedChunks.joined()

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

    // MARK: - Context-wrapped prompt

    /// Builds a structured user-message prompt with optional BEFORE / AFTER
    /// context blocks around the CURRENT chunk to refine. Sections use plain
    /// `===` markers — clearer for small models than nested XML or JSON.
    static func buildContextPrompt(
        chunk: String,
        contextBefore: String?,
        contextAfter: String?
    ) -> String {
        var lines: [String] = []
        lines.append("Below is a transcript split into parts. Rewrite ONLY the CURRENT part — change spelled-out numbers to digits per the system instructions. Use BEFORE and AFTER as context to disambiguate (e.g. years, times) but do not include them in your reply. Return only the rewritten CURRENT text, nothing else.")
        lines.append("")
        if let before = contextBefore, !before.isEmpty {
            lines.append("=== BEFORE (context only — do not include in reply) ===")
            lines.append(before)
            lines.append("")
        }
        lines.append("=== CURRENT (rewrite this) ===")
        lines.append(chunk)
        lines.append("")
        if let after = contextAfter, !after.isEmpty {
            lines.append("=== AFTER (context only — do not include in reply) ===")
            lines.append(after)
        }
        return lines.joined(separator: "\n")
    }

    /// Splits `text` at paragraph boundaries (`\n\n`), greedy-packing into
    /// chunks of up to `maxChars`. A single oversized paragraph is
    /// hard-split by character count as a last resort. Always returns at
    /// least one chunk.
    ///
    /// Kept for reference / coarse splitting needs. The chunked refiner uses
    /// `splitIntoChunks` (sentence-aware) instead, which produces smaller
    /// natural-language-boundary chunks suited to per-chunk LLM refinement.
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

    /// Splits `text` into chunks of at most `maxChars` characters, breaking
    /// at sentence boundaries (`.`, `!`, `?` followed by whitespace).
    /// Sentences are greedy-packed: small adjacent sentences ride in the
    /// same chunk until they'd exceed the budget.
    ///
    /// Each returned chunk preserves the original trailing whitespace from
    /// the source — so simple concatenation of chunks reconstructs the
    /// original spacing without inserting extra separators.
    ///
    /// A single sentence longer than `maxChars` becomes its own chunk
    /// (last-resort path; the safety gate still operates on it normally).
    /// Always returns at least one chunk.
    static func splitIntoChunks(text: String, maxChars: Int) -> [String] {
        guard !text.isEmpty else { return [""] }
        let sentences = splitIntoSentences(text)
        guard !sentences.isEmpty else { return [text] }

        var chunks: [String] = []
        var current = ""

        for sentence in sentences {
            // Always allow at least one sentence per chunk, even if it's longer
            // than maxChars on its own — there's no smaller unit to split on.
            if current.isEmpty {
                current = sentence
                continue
            }
            if current.count + sentence.count <= maxChars {
                current += sentence
            } else {
                chunks.append(current)
                current = sentence
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    /// Walks `text` and returns the longest prefixes that end at a sentence
    /// boundary. Sentence-end is one of `.`, `!`, `?` followed by whitespace
    /// or end of string. Decimal points inside numbers (e.g. `2.5`) are not
    /// boundaries because they aren't followed by whitespace.
    ///
    /// Each returned sentence keeps its original trailing whitespace, so
    /// joining them reconstructs the input. The final sentence may have no
    /// terminator (mid-thought transcripts).
    static func splitIntoSentences(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var sentences: [String] = []
        var start = text.startIndex
        var i = text.startIndex

        while i < text.endIndex {
            let ch = text[i]
            if ch == "." || ch == "!" || ch == "?" {
                // Look ahead: is the next character whitespace or end of string?
                let next = text.index(after: i)
                if next == text.endIndex {
                    sentences.append(String(text[start..<text.endIndex]))
                    return sentences
                }
                if text[next].isWhitespace {
                    // Include the terminator AND the trailing whitespace run
                    // in this sentence, so concatenation reconstructs the input.
                    var afterWs = next
                    while afterWs < text.endIndex, text[afterWs].isWhitespace {
                        afterWs = text.index(after: afterWs)
                    }
                    sentences.append(String(text[start..<afterWs]))
                    start = afterWs
                    i = afterWs
                    continue
                }
            }
            i = text.index(after: i)
        }
        if start < text.endIndex {
            sentences.append(String(text[start..<text.endIndex]))
        }
        return sentences
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
