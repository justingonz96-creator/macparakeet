# URL Transcription — Any Platform (multi-platform) + Recognition UI

> Status: **IMPLEMENTED** · Shipped in PR #467 (squash-merged 2026-06-09, `1c27de8`) · Follow-up to PR #457 (X support)

## Goal

Two parts:

1. **Accept any media URL.** Today the GUI's Transcribe button only lights up for
   YouTube / X / Apple Podcasts, even though the bundled `yt-dlp` download path
   already handles any media URL (Vimeo, Facebook, TikTok, Instagram, …). Stop
   gating: paste anything plausible, the button enables, yt-dlp tries it, failures
   surface in the existing error banner (same contract the CLI already honors).
   **No allowlist** (owner direction 2026-06-08, overriding the earlier PR #457
   note). The CLI is already permissive — unchanged.

2. **Enterprise-grade URL card UX.** Replace the muddy static SF-Symbol cluster
   with clean, recolorable vector brand glyphs and a live **orbiting constellation**
   hero: glyphs slowly orbit a core; when a recognized URL is pasted, the matched
   platform's glyph flies to focus and blooms to its brand color. Rename the entry
   points ("Transcribe Video…" → "Transcribe YouTube & more"). Update placeholder /
   caption copy.

## Non-goals / invariants

- **Do not change the download/transcription pipeline** — `YouTubeDownloader` +
  `yt-dlp` already handle arbitrary URLs. No new download code.
- **Keep podcast routing** (`PodcastURLValidator` → iTunes resolver) and **YouTube
  videoID dedup** (`YouTubeURLValidator.extractVideoID`) exactly as-is.
- **CLI public contract unchanged** — it already accepts any downloadable URL.
- The idle orbit is fully static — zero continuous animation, so the Transcribe tab
  costs no CPU and cannot jitter (protects the app's low-idle-CPU ethos; cf. issue
  #107). Motion is on intent only: one eased revolution on hover and a bloom on a
  match, both gated by Reduce Motion. (A continuous `repeatForever` `.rotationEffect`
  was tried and *measured* at ~17% CPU — SwiftUI drives a per-frame main-thread
  display-list regeneration for it, not a free render-server transform — so it was
  dropped.)
- Real platform marks, not hand-drawn approximations: single-path brand glyphs from
  [Simple Icons](https://simpleicons.org) (icon set CC0) shipped as monochrome vector
  PDFs (`Resources/BrandGlyphs/`) and tinted as template images (`BrandGlyphImage`).
  Brand trademarks belong to their owners and are used nominatively (provenance:
  `Resources/BrandGlyphs/README.md`).

## Architecture

### Core (pure, testable — no SwiftUI)
- **NEW `MediaPlatform`** (`Sources/MacParakeetCore/Utilities/MediaPlatform.swift`):
  - `enum MediaPlatform` cases: youtube, x, vimeo, facebook, tiktok, instagram,
    applePodcasts, soundcloud, twitch, … (+ recognition by host).
  - `static func recognize(_ urlString:) -> MediaPlatform?` — host-based, best-effort.
  - `var displayName: String`.
  - `static func isTranscribable(_:) -> Bool` — the ONE permissive gate that
    replaces the 4 duplicated OR-chains (podcast OR any http(s) media OR
    scheme-less known host). Consolidation, not new abstraction.
  - `static func normalizedURLString(_:) -> String` — prepends `https://` to a
    scheme-less *recognized* host so the download layer (which requires a scheme)
    accepts everything the gate does.
- **Keep** `YouTubeURLValidator` (dedup), `PodcastURLValidator` (routing), and
  `DownloadableMediaURLValidator` (generic http(s)).
- **Delete** `XURLValidator` — accept-all obviates its strict `/status/` gate; X is
  recognized by host like every other platform.

### App / UI
- **NEW `PlatformGlyph`** (`Views/Components/PlatformGlyph.swift`): renders each
  platform's real brand mark from a bundled monochrome vector PDF, loaded as a
  tintable template image by **`BrandGlyphImage`** (`Views/Components/`). A hand-drawn
  globe covers the generic/unknown case.
- **NEW `MediaPlatformOrbitView`** (`Views/Transcription/MediaPlatformOrbitView.swift`):
  the constellation hero. Inputs: matched `MediaPlatform?`. Static at rest (zero CPU);
  one eased full revolution on hover; the matched mark blooms to the center on a
  match. All motion gated by `accessibilityReduceMotion`.
- **DesignSystem**: add brand tints (vimeoBlue, facebookBlue, tiktok, instagramPink;
  reuse youtubeRed/xMark/podcastPurple) + a `MediaPlatform → (tint, glyph)` mapping
  in the app layer.

### Wire-up (edits)
- `TranscribeView.swift` — swap icon cluster → orbit; permissive gate; copy.
- `YouTubeInputPanelView.swift` — compact reactive matched-glyph header; permissive
  gate; copy.
- `YouTubeInputPanelController.swift` — clipboard auto-paste uses permissive gate.
- `TranscriptionViewModel.swift` — `isValidURL` → `MediaPlatform.isTranscribableURL`;
  `transcribeURL()` placeholder name uses recognized `displayName` (routing intact).
- `TranscriptionSourceDisplay.swift` — derive richer library badges from
  `MediaPlatform.recognize` (Vimeo/TikTok/… instead of generic "Video").
- `MenuBarCoordinator.swift` (×2) — "Transcribe Video…" → "Transcribe YouTube & more…".

## Tests
- `MediaPlatformTests` — recognize() host mapping for all platforms + nil fallback;
  isTranscribableURL permissive accepts (vimeo/tiktok/ig/fb/yt/x/podcast/scheme-less)
  and rejects ("hello", empty, whitespace, non-URL).
- Update `TranscriptionViewModelTests` any case asserting non-YT/X/podcast URLs are
  invalid (now valid).
- `BrandGlyphImageTests` — every platform resolves a bundled template mark (guards the
  SPM `.process` flattening behavior; a regression silently degrades chips to globes).
- Keep existing validator tests green.

## Verification
- `swift test` green.
- Built + ran the app: real marks render in the orbit; idle Transcribe tab measured at
  **0% CPU** (was ~17% with the continuous rotation).
- Glyph/orbit fidelity verified via offscreen `ImageRenderer` snapshots of the bundled
  marks (idle, hover-revolve, bloom).
- Spot-check a Vimeo/TikTok download via CLI if network allows (not gating-critical).

## Docs
- spec/02-features.md F11, CLAUDE.md (mode #2 copy), traceability, README if user-visible.
