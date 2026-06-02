import AppKit
import CoreGraphics
import Carbon

/// Captures the global `fn` key using a CGEventTap and swallows it so macOS does not open Emoji & Symbols.
final class FnKeyTap {
    static let shared = FnKeyTap()

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isFnDown = false
    private var pressReported = false
    private var handlingGlobeKey = false
    private var pendingModifierRelease: DispatchWorkItem?
    private var isEnabled = false
    private var onFnPress: (() -> Void)?
    private var onFnRelease: (() -> Void)?

    private init() {
        _ = installTapIfNeeded()
    }

    @discardableResult
    func activate(onPress: @escaping () -> Void, onRelease: @escaping () -> Void) -> Bool {
        guard installTapIfNeeded() else { return false }
        isEnabled = true
        onFnPress = onPress
        onFnRelease = onRelease
        isFnDown = false
        return true
    }

    func deactivate() {
        isEnabled = false
        onFnPress = nil
        onFnRelease = nil
        isFnDown = false
        pressReported = false
        handlingGlobeKey = false
        pendingModifierRelease?.cancel()
        pendingModifierRelease = nil
    }

    private func installTapIfNeeded() -> Bool {
        if eventTap != nil { return true }

        let options: NSDictionary = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ]
        let trusted = AXIsProcessTrustedWithOptions(options)
        if !trusted {
            vxLog("[fnkey/install] Accessibility permission not yet granted")
        }

        let mask = CGEventMask(
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)
        )

        eventTap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon = refcon else {
                    return Unmanaged.passUnretained(event)
                }

                let tap = Unmanaged<FnKeyTap>.fromOpaque(refcon).takeUnretainedValue()
                return tap.handle(type: type, event: event)
            },
            userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        )

        guard let eventTap else {
            vxLog("[fnkey/install] Failed to create event tap")
            return false
        }

        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        vxLog("[fnkey/install] Installed")
        return true
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        guard isEnabled else {
            return Unmanaged.passUnretained(event)
        }

        // Handle Globe key (keyDown/keyUp) - common keycodes: 179, 193, 103
        if type == .keyDown || type == .keyUp {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            
            // Common Globe key keycodes (some keyboards use different values)
            let globeKeycodes: [Int64] = [179, 193, 103]
            
            if globeKeycodes.contains(keyCode) {
                if type == .keyDown {
                    pendingModifierRelease?.cancel()
                    pendingModifierRelease = nil
                    handlingGlobeKey = true
                    if !pressReported {
                        pressReported = true
                        isFnDown = true
                        onFnPress?()
                        debugLog("Globe key pressed (keycode=\(keyCode)) – swallowing")
                    }
                    return nil
                } else if type == .keyUp {
                    pendingModifierRelease?.cancel()
                    pendingModifierRelease = nil
                    if handlingGlobeKey && pressReported {
                        pressReported = false
                        isFnDown = false
                        onFnRelease?()
                        debugLog("Globe key released (keycode=\(keyCode)) – swallowing")
                    }
                    handlingGlobeKey = false
                    return nil
                }
            }
            
            // If it's not a Globe key, pass it through
            return Unmanaged.passUnretained(event)
        }

        // Handle Fn modifier (flagsChanged) - for keyboards that send modifier events
        guard type == .flagsChanged else {
            return Unmanaged.passUnretained(event)
        }

        if handlingGlobeKey {
            // Ignore modifier changes while we are already handling the hardware key events
            return Unmanaged.passUnretained(event)
        }

        let flags = event.flags
        let fnDownFlag = flags.contains(.maskSecondaryFn)

        if fnDownFlag && !isFnDown {
            pendingModifierRelease?.cancel()
            pendingModifierRelease = nil
            isFnDown = true
            if !pressReported {
                pressReported = true
                onFnPress?()
                debugLog("fn pressed (via modifier) – swallowing")
            }
            return nil
        }

        if !fnDownFlag && isFnDown {
            pendingModifierRelease?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                if self.handlingGlobeKey {
                    self.debugLog("modifier release ignored (globe handling active)")
                    return
                }
                if self.pressReported {
                    self.pressReported = false
                    self.isFnDown = false
                    self.onFnRelease?()
                    self.debugLog("fn released (via modifier) – swallowing")
                }
            }
            pendingModifierRelease = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03, execute: work)
            return nil
        }

        return Unmanaged.passUnretained(event)
    }

    private func debugLog(_ message: String) {
        vxLog("[fnkey] \(message)")
    }
}

