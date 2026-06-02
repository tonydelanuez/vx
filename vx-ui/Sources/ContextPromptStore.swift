import Foundation

// MARK: - ContextPromptStore

/// Manages per-context AI post-processing instruction files in `~/.vx/prompts/`.
///
/// Each file contains free-form text appended to the LLM system prompt when that
/// context is active. Comment lines (starting with `#`) are stripped before use
/// so users can annotate their files without affecting the AI output.
///
/// File naming mirrors the `AppContext.promptID` property:
///   `~/.vx/prompts/general.txt`   — always loaded (no context or fallback)
///   `~/.vx/prompts/email.txt`     — loaded when an email client is frontmost
///   `~/.vx/prompts/chat.txt`      — loaded for chat and messaging apps
///   `~/.vx/prompts/document.txt`  — loaded for document editors
///   `~/.vx/prompts/code.txt`      — loaded for code editors and IDEs
///   `~/.vx/prompts/terminal.txt`  — loaded for terminal emulators
struct ContextPromptStore {

    // MARK: Context list

    struct PromptContext: Identifiable {
        let id: String        // matches AppContext.promptID
        let displayName: String
    }

    /// One entry per `DictationMode`, in the same order.
    /// IDs match `DictationMode.promptID` (= `DictationMode.rawValue`).
    static let allContexts: [PromptContext] = DictationMode.allCases.map {
        PromptContext(id: $0.promptID, displayName: $0.displayName)
    }

    // MARK: Paths

    static var promptsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".vx/prompts")
    }

    static func promptURL(contextID: String) -> URL {
        promptsDirectory.appendingPathComponent("\(contextID).txt")
    }

    // MARK: Read / write

    /// Loads and returns the instructions for a context, with comment lines stripped.
    /// Returns an empty string if the file doesn't exist or is empty after stripping.
    static func load(contextID: String) -> String {
        let url = promptURL(contextID: contextID)
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return raw
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Writes raw content (including comments) to the context's file.
    static func save(_ content: String, contextID: String) throws {
        let url = promptURL(contextID: contextID)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try content.write(to: url, atomically: true, encoding: .utf8)
        vxLog("[prompts/save] Saved \(contextID).txt")
    }

    // MARK: Default files

    /// Creates default prompt files for any context that does not yet have one.
    /// Called once at launch — safe to call repeatedly.
    static func createDefaultFilesIfNeeded() {
        let dir = promptsDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for ctx in allContexts {
            let url = promptURL(contextID: ctx.id)
            guard !FileManager.default.fileExists(atPath: url.path) else { continue }
            try? defaultContent(for: ctx.id).write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private static func defaultContent(for contextID: String) -> String {
        switch contextID {
        case DictationMode.plainText.rawValue:
            return """
            # AI instructions for Plain Text mode.
            # Applied during general dictation with no specific app context.
            #
            # Example:
            # Always use American English spelling.

            """
        case DictationMode.email.rawValue:
            return """
            # AI instructions for Email mode (Mail, Outlook, Mimestream, etc.).
            #
            # Example:
            # Always close with "Best, [Your Name]".
            # Use a formal salutation if one is not already present.

            """
        case DictationMode.chat.rawValue:
            return """
            # AI instructions for Chat mode (Slack, Discord, Messages, Teams, etc.).
            #
            # Example:
            # Keep responses concise — no more than 2 sentences unless the input is long.
            # Contractions and casual punctuation are fine.

            """
        case DictationMode.markdown.rawValue:
            return """
            # AI instructions for Markdown mode (Notion, Obsidian, Notes, etc.).
            #
            # Example:
            # Format enumerated items as markdown bullet lists.
            # Use sentence case for headings.

            """
        case DictationMode.code.rawValue:
            return """
            # AI instructions for Code mode (Xcode, VS Code, Cursor, etc.).
            #
            # Example:
            # Preserve all camelCase and snake_case identifiers exactly as spoken.
            # Do not add prose punctuation inside code snippets.

            """
        case DictationMode.terminal.rawValue:
            return """
            # AI instructions for Terminal mode (Terminal, iTerm2, Warp, etc.).
            #
            # Preserve all flags, paths, and command syntax exactly.
            # Do not add trailing punctuation.

            """
        default:
            return "# AI instructions for \(contextID) mode.\n\n"
        }
    }
}
