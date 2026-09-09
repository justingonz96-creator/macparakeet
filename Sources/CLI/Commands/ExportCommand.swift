import ArgumentParser
import Foundation
import MacParakeetCore

enum ExportFormat: String, ExpressibleByArgument, CaseIterable {
    case txt
    case markdown
    case srt
    case vtt
    case dapt
    case json

    var fileExtension: String {
        switch self {
        case .txt: return "txt"
        case .markdown: return "md"
        case .srt: return "srt"
        case .vtt: return "vtt"
        case .dapt: return "dapt.xml"
        case .json: return "json"
        }
    }
}

/// Named `SubtitleExportConfig` starting points for the `--subtitle-preset`
/// flag on `export` and `transcribe`. There is no preset picker in the GUI
/// (see `SubtitleExportConfig.echelon`'s doc comment) — this is CLI-only.
enum SubtitlePreset: String, ExpressibleByArgument, CaseIterable {
    case `default`
    case echelon

    var config: SubtitleExportConfig {
        switch self {
        case .default: return .default
        case .echelon: return .echelon
        }
    }
}

struct ExportCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Export a transcription to a file.",
        discussion: "Supported formats: txt, markdown, srt, vtt, dapt, json."
    )

    @Argument(help: "The UUID (or prefix) of the transcription to export.")
    var id: String

    @Option(name: .shortAndLong, help: "Output format: txt, markdown, srt, vtt, dapt, json.")
    var format: ExportFormat = .txt

    @Option(name: .shortAndLong, help: "Output file path (defaults to current directory with auto-generated name).")
    var output: String?

    @Flag(help: "Print to stdout instead of writing a file.")
    var stdout: Bool = false

    @Option(help: "Path to SQLite database file (defaults to the app database).")
    var database: String?

    @Option(name: .long, help: "Subtitle preset to start SRT/VTT cue layout from: default, echelon.")
    var subtitlePreset: SubtitlePreset = .default

    @Flag(name: .long, help: "Convert spelled-out cardinals to digits in SRT/VTT cue text.")
    var normalizeNumbers: Bool = false

    @Flag(name: .long, help: "Use the LLM layout planner for SRT/VTT cue boundaries (reads the same stored LLM provider config as the app).")
    var llmRefinement: Bool = false

    /// SubtitleExportConfig with the CLI flag overlay applied. Used by the
    /// SRT/VTT branches; the other formats ignore it.
    var subtitleConfig: SubtitleExportConfig {
        var c = subtitlePreset.config
        c.normalizeNumbers = normalizeNumbers
        c.useLLMRefinement = llmRefinement
        return c
    }

    func run() async throws {
        try await emitJSONOrRethrow(json: stdout && format == .json) {
            try AppPaths.ensureDirectories()
            let dbManager = try DatabaseManager(path: resolvedDatabasePath(database))
            let repo = TranscriptionRepository(dbQueue: dbManager.dbQueue)
            let attributionReader = SpeakerAttributionReadService(dbQueue: dbManager.dbQueue)

            let transcription = try findTranscription(id: id, repo: repo)
            let projection = try attributionReader.resolve(transcription: transcription)
            let exportService = ExportService()

            if stdout {
                let content = try await formatContent(projection: projection, exportService: exportService)
                print(content)
            } else {
                let outputURL = resolveOutputURL(transcription: transcription)
                try FileManager.default.createDirectory(
                    at: outputURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try await writeExport(projection: projection, exportService: exportService, url: outputURL)
                print("Exported to \(outputURL.path)")
            }
        }
    }

    func resolveOutputURL(transcription: Transcription) -> URL {
        if let output {
            return URL(fileURLWithPath: expandTilde(output))
        }
        let baseName = TranscriptSegmenter.sanitizedExportStem(from: transcription.fileName)
        let fileName = "\(baseName).\(format.fileExtension)"
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(fileName)
    }

    /// Text/Markdown exports from the CLI include speaker labels, matching
    /// upstream. The fork keeps `TranscriptExportOptions.default` with speaker
    /// labels OFF for GUI exports (see `SubtitleExportConfigTests`), so the CLI
    /// asks for them explicitly instead of flipping the shared default.
    private static let textExportOptions = TranscriptExportOptions.speakerAttributed

    private func formatContent(
        projection: SpeakerAttributionProjection,
        exportService: ExportService
    ) async throws -> String {
        switch format {
        case .txt:
            return exportService.formatPlainText(projection: projection, options: Self.textExportOptions)
        case .markdown:
            return exportService.formatMarkdown(projection: projection, options: Self.textExportOptions)
        case .srt:
            // Fork: the subtitle preset/flag overlay drives cue layout, so the
            // config-aware formatter replaces upstream's `formatSRT(projection:)`
            // convenience (same speaker-corrected transcript underneath).
            return exportService.formatSRT(
                transcription: projection.effectiveTranscription,
                config: subtitleConfig
            )
        case .vtt:
            return exportService.formatVTT(
                transcription: projection.effectiveTranscription,
                config: subtitleConfig
            )
        case .dapt:
            return exportService.formatDAPT(projection: projection)
        case .json:
            return try projectedJSON(projection)
        }
    }

    private func writeExport(
        projection: SpeakerAttributionProjection,
        exportService: ExportService,
        url: URL
    ) async throws {
        switch format {
        case .txt:
            try exportService.exportToTxt(
                transcription: projection.effectiveTranscription,
                url: url,
                options: Self.textExportOptions
            )
        case .markdown:
            try exportService.exportToMarkdown(
                transcription: projection.effectiveTranscription,
                url: url,
                options: Self.textExportOptions
            )
        case .srt:
            if llmRefinement {
                let llmService = buildLLMServiceFromGUIDefaults()
                try await exportService.exportToSRT(
                    transcription: projection.effectiveTranscription,
                    url: url,
                    config: subtitleConfig,
                    llmService: llmService
                )
            } else {
                try exportService.exportToSRT(
                    transcription: projection.effectiveTranscription,
                    url: url,
                    config: subtitleConfig,
                    includeSpeakerLabels: false
                )
            }
        case .vtt:
            if llmRefinement {
                let llmService = buildLLMServiceFromGUIDefaults()
                try await exportService.exportToVTT(
                    transcription: projection.effectiveTranscription,
                    url: url,
                    config: subtitleConfig,
                    llmService: llmService
                )
            } else {
                try exportService.exportToVTT(
                    transcription: projection.effectiveTranscription,
                    url: url,
                    config: subtitleConfig,
                    includeSpeakerLabels: false
                )
            }
        case .dapt:
            try exportService.exportToDAPT(transcription: projection.effectiveTranscription, url: url)
        case .json:
            try Data(projectedJSON(projection).utf8).write(to: url, options: .atomic)
        }
    }

    /// LLMConfigStore defaults to `UserDefaults.standard`, which for a
    /// bundle-less CLI binary resolves to a different domain than the
    /// GUI app's. The GUI saves its provider config under either
    /// `com.macparakeet.dev` (debug build) or `com.macparakeet.MacParakeet`
    /// (release). Try both, prefer whichever has a saved config.
    private func buildLLMServiceFromGUIDefaults() -> LLMService {
        let candidates = [
            "com.macparakeet.dev",
            "com.macparakeet.MacParakeet",
        ]
        for suite in candidates {
            guard let defaults = UserDefaults(suiteName: suite) else { continue }
            if defaults.data(forKey: "llm_provider_config") != nil {
                let store = LLMConfigStore(defaults: defaults)
                return LLMService(
                    client: RoutingLLMClient(),
                    contextResolver: StoredLLMExecutionContextResolver(
                        configStore: store,
                        cliConfigStore: LocalCLIConfigStore()
                    )
                )
            }
        }
        // No GUI config found — fall through to default-everything
        // (which will throw `notConfigured` per chunk).
        return LLMService()
    }

    private func projectedJSON(_ projection: SpeakerAttributionProjection) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encoded = try encoder.encode(projection.effectiveTranscription)
        guard var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        object["speakerCorrectionsApplied"] = projection.correctionsApplied
        object["speakerCorrectionRevision"] = projection.correctionRevision
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        guard let string = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return string
    }
}
