import SwiftUI
import MacParakeetViewModels

/// Source attribution for a Library row or card, drawn at the level the
/// surrounding context actually leaves open.
///
/// Both the grid card and the list row render source the same way, so the
/// decision lives here rather than being restated at each call site.
///
/// `style` says how much the context leaves unanswered; the resolved source
/// says whether its own glyph can carry the meaning alone. `.iconOnly`
/// degrades to icon-and-text for a source whose mark is a plain SF Symbol —
/// under Video, a SoundCloud upload is "Audio" and a Twitch VOD is "Video",
/// and a bare waveform would drop that distinction rather than tighten it.
struct TranscriptionSourceLabel: View {
    let source: TranscriptionSourceDisplay
    let style: LibrarySourceLabelStyle
    var font: Font = DesignSystem.Typography.caption

    var body: some View {
        switch style {
        case .hidden:
            EmptyView()
        case .full:
            label(showsText: true)
        case .iconOnly:
            label(showsText: source.markIsSelfEvident == false)
        }
    }

    private func label(showsText: Bool) -> some View {
        Label {
            if showsText {
                Text(source.collapsedText)
            }
        } icon: {
            Image(systemName: source.systemImage)
        }
        .labelStyle(.titleAndIcon)
        .font(font)
        .foregroundStyle(source.tint)
        .lineLimit(1)
        .fixedSize()
        // The text is dropped only because the glyph already says it; a
        // screen reader gets no glyph, so it always hears the full name.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(source.collapsedText)
    }
}
