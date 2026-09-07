import SwiftUI
import MacParakeetCore
import MacParakeetViewModels

/// Source attribution for a Library row or card, drawn at the level the
/// surrounding context leaves open.
///
/// Both the grid card and the list row render source the same way, so the
/// decision lives here rather than being restated at each call site.
///
/// The text is dropped only where a real brand mark replaces it. The SF Symbol
/// fallback cannot carry a source on its own — seven of the sources reachable
/// under the Video filter share `play.rectangle.fill` and differ only by tint,
/// which names nothing to a reader who cannot separate those colors — so
/// anything without a bundled mark keeps its word.
struct TranscriptionSourceLabel: View {
    let source: TranscriptionSourceDisplay
    let style: LibrarySourceLabelStyle
    var font: Font = DesignSystem.Typography.caption
    var markSize: CGFloat = 11

    /// A brand mark stands in for the text only when we actually ship one for
    /// this source *and* the context has already narrowed the family.
    private var brandMark: MediaPlatform? {
        guard style == .brandMarkOnly else { return nil }
        guard let platform = source.brandedPlatform else { return nil }
        guard BrandGlyphImage.image(for: platform) != nil else { return nil }
        return platform
    }

    var body: some View {
        switch style {
        case .hidden:
            EmptyView()
        case .visible, .brandMarkOnly:
            if let platform = brandMark {
                PlatformGlyph(platform: platform, color: source.tint)
                    .frame(width: markSize, height: markSize)
                    // PlatformGlyph hides itself from accessibility, so the
                    // name a sighted reader gets from the logo is restored
                    // here rather than lost with the text.
                    .accessibilityElement()
                    .accessibilityLabel(source.collapsedText)
            } else {
                Label(source.collapsedText, systemImage: source.systemImage)
                    .font(font)
                    .foregroundStyle(source.tint)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
    }
}
