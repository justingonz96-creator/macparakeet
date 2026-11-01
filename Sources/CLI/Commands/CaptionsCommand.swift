import ArgumentParser
import Foundation
import MacParakeetCore

struct CaptionsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "captions",
        abstract: "Work with caption files.",
        subcommands: [CaptionsCheckCommand.self]
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
