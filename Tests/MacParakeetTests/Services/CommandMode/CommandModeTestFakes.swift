import AppKit
import Foundation
import os
@testable import MacParakeetCore

/// Records replacement-backend interactions for Command Mode tests.
final class FakeCommandModeReplacementBackend: SelectionReplacementBackend, @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<State>(initialState: State())
    struct State {
        var axWrites: [String] = []
        var pasteWrites: [String] = []
        var deleteKeyCount = 0
        var cmdVCount = 0
        var changeCount = 100
    }

    var axWrites: [String] { lock.withLock { $0.axWrites } }
    var pasteWrites: [String] { lock.withLock { $0.pasteWrites } }
    var deleteKeyCount: Int { lock.withLock { $0.deleteKeyCount } }

    func isAccessibilityTrusted() -> Bool { true }
    func writeSelectionViaAX(_ text: String, element: AXUIElement) -> Bool {
        lock.withLock { $0.axWrites.append(text) }
        return true
    }
    @MainActor func writePasteboardString(_ text: String) -> Bool {
        lock.withLock { $0.pasteWrites.append(text); $0.changeCount += 1 }
        return true
    }
    @MainActor func activateApplication(target: SelectionCaptureTarget) -> Bool { true }
    @MainActor func isFrontmostApplication(target: SelectionCaptureTarget) -> Bool { true }
    @MainActor func postCmdV() throws { lock.withLock { $0.cmdVCount += 1 } }
    @MainActor func postDeleteKey() throws { lock.withLock { $0.deleteKeyCount += 1 } }
    @MainActor func currentChangeCount() -> Int { lock.withLock { $0.changeCount } }
    @MainActor func snapshotPasteboard() -> PasteboardSnapshot { .none }
    @MainActor func restoreSnapshot(_ snapshot: PasteboardSnapshot) {}
}
