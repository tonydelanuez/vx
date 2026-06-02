import Foundation

// MARK: - DictationMode

/// The high-level operating mode for dictation. Controls which normalisation pass
/// runs and which rule files are loaded from `~/.vx/rules/`.
public enum DictationMode: String, CaseIterable, Codable, Identifiable {
    case plainText = "plain"
    case email     = "email"
    case chat      = "chat"
    case code      = "code"
    case markdown  = "markdown"
    case terminal  = "terminal"

    public var id: String { rawValue }

    var displayName: String {
        switch self {
        case .plainText: return "Plain Text"
        case .email:     return "Email"
        case .chat:      return "Chat"
        case .code:      return "Code"
        case .markdown:  return "Markdown"
        case .terminal:  return "Terminal"
        }
    }

    /// SF Symbol name for use in menus and preferences.
    var systemSymbol: String {
        switch self {
        case .plainText: return "text.alignleft"
        case .email:     return "envelope"
        case .chat:      return "bubble.left.and.bubble.right"
        case .code:      return "chevron.left.forwardslash.chevron.right"
        case .markdown:  return "textformat"
        case .terminal:  return "terminal"
        }
    }

    /// Instruction appended to the LLM post-processor system prompt when this
    /// mode is active. Empty string means no additional instruction.
    var postProcessingHint: String {
        switch self {
        case .plainText:
            return ""
        case .email:
            return "CONTEXT: The user is composing an email. Use full sentences with proper punctuation and a professional tone. Capitalize greetings and closings where present."
        case .chat:
            return "CONTEXT: The user is typing in a chat or messaging app. Use a casual, conversational tone. Contractions are preferred. Sentence-final punctuation is optional for short messages. Avoid overly formal language."
        case .markdown:
            return "CONTEXT: The user is writing in a document or note-taking app. Use clear prose with proper paragraphs, punctuation, and capitalization. Format lists and headings where the speaker implies them."
        case .code:
            return "CONTEXT: The user is writing in a code editor. Preserve all technical identifiers, keywords, and syntax exactly. Do not rephrase code constructs or add prose punctuation."
        case .terminal:
            return "CONTEXT: The user is entering shell commands. Preserve all flags, paths, and command syntax exactly. Do not add prose punctuation."
        }
    }

    /// Key used to look up this mode's file in `ContextPromptStore` (`~/.vx/prompts/<promptID>.txt`).
    var promptID: String { rawValue }
}

// MARK: - CodeProfile

/// A language-specific rule pack active when `DictationMode == .code`.
///
/// vx does not "know" any language internally. The profile is only a key used to
/// locate the user-editable file at `~/.vx/rules/code/<profile>.yaml`. Adding a
/// new language means adding a case here and a YAML file — nothing else changes.
public enum CodeProfile: String, CaseIterable, Codable, Identifiable {
    case generic    = "generic"
    case swift      = "swift"
    case javascript = "javascript"
    case typescript = "typescript"
    case python     = "python"
    case go         = "go"
    case rust       = "rust"

    public var id: String { rawValue }

    var displayName: String {
        switch self {
        case .generic:    return "Generic"
        case .swift:      return "Swift"
        case .javascript: return "JavaScript"
        case .typescript: return "TypeScript"
        case .python:     return "Python"
        case .go:         return "Go"
        case .rust:       return "Rust"
        }
    }

    /// The filename within the `code/` subdirectory.
    var ruleFileName: String { "\(rawValue).yaml" }
}

// MARK: - RuleContext

/// Fully describes what rules should be loaded for a given dictation session.
///
/// This is the single value that flows from AppState → TransformationPipeline →
/// RuleStore. Adding new context dimensions (repo-local rules, auto-detected app,
/// etc.) means extending this struct, not changing every call site individually.
struct RuleContext: Equatable {
    let mode: DictationMode

    /// Active language profile. Only used when `mode == .code`; ignored otherwise.
    let codeProfile: CodeProfile

    static let `default` = RuleContext(mode: .plainText, codeProfile: .generic)

    /// Human-readable label for use in status messages and trace headers.
    var descriptionForDisplay: String {
        switch mode {
        case .code: return "\(mode.displayName) / \(codeProfile.displayName)"
        default:    return mode.displayName
        }
    }
}
