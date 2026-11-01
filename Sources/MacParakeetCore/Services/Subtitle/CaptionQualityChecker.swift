import Foundation

/// One caption cue as read back from an SRT or WebVTT file.
public struct CaptionFileCue: Sendable, Equatable {
    public let index: Int
    public let startMs: Int
    public let endMs: Int
    public let lines: [String]

    public init(index: Int, startMs: Int, endMs: Int, lines: [String]) {
        self.index = index
        self.startMs = startMs
        self.endMs = endMs
        self.lines = lines
    }

    public var text: String { lines.joined(separator: " ") }
    public var durationMs: Int { endMs - startMs }
}

public struct CaptionQualityIssue: Sendable, Equatable, Codable {
    public enum Severity: String, Sendable, Codable {
        /// Breaks the caption rules or the file format; fix before delivery.
        case error
        /// Worth a look by eye or ear; often fine.
        case review
    }

    public enum Kind: String, Sendable, Codable {
        case lineTooLong, tooManyLines, emptyCue, badTiming, overlap
        case flashCue, veryFast, repeatLoop, profanity, offFrame
    }

    public let cue: Int
    public let startMs: Int
    public let kind: Kind
    public let severity: Severity
    public let message: String
}

public struct CaptionQualityReport: Sendable, Equatable, Codable {
    public let cueCount: Int
    public let issues: [CaptionQualityIssue]
    /// Cues read faster than the profile's CPS target (informational: fast
    /// instructors make many cues exceed it, and splitting cannot slow speech).
    public let cuesOverReadingSpeed: Int
    /// Cues shown longer than the profile's max duration plus its end hold.
    public let cuesOverMaxDuration: Int

    public var errorCount: Int { issues.filter { $0.severity == .error }.count }
    public var reviewCount: Int { issues.filter { $0.severity == .review }.count }
    public var passed: Bool { errorCount == 0 }
}

/// Checks caption files against a ``SubtitleExportConfig`` profile (the
/// Echelon preset by default): the rules the team delivers to, not generic
/// broadcast standards.
public enum CaptionQualityChecker {
    /// A cue shown for less than this is hard to read.
    static let flashCueMs = 700
    /// Reading speed above this is flagged for review (the profile's own CPS
    /// target is reported as a count only).
    static let veryFastCPS = 25.0
    /// A 1–3 word phrase repeated this many times in a row looks like a
    /// recognition loop. Instructors legitimately repeat a cue word seven
    /// times ("slow, slow, slow…", "drive drive drive…" in a real class).
    static let loopRepeats = 10
    /// Words that should never reach a fitness-class caption unreviewed; in
    /// practice they arrive as song lyrics recognised as speech.
    static let profanity: Set<String> = [
        "fuck", "fucking", "fucked", "shit", "bitch", "bitches", "asshole",
        "motherfucker", "cunt", "pussy", "nigga",
    ]

    // MARK: Parsing

    /// Parses SRT or WebVTT text. Blocks without a valid timing line are skipped.
    public static func parse(_ text: String) -> [CaptionFileCue] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        var cues: [CaptionFileCue] = []
        for block in normalized.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[timingIndex].components(separatedBy: "-->")
            guard parts.count == 2,
                  let start = timestampMs(parts[0]),
                  let end = timestampMs(parts[1].split(separator: " ", omittingEmptySubsequences: true).first.map(String.init) ?? "")
            else { continue }
            let body = lines[(timingIndex + 1)...]
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            cues.append(CaptionFileCue(index: cues.count + 1, startMs: start, endMs: end, lines: Array(body)))
        }
        return cues
    }

    /// `00:01:02,345`, `00:01:02.345` or WebVTT's short `01:02.345`.
    static func timestampMs(_ raw: String) -> Int? {
        let value = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let pieces = value.split(separator: ":").map(String.init)
        guard pieces.count == 2 || pieces.count == 3 else { return nil }
        let secondsParts = pieces.last!.split(separator: ".").map(String.init)
        guard secondsParts.count == 2,
              let seconds = Int(secondsParts[0]),
              let millis = Int(secondsParts[1].prefix(3).padding(toLength: 3, withPad: "0", startingAt: 0))
        else { return nil }
        let numbers = pieces.dropLast().compactMap { Int($0) }
        guard numbers.count == pieces.count - 1 else { return nil }
        let hours = numbers.count == 2 ? numbers[0] : 0
        let minutes = numbers.last ?? 0
        return ((hours * 60 + minutes) * 60 + seconds) * 1000 + millis
    }

    // MARK: Checking

    public static func check(text: String, config: SubtitleExportConfig = .echelon) -> CaptionQualityReport {
        check(cues: parse(text), config: config)
    }

    public static func check(cues: [CaptionFileCue], config: SubtitleExportConfig = .echelon) -> CaptionQualityReport {
        var issues: [CaptionQualityIssue] = []
        var overSpeed = 0
        var overDuration = 0
        let durationLimit = config.maxDurationMs + config.endTimeBufferMs

        func add(_ cue: CaptionFileCue, _ kind: CaptionQualityIssue.Kind, _ severity: CaptionQualityIssue.Severity, _ message: String) {
            issues.append(CaptionQualityIssue(cue: cue.index, startMs: cue.startMs, kind: kind, severity: severity, message: message))
        }

        for (position, cue) in cues.enumerated() {
            if cue.lines.isEmpty {
                add(cue, .emptyCue, .error, "Cue has no text.")
            }
            if cue.lines.count > config.maxLinesPerCue {
                add(cue, .tooManyLines, .error, "\(cue.lines.count) lines (limit \(config.maxLinesPerCue)).")
            }
            for line in cue.lines where line.count > config.maxCharsPerLine {
                add(cue, .lineTooLong, .error, "Line has \(line.count) characters (limit \(config.maxCharsPerLine)).")
            }
            if cue.durationMs <= 0 {
                add(cue, .badTiming, .error, "Ends at or before it starts.")
                continue
            }
            if position > 0, cue.startMs < cues[position - 1].endMs {
                add(cue, .overlap, .error, "Starts before the previous cue ends.")
            }
            if cue.durationMs < flashCueMs {
                add(cue, .flashCue, .review, "On screen for only \(cue.durationMs) ms.")
            }
            let cps = Double(cue.text.count) / (Double(cue.durationMs) / 1000)
            if config.maxCPS > 0, cps > config.maxCPS { overSpeed += 1 }
            if cps > veryFastCPS {
                add(cue, .veryFast, .review, String(format: "Reads at %.0f characters per second.", cps))
            }
            if cue.durationMs > durationLimit { overDuration += 1 }
            if let rate = config.snapToFrameRate, rate > 0 {
                // Millisecond rounding and the 1 ms anti-overlap gap leave
                // snapped times ~1–2 ms off; a quarter frame is clearly wrong.
                let toleranceMs = 250 / rate
                if offFrameMs(cue.startMs, rate: rate) > toleranceMs || offFrameMs(cue.endMs, rate: rate) > toleranceMs {
                    add(cue, .offFrame, .review, "Timing is not on a \(rate) fps frame.")
                }
            }
            let words = Self.words(cue.text)
            if let swear = words.first(where: { profanity.contains($0) }) {
                add(cue, .profanity, .review, "Contains \"\(swear)\" (often a song lyric heard as speech).")
            }
        }

        for loop in repeatLoops(in: cues) {
            issues.append(loop)
        }

        issues.sort { ($0.cue, $0.kind.rawValue) < ($1.cue, $1.kind.rawValue) }
        return CaptionQualityReport(
            cueCount: cues.count,
            issues: issues,
            cuesOverReadingSpeed: overSpeed,
            cuesOverMaxDuration: overDuration
        )
    }

    /// Distance in ms from the nearest frame boundary.
    static func offFrameMs(_ ms: Int, rate: Double) -> Double {
        let frameMs = 1000 / rate
        let frames = Double(ms) / frameMs
        return abs(frames - frames.rounded()) * frameMs
    }

    static func words(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.letters.union(CharacterSet(charactersIn: "'")).inverted)
            .filter { !$0.isEmpty }
    }

    /// Finds a 1–3 word phrase repeated `loopRepeats`+ times in a row across
    /// consecutive cues; reports it once, on the cue where it starts.
    static func repeatLoops(in cues: [CaptionFileCue]) -> [CaptionQualityIssue] {
        var stream: [(word: String, cue: CaptionFileCue)] = []
        for cue in cues {
            for word in words(cue.text) { stream.append((word, cue)) }
        }
        var issues: [CaptionQualityIssue] = []
        var index = 0
        while index < stream.count {
            var best: (size: Int, repeats: Int) = (0, 0)
            for size in 1...3 where index + size <= stream.count {
                let phrase = stream[index..<(index + size)].map(\.word)
                var repeats = 1
                while index + (repeats + 1) * size <= stream.count,
                      Array(stream[(index + repeats * size)..<(index + (repeats + 1) * size)].map(\.word)) == phrase {
                    repeats += 1
                }
                if repeats > best.repeats { best = (size, repeats) }
            }
            if best.repeats >= loopRepeats {
                let cue = stream[index].cue
                let phrase = stream[index..<(index + best.size)].map(\.word).joined(separator: " ")
                issues.append(CaptionQualityIssue(
                    cue: cue.index, startMs: cue.startMs, kind: .repeatLoop, severity: .review,
                    message: "\"\(phrase)\" repeats \(best.repeats) times in a row; check it was really said."
                ))
                index += best.size * best.repeats
            } else {
                index += 1
            }
        }
        return issues
    }
}
