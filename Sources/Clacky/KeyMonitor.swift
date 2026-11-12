import CoreGraphics
import Foundation

/// Listens (read-only) to key presses system-wide with a CGEvent tap.
///
/// Requires the Input Monitoring permission. Only the key code is used, to pick a
/// sound and a position; nothing about what you type is stored or sent anywhere.
final class KeyMonitor {
    var onKey: ((_ keyCode: UInt16, _ down: Bool) -> Void)?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    var isRunning: Bool { tap != nil }

    static var hasPermission: Bool { CGPreflightListenEventAccess() }

    /// Shows the system prompt the first time; afterwards the user has to use System Settings.
    @discardableResult
    static func requestPermission() -> Bool { CGRequestListenEventAccess() }

    @discardableResult
    func start() -> Bool {
        if tap != nil { return true }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
            eventsOfInterest: CGEventMask(mask), callback: keyTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        runLoopSource = source
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        CFMachPortInvalidate(tap)
        self.tap = nil
        runLoopSource = nil
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .keyDown:
            // Holding a key auto-repeats; a real switch only clicks once.
            guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return }
            onKey?(keyCode(event), true)
        case .keyUp:
            onKey?(keyCode(event), false)
        case .flagsChanged:
            handleModifier(keyCode(event), flags: event.flags.rawValue)
        default:
            break
        }
    }

    private func keyCode(_ event: CGEvent) -> UInt16 {
        UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
    }

    /// Device-specific modifier bits (NX_DEVICE*KEYMASK) tell left and right keys apart.
    private static let modifierBits: [UInt16: UInt64] = [
        56: 0x02, 60: 0x04, // shift L/R
        59: 0x01, 62: 0x2000, // control L/R
        58: 0x20, 61: 0x40, // option L/R
        55: 0x08, 54: 0x10, // command L/R
        63: CGEventFlags.maskSecondaryFn.rawValue,
    ]

    private func handleModifier(_ code: UInt16, flags: UInt64) {
        if code == 57 { // Caps Lock only reports a toggle, so play a whole press.
            onKey?(code, true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) { [weak self] in self?.onKey?(code, false) }
            return
        }
        guard let bit = Self.modifierBits[code] else { return }
        onKey?(code, flags & bit != 0)
    }
}

private func keyTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                            refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if let refcon {
        Unmanaged<KeyMonitor>.fromOpaque(refcon).takeUnretainedValue().handle(type: type, event: event)
    }
    return Unmanaged.passUnretained(event)
}
