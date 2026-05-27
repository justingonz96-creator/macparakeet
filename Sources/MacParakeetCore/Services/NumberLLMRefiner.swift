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

    /// `true` when input and output differ only in number / punctuation content.
    /// We compute a "non-number skeleton" of each (strip digits + common
    /// punctuation + lowercase + collapse whitespace) and compare character
    /// counts. A 2%-of-input tolerance (floor 5 chars) covers tiny noise
    /// like curly-quote substitution without letting in real paraphrasing.
    static func safetyGatePasses(input: String, output: String) -> Bool {
        let inSkel = nonNumberSkeleton(input)
        let outSkel = nonNumberSkeleton(output)
        let delta = abs(inSkel.count - outSkel.count)
        let threshold = max(input.count / 50, 5)
        return delta <= threshold
    }

    static func nonNumberSkeleton(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        var lastWasSpace = false
        for char in text {
            if char.isNumber { continue }
            if Self.skeletonStripPunctuation.contains(char) { continue }
            if char.isWhitespace {
                if !lastWasSpace {
                    out.append(" ")
                    lastWasSpace = true
                }
                continue
            }
            // Use lowercased() to fold case differences; falls back to the
            // original character if lowercasing produces multiple characters
            // (some Unicode characters do — we just take the first to keep
            // the length comparison meaningful).
            let lower = String(char).lowercased()
            if let first = lower.first {
                out.append(first)
            } else {
                out.append(char)
            }
            lastWasSpace = false
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    private static let skeletonStripPunctuation: Set<Character> = [
        ".", ",", "!", "?", ";", ":", "'", "\"", "(", ")", "[", "]", "-",
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
