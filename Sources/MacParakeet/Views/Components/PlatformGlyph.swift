import SwiftUI
import MacParakeetCore

/// A recolorable, single-color mark for a media platform.
///
/// Known platforms render their **real** brand mark from a bundled monochrome vector
/// PDF (`BrandGlyphImage`), tinted as a template image so it dims when idle and blooms
/// to brand color on recognition. A `nil` (or asset-less) platform renders a neutral
/// hand-drawn globe ("any website"). Vector + template means the mark is crisp at any
/// size and the orbit moves it as a layer transform — no per-frame re-rasterization.
struct PlatformGlyph: View {
    let platform: MediaPlatform?
    var color: Color = .primary

    var body: some View {
        Group {
            if let platform, let image = BrandGlyphImage.image(for: platform) {
                Image(nsImage: image)
                    .resizable()
                    .renderingMode(.template)
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(color)
            } else {
                GenericGlobe(color: color)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Neutral "any website" mark for unrecognized links. Hand-drawn (no brand asset).
private struct GenericGlobe: View {
    var color: Color

    var body: some View {
        Canvas { ctx, size in
            let r = CGRect(origin: .zero, size: size)
                .insetBy(dx: size.width * 0.07, dy: size.height * 0.07)
            let lw = r.width * 0.08
            ctx.stroke(Path(ellipseIn: r.insetBy(dx: lw / 2, dy: lw / 2)),
                       with: .color(color), style: StrokeStyle(lineWidth: lw))
            var equator = Path()
            equator.move(to: CGPoint(x: r.minX + r.width * 0.06, y: r.midY))
            equator.addLine(to: CGPoint(x: r.minX + r.width * 0.94, y: r.midY))
            ctx.stroke(equator, with: .color(color), style: StrokeStyle(lineWidth: lw * 0.8))
            let meridian = CGRect(x: r.midX - r.width * 0.18, y: r.minY + lw / 2,
                                  width: r.width * 0.36, height: r.height - lw)
            ctx.stroke(Path(ellipseIn: meridian), with: .color(color), style: StrokeStyle(lineWidth: lw * 0.8))
        }
    }
}

// MARK: - Brand tint mapping

extension MediaPlatform {
    /// The brand tint used when this platform's glyph "blooms" to color.
    var brandTint: Color {
        switch self {
        case .youtube: return DesignSystem.Colors.youtubeRed
        case .x: return DesignSystem.Colors.xMark
        case .vimeo: return DesignSystem.Colors.vimeoBlue
        case .facebook: return DesignSystem.Colors.facebookBlue
        case .tiktok: return DesignSystem.Colors.tiktokTeal
        case .instagram: return DesignSystem.Colors.instagramPink
        case .applePodcasts: return DesignSystem.Colors.podcastPurple
        case .soundcloud: return DesignSystem.Colors.warningAmber
        case .twitch: return DesignSystem.Colors.twitchPurple
        }
    }
}

#if DEBUG
#Preview("Platform glyphs") {
    let platforms: [MediaPlatform] = [
        .youtube, .x, .vimeo, .facebook, .tiktok, .instagram, .applePodcasts,
        .soundcloud, .twitch,
    ]
    return VStack(spacing: 24) {
        HStack(spacing: 20) {
            ForEach(platforms, id: \.self) { p in
                VStack {
                    PlatformGlyph(platform: p, color: p.brandTint)
                        .frame(width: 44, height: 44)
                    Text(p.displayName).font(.caption2)
                }
            }
            VStack {
                PlatformGlyph(platform: nil, color: .secondary)
                    .frame(width: 44, height: 44)
                Text("Other").font(.caption2)
            }
        }
        HStack(spacing: 20) {
            ForEach(platforms, id: \.self) { p in
                PlatformGlyph(platform: p, color: .primary)
                    .frame(width: 34, height: 34)
            }
        }
    }
    .padding(40)
}
#endif
