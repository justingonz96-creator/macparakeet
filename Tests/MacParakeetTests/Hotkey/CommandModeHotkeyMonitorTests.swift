import XCTest
import AppKit
import MacParakeetCore
@testable import MacParakeet

final class CommandModeHotkeyMonitorTests: XCTestCase {
    func testPressStartAndEndFireForBoundChord() throws {
        let monitor = CommandModeHotkeyMonitor()
        // Option+Space (keyCode 0x31)
        monitor.setShortcut(KeyboardShortcut(modifiers: KeyboardShortcut.ModifierFlag.option.rawValue, keyCode: 0x31, keyLabel: "Space"))

        var starts = 0, ends = 0
        monitor.onPressStart = { starts += 1 }
        monitor.onPressEnd = { ends += 1 }

        let down = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 0x31, keyDown: true))
        down.flags = .maskAlternate
        XCTAssertNil(monitor.handleEvent(type: .keyDown, event: down)) // swallowed
        XCTAssertEqual(starts, 1)
        // Auto-repeat keyDowns must not refire onPressStart.
        XCTAssertNil(monitor.handleEvent(type: .keyDown, event: down))
        XCTAssertEqual(starts, 1)

        let up = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 0x31, keyDown: false))
        up.flags = .maskAlternate
        XCTAssertNil(monitor.handleEvent(type: .keyUp, event: up))
        XCTAssertEqual(ends, 1)
    }

    func testUnboundMonitorIgnoresEvents() throws {
        let monitor = CommandModeHotkeyMonitor()
        var starts = 0
        monitor.onPressStart = { starts += 1 }
        let down = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 0x31, keyDown: true))
        down.flags = .maskAlternate
        XCTAssertNotNil(monitor.handleEvent(type: .keyDown, event: down)) // passed through
        XCTAssertEqual(starts, 0)
    }

    func testRebindingMidHoldResetsState() throws {
        let monitor = CommandModeHotkeyMonitor()
        monitor.setShortcut(KeyboardShortcut(modifiers: KeyboardShortcut.ModifierFlag.option.rawValue, keyCode: 0x31, keyLabel: "Space"))
        var starts = 0
        monitor.onPressStart = { starts += 1 }
        let down = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 0x31, keyDown: true))
        down.flags = .maskAlternate
        _ = monitor.handleEvent(type: .keyDown, event: down) // isDown = true
        XCTAssertEqual(starts, 1)
        // Rebind to a different chord while the old key is still logically held.
        monitor.setShortcut(KeyboardShortcut(modifiers: KeyboardShortcut.ModifierFlag.option.rawValue, keyCode: 0x00, keyLabel: "A"))
        let downA = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 0x00, keyDown: true))
        downA.flags = .maskAlternate
        _ = monitor.handleEvent(type: .keyDown, event: downA)
        XCTAssertEqual(starts, 2, "rebinding should reset isDown so the new chord fires")
    }
}
