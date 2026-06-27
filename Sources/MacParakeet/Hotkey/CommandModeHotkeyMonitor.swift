import Cocoa
import Foundation
import MacParakeetCore
import OSLog

/// Single-chord event tap exposing a hold gesture (press-start on keyDown, press-end
/// on keyUp) for Command Mode. Sibling of `TransformsHotkeyRegistry`; dormant until a
/// shortcut is set. See ADR-023 §2.
public final class CommandModeHotkeyMonitor {
    private static let logger = Logger(subsystem: "com.macparakeet", category: "CommandModeHotkeyMonitor")

    public var onPressStart: (() -> Void)?
    public var onPressEnd: (() -> Void)?

    private var keyCode: UInt16?
    private var modifierBits: UInt64 = 0
    private var isDown = false

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var retainedSelf: Unmanaged<CommandModeHotkeyMonitor>?
    private var installedRunLoop: CFRunLoop?

    public init() {}

    deinit {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource, let runLoop = installedRunLoop {
            CFRunLoopRemoveSource(runLoop, source, .commonModes)
        }
        retainedSelf?.release()
    }

    // MARK: - Public API

    public func setShortcut(_ shortcut: KeyboardShortcut?) {
        guard let shortcut else {
            keyCode = nil
            modifierBits = 0
            isDown = false
            return
        }
        keyCode = shortcut.keyCode
        modifierBits = UInt64(shortcut.modifiers) & HotkeyTrigger.relevantModifierBits
    }

    // MARK: - Tap lifecycle

    /// Install the system-wide event tap. Idempotent; safe to call again if
    /// the tap was previously stopped.
    @discardableResult
    public func start() -> Bool {
        if eventTap != nil {
            stop()
        }

        let eventMask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { _, type, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<CommandModeHotkeyMonitor>
                    .fromOpaque(refcon)
                    .takeUnretainedValue()
                return monitor.handleEvent(type: type, event: event)
            },
            userInfo: {
                let retained = Unmanaged.passRetained(self)
                self.retainedSelf = retained
                return retained.toOpaque()
            }()
        ) else {
            retainedSelf?.release()
            retainedSelf = nil
            let isTrusted = AXIsProcessTrusted()
            Self.logger.error(
                "command_mode_tap_create_failed accessibility_trusted=\(isTrusted, privacy: .public)"
            )
            return false
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        let runLoop = CFRunLoopGetCurrent()
        installedRunLoop = runLoop
        CFRunLoopAddSource(runLoop, runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    public func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource, let runLoop = installedRunLoop {
            CFRunLoopRemoveSource(runLoop, source, .commonModes)
        }
        retainedSelf?.release()
        retainedSelf = nil
        eventTap = nil
        runLoopSource = nil
        installedRunLoop = nil
        isDown = false
    }

    // MARK: - Event handling

    func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            isDown = false
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard let boundKey = keyCode else { return Unmanaged.passUnretained(event) }

        let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let mods = event.flags.rawValue & HotkeyTrigger.relevantModifierBits

        switch type {
        case .keyDown:
            guard code == boundKey, mods == modifierBits else { return Unmanaged.passUnretained(event) }
            guard !isDown else { return nil } // swallow auto-repeat
            isDown = true
            onPressStart?()
            return nil
        case .keyUp:
            guard code == boundKey, isDown else { return Unmanaged.passUnretained(event) }
            isDown = false
            onPressEnd?()
            return nil
        default:
            return Unmanaged.passUnretained(event)
        }
    }
}
