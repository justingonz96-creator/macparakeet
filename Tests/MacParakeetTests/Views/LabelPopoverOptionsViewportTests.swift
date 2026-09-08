import AppKit
import Combine
import SwiftUI
import XCTest
@testable import MacParakeet

/// Native sizing tests for the shared label-popover option viewport.
///
/// The viewport intentionally lets a short option list determine a popover's
/// fitting height. It only introduces scrolling after the list reaches its
/// cap, which avoids the one-point geometry-preference feedback loop that
/// could hide label chips and the create action.
@MainActor
final class LabelPopoverOptionsViewportTests: XCTestCase {
    // The native popover wraps the viewport with a small AppKit fitting inset.
    // This keeps the behavior assertion independent of that private chrome
    // while still rejecting an unbounded list.
    private let maximumBoundedPopoverHeight: CGFloat = 300

    private final class QueryState: ObservableObject {
        @Published var query = ""
    }

    private struct FilterOptions: View {
        @ObservedObject var state: QueryState
        let labels: [String]

        private var matches: [String] {
            guard !state.query.isEmpty else { return labels }
            return labels.filter { $0.localizedCaseInsensitiveContains(state.query) }
        }

        var body: some View {
            LabelPopoverOptionsViewport {
                VStack(alignment: .leading, spacing: 2) {
                    if matches.isEmpty {
                        Text("No labels match \(state.query)")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 5)
                    } else {
                        ForEach(matches, id: \.self) { label in
                            Text(label)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 5)
                        }
                    }
                }
            }
            .frame(width: 320)
        }
    }

    /// Exercises the same SwiftUI `.popover` presentation used by the label
    /// controls. A manually constructed `NSPopover` starts at AppKit's 320pt
    /// default and bypasses SwiftUI's fitting-size update path.
    private struct PopoverHost<Content: View>: View {
        let content: Content
        @State private var isPresented = true

        var body: some View {
            Color.clear
                .frame(width: 1, height: 1)
                .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                    content
                }
        }
    }

    private struct PresentedPopover {
        let popoverWindow: NSWindow
        let anchorWindow: NSWindow
    }

    private func show<Content: View>(_ content: Content) throws -> PresentedPopover {
        _ = NSApplication.shared
        let existingWindows = Set(NSApplication.shared.windows.map(ObjectIdentifier.init))
        let host = NSHostingView(rootView: PopoverHost(content: content))
        let anchorWindow = NSWindow(
            contentRect: NSRect(x: -20_000, y: -20_000, width: 1, height: 1),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        anchorWindow.contentView = host
        anchorWindow.orderFront(nil)

        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            if let popoverWindow = NSApplication.shared.windows.first(where: {
                !existingWindows.contains(ObjectIdentifier($0))
                    && $0 !== anchorWindow
                    && NSStringFromClass(type(of: $0)).contains("Popover")
            }) {
                settle(popoverWindow)
                return PresentedPopover(popoverWindow: popoverWindow, anchorWindow: anchorWindow)
            }
        }

        anchorWindow.close()
        throw NSError(
            domain: "LabelPopoverOptionsViewportTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "SwiftUI did not present a native popover"]
        )
    }

    private func settle(_ popoverWindow: NSWindow) {
        popoverWindow.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }

    private func dismiss(_ presented: PresentedPopover) {
        presented.popoverWindow.close()
        presented.anchorWindow.close()
    }

    private func height<Content: View>(of content: Content) throws -> CGFloat {
        let presented = try show(content)
        defer { dismiss(presented) }
        return presented.popoverWindow.contentView?.fittingSize.height ?? 0
    }

    func testEmptyAndFewOptionsUseNaturalPopoverHeights() throws {
        let emptyHeight = try height(of: FilterOptions(state: QueryState(), labels: []))
        let fewHeight = try height(
            of: FilterOptions(state: QueryState(), labels: ["Research", "Planning", "Follow-up"]))

        XCTAssertGreaterThan(emptyHeight, 0)
        XCTAssertLessThan(emptyHeight, maximumBoundedPopoverHeight)
        XCTAssertGreaterThan(fewHeight, emptyHeight)
        XCTAssertLessThan(fewHeight, maximumBoundedPopoverHeight)
    }

    func testManyOptionsUseBoundedScrollablePopoverHeight() throws {
        let labels = (1...40).map { "Label \($0)" }
        let optionsHeight = try height(of: FilterOptions(state: QueryState(), labels: labels))

        XCTAssertLessThanOrEqual(optionsHeight, maximumBoundedPopoverHeight)
        XCTAssertGreaterThan(optionsHeight, 200)
    }

    func testChangingQueryShrinksAndRegrowsThePopover() throws {
        let state = QueryState()
        let labels = (1...40).map { "Label \($0)" }
        let presented = try show(FilterOptions(state: state, labels: labels))
        defer { dismiss(presented) }

        let manyHeight = presented.popoverWindow.contentView?.fittingSize.height ?? 0
        state.query = "missing"
        settle(presented.popoverWindow)
        let noMatchesHeight = presented.popoverWindow.contentView?.fittingSize.height ?? 0
        state.query = "Label 40"
        settle(presented.popoverWindow)
        let fewMatchesHeight = presented.popoverWindow.contentView?.fittingSize.height ?? 0
        state.query = ""
        settle(presented.popoverWindow)
        let regrownHeight = presented.popoverWindow.contentView?.fittingSize.height ?? 0

        XCTAssertLessThanOrEqual(manyHeight, maximumBoundedPopoverHeight)
        XCTAssertLessThan(noMatchesHeight, manyHeight)
        XCTAssertLessThan(fewMatchesHeight, manyHeight)
        XCTAssertEqual(regrownHeight, manyHeight, accuracy: 1)
    }
}
