import AppKit
import MacParakeetCore

/// Loads the bundled monochrome brand marks (single-path vector PDFs in
/// `Resources/BrandGlyphs`) as tintable **template** images.
///
/// Template rendering means the alpha silhouette is the mask and the fill color is
/// supplied by the view (`.foregroundStyle`), so one asset serves every state: a
/// dim chip while idle, the full brand color when a URL is recognized, and a visible
/// tint for marks that are near-black at rest (X, TikTok) on a dark surface.
///
/// Provenance and trademark notes: `Resources/BrandGlyphs/README.md`.
@MainActor
enum BrandGlyphImage {
    /// All bundled marks, loaded once. A platform with no bundled asset is absent —
    /// `PlatformGlyph` falls back to its hand-drawn globe.
    static let byPlatform: [MediaPlatform: NSImage] = {
        var images: [MediaPlatform: NSImage] = [:]
        // SPM `.process` flattens resource subdirectories, so the marks (authored
        // under Resources/BrandGlyphs/) resolve by basename at the bundle root.
        for platform in MediaPlatform.allCases {
            guard let url = Bundle.module.url(forResource: resourceName(for: platform),
                                              withExtension: "pdf"),
                  let image = NSImage(contentsOf: url) else { continue }
            image.isTemplate = true
            images[platform] = image
        }
        return images
    }()

    static func image(for platform: MediaPlatform) -> NSImage? {
        byPlatform[platform]
    }

    /// Asset basename for a platform (matches the SoundCloud/Apple-Podcasts simple-
    /// icons slugs, which differ from the enum case names).
    private static func resourceName(for platform: MediaPlatform) -> String {
        switch platform {
        case .youtube: return "youtube"
        case .x: return "x"
        case .vimeo: return "vimeo"
        case .facebook: return "facebook"
        case .tiktok: return "tiktok"
        case .instagram: return "instagram"
        case .applePodcasts: return "applepodcasts"
        case .soundcloud: return "soundcloud"
        case .twitch: return "twitch"
        }
    }
}
