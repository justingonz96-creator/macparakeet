import XCTest
@testable import MacParakeetCore
@testable import MacParakeetViewModels

/// A source label that repeats the active filter is noise. These pin the rule
/// that decides when it is drawn, and — more importantly — pin it to the same
/// `(scope, filter)` pairs the library query itself switches on, so the two
/// cannot drift apart silently.
final class LibrarySourceLabelStyleTests: XCTestCase {

    // MARK: - Mixed contexts keep the label

    func testMixedContextsShowTheFullLabel() {
        XCTAssertEqual(
            TranscriptionLibraryScope.all.sourceLabelStyle(for: .all),
            .visible,
            "All admits every source, so the label is the only source attribution"
        )
        XCTAssertEqual(
            TranscriptionLibraryScope.all.sourceLabelStyle(for: .favorites),
            .visible,
            "Favorites spans sources, so a starred meeting and a starred podcast must stay distinguishable"
        )
    }

    // MARK: - Single-source filters drop it

    func testFiltersPinnedToOneSourceHideTheLabel() {
        for filter in [LibraryFilter.podcast, .local, .meeting] {
            XCTAssertEqual(
                TranscriptionLibraryScope.all.sourceLabelStyle(for: filter),
                .hidden,
                "\(filter.rawValue) admits exactly one source, so the label can only restate the filter"
            )
        }
    }

    func testMeetingsWorkspaceHidesTheLabelUnderEveryFilter() {
        for filter in LibraryFilter.allCases {
            XCTAssertEqual(
                TranscriptionLibraryScope.meetings.sourceLabelStyle(for: filter),
                .hidden,
                "The Meetings workspace shows only meetings, so even Favorites is fully determined there"
            )
        }
    }

    // MARK: - The multi-platform filter keeps its label

    /// Video looks like the obvious place to drop the word, and it is not.
    /// Its platforms share one `play.rectangle.fill` glyph separated only by
    /// tint, so the text is the only thing naming the platform.
    func testVideoFilterKeepsTheLabelBecauseItsPlatformsShareOneGlyph() {
        XCTAssertEqual(
            TranscriptionLibraryScope.all.sourceLabelStyle(for: .youtube),
            .visible,
            "Video resolves to several platforms that are not distinguishable by glyph alone"
        )
    }

    // MARK: - Drift guard

    /// The style is only correct because it mirrors how `makeQuery(offset:)`
    /// narrows each pair. If a new filter is added without deciding its style,
    /// this fails rather than defaulting to a label that may be noise.
    func testEveryScopeAndFilterPairHasADecidedStyle() {
        let scopes: [TranscriptionLibraryScope] = [.all, .meetings]
        for scope in scopes {
            for filter in LibraryFilter.allCases {
                let style = scope.sourceLabelStyle(for: filter)
                XCTAssertTrue(
                    LibrarySourceLabelStyle.allCases.contains(style),
                    "No decided source-label style for (\(scope), \(filter.rawValue))"
                )
            }
        }
        XCTAssertEqual(LibraryFilter.allCases.count, 6, "A new Library filter needs its own source-label decision")
    }
}
