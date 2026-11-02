import AppKit
import MacParakeetCore
import SwiftUI

/// One class: the video with captions where Premiere will place them, the
/// whole-class caption strip, the caption list with checks, an editor for
/// the selected caption, languages, and export for Premiere.
struct ClassWorkspaceView: View {
    @State var model: ClassWorkspaceModel
    let onBack: () -> Void

    @State private var draftText = ""
    @FocusState private var editorFocused: Bool
    @State private var exportMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(DesignSystem.Colors.divider)
            HStack(spacing: 0) {
                stage
                Divider().overlay(DesignSystem.Colors.divider)
                captionPanel.frame(width: 420)
            }
        }
        .background(DesignSystem.Colors.background)
        // Video, caption list and editor side by side need a real window.
        .frame(minWidth: 960, minHeight: 680)
        .task { await model.load() }
        .onChange(of: model.player.currentTimeMs) { _, _ in model.followPlayhead() }
        .onChange(of: model.selectedCueID) { old, _ in
            commitDraft(for: old)
            draftText = model.selectedCue?.text ?? ""
        }
        .onChange(of: model.language) { _, _ in draftText = model.selectedCue?.text ?? "" }
        .onDisappear { model.player.cleanup() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Button(action: onBack) { Image(systemName: "chevron.left") }
                .buttonStyle(.bordered)
                .help("Back to classes")
                .keyboardShortcut("[", modifiers: .command)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.transcription.effectiveDisplayTitle)
                    .font(.system(size: 17, weight: .semibold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(DesignSystem.Colors.textTertiary)
            }
            if model.document != nil {
                CaptionCheckPill(errors: model.errorCount, toCheck: model.reviewCount)
            }
            Spacer()
            Picker("Language", selection: $model.language) {
                ForEach(CaptionLanguage.allCases) { language in
                    Text(language.displayName + (model.documents[language]?.isDraft == true ? " ·" : "")).tag(language)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 270)
            .help("German and Spanish marked · are AI drafts waiting for a native speaker's review")
            exportMenu
        }
        .padding(.horizontal, 20)
        .frame(height: 56)
        .background(DesignSystem.Colors.surface.opacity(0.6))
    }

    private var subtitle: String {
        var parts: [String] = []
        if let ms = model.transcription.durationMs { parts.append(CaptionStrip.clock(ms)) }
        parts.append("\(model.cues.count) captions")
        parts.append(model.document?.usedAILayout == true ? "AI layout" : "Echelon caption style")
        return parts.joined(separator: " · ")
    }

    private var exportMenu: some View {
        Menu {
            Button("\(model.language.displayName) captions (SRT)…") { export([model.language], vtt: false) }
                .disabled(model.document == nil)
            Button("All languages (SRT)…") { export(CaptionLanguage.allCases, vtt: false) }
            Button("All languages (SRT + VTT)…") { export(CaptionLanguage.allCases, vtt: true) }
        } label: {
            Label("Export for Premiere", systemImage: "square.and.arrow.down")
        }
        .menuStyle(.borderedButton)
        .tint(DesignSystem.Colors.accentDark)
        .fixedSize()
        .alert("Exported", isPresented: Binding(get: { exportMessage != nil }, set: { if !$0 { exportMessage = nil } })) {
            Button("OK") { exportMessage = nil }
        } message: {
            Text(exportMessage ?? "")
        }
    }

    private func export(_ languages: [CaptionLanguage], vtt: Bool) {
        commitDraft(for: model.selectedCueID)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.message = "Choose the folder for the caption files"
        panel.directoryURL = model.defaultExportFolder
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        do {
            let files = try model.export(languages: languages, includeVTT: vtt, to: folder)
            exportMessage = files.map(\.lastPathComponent).joined(separator: "\n") + "\n\nin \(folder.path)"
            NSWorkspace.shared.activateFileViewerSelecting(files)
        } catch {
            exportMessage = "Couldn't write the files: \(error.localizedDescription)"
        }
    }

    // MARK: Stage

    private var stage: some View {
        VStack(alignment: .leading, spacing: 12) {
            video
            transport
            CaptionStrip(
                cues: model.cues,
                flags: model.flaggedIndices,
                durationMs: max(model.player.durationMs, model.transcription.durationMs ?? 0),
                playheadMs: model.player.currentTimeMs,
                onSeek: { ms in
                    model.player.seek(toMs: ms)
                    if let cue = model.cues.last(where: { $0.startMs <= ms }) { model.select(cue.id, seek: false) }
                }
            )
            legend
            inspector
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var video: some View {
        GeometryReader { geometry in
            let size = fitted(in: geometry.size)
            ZStack(alignment: .topLeading) {
                PlayerSurface(player: model.player.player)
                EchelonCaptionOverlay(text: model.currentCue?.text ?? model.selectedCue?.text, videoHeight: size.height)
                    .position(x: size.width / 2, y: size.height * 0.525 + captionHalfHeight(size.height))
                Text("Caption shown as Premiere will place it")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 4).fill(.black.opacity(0.45)))
                    .padding(10)
            }
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minHeight: 220, maxHeight: 460)
    }

    /// The overlay is positioned by its centre; Echelon's box starts at 52.5%.
    private func captionHalfHeight(_ videoHeight: CGFloat) -> CGFloat {
        videoHeight * 0.045 * 1.3
    }

    private func fitted(in available: CGSize) -> CGSize {
        let aspect = model.videoAspect
        let width = min(available.width, available.height * aspect)
        return CGSize(width: width, height: width / aspect)
    }

    private var transport: some View {
        HStack(spacing: 12) {
            Button { model.player.togglePlayPause() } label: {
                Image(systemName: model.player.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.bordered)
            .keyboardShortcut(.space, modifiers: [])
            .help(model.player.isPlaying ? "Pause (Space)" : "Play (Space)")
            Text(Timecode.string(model.player.currentTimeMs))
                .font(.system(size: 13, weight: .medium, design: .monospaced))
            + Text(" / " + Timecode.string(max(model.player.durationMs, model.transcription.durationMs ?? 0)))
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundColor(DesignSystem.Colors.textTertiary)
            Spacer()
            Text("Space plays · ↑↓ moves between captions")
                .font(.system(size: 12))
                .foregroundStyle(DesignSystem.Colors.textTertiary)
        }
    }

    private var legend: some View {
        HStack(spacing: 16) {
            legendItem(Color(red: 0.27, green: 0.34, blue: 0.42), "Caption")
            legendItem(DesignSystem.Colors.warningAmber, "Worth a look")
            legendItem(DesignSystem.Colors.errorRed, "Breaks a caption rule")
        }
        .font(.system(size: 12))
        .foregroundStyle(DesignSystem.Colors.textTertiary)
    }

    private func legendItem(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
            Text(label)
        }
    }

    // MARK: Inspector

    @ViewBuilder
    private var inspector: some View {
        if let cue = model.selectedCue, let index = model.selectedIndex {
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("Caption \(index + 1)").font(.system(size: 14, weight: .semibold))
                        Text("\(Self.seconds(cue.startMs)) → \(Self.seconds(cue.endMs))")
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(DesignSystem.Colors.textTertiary)
                    }
                    TextEditor(text: $draftText)
                        .font(.system(size: 16))
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .frame(height: 64)
                        .background(RoundedRectangle(cornerRadius: 6).fill(DesignSystem.Colors.background))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(editorFocused ? DesignSystem.Colors.accent.opacity(0.6) : DesignSystem.Colors.border))
                        .focused($editorFocused)
                        .onChange(of: editorFocused) { _, focused in if !focused { commitDraft(for: cue.id) } }
                        .accessibilityLabel("Caption text")
                    measures(for: draftText.isEmpty ? cue.text : draftText, cue: cue)
                    HStack(spacing: 8) {
                        Button { model.playSelected() } label: { Label("Play this caption", systemImage: "play") }
                        Button("Split") { commitDraft(for: cue.id); model.splitSelected() }
                        Button("Merge with next") { commitDraft(for: cue.id); model.mergeSelectedWithNext() }
                            .disabled(index + 1 >= model.cues.count)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                Divider().overlay(DesignSystem.Colors.divider)
                VStack(alignment: .leading, spacing: 12) {
                    Text("Timing").font(.system(size: 12, weight: .semibold)).foregroundStyle(DesignSystem.Colors.textSecondary)
                    timingRow("In", ms: cue.startMs, edge: .start)
                    timingRow("Out", ms: cue.endMs, edge: .end)
                    Text("Nudges move one video frame. Fixes made here go into every export.")
                        .font(.system(size: 12))
                        .foregroundStyle(DesignSystem.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(14)
                .frame(width: 250, alignment: .leading)
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(DesignSystem.Colors.surface))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(DesignSystem.Colors.divider))
        }
    }

    private func measures(for text: String, cue: CaptionDocumentCue) -> some View {
        let lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let characters = lines.joined(separator: " ").count
        let seconds = Double(cue.endMs - cue.startMs) / 1000
        let cps = seconds > 0 ? Double(characters) / seconds : 0
        let overBudget = characters > model.config.maxCharsPerLine
        let lineTooLong = lines.contains { $0.count > model.config.maxCharsPerLine }
        return HStack(spacing: 18) {
            (Text("\(characters)").bold().foregroundColor(overBudget ? DesignSystem.Colors.warningAmber : DesignSystem.Colors.textPrimary)
                + Text(" / \(model.config.maxCharsPerLine) characters"))
            (Text(String(format: "%.0f", cps)).bold().foregroundColor(cps > 30 ? DesignSystem.Colors.warningAmber : DesignSystem.Colors.textPrimary)
                + Text(" characters a second"))
            (Text(String(format: "%.2f s", seconds)).bold().foregroundColor(DesignSystem.Colors.textPrimary) + Text(" on screen"))
            (Text("Lines ") + Text(lines.map { "\($0.count)" }.joined(separator: " + ")).bold()
                .foregroundColor(lineTooLong || lines.count > model.config.maxLinesPerCue ? DesignSystem.Colors.errorRed : DesignSystem.Colors.textPrimary))
        }
        .font(.system(size: 12).monospacedDigit())
        .foregroundStyle(DesignSystem.Colors.textSecondary)
    }

    private func timingRow(_ label: String, ms: Int, edge: CaptionDocument.CueEdge) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 12)).foregroundStyle(DesignSystem.Colors.textTertiary).frame(width: 30, alignment: .leading)
            Text(Timecode.string(ms)).font(.system(size: 13, weight: .medium, design: .monospaced))
            Spacer()
            ControlGroup {
                Button { model.nudge(edge, frames: -1) } label: { Image(systemName: "minus") }
                    .help("One frame earlier")
                Button { model.nudge(edge, frames: 1) } label: { Image(systemName: "plus") }
                    .help("One frame later")
            }
            .controlSize(.small)
            .frame(width: 64)
        }
    }

    private func commitDraft(for id: UUID?) {
        guard let id, model.cues.contains(where: { $0.id == id }) else { return }
        let text = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        model.setText(text, forCue: id)
    }

    static func seconds(_ ms: Int) -> String {
        String(format: "%d:%02d.%03d", ms / 60_000, ms / 1000 % 60, ms % 1000)
    }

    // MARK: Caption panel

    private var captionPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                panelTab("All captions", count: model.cues.count, active: !model.showOnlyFlagged, tone: .quiet) { model.showOnlyFlagged = false }
                panelTab("To check", count: model.flaggedIndices.count, active: model.showOnlyFlagged, tone: .amber) { model.showOnlyFlagged = true }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            Divider().overlay(DesignSystem.Colors.divider)
            panelStatus
            Divider().overlay(DesignSystem.Colors.divider)
            if model.document == nil {
                emptyLanguage
            } else {
                cueList
            }
        }
        .background(DesignSystem.Colors.surface.opacity(0.6))
    }

    private func panelTab(_ title: String, count: Int, active: Bool, tone: EchelonPill.Tone, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text("\(count)").font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(tone == .amber && count > 0 ? DesignSystem.Colors.warningAmber : DesignSystem.Colors.textTertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .foregroundStyle(active ? DesignSystem.Colors.textPrimary : DesignSystem.Colors.textSecondary)
            .overlay(alignment: .bottom) {
                Rectangle().fill(active ? DesignSystem.Colors.accent : .clear).frame(height: 2)
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var panelStatus: some View {
        switch model.job {
        case .working(let title, let detail, let progress):
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(DesignSystem.Colors.textTertiary)
                if let progress { ProgressView(value: progress).tint(DesignSystem.Colors.accent) } else { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(DesignSystem.Colors.warningAmber)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .idle:
            if let document = model.document {
                HStack(spacing: 10) {
                    if model.errorCount == 0 {
                        EchelonPill(text: "Passes rules", tone: .green)
                    } else {
                        EchelonPill(text: "Breaks rules", tone: .red)
                    }
                    Text("\(model.errorCount) errors · \(model.reviewCount) to check")
                        .font(.system(size: 12))
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                    Spacer()
                    if document.isDraft {
                        Button("Mark reviewed") { model.markReviewed() }
                            .controlSize(.small)
                            .help("A native speaker has checked this translation")
                    } else if model.language == .en, !document.usedAILayout, model.aiAvailable {
                        Button("Improve with AI") { Task { await model.buildEnglish(withAI: true) } }
                            .controlSize(.small)
                            .help("Let the AI model choose where captions break. Runs on this Mac.")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
    }

    private var emptyLanguage: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "character.bubble").font(.system(size: 28)).foregroundStyle(DesignSystem.Colors.accent)
            Text("No \(model.language.displayName) captions yet").font(.system(size: 15, weight: .semibold))
            Text("Echo translates the English captions and keeps every caption's timing, so the file lines up in Premiere. A native speaker should review the draft.")
                .font(.system(size: 13))
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            if model.aiAvailable {
                Button("Translate to \(model.language.displayName)") {
                    let language = model.language
                    Task { await model.translate(to: language) }
                }
                .buttonStyle(.borderedProminent)
                .tint(DesignSystem.Colors.accentDark)
                .disabled(model.documents[.en] == nil || model.job != .idle)
                Text("Runs on this Mac. About 3–8 minutes for a 20-minute class.")
                    .font(.system(size: 12))
                    .foregroundStyle(DesignSystem.Colors.textTertiary)
            } else {
                Text("Set up a caption AI model in Settings → AI to translate.")
                    .font(.system(size: 12))
                    .foregroundStyle(DesignSystem.Colors.warningAmber)
            }
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }

    private var cueList: some View {
        let flags = model.flaggedIndices
        let rows = model.cues.enumerated().filter { !model.showOnlyFlagged || flags[$0.offset] != nil }
        return ScrollViewReader { proxy in
            List(selection: Binding(get: { model.selectedCueID }, set: { if let id = $0 { model.select(id) } })) {
                ForEach(rows, id: \.element.id) { index, cue in
                    CueRow(
                        index: index,
                        cue: cue,
                        unsureWords: model.unsureWordsByCue[cue.id] ?? [],
                        issues: model.issues(forCueAt: index)
                    )
                    .tag(cue.id)
                    .id(cue.id)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .onChange(of: model.selectedCueID) { _, id in
                guard let id else { return }
                // Unanimated: a long jump (strip click, playback) through a
                // lazy list stops short when animated.
                DispatchQueue.main.async { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }
}

private struct CueRow: View {
    let index: Int
    let cue: CaptionDocumentCue
    let unsureWords: [String]
    let issues: [CaptionQualityIssue]

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 0) {
                Text("\(index + 1)")
                Text(CaptionStrip.clock(cue.startMs))
            }
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(DesignSystem.Colors.textTertiary)
            .frame(width: 40, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                Text(attributed)
                    .font(.system(size: 13.5))
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                if !unsureWords.isEmpty || !issues.isEmpty {
                    FlowPills(unsureWords: unsureWords, issues: issues)
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var attributed: AttributedString {
        var text = AttributedString(cue.lines.joined(separator: " "))
        for word in unsureWords where !word.isEmpty {
            var searchStart = text.startIndex
            while let range = text[searchStart...].range(of: word) {
                text[range].underlineStyle = Text.LineStyle(pattern: .dot, color: DesignSystem.Colors.warningAmber)
                searchStart = range.upperBound
            }
        }
        return text
    }
}

private struct FlowPills: View {
    let unsureWords: [String]
    let issues: [CaptionQualityIssue]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
                EchelonPill(text: issue.message, tone: issue.severity == .error ? .red : .amber)
            }
            if !unsureWords.isEmpty {
                EchelonPill(
                    text: unsureWords.count == 1 ? "Not sure it heard \"\(unsureWords[0])\" right" : "\(unsureWords.count) unclear words",
                    tone: .amber
                )
            }
        }
    }
}
