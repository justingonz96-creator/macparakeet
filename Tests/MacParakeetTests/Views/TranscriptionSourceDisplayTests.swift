import XCTest
import MacParakeetCore
@testable import MacParakeet

final class TranscriptionSourceDisplayTests: XCTestCase {
    func testYouTubeURLDisplaysAsYouTube() {
        let transcription = Transcription(
            fileName: "youtube.m4a",
            sourceURL: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
            sourceType: .youtube
        )

        let display = TranscriptionSourceDisplay.resolve(for: transcription)

        XCTAssertEqual(display, .youtube)
        XCTAssertEqual(display.collapsedText, "YouTube")
        XCTAssertEqual(display.expandedText, "YouTube source")
        XCTAssertNil(display.symbolText)
    }

    func testXURLDisplaysAsX() {
        let transcription = Transcription(
            fileName: "x.m4a",
            sourceURL: "https://x.com/macparakeet/status/1234567890123456789",
            sourceType: .youtube
        )

        let display = TranscriptionSourceDisplay.resolve(for: transcription)

        XCTAssertEqual(display, .x)
        XCTAssertEqual(display.collapsedText, "X")
        XCTAssertEqual(display.expandedText, "X source")
        XCTAssertEqual(display.symbolText, "𝕏")
    }

    func testPodcastDisplaysAsPodcast() {
        let transcription = Transcription(
            fileName: "podcast.m4a",
            sourceURL: "https://podcasts.apple.com/us/podcast/show/id123?i=456",
            sourceType: .podcast
        )

        let display = TranscriptionSourceDisplay.resolve(for: transcription)

        XCTAssertEqual(display, .podcast)
        XCTAssertEqual(display.collapsedText, "Podcast")
        XCTAssertEqual(display.expandedText, "Podcast episode")
        XCTAssertNil(display.symbolText)
    }

    func testUnknownDownloaderURLDisplaysAsVideo() {
        let transcription = Transcription(
            fileName: "video.m4a",
            sourceURL: "https://example.com/watch/123",
            sourceType: .youtube
        )

        let display = TranscriptionSourceDisplay.resolve(for: transcription)

        XCTAssertEqual(display, .mediaURL)
        XCTAssertEqual(display.collapsedText, "Video")
        XCTAssertEqual(display.expandedText, "Video source")
        XCTAssertNil(display.symbolText)
    }

    func testSoundCloudURLDisplaysAsAudio() {
        let transcription = Transcription(
            fileName: "track.m4a",
            sourceURL: "https://soundcloud.com/artist/some-track",
            sourceType: .youtube
        )

        let display = TranscriptionSourceDisplay.resolve(for: transcription)

        // SoundCloud is audio-first — it must not show the generic Video badge.
        XCTAssertEqual(display, .audioURL)
        XCTAssertEqual(display.collapsedText, "Audio")
        XCTAssertEqual(display.expandedText, "Audio source")
        XCTAssertNil(display.symbolText)
    }

    func testNonURLSourcesKeepExistingLabels() {
        let local = Transcription(fileName: "local.m4a", sourceType: .file)
        let meeting = Transcription(fileName: "Team Sync", sourceType: .meeting)

        XCTAssertEqual(TranscriptionSourceDisplay.resolve(for: local).collapsedText, "Local")
        XCTAssertEqual(TranscriptionSourceDisplay.resolve(for: meeting).collapsedText, "Meeting")
    }

    // MARK: - Which glyphs can stand alone

    /// Under the Video filter the word is dropped and the mark carries the
    /// source. That only works for real logos, so the split has to hold.
    func testPlatformMarksStandAloneAndGenericGlyphsDoNot() {
        for branded in [TranscriptionSourceDisplay.youtube, .x, .vimeo, .facebook, .tiktok, .instagram] {
            XCTAssertTrue(
                branded.markIsSelfEvident,
                "\(branded.collapsedText) is a logo people already read as the brand"
            )
        }
        for generic in [TranscriptionSourceDisplay.meeting, .localFile, .podcast, .audioURL, .mediaURL] {
            XCTAssertFalse(
                generic.markIsSelfEvident,
                "\(generic.collapsedText) is a plain SF Symbol and names no source without its text"
            )
        }
    }

    /// A SoundCloud upload and a Twitch VOD both live under the Video filter
    /// but resolve to generic glyphs, so collapsing them to an icon would drop
    /// the audio-versus-video distinction rather than remove a repetition.
    func testVideoFilterSourcesThatMustKeepTheirText() {
        let soundcloud = Transcription(
            fileName: "set.m4a",
            sourceURL: "https://soundcloud.com/artist/track",
            sourceType: .youtube
        )
        let twitch = Transcription(
            fileName: "vod.m4a",
            sourceURL: "https://www.twitch.tv/videos/123456789",
            sourceType: .youtube
        )

        XCTAssertEqual(TranscriptionSourceDisplay.resolve(for: soundcloud), .audioURL)
        XCTAssertEqual(TranscriptionSourceDisplay.resolve(for: twitch), .mediaURL)
        XCTAssertFalse(TranscriptionSourceDisplay.resolve(for: soundcloud).markIsSelfEvident)
        XCTAssertFalse(TranscriptionSourceDisplay.resolve(for: twitch).markIsSelfEvident)
    }
}
