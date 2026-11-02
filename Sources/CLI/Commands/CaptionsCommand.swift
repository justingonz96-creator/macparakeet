import ArgumentParser
import Foundation
import MacParakeetCore

struct CaptionsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "captions",
        abstract: "Work with caption files.",
        subcommands: [CaptionsCheckCommand.self, CaptionsTranslateCommand.self]
    )
}

struct CaptionsCheckCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "check",
        abstract: "Check SRT/VTT caption files against a caption preset (Echelon by default).",
        discussion: """
        Errors break the preset's rules or the file format (line length, line count, \
        empty cues, bad or overlapping timing). Review items are worth a look: flash \
        cues, very fast reading, repeated-phrase loops, profanity (often a song lyric \
        heard as speech) and timings off the video frame grid. Exits with status 1 \
        when any file has errors.
        """
    )

    @Argument(help: "SRT or VTT files to check.")
    var files: [String]

    @Option(name: .long, help: "Caption preset to check against: default, echelon.")
    var preset: SubtitlePreset = .echelon

    @Flag(name: .long, help: "Emit JSON instead of human-readable output.")
    var json: Bool = false

    struct FileReport: Encodable {
        let file: String
        let report: CaptionQualityReport
    }

    func run() throws {
        var reports: [FileReport] = []
        for file in files {
            let text = try String(contentsOf: URL(fileURLWithPath: file), encoding: .utf8)
            reports.append(FileReport(file: file, report: CaptionQualityChecker.check(text: text, config: preset.config)))
        }
        if json {
            try printJSON(reports)
        } else {
            for (position, entry) in reports.enumerated() {
                if position > 0 { print() }
                print(Self.render(entry.report, file: entry.file))
            }
        }
        if reports.contains(where: { !$0.report.passed }) {
            throw ExitCode(1)
        }
    }

    static func render(_ report: CaptionQualityReport, file: String) -> String {
        var lines = [file]
        let verdict = report.passed ? "PASS" : "FAIL"
        lines.append("\(verdict): \(report.cueCount) cues, \(report.errorCount) errors, \(report.reviewCount) to review")
        lines.append("  Info: \(report.cuesOverReadingSpeed) cues read faster than the preset target; \(report.cuesOverMaxDuration) stay up longer than its max duration plus hold.")
        for issue in report.issues {
            let label = issue.severity == .error ? "ERROR " : "review"
            lines.append("  \(label) cue \(issue.cue) at \(Self.clock(issue.startMs)): \(issue.message)")
        }
        return lines.joined(separator: "\n")
    }

    static func clock(_ ms: Int) -> String {
        let seconds = ms / 1000
        return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }
}

extension SubtitleLanguage: ExpressibleByArgument {}

struct CaptionsTranslateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "translate",
        abstract: "Translate an English SRT/VTT into another language, keeping every caption's timing.",
        discussion: """
        Uses the app's AI provider unless --llm-provider is given. Names in Echo's \
        Vocabulary that have no replacement (Echelon, product and instructor names), \
        plus any --term or --glossary entries, are kept exactly. The result is checked \
        against the caption preset like `captions check`.
        """
    )

    @Argument(help: "English SRT or VTT file.")
    var file: String

    @Option(name: .long, help: "Target language: de (German) or es (Spanish).")
    var to: SubtitleLanguage

    @Option(name: .shortAndLong, help: "Output SRT path (defaults to <input>.<language>.srt).")
    var output: String?

    @Option(name: .long, help: "Caption preset for line length and checks: default, echelon.")
    var preset: SubtitlePreset = .echelon

    @Option(name: .long, help: "Extra name to keep untranslated (repeatable).")
    var term: [String] = []

    @Option(name: .long, help: "Text file of names to keep untranslated, one per line.")
    var glossary: String?

    @Option(name: .long, help: "AI provider for this run instead of the app's saved one (e.g. ollama).")
    var llmProvider: String?

    @Option(name: .long, help: "Model for --llm-provider (e.g. qwen3.8:27b-mlx).")
    var llmModel: String?

    @Option(help: "Path to SQLite database file (defaults to the app database).")
    var database: String?

    func run() async throws {
        let input = URL(fileURLWithPath: file)
        let cues = CaptionQualityChecker.parse(try String(contentsOf: input, encoding: .utf8))
        guard !cues.isEmpty else { throw ValidationError("No captions found in \(file).") }

        var terms = term
        if let glossary {
            terms += try String(contentsOf: URL(fileURLWithPath: glossary), encoding: .utf8)
                .split(separator: "\n").map(String.init)
        }
        let dbManager = try DatabaseManager(path: resolvedDatabasePath(database))
        terms += try CustomWordRepository(dbQueue: dbManager.dbQueue).fetchEnabled()
            .filter { ($0.replacement ?? "").isEmpty }
            .map(\.word)

        let translator = SubtitleTranslator(
            llmService: try await makeCaptionLLMService(provider: llmProvider, model: llmModel),
            protectedTerms: terms
        )
        let result = await translator.translate(cues: cues, to: to, config: preset.config) { done, total in
            FileHandle.standardError.write(Data("Translating… \(done)/\(total)\n".utf8))
        }

        let outputURL = output.map { URL(fileURLWithPath: $0) }
            ?? input.deletingPathExtension().appendingPathExtension("\(to.rawValue).srt")
        let srt = result.cues.map { cue in
            "\(cue.index)\n\(Self.srtTime(cue.startMs)) --> \(Self.srtTime(cue.endMs))\n\(cue.lines.joined(separator: "\n"))"
        }.joined(separator: "\n\n") + "\n"
        try srt.write(to: outputURL, atomically: true, encoding: .utf8)

        print("Wrote \(outputURL.path)")
        if !result.untranslatedCues.isEmpty {
            print("Left in English (translation kept failing): cues \(result.untranslatedCues.map(String.init).joined(separator: ", "))")
        }
        for missing in result.missingTerms {
            print("Cue \(missing.cue): \"\(missing.term)\" changed in translation")
        }
        let report = CaptionQualityChecker.check(cues: result.cues, config: preset.config)
        print(CaptionsCheckCommand.render(report, file: outputURL.lastPathComponent))
    }

    static func srtTime(_ ms: Int) -> String {
        String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
    }
}
