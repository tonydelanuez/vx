import AppKit
import Carbon

// MARK: - ModifierKey

/// A modifier key usable as a shortcut trigger (single-press, held, or double-tapped).
/// Left and right sides are tracked separately so the user can bind, e.g., right Option only.
enum ModifierKey: String, CaseIterable, Equatable {
    case leftOption
    case rightOption
    case leftCommand
    case rightCommand
    case leftControl
    case rightControl
    case leftShift
    case rightShift

    var keyCode: CGKeyCode {
        switch self {
        case .leftOption:   return CGKeyCode(kVK_Option)
        case .rightOption:  return CGKeyCode(kVK_RightOption)
        case .leftCommand:  return CGKeyCode(kVK_Command)
        case .rightCommand: return CGKeyCode(kVK_RightCommand)
        case .leftControl:  return CGKeyCode(kVK_Control)
        case .rightControl: return CGKeyCode(kVK_RightControl)
        case .leftShift:    return CGKeyCode(kVK_Shift)
        case .rightShift:   return CGKeyCode(kVK_RightShift)
        }
    }

    var modifierFlag: CGEventFlags {
        switch self {
        case .leftOption,   .rightOption:  return .maskAlternate
        case .leftCommand,  .rightCommand: return .maskCommand
        case .leftControl,  .rightControl: return .maskControl
        case .leftShift,    .rightShift:   return .maskShift
        }
    }

    /// The glyph for this modifier (⌥ / ⌘ / ⌃ / ⇧).
    var symbol: String {
        switch self {
        case .leftOption,  .rightOption:  return "⌥"
        case .leftCommand, .rightCommand: return "⌘"
        case .leftControl, .rightControl: return "⌃"
        case .leftShift,   .rightShift:   return "⇧"
        }
    }

    /// Human label with side, e.g. "Right Option".
    var sideName: String {
        switch self {
        case .leftOption:   return "Left Option"
        case .rightOption:  return "Right Option"
        case .leftCommand:  return "Left Command"
        case .rightCommand: return "Right Command"
        case .leftControl:  return "Left Control"
        case .rightControl: return "Right Control"
        case .leftShift:    return "Left Shift"
        case .rightShift:   return "Right Shift"
        }
    }

    /// Label shown for a double-tap binding, e.g. "⌥ ⌥  Right Option".
    var displayName: String { "\(symbol) \(symbol)  \(sideName)" }

    /// Label shown for a single-press binding, e.g. "⌥  Right Option". The
    /// surrounding UI supplies the verb ("Hold …" / "Press …") based on the
    /// activation mode, so this stays verb-free.
    var singleDisplayName: String { "\(symbol)  \(sideName)" }
}

// MARK: - Shortcut

enum Shortcut: Equatable {
    case combo(keyCode: CGKeyCode, modifiers: CGEventFlags)
    case doubleTap(ModifierKey)
    /// A single modifier key (e.g. Right Option) as the trigger: held for the
    /// duration of dictation in hold-to-talk mode, or pressed to flip recording
    /// on/off in toggle mode.
    case modifier(ModifierKey)

    /// Convenience initialiser matching the old struct API.
    /// Handles the fn-key modifier promotion automatically.
    init(keyCode: CGKeyCode, modifiers: CGEventFlags) {
        if keyCode == CGKeyCode(kVK_Function) {
            self = .combo(keyCode: keyCode, modifiers: modifiers.union(.maskSecondaryFn))
        } else if Shortcut.isFunctionKey(keyCode) {
            // On Macs where the function row defaults to media keys, F1…F20 only emit
            // their key code while fn is held, so the captured flags carry fn. That's an
            // artifact of the keyboard setting, not a chosen modifier — drop it so the
            // binding reads as just "F1" and matches with or without fn held.
            self = .combo(keyCode: keyCode, modifiers: modifiers.subtracting(.maskSecondaryFn))
        } else {
            self = .combo(keyCode: keyCode, modifiers: modifiers)
        }
    }

    static let optionSpace   = Shortcut.combo(keyCode: CGKeyCode(kVK_Space),  modifiers: [.maskAlternate])
    static let controlOptionSpace = Shortcut.combo(keyCode: CGKeyCode(kVK_Space), modifiers: [.maskControl, .maskAlternate])
    static let commandShiftC = Shortcut.combo(keyCode: CGKeyCode(kVK_ANSI_C), modifiers: [.maskCommand, .maskShift])

    var displayName: String {
        switch self {
        case .combo(let keyCode, let modifiers):
            let modifierText = Shortcut.stringForModifiers(modifiers)
            let keyText      = Shortcut.stringForKeyCode(keyCode)
            let pieces = [modifierText, keyText].filter { !$0.isEmpty }
            if pieces.isEmpty, keyCode == CGKeyCode(kVK_Function) { return "fn" }
            return pieces.joined(separator: " ")
        case .doubleTap(let modifier):
            return modifier.displayName
        case .modifier(let modifier):
            return modifier.singleDisplayName
        }
    }

    /// Single-character string suitable for NSMenuItem.keyEquivalent (empty if not mappable).
    var menuKeyEquivalent: String {
        switch self {
        case .combo(let keyCode, _): return keyCodeToString(keyCode)?.lowercased() ?? ""
        case .doubleTap:             return ""
        case .modifier:              return ""
        }
    }

    /// Modifier mask suitable for NSMenuItem.keyEquivalentModifierMask.
    var menuKeyEquivalentModifierMask: NSEvent.ModifierFlags {
        switch self {
        case .combo(_, let modifiers):
            var mask: NSEvent.ModifierFlags = []
            if modifiers.contains(.maskCommand)   { mask.insert(.command) }
            if modifiers.contains(.maskShift)     { mask.insert(.shift) }
            if modifiers.contains(.maskAlternate) { mask.insert(.option) }
            if modifiers.contains(.maskControl)   { mask.insert(.control) }
            return mask
        case .doubleTap:
            return []
        case .modifier:
            return []
        }
    }

    func serialize() -> String {
        switch self {
        case .combo(let keyCode, let modifiers):
            return "\(keyCode):\(modifiers.rawValue)"
        case .doubleTap(let modifier):
            return "doubletap:\(modifier.rawValue)"
        case .modifier(let modifier):
            return "mod:\(modifier.rawValue)"
        }
    }

    static func deserialize(_ value: String) -> Shortcut? {
        if value.hasPrefix("doubletap:") {
            let raw = String(value.dropFirst("doubletap:".count))
            return ModifierKey(rawValue: raw).map { .doubleTap($0) }
        }
        // "mod:" is the current single-modifier prefix; "hold:" is the earlier name.
        for prefix in ["mod:", "hold:"] where value.hasPrefix(prefix) {
            let raw = String(value.dropFirst(prefix.count))
            return ModifierKey(rawValue: raw).map { .modifier($0) }
        }
        let parts = value.split(separator: ":")
        guard parts.count == 2,
              let code = UInt32(parts[0]),
              let flagsValue = UInt64(parts[1]) else { return nil }
        return Shortcut(keyCode: CGKeyCode(code), modifiers: CGEventFlags(rawValue: flagsValue))
    }

    private static func stringForModifiers(_ flags: CGEventFlags) -> String {
        var pieces: [String] = []
        if flags.contains(.maskCommand)     { pieces.append("⌘") }
        if flags.contains(.maskShift)       { pieces.append("⇧") }
        if flags.contains(.maskAlternate)   { pieces.append("⌥") }
        if flags.contains(.maskControl)     { pieces.append("⌃") }
        if flags.contains(.maskSecondaryFn) { pieces.append("fn") }
        return pieces.joined(separator: " ")
    }

    private static func stringForKeyCode(_ keyCode: CGKeyCode) -> String {
        if let name = functionKeyNames[Int(keyCode)] { return name }
        switch Int(keyCode) {
        case kVK_Space:    return "Space"
        case kVK_Return:   return "Return"
        case kVK_Escape:   return "Esc"
        case kVK_Delete:   return "Delete"
        case kVK_Function: return ""
        default:
            if let string = keyCodeToString(keyCode) { return string.uppercased() }
            return "#\(keyCode)"
        }
    }

    /// Maps function-row key codes to their labels (F1…F20). Their "display"
    /// character is empty via UCKeyTranslate, so they need explicit names.
    static let functionKeyNames: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
        kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
        kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15",
        kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
    ]

    /// True for the F1…F20 function-row keys. The fn/Globe flag on these is an
    /// artifact of the keyboard's function-row setting, not an intentional
    /// modifier, so it is ignored when binding and matching them.
    static func isFunctionKey(_ keyCode: CGKeyCode) -> Bool {
        functionKeyNames[Int(keyCode)] != nil
    }
}

// MARK: - GlobalShortcutMonitor

final class GlobalShortcutMonitor {
    enum Event {
        case keyDown
        case keyUp
    }

    private let keyCode: CGKeyCode
    private let modifiers: CGEventFlags
    private let handler: (Event) -> Void

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var monitorQueue: DispatchQueue?
    private var isPressed = false
    private var fnPressed = false

    init(keyCode: CGKeyCode, modifiers: CGEventFlags, handler: @escaping (Event) -> Void) {
        self.keyCode   = keyCode
        self.modifiers = modifiers
        self.handler   = handler
    }

    func start() {
        guard eventTap == nil else { return }

        let mask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo = userInfo else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<GlobalShortcutMonitor>.fromOpaque(userInfo).takeUnretainedValue()
            if monitor.handle(event: event, type: type) {
                return Unmanaged.passUnretained(event)
            } else {
                return nil
            }
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        ) else {
            NSLog("[vx-ui] Failed to create global shortcut monitor")
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)

        monitorQueue = DispatchQueue(label: "voice.vx.hotkey", qos: .userInteractive)
        monitorQueue?.async { [weak self] in
            guard let self, let runLoopSource = self.runLoopSource else { return }
            let runLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(runLoop, runLoopSource, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
        }
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        runLoopSource = nil
        eventTap = nil
        monitorQueue = nil
        isPressed = false
        fnPressed = false
    }

    @discardableResult
    private func handle(event: CGEvent, type: CGEventType) -> Bool {
        if type == .flagsChanged {
            return handleFlagsChanged(event: event)
        }

        guard type == .keyDown || type == .keyUp else { return true }

        // For function keys, ignore the fn/Globe flag entirely: whether F1 carries it
        // depends on the keyboard's function-row setting, so the binding must match both.
        var relevantFlags: CGEventFlags = [.maskShift, .maskControl, .maskAlternate, .maskCommand, .maskSecondaryFn]
        if Shortcut.isFunctionKey(keyCode) { relevantFlags.remove(.maskSecondaryFn) }
        let flags = event.flags.intersection(relevantFlags)
        let eventKeyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))

        if eventKeyCode == CGKeyCode(kVK_Function) {
            return true
        }

        guard eventKeyCode == keyCode, flags == modifiers else {
            return true
        }

        switch type {
        case .keyDown:
            if !isPressed {
                isPressed = true
                handler(.keyDown)
            }
        case .keyUp:
            if isPressed {
                isPressed = false
                handler(.keyUp)
            }
        default:
            break
        }

        return false
    }

    private func handleFlagsChanged(event: CGEvent) -> Bool {
        let eventKeyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let relevantFlags: CGEventFlags = [.maskShift, .maskControl, .maskAlternate, .maskCommand, .maskSecondaryFn]
        let flags = event.flags.intersection(relevantFlags)

        if modifiers.contains(.maskSecondaryFn) && eventKeyCode == CGKeyCode(kVK_Function) {
            let pressed = flags.contains(.maskSecondaryFn)
            if pressed && flags == modifiers {
                if !fnPressed {
                    fnPressed = true
                    handler(.keyDown)
                }
                return false
            } else if fnPressed && (!pressed || flags != modifiers) {
                fnPressed = false
                handler(.keyUp)
                return false
            }
        }

        if eventKeyCode == CGKeyCode(kVK_Function) {
            return false
        }

        return true
    }
}

// MARK: - DoubleTapMonitor

/// Detects when the user double-taps a single modifier key (e.g. right Option twice)
/// and fires keyDown / keyUp events mirroring GlobalShortcutMonitor's pattern.
///
/// Detection:
///   1. First modifier press + release  → window opens
///   2. Second modifier press within 0.4 s → fires .keyDown
///   3. Second modifier release          → fires .keyUp
///
/// All flagsChanged events for the watched key are swallowed so single taps
/// do not leak modifier state into other apps.
final class DoubleTapMonitor {
    enum Event { case keyDown, keyUp }

    private let modifier: ModifierKey
    private let handler: (Event) -> Void
    private let doubleTapWindow: TimeInterval = 0.4

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var monitorQueue: DispatchQueue?

    // State — accessed only from monitorQueue's run loop
    private var firstTapReleasedAt: Date? = nil
    private var isModifierDown = false
    private var isActivated = false

    init(modifier: ModifierKey, handler: @escaping (Event) -> Void) {
        self.modifier = modifier
        self.handler  = handler
    }

    func start() {
        guard eventTap == nil else { return }

        let mask = 1 << CGEventType.flagsChanged.rawValue
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<DoubleTapMonitor>.fromOpaque(userInfo).takeUnretainedValue()
            return monitor.handle(event: event, type: type)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        ) else {
            vxLog("[doubletap/start] Failed to create CGEventTap")
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)

        monitorQueue = DispatchQueue(label: "voice.vx.doubletap", qos: .userInteractive)
        monitorQueue?.async { [weak self] in
            guard let self, let source = self.runLoopSource else { return }
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
        }
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        runLoopSource = nil
        eventTap = nil
        monitorQueue = nil
        firstTapReleasedAt = nil
        isModifierDown = false
        isActivated = false
    }

    private func handle(event: CGEvent, type: CGEventType) -> Unmanaged<CGEvent>? {
        guard type == .flagsChanged else { return Unmanaged.passUnretained(event) }

        let eventKeyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        guard eventKeyCode == modifier.keyCode else { return Unmanaged.passUnretained(event) }

        let isDown = event.flags.contains(modifier.modifierFlag)

        if isDown && !isModifierDown {
            isModifierDown = true
            if !isActivated,
               let released = firstTapReleasedAt,
               Date().timeIntervalSince(released) < doubleTapWindow {
                // Second tap within window — activate
                firstTapReleasedAt = nil
                isActivated = true
                handler(.keyDown)
            } else {
                // First tap (or window expired) — reset
                firstTapReleasedAt = nil
            }
        } else if !isDown && isModifierDown {
            isModifierDown = false
            if isActivated {
                isActivated = false
                handler(.keyUp)
            } else {
                // First tap released — open window for second tap
                firstTapReleasedAt = Date()
            }
        }

        return nil  // Swallow all flagsChanged events for this key
    }
}

// MARK: - ModifierKeyMonitor

/// Fires keyDown when a single modifier key (e.g. right Option) is pressed and
/// keyUp when it is released, so a bare modifier can drive dictation — held to
/// talk in hold-to-talk mode, or pressed to flip recording on/off in toggle
/// mode. A bare modifier only emits `flagsChanged` events (never a keyDown with
/// a keycode), which is why GlobalShortcutMonitor can't see it — this watches
/// those flag transitions for one specific left/right key.
///
/// Events are passed through unchanged so the modifier keeps working normally
/// for the rest of the system (typing, other shortcuts); a lone modifier press
/// reaching the focused app is harmless.
final class ModifierKeyMonitor {
    enum Event { case keyDown, keyUp }

    private let modifier: ModifierKey
    private let handler: (Event) -> Void

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var monitorQueue: DispatchQueue?

    // State — accessed only from monitorQueue's run loop
    private var isDown = false

    init(modifier: ModifierKey, handler: @escaping (Event) -> Void) {
        self.modifier = modifier
        self.handler  = handler
    }

    func start() {
        guard eventTap == nil else { return }

        let mask = 1 << CGEventType.flagsChanged.rawValue
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<ModifierKeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
            monitor.handle(event: event, type: type)
            return Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        ) else {
            vxLog("[holdmod/start] Failed to create CGEventTap")
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)

        monitorQueue = DispatchQueue(label: "voice.vx.holdmodifier", qos: .userInteractive)
        monitorQueue?.async { [weak self] in
            guard let self, let source = self.runLoopSource else { return }
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
        }
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        runLoopSource = nil
        eventTap = nil
        monitorQueue = nil
        isDown = false
    }

    private func handle(event: CGEvent, type: CGEventType) {
        guard type == .flagsChanged else { return }

        let eventKeyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        guard eventKeyCode == modifier.keyCode else { return }

        let pressed = event.flags.contains(modifier.modifierFlag)
        if pressed && !isDown {
            isDown = true
            handler(.keyDown)
        } else if !pressed && isDown {
            isDown = false
            handler(.keyUp)
        }
    }
}

// MARK: - keyCodeToString

private func keyCodeToString(_ keyCode: CGKeyCode) -> String? {
    var layout: TISInputSource?
    let result = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
    layout = result

    guard let source = layout,
          let rawLayoutData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
        return nil
    }

    let layoutData = Unmanaged<CFData>.fromOpaque(rawLayoutData).takeUnretainedValue() as Data
    guard let keyLayout = layoutData.withUnsafeBytes({ $0.bindMemory(to: UCKeyboardLayout.self).baseAddress }) else {
        return nil
    }

    var deadKeyState: UInt32 = 0
    let maxLength = 2
    var chars = [UniChar](repeating: 0, count: maxLength)
    var actualLength = 0

    let modifiers = UInt32(0)
    let error = UCKeyTranslate(
        keyLayout,
        UInt16(keyCode),
        UInt16(kUCKeyActionDisplay),
        modifiers,
        UInt32(LMGetKbdType()),
        UInt32(kUCKeyTranslateNoDeadKeysBit),
        &deadKeyState,
        maxLength,
        &actualLength,
        &chars
    )

    guard error == noErr else { return nil }
    return String(utf16CodeUnits: chars, count: actualLength)
}
