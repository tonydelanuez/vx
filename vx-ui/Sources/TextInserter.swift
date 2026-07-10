import AppKit
import Carbon

enum TextInsertionError: LocalizedError {
    case emptyText

    var errorDescription: String? {
        switch self {
        case .emptyText:
            return "Nothing to insert."
        }
    }
}

enum TextSubmitBehavior: Equatable {
    case none
    case returnKey
    case terminalReturnKey

    var logName: String {
        switch self {
        case .none:
            return "none"
        case .returnKey:
            return "returnKey"
        case .terminalReturnKey:
            return "terminalReturnKey"
        }
    }
}

enum TextInserter {
    static func insert(_ text: String, submit: Bool = false) throws {
        try insert(text, submitBehavior: submit ? .returnKey : .none)
    }

    static func submit(behavior: TextSubmitBehavior = .returnKey) {
        guard behavior != .none else { return }
        simulateReturn()
    }

    static func insert(_ text: String, submitBehavior: TextSubmitBehavior) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw TextInsertionError.emptyText
        }

        let pasteboard = NSPasteboard.general
        let previous = pasteboard.string(forType: .string)
        let pastedText = pasteboardPayload(for: trimmed, submitBehavior: submitBehavior)

        pasteboard.clearContents()
        pasteboard.setString(pastedText, forType: .string)

        simulatePaste()

        if submitBehavior == .returnKey || submitBehavior == .terminalReturnKey {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                simulateReturn()
            }
        }

        let restoreDelay: TimeInterval = submitBehavior == .none ? 0.25 : 0.55
        DispatchQueue.main.asyncAfter(deadline: .now() + restoreDelay) {
            pasteboard.clearContents()
            if let previous {
                pasteboard.setString(previous, forType: .string)
            }
        }
    }

    private static func simulatePaste() {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true)
        keyDown?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)

        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        keyUp?.flags = .maskCommand
        keyUp?.post(tap: .cghidEventTap)
    }

    static func pasteboardPayload(for trimmedText: String, submitBehavior: TextSubmitBehavior) -> String {
        switch submitBehavior {
        case .none, .returnKey, .terminalReturnKey:
            return trimmedText
        }
    }

    private static func simulateReturn() {
        guard let source = CGEventSource(stateID: .privateState) else { return }
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Return), keyDown: true)
        keyDown?.flags = []
        keyDown?.post(tap: .cghidEventTap)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Return), keyDown: false)
            keyUp?.flags = []
            keyUp?.post(tap: .cghidEventTap)
        }
    }
}
