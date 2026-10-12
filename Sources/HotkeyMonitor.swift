import Cocoa

/// Watches the dictation key system-wide through a CGEvent tap. Needs Accessibility permission.
final class HotkeyMonitor {
    enum Event { case triggerDown, triggerUp, space, escape, otherKey }

    /// Called on the main thread for every relevant key event; return true to swallow the event.
    var handler: ((Event) -> Bool)?
    var hotkey: HotkeyChoice = .fn

    private var tap: CFMachPort?
    private var triggerHeld = false
    private var swallowedKeys = Set<Int64>()

    var isRunning: Bool { tap != nil }

    func start() -> Bool {
        if tap != nil { return true }
        let types: [CGEventType] = [.flagsChanged, .keyDown, .keyUp]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << CGEventMask($1.rawValue)) }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: hotkeyTapCallback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        return true
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .flagsChanged:
            guard event.getIntegerValueField(.keyboardEventKeycode) == hotkey.keyCode else { break }
            let down = hotkey.isDown(event.flags)
            if down != triggerHeld {
                triggerHeld = down
                _ = handler?(down ? .triggerDown : .triggerUp)
            }
        case .keyDown:
            if event.getIntegerValueField(.eventSourceUserData) == Paster.eventMarker { break }
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            if swallowedKeys.contains(code) { return nil }  // auto-repeat of a key we already took
            let kind: Event = code == 49 ? .space : code == 53 ? .escape : .otherKey
            if handler?(kind) == true {
                swallowedKeys.insert(code)
                return nil
            }
        case .keyUp:
            if swallowedKeys.remove(event.getIntegerValueField(.keyboardEventKeycode)) != nil { return nil }
        default:
            break
        }
        return pass
    }
}

private func hotkeyTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                               refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    return Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue().handle(type: type, event: event)
}

extension HotkeyChoice {
    var keyCode: Int64 {
        switch self {
        case .fn: return 63            // kVK_Function
        case .rightOption: return 61   // kVK_RightOption
        case .rightCommand: return 54  // kVK_RightCommand
        case .rightControl: return 62  // kVK_RightControl
        }
    }

    func isDown(_ flags: CGEventFlags) -> Bool {
        switch self {
        case .fn: return flags.contains(.maskSecondaryFn)
        case .rightOption: return flags.rawValue & 0x40 != 0     // NX_DEVICERALTKEYMASK
        case .rightCommand: return flags.rawValue & 0x10 != 0    // NX_DEVICERCMDKEYMASK
        case .rightControl: return flags.rawValue & 0x2000 != 0  // NX_DEVICERCTLKEYMASK
        }
    }
}
