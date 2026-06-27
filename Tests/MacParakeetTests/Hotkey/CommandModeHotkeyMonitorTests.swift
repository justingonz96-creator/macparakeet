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

    func testTapDisabledRecoversInFlightPress() throws {
        let monitor = CommandModeHotkeyMonitor()
        monitor.setShortcut(KeyboardShortcut(modifiers: KeyboardShortcut.ModifierFlag.option.rawValue, keyCode: 0x31, keyLabel: "Space"))

        var starts = 0, ends = 0
        monitor.onPressStart = { starts += 1 }
        monitor.onPressEnd = { ends += 1 }

        // A matching keyDown puts a press in flight (isDown == true).
        let down = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 0x31, keyDown: true))
        down.flags = .maskAlternate
        XCTAssertNil(monitor.handleEvent(type: .keyDown, event: down))
        XCTAssertEqual(starts, 1)

        // macOS disables the tap mid-hold. The handler branches on `type`, not
        // event contents, so any CGEvent works as the carrier; only the type
        // matters here. The in-flight press must be recovered via onPressEnd so
        // the coordinator's hold is torn down even though the physical keyUp is
        // never delivered.
        let disableEvent = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 0x31, keyDown: false))
        XCTAssertNotNil(monitor.handleEvent(type: .tapDisabledByTimeout, event: disableEvent)) // passed through
        XCTAssertEqual(ends, 1, "tap-disable with a press in flight must fire onPressEnd exactly once")

        // The recovery cleared isDown, so the now-stale physical keyUp must not
        // fire a second onPressEnd.
        let up = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 0x31, keyDown: false))
        up.flags = .maskAlternate
        XCTAssertNotNil(monitor.handleEvent(type: .keyUp, event: up)) // passed through, no longer swallowed
        XCTAssertEqual(ends, 1, "stale keyUp after recovery must not refire onPressEnd")
    }

    func testTapDisabledWithNoPressInFlightDoesNotFirePressEnd() throws {
        let monitor = CommandModeHotkeyMonitor()
        monitor.setShortcut(KeyboardShortcut(modifiers: KeyboardShortcut.ModifierFlag.option.rawValue, keyCode: 0x31, keyLabel: "Space"))

        var ends = 0
        monitor.onPressEnd = { ends += 1 }

        // No keyDown was delivered, so no press is in flight. A tap-disable must
        // re-enable the tap without synthesizing a spurious release.
        let disableEvent = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 0x31, keyDown: false))
        XCTAssertNotNil(monitor.handleEvent(type: .tapDisabledByUserInput, event: disableEvent))
        XCTAssertEqual(ends, 0, "tap-disable with no press in flight must not fire onPressEnd")
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
