import Foundation

/// Makes a class's caption documents: English from the transcript (Echelon
/// rules, optionally the AI layout) and translations of the English.
public struct CaptionBuilder: Sendable {
    public let config: SubtitleExportConfig
    let exportService: ExportService

    public init(config: SubtitleExportConfig = .echelon, exportService: ExportService = ExportService()) {
        self.config = config
        self.exportService = exportService
    }

    /// English captions. With an AI service and the preset's AI layout on,
    /// cues come from the AI layout (falling back per chunk); otherwise from
    /// the rule-based layout, which is instant.
    public func englishDocument(
        for transcription: Transcription,
        llmService: LLMServiceProtocol?,
        onProgress: SubtitleExportProgressHandler? = nil
    ) async throws -> CaptionDocument {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("echo-captions-\(UUID().uuidString).srt")
        defer { try? FileManager.default.removeItem(at: url) }
        let useAI = config.useLLMRefinement && llmService != nil
        if useAI {
            try await exportService.exportToSRT(
                transcription: transcription,
                url: url,
                config: config,
                includeSpeakerLabels: false,
                llmService: llmService,
                onExportProgress: onProgress
            )
        } else {
            try exportService.exportToSRT(transcription: transcription, url: url, config: config, includeSpeakerLabels: false)
        }
        let cues = CaptionQualityChecker.parse(try String(contentsOf: url, encoding: .utf8))
        return CaptionDocument(transcriptionID: transcription.id, language: .en, fileCues: cues, usedAILayout: useAI)
    }

    /// A machine translation of the English document, marked as a draft.
    public func translation(
        of english: CaptionDocument,
        to language: CaptionLanguage,
        llmService: LLMServiceProtocol,
        protectedTerms: [String],
        onProgress: SubtitleTranslator.ProgressHandler? = nil
    ) async -> (document: CaptionDocument, untranslatedCues: [Int]) {
        guard let target = language.translationTarget else { return (english, []) }
        let translator = SubtitleTranslator(llmService: llmService, protectedTerms: protectedTerms)
        let result = await translator.translate(cues: english.fileCues, to: target, config: config, onProgress: onProgress)
        let document = CaptionDocument(transcriptionID: english.transcriptionID, language: language, fileCues: result.cues, isDraft: true)
        return (document, result.untranslatedCues)
    }
}
