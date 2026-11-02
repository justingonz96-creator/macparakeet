import AppKit
import MacParakeetCore
import MacParakeetViewModels
import SwiftUI
import UniformTypeIdentifiers

/// Echo's home: drop one class video, watch it work, open a class to check
/// and export its captions.
struct ClassesView: View {
    let transcriptionViewModel: TranscriptionViewModel
    let llmService: LLMServiceProtocol?
    let protectedTerms: [String]

    @State private var openClass: Transcription?
    @State private var openWhenDone = false
    @State private var isDropTargeted = false
    @State private var summaries: [UUID: ClassSummary] = [:]

    var body: some View {
        if let openClass {
            ClassWorkspaceView(
                model: ClassWorkspaceModel(transcription: openClass, llmService: llmService, protectedTerms: protectedTerms),
                onBack: {
                    self.openClass = nil
                    refreshSummaries()
                }
            )
            .id(openClass.id)
        } else {
            home
        }
    }

    private var classes: [Transcription] {
        transcriptionViewModel.transcriptions.filter { $0.sourceType != .meeting }
    }

    private var home: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Classes").font(.system(size: 17, weight: .semibold))
                Spacer()
                Button { chooseFile() } label: { Label("Add class video", systemImage: "plus") }
                    .buttonStyle(.borderedProminent)
                    .tint(DesignSystem.Colors.accentDark)
                    .disabled(transcriptionViewModel.isTranscribing)
            }
            .padding(.horizontal, 20)
            .frame(height: 56)
            .background(DesignSystem.Colors.surface.opacity(0.6))
            Divider().overlay(DesignSystem.Colors.divider)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    dropZone
                    if transcriptionViewModel.isTranscribing { progressCard }
                    classList
                    if summaries.values.contains(where: { $0.languages.values.contains(.draft) }) {
                        Text("German and Spanish marked in amber are AI drafts waiting for a native speaker's review.")
                            .font(.system(size: 12))
                            .foregroundStyle(DesignSystem.Colors.textTertiary)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 22)
            }
        }
        .background(DesignSystem.Colors.background)
        .onAppear {
            transcriptionViewModel.loadTranscriptions()
            refreshSummaries()
        }
        .onChange(of: transcriptionViewModel.transcriptions.map(\.id)) { _, _ in refreshSummaries() }
        .onChange(of: transcriptionViewModel.isTranscribing) { _, busy in
            guard !busy, openWhenDone else { return }
            openWhenDone = false
            transcriptionViewModel.loadTranscriptions()
            if let finished = transcriptionViewModel.currentTranscription {
                openClass = finished
            }
        }
    }

    // MARK: Drop zone

    private var dropZone: some View {
        HStack(spacing: 18) {
            Image(systemName: "square.and.arrow.down")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(DesignSystem.Colors.accent)
                .frame(width: 44, height: 44)
                .background(RoundedRectangle(cornerRadius: 10).fill(DesignSystem.Colors.accentLight))
            VStack(alignment: .leading, spacing: 2) {
                Text("Drop a class video to caption it").font(.system(size: 15, weight: .semibold))
                Text("Raw studio files are transcribed from the instructor mic only, so music lyrics stay out of the captions.")
                    .font(.system(size: 13))
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
            Spacer()
            Button("Choose file…") { chooseFile() }
                .buttonStyle(.bordered)
                .disabled(transcriptionViewModel.isTranscribing)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .background(RoundedRectangle(cornerRadius: 10).fill(isDropTargeted ? DesignSystem.Colors.accentLight : DesignSystem.Colors.surface))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isDropTargeted ? DesignSystem.Colors.accent : DesignSystem.Colors.border, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
        )
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in start(url) }
            }
            return true
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .audio]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a class video to caption"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        start(url)
    }

    private func start(_ url: URL) {
        guard !transcriptionViewModel.isTranscribing else { return }
        openWhenDone = true
        transcriptionViewModel.transcribeFile(url: url)
    }

    // MARK: Progress

    private var progressCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "waveform")
                    .font(.system(size: 18))
                    .foregroundStyle(DesignSystem.Colors.accent)
                    .frame(width: 44, height: 44)
                    .background(RoundedRectangle(cornerRadius: 8).fill(DesignSystem.Colors.surfaceElevated))
                VStack(alignment: .leading, spacing: 2) {
                    Text(transcriptionViewModel.progressHeadline).font(.system(size: 14, weight: .semibold))
                    Text(transcriptionViewModel.progressSubline ?? transcriptionViewModel.progress)
                        .font(.system(size: 12))
                        .foregroundStyle(DesignSystem.Colors.textTertiary)
                        .lineLimit(1)
                }
                Spacer()
                Button("Stop") { transcriptionViewModel.cancelTranscription() }
                    .buttonStyle(.bordered)
            }
            .padding(16)
            Divider().overlay(DesignSystem.Colors.divider)
            HStack(spacing: 0) {
                step("Listening", detail: "Speech engine", state: .now, progress: transcriptionViewModel.transcriptionProgress)
                Divider().overlay(DesignSystem.Colors.divider)
                step("Laying out captions", detail: "Echelon caption rules", state: .next, progress: 0)
                Divider().overlay(DesignSystem.Colors.divider)
                step("Checking", detail: "Opens the class when done", state: .next, progress: 0)
            }
            .frame(height: 74)
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(DesignSystem.Colors.surface))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(DesignSystem.Colors.divider))
    }

    private enum StepState { case done, now, next }

    private func step(_ title: String, detail: String, state: StepState, progress: Double?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: state == .done ? "checkmark" : "circle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(state == .next ? DesignSystem.Colors.textTertiary : DesignSystem.Colors.textPrimary)
            Text(detail).font(.system(size: 12)).foregroundStyle(DesignSystem.Colors.textTertiary)
            Group {
                if state == .now, progress == nil {
                    ProgressView().progressViewStyle(.linear)
                } else {
                    ProgressView(value: state == .done ? 1 : (progress ?? 0))
                }
            }
            .tint(state == .done ? DesignSystem.Colors.successGreen : DesignSystem.Colors.accent)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: List

    @ViewBuilder
    private var classList: some View {
        if classes.isEmpty {
            VStack(spacing: 6) {
                Text("No classes yet").font(.system(size: 15, weight: .semibold))
                Text("Drop a class video above. Echo transcribes it, lays out the captions with Echelon's rules, checks them, and opens the class for review.")
                    .font(.system(size: 13))
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
        } else {
            VStack(spacing: 0) {
                HStack(spacing: 16) {
                    Text("Class").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Captions").frame(width: 190, alignment: .leading)
                    Text("Languages").frame(width: 110, alignment: .leading)
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DesignSystem.Colors.textTertiary)
                .padding(.horizontal, 16)
                .frame(height: 34)
                .background(DesignSystem.Colors.surface.opacity(0.6))
                ForEach(classes) { transcription in
                    Divider().overlay(DesignSystem.Colors.divider)
                    ClassRow(transcription: transcription, summary: summaries[transcription.id]) {
                        openClass = transcription
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(DesignSystem.Colors.surface))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(DesignSystem.Colors.divider))
        }
    }

    private func refreshSummaries() {
        let store = CaptionDocumentStore()
        let items = classes.map { ($0.id, $0.wordTimestamps ?? []) }
        let terms = protectedTerms
        Task.detached(priority: .utility) {
            var result: [UUID: ClassSummary] = [:]
            for (id, words) in items {
                result[id] = ClassSummary.load(id, words: words, protectedTerms: terms, store: store)
            }
            await MainActor.run { summaries = result }
        }
    }
}

struct ClassSummary: Sendable {
    let errors: Int
    let toCheck: Int
    let hasEnglish: Bool
    let languages: [CaptionLanguage: LanguageChip.State]

    /// Same counting as the workspace: a caption counts once, as an error if
    /// it breaks a rule, otherwise as "to check" for a review flag or a word
    /// the engine was unsure about.
    static func load(_ id: UUID, words: [WordTimestamp], protectedTerms: [String], store: CaptionDocumentStore) -> ClassSummary {
        var languages: [CaptionLanguage: LanguageChip.State] = [:]
        var errors = 0
        var toCheck = 0
        var hasEnglish = false
        for language in CaptionLanguage.allCases {
            guard let document = store.load(id, language: language) else {
                languages[language] = LanguageChip.State.none
                continue
            }
            languages[language] = document.isDraft ? .draft : .done
            if language == .en {
                hasEnglish = true
                let report = document.check()
                let errorCues = Set(report.issues.filter { $0.severity == .error }.map(\.cue))
                var reviewCues = Set(report.issues.filter { $0.severity == .review }.map(\.cue))
                let unsure = UnsureWordDetector.unsureWords(in: words, protectedTerms: protectedTerms)
                for (offset, cue) in document.cues.enumerated()
                where unsure.contains(where: { $0.startMs >= cue.startMs && $0.startMs < cue.endMs }) {
                    reviewCues.insert(offset + 1)
                }
                errors = errorCues.count
                toCheck = reviewCues.subtracting(errorCues).count
            }
        }
        return ClassSummary(errors: errors, toCheck: toCheck, hasEnglish: hasEnglish, languages: languages)
    }
}

private struct ClassRow: View {
    let transcription: Transcription
    let summary: ClassSummary?
    let onOpen: () -> Void
    @State private var hovering = false
    @State private var thumbnail: CGImage?

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 16) {
                HStack(spacing: 12) {
                    thumb
                    VStack(alignment: .leading, spacing: 2) {
                        Text(transcription.effectiveDisplayTitle)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        Text(detail)
                            .font(.system(size: 12))
                            .foregroundStyle(DesignSystem.Colors.textTertiary)
                            .lineLimit(1)
                    }
                }
                .frame(minWidth: 200, maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)
                Group {
                    if let summary, summary.hasEnglish {
                        CaptionCheckPill(errors: summary.errors, toCheck: summary.toCheck)
                    } else {
                        EchelonPill(text: "Not laid out yet", tone: .quiet)
                    }
                }
                .frame(width: 190, alignment: .leading)
                HStack(spacing: 5) {
                    ForEach(CaptionLanguage.allCases) { language in
                        LanguageChip(language: language, state: summary?.languages[language] ?? LanguageChip.State.none)
                    }
                }
                .frame(width: 110, alignment: .leading)
            }
            .padding(.horizontal, 16)
            .frame(height: 70)
            .contentShape(Rectangle())
            .background(hovering ? DesignSystem.Colors.surfaceElevated : .clear)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .task(id: transcription.id) { await loadThumbnail() }
        .accessibilityLabel("Open \(transcription.effectiveDisplayTitle)")
    }

    private var detail: String {
        var parts: [String] = []
        if let ms = transcription.durationMs { parts.append(CaptionStrip.clock(ms)) }
        parts.append(transcription.createdAt.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var thumb: some View {
        let image = thumbnail ?? LibraryThumbnailStore.shared.cachedImage(for: transcription.id)
        ZStack {
            RoundedRectangle(cornerRadius: 5).fill(Color.black)
            if let image {
                Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "film").foregroundStyle(DesignSystem.Colors.textTertiary)
            }
        }
        .frame(width: 96, height: 54)
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    private func loadThumbnail() async {
        guard thumbnail == nil, let source = LibraryThumbnailStore.shared.source(for: transcription) else { return }
        thumbnail = await LibraryThumbnailStore.shared.image(for: transcription.id, from: source)
    }
}
