import Foundation
@testable import MacParakeet
import SwiftStreamingMarkdown
import XCTest

final class MarkdownContentViewTests: XCTestCase {
    func testStreamingSourcePublishesAccumulatedSnapshots() async {
        let source = MarkdownSnapshotSource(initialContent: "# Sum")
        var iterator = source.text.makeAsyncIterator()

        let initial = await iterator.next()
        XCTAssertEqual(initial, "# Sum")
        source.send("# Summary\n\n- [ ] Review")
        let updated = await iterator.next()
        XCTAssertEqual(updated, "# Summary\n\n- [ ] Review")
    }

    func testKitchenSinkAndIncompleteSnapshotsProduceRenderableContent() async {
        let parser = MarkdownParserImpl()
        let config = MarkdownContentConfiguration.make(baseFontSize: 14, isStreaming: false)
        let fixtures = [
            """
            # Summary

            **Bold**, *italic*, ~~removed~~, `inline code`, and [web](https://example.com).

            - Parent
              - Nested
            - [x] Done
            - [ ] Next

            3. Third
            4. Fourth

            | Item | Owner | Status |
            |:-----|:-----:|-------:|
            | API | **Sam** | Done |

            > Quoted context

            ```swift
            let value = 42
            ```

            ---
            """,
            "**unfinished emphasis",
            "```swift\nlet value = 42",
            "| Item | Owner |\n|:--|--:|\n| Work",
        ]

        for fixture in fixtures {
            let rendered = await parser.parse(text: fixture, config: config)
            XCTAssertNotEqual(rendered, .empty, "Fixture should stay readable: \(fixture)")
        }
    }

    func testLinkPolicyAllowsOnlyWebLinks() {
        XCTAssertTrue(MarkdownContentPolicy.isAllowedLink(URL(string: "https://example.com/path")!))
        XCTAssertTrue(MarkdownContentPolicy.isAllowedLink(URL(string: "HTTP://example.com")!))

        XCTAssertFalse(MarkdownContentPolicy.isAllowedLink(URL(string: "file:///tmp/private.txt")!))
        XCTAssertFalse(MarkdownContentPolicy.isAllowedLink(URL(string: "data:text/plain,secret")!))
        XCTAssertFalse(MarkdownContentPolicy.isAllowedLink(URL(string: "javascript:alert(1)")!))
        XCTAssertFalse(MarkdownContentPolicy.isAllowedLink(URL(string: "mailto:test@example.com")!))
        XCTAssertFalse(MarkdownContentPolicy.isAllowedLink(URL(string: "/relative/path")!))
    }

    func testRenderConfigurationKeepsImagesDisabledAndSelectionEnabled() {
        let config = MarkdownContentConfiguration.make(baseFontSize: 15, isStreaming: false)

        XCTAssertFalse(config.imageConfig.enabled)
        XCTAssertTrue(config.imageConfig.allowedImageTypes.isEmpty)
        XCTAssertTrue(config.textSelectionConfig.isEnabled)
        XCTAssertFalse(config.shouldAnimateText)
    }

    func testStreamingConfigurationOnlyEnablesTextAnimation() {
        let staticConfig = MarkdownContentConfiguration.make(baseFontSize: 14, isStreaming: false)
        let streamingConfig = MarkdownContentConfiguration.make(baseFontSize: 14, isStreaming: true)

        XCTAssertFalse(staticConfig.shouldAnimateText)
        XCTAssertTrue(streamingConfig.shouldAnimateText)
        XCTAssertEqual(staticConfig.imageConfig, streamingConfig.imageConfig)
        XCTAssertEqual(staticConfig.paragraphStyle, streamingConfig.paragraphStyle)
        XCTAssertEqual(staticConfig.tableStyle, streamingConfig.tableStyle)
    }
}
