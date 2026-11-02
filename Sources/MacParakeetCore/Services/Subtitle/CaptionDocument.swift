import Foundation

/// Languages a class can have captions in.
public enum CaptionLanguage: String, Codable, CaseIterable, Sendable, Identifiable {
    case en
    case de
    case es

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .en: "English"
        case .de: "German"
        case .es: "Spanish"
        }
    }

    /// The translator's target, or nil for the source language.
    public var translationTarget: SubtitleLanguage? {
        switch self {
        case .en: nil
        case .de: .de
        case .es: .es
        }
    }
}

public struct CaptionDocumentCue: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var startMs: Int
    public var endMs: Int
    /// Display text; lines separated by "\n" exactly as they will appear.
    public var text: String

    public init(id: UUID = UUID(), startMs: Int, endMs: Int, text: String) {
        self.id = id
        self.startMs = startMs
        self.endMs = endMs
        self.text = text
    }

    public var lines: [String] {
        text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

/// One class's captions in one language: the file the team exports to
/// Premiere. Created from the transcript (English) or by translation, then
/// edited in place; edits are what every later export uses.
public struct CaptionDocument: Codable, Equatable, Sendable {
    public var transcriptionID: UUID
    public var language: CaptionLanguage
    public var cues: [CaptionDocumentCue]
    /// True for machine translations nobody has marked as reviewed.
    public var isDraft: Bool
    public var usedAILayout: Bool
    public var updatedAt: Date

    public init(
        transcriptionID: UUID,
        language: CaptionLanguage,
        cues: [CaptionDocumentCue],
        isDraft: Bool = false,
        usedAILayout: Bool = false,
        updatedAt: Date = Date()
    ) {
        self.transcriptionID = transcriptionID
        self.language = language
        self.cues = cues
        self.isDraft = isDraft
        self.usedAILayout = usedAILayout
        self.updatedAt = updatedAt
    }

    public init(transcriptionID: UUID, language: CaptionLanguage, fileCues: [CaptionFileCue], isDraft: Bool = false, usedAILayout: Bool = false) {
        self.init(
            transcriptionID: transcriptionID,
            language: language,
            cues: fileCues.map { CaptionDocumentCue(startMs: $0.startMs, endMs: $0.endMs, text: $0.lines.joined(separator: "\n")) },
            isDraft: isDraft,
            usedAILayout: usedAILayout
        )
    }

    public var fileCues: [CaptionFileCue] {
        cues.enumerated().map { CaptionFileCue(index: $0.offset + 1, startMs: $0.element.startMs, endMs: $0.element.endMs, lines: $0.element.lines) }
    }

    public func check(config: SubtitleExportConfig = .echelon) -> CaptionQualityReport {
        CaptionQualityChecker.check(cues: fileCues, config: config)
    }

    // MARK: - Files

    public func srt() -> String {
        fileCues.map { "\($0.index)\n\(Self.timestamp($0.startMs, separator: ",")) --> \(Self.timestamp($0.endMs, separator: ","))\n\($0.lines.joined(separator: "\n"))" }
            .joined(separator: "\n\n") + "\n"
    }

    public func vtt() -> String {
        "WEBVTT\n\n" + fileCues.map { "\(Self.timestamp($0.startMs, separator: ".")) --> \(Self.timestamp($0.endMs, separator: "."))\n\($0.lines.joined(separator: "\n"))" }
            .joined(separator: "\n\n") + "\n"
    }

    static func timestamp(_ ms: Int, separator: String) -> String {
        let ms = max(0, ms)
        return String(format: "%02d:%02d:%02d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60) + separator + String(format: "%03d", ms % 1000)
    }

    // MARK: - Editing

    /// Re-wraps edited text to the preset's line layout unless the editor
    /// already chose the line break.
    public mutating func setText(_ text: String, forCue id: UUID, config: SubtitleExportConfig = .echelon) {
        guard let index = cues.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        cues[index].text = trimmed.contains("\n") ? trimmed : ExportService.wrapSubtitleTextStatic(trimmed, config: config)
        updatedAt = Date()
    }

    /// Moves a cue boundary by whole video frames, never past its neighbours.
    public mutating func nudge(cue id: UUID, edge: CueEdge, frames: Int, frameRate: Double = 29.97) {
        guard let index = cues.firstIndex(where: { $0.id == id }) else { return }
        let delta = Int((Double(frames) * 1000 / frameRate).rounded())
        switch edge {
        case .start:
            let floor = index > 0 ? cues[index - 1].endMs + 1 : 0
            cues[index].startMs = min(max(floor, cues[index].startMs + delta), cues[index].endMs - 1)
        case .end:
            let ceiling = index + 1 < cues.count ? cues[index + 1].startMs - 1 : Int.max
            cues[index].endMs = max(min(ceiling, cues[index].endMs + delta), cues[index].startMs + 1)
        }
        updatedAt = Date()
    }

    public enum CueEdge: Sendable { case start, end }

    /// Splits a cue at its middle word, dividing the time by text length.
    @discardableResult
    public mutating func split(cue id: UUID, config: SubtitleExportConfig = .echelon) -> UUID? {
        guard let index = cues.firstIndex(where: { $0.id == id }) else { return nil }
        let words = cues[index].text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.count >= 2 else { return nil }
        let first = words[..<(words.count / 2)].joined(separator: " ")
        let second = words[(words.count / 2)...].joined(separator: " ")
        let cue = cues[index]
        let splitMs = cue.startMs + (cue.endMs - cue.startMs) * first.count / max(1, first.count + second.count)
        cues[index].text = ExportService.wrapSubtitleTextStatic(first, config: config)
        cues[index].endMs = splitMs
        let newCue = CaptionDocumentCue(startMs: splitMs + 1, endMs: cue.endMs, text: ExportService.wrapSubtitleTextStatic(second, config: config))
        cues.insert(newCue, at: index + 1)
        updatedAt = Date()
        return newCue.id
    }

    /// Joins a cue with the one after it.
    public mutating func mergeWithNext(cue id: UUID, config: SubtitleExportConfig = .echelon) {
        guard let index = cues.firstIndex(where: { $0.id == id }), index + 1 < cues.count else { return }
        let joined = (cues[index].lines + cues[index + 1].lines).joined(separator: " ")
        cues[index].text = ExportService.wrapSubtitleTextStatic(joined, config: config)
        cues[index].endMs = cues[index + 1].endMs
        cues.remove(at: index + 1)
        updatedAt = Date()
    }
}

/// Saves each class's caption documents as JSON beside Echo's library:
/// `<app support>/Captions/<transcription id>/<language>.json`.
public struct CaptionDocumentStore: Sendable {
    public let root: URL

    public init(root: URL = URL(fileURLWithPath: AppPaths.appSupportDir).appendingPathComponent("Captions")) {
        self.root = root
    }

    private func url(_ id: UUID, _ language: CaptionLanguage) -> URL {
        root.appendingPathComponent(id.uuidString).appendingPathComponent("\(language.rawValue).json")
    }

    public func load(_ id: UUID, language: CaptionLanguage) -> CaptionDocument? {
        guard let data = try? Data(contentsOf: url(id, language)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(CaptionDocument.self, from: data)
    }

    public func save(_ document: CaptionDocument) throws {
        let target = url(document.transcriptionID, document.language)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(document).write(to: target, options: .atomic)
    }

    public func delete(_ id: UUID, language: CaptionLanguage) {
        try? FileManager.default.removeItem(at: url(id, language))
    }

    public func languages(for id: UUID) -> [CaptionLanguage] {
        CaptionLanguage.allCases.filter { FileManager.default.fileExists(atPath: url(id, $0).path) }
    }
}

/// Words the speech engine was unsure about that a person should glance at:
/// mid-sentence capitalised words (rider shout-outs, names) under 85%
/// confidence, and any other uncommon word under 60%. Common words and
/// protected names are skipped; low scores on them are noise from music.
/// Calibrated on three real classes (27 / 4 / 3 flags), catching misheard
/// rider names and "Mark" for the instructor Marc.
public enum UnsureWordDetector {
    static let common: Set<String> = Set("""
    the a an and or but so if to of in on at for with from by up down out over into onto off back now then here there this that these those \
    it its it's is are was were be been being am do does did done have has had having will would can could should may might must shall \
    i you he she we they me him her us them my your his our their mine yours what which who whom whose when where why how all any both \
    each few more most other some such no nor not only own same than too very just one two three four five six seven eight nine ten \
    twenty thirty forty fifty hundred yes yeah okay ok right gonna wanna gotta let's let go going get got keep come take make feel nice \
    good great new fun man push pull hold ride class work time way little bit like know want need see look think minute minutes second \
    seconds round set rep reps
    """.split(whereSeparator: \.isWhitespace).map(String.init))

    public static func unsureWords(in words: [WordTimestamp], protectedTerms: [String] = []) -> [WordTimestamp] {
        let protected = Set(protectedTerms.map { $0.lowercased() })
        var result: [WordTimestamp] = []
        var previous = "."
        for word in words {
            let token = word.word.trimmingCharacters(in: .whitespaces)
            defer { previous = token }
            let core = token.trimmingCharacters(in: CharacterSet(charactersIn: ".,?!:;\""))
            let lower = core.lowercased()
            guard core.filter(\.isLetter).count >= 3, !common.contains(lower), !protected.contains(lower) else { continue }
            let startsSentence = previous.hasSuffix(".") || previous.hasSuffix("?") || previous.hasSuffix("!")
            let midSentenceName = core.first?.isUppercase == true && !startsSentence
            if (midSentenceName && word.confidence < 0.85) || word.confidence < 0.6 {
                result.append(word)
            }
        }
        return result
    }
}
