import AVFoundation
import Foundation
import MacParakeetCore
import MacParakeetViewModels

/// State and actions for one class's caption workspace: the caption
/// documents per language, the checker report, the selected caption, the
/// player, and the long-running jobs (AI layout, translation).
@MainActor @Observable
final class ClassWorkspaceModel {
    enum Job: Equatable {
        case idle
        case working(title: String, detail: String, progress: Double?)
        case failed(String)
    }

    let transcription: Transcription
    let player = MediaPlayerViewModel()
    let config: SubtitleExportConfig = .echelon
    private let store: CaptionDocumentStore
    private let builder: CaptionBuilder
    private let llmService: LLMServiceProtocol?
    private let protectedTerms: [String]

    var language: CaptionLanguage = .en {
        didSet { refreshDerived() }
    }
    private(set) var documents: [CaptionLanguage: CaptionDocument] = [:]
    private(set) var report: CaptionQualityReport?
    /// Words the engine was unsure about, by English cue id.
    private(set) var unsureWordsByCue: [UUID: [String]] = [:]
    var selectedCueID: UUID?
    var showOnlyFlagged = false
    private(set) var job: Job = .idle
    private(set) var videoAspect: CGFloat = 16 / 9

    private var saveTask: Task<Void, Never>?

    init(
        transcription: Transcription,
        llmService: LLMServiceProtocol?,
        protectedTerms: [String],
        store: CaptionDocumentStore = CaptionDocumentStore()
    ) {
        self.transcription = transcription
        self.llmService = llmService
        self.protectedTerms = protectedTerms
        self.store = store
        self.builder = CaptionBuilder(config: .echelon)
    }

    var aiAvailable: Bool { llmService != nil }
    var document: CaptionDocument? { documents[language] }
    var cues: [CaptionDocumentCue] { document?.cues ?? [] }

    var selectedIndex: Int? {
        guard let id = selectedCueID else { return nil }
        return cues.firstIndex { $0.id == id }
    }

    var selectedCue: CaptionDocumentCue? {
        selectedIndex.map { cues[$0] }
    }

    /// Cue positions (0-based) that carry a checker issue or an unsure word.
    var flaggedIndices: [Int: CaptionQualityIssue.Severity] {
        var result: [Int: CaptionQualityIssue.Severity] = [:]
        for issue in report?.issues ?? [] {
            let index = issue.cue - 1
            if issue.severity == .error || result[index] == nil { result[index] = issue.severity }
        }
        for (index, cue) in cues.enumerated() where !(unsureWordsByCue[cue.id] ?? []).isEmpty {
            if result[index] == nil { result[index] = .review }
        }
        return result
    }

    var errorCount: Int { flaggedIndices.values.filter { $0 == .error }.count }
    var reviewCount: Int { flaggedIndices.values.filter { $0 == .review }.count }

    func issues(forCueAt index: Int) -> [CaptionQualityIssue] {
        (report?.issues ?? []).filter { $0.cue == index + 1 }
    }

    // MARK: - Loading

    func load() async {
        for language in CaptionLanguage.allCases {
            if let saved = store.load(transcription.id, language: language) {
                documents[language] = saved
            }
        }
        if documents[.en] == nil {
            await buildEnglish(withAI: false)
        }
        refreshDerived()
        selectedCueID = selectedCueID ?? cues.first?.id
        await player.load(for: transcription)
        await loadVideoAspect()
    }

    private func loadVideoAspect() async {
        guard let path = transcription.filePath else { return }
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let size = try? await track.load(.naturalSize),
              let transform = try? await track.load(.preferredTransform)
        else { return }
        let rect = CGRect(origin: .zero, size: size).applying(transform)
        if rect.height > 0 { videoAspect = abs(rect.width / rect.height) }
    }

    /// English captions from the transcript. Rule-based is instant; the AI
    /// layout runs in the background with progress.
    func buildEnglish(withAI: Bool) async {
        job = .working(
            title: withAI ? "Improving the layout with AI" : "Laying out captions",
            detail: withAI ? "Runs on this Mac. About 3–10 minutes for a class." : "Echelon caption rules",
            progress: nil
        )
        do {
            let builder = withAI ? self.builder : CaptionBuilder(config: rulesOnlyConfig)
            let document = try await builder.englishDocument(
                for: transcription,
                llmService: withAI ? llmService : nil
            ) { [weak self] progress in
                Task { @MainActor in
                    let phase = progress.phase == .layout ? "Laying out" : "Reviewing"
                    self?.job = .working(
                        title: "Improving the layout with AI",
                        detail: "\(phase) \(progress.completed) of \(progress.total)",
                        progress: progress.total > 0 ? Double(progress.completed) / Double(progress.total) : nil
                    )
                }
            }
            documents[.en] = document
            try store.save(document)
            selectedCueID = document.cues.first?.id
            job = .idle
        } catch {
            job = .failed("Couldn't make captions: \(error.localizedDescription)")
        }
        refreshDerived()
    }

    private var rulesOnlyConfig: SubtitleExportConfig {
        var config = self.config
        config.useLLMRefinement = false
        return config
    }

    // MARK: - Translation

    func translate(to language: CaptionLanguage) async {
        guard let english = documents[.en], let llmService else { return }
        job = .working(title: "Translating to \(language.displayName)", detail: "Runs on this Mac", progress: 0)
        let result = await builder.translation(
            of: english, to: language, llmService: llmService, protectedTerms: protectedTerms
        ) { [weak self] done, total in
            Task { @MainActor in
                self?.job = .working(
                    title: "Translating to \(language.displayName)",
                    detail: "Part \(done) of \(total)",
                    progress: total > 0 ? Double(done) / Double(total) : nil
                )
            }
        }
        documents[language] = result.document
        try? store.save(result.document)
        job = result.untranslatedCues.isEmpty
            ? .idle
            : .failed("\(result.untranslatedCues.count) captions stayed in English because translation kept failing. Edit them by hand or translate again.")
        if self.language == language { refreshDerived() }
    }

    func markReviewed() {
        guard var document else { return }
        document.isDraft = false
        commit(document)
    }

    // MARK: - Editing

    func setText(_ text: String, forCue id: UUID) {
        guard var document, document.cues.first(where: { $0.id == id })?.text != text else { return }
        document.setText(text, forCue: id, config: config)
        commit(document)
    }

    func nudge(_ edge: CaptionDocument.CueEdge, frames: Int) {
        guard var document, let id = selectedCueID else { return }
        document.nudge(cue: id, edge: edge, frames: frames, frameRate: config.snapToFrameRate ?? 29.97)
        commit(document)
    }

    func splitSelected() {
        guard var document, let id = selectedCueID else { return }
        document.split(cue: id, config: config)
        commit(document)
    }

    func mergeSelectedWithNext() {
        guard var document, let id = selectedCueID else { return }
        document.mergeWithNext(cue: id, config: config)
        commit(document)
    }

    private func commit(_ document: CaptionDocument) {
        documents[document.language] = document
        refreshDerived()
        saveTask?.cancel()
        saveTask = Task { [store] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            try? store.save(document)
        }
    }

    private func refreshDerived() {
        report = document?.check(config: config)
        unsureWordsByCue = [:]
        guard language == .en, let document, let words = transcription.wordTimestamps else { return }
        let unsure = UnsureWordDetector.unsureWords(in: words, protectedTerms: protectedTerms)
        guard !unsure.isEmpty else { return }
        for cue in document.cues {
            let inside = unsure.filter { $0.startMs >= cue.startMs && $0.startMs < cue.endMs }
                .map { $0.word.trimmingCharacters(in: CharacterSet(charactersIn: ".,?!:;\" ")) }
            if !inside.isEmpty { unsureWordsByCue[cue.id] = inside }
        }
    }

    // MARK: - Playback

    func select(_ id: UUID, seek: Bool = true) {
        selectedCueID = id
        if seek, let cue = cues.first(where: { $0.id == id }) {
            player.seek(toMs: cue.startMs)
        }
    }

    func playSelected() {
        guard let cue = selectedCue else { return }
        player.seek(toMs: cue.startMs)
        if !player.isPlaying { player.togglePlayPause() }
    }

    /// The caption on screen at the playhead, if any.
    var currentCue: CaptionDocumentCue? {
        let now = player.currentTimeMs
        return cues.last { $0.startMs <= now && now <= $0.endMs }
    }

    /// Follows the playhead while the video plays.
    func followPlayhead() {
        guard player.isPlaying, let cue = currentCue, cue.id != selectedCueID else { return }
        selectedCueID = cue.id
    }

    // MARK: - Export

    var exportBaseName: String {
        let title = transcription.effectiveDisplayTitle
        return (title as NSString).deletingPathExtension
    }

    /// Writes the chosen languages into `folder` as `<class>.<lang>.srt`
    /// (and `.vtt` when asked). Returns the files written.
    func export(languages: [CaptionLanguage], includeVTT: Bool, to folder: URL) throws -> [URL] {
        var written: [URL] = []
        for language in languages {
            guard let document = documents[language] else { continue }
            let srt = folder.appendingPathComponent("\(exportBaseName).\(language.rawValue).srt")
            try document.srt().write(to: srt, atomically: true, encoding: .utf8)
            written.append(srt)
            if includeVTT {
                let vtt = folder.appendingPathComponent("\(exportBaseName).\(language.rawValue).vtt")
                try document.vtt().write(to: vtt, atomically: true, encoding: .utf8)
                written.append(vtt)
            }
        }
        return written
    }

    var defaultExportFolder: URL? {
        transcription.filePath.map { URL(fileURLWithPath: $0).deletingLastPathComponent() }
    }
}
