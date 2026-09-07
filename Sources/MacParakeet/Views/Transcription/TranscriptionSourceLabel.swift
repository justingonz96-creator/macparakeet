import SwiftUI
import MacParakeetViewModels

/// Source attribution for a Library row or card, drawn only where the
/// surrounding context leaves the source open.
///
/// Both the grid card and the list row render source the same way, so the
/// decision lives here rather than being restated at each call site.
///
/// The text is never dropped while the glyph stays. Seven of the sources
/// reachable under the Video filter share `play.rectangle.fill` and differ
/// only by tint, so an icon on its own would name no platform — and would
/// name nothing at all to a reader who cannot separate those tints. Hiding
/// the label entirely is honest; hiding only its text is not.
struct TranscriptionSourceLabel: View {
    let source: TranscriptionSourceDisplay
    let style: LibrarySourceLabelStyle
    var font: Font = DesignSystem.Typography.caption

    var body: some View {
        switch style {
        case .hidden:
            EmptyView()
        case .visible:
            Label(source.collapsedText, systemImage: source.systemImage)
                .font(font)
                .foregroundStyle(source.tint)
                .lineLimit(1)
                .fixedSize()
        }
    }
}
