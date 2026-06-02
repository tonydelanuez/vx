import ApplicationServices
import Foundation

// MARK: - AppContext

/// The high-level context inferred from the frontmost application.
///
/// Used to auto-select a `DictationMode` for the transformation pipeline and to
/// inject a formatting hint into the LLM post-processor system prompt.
enum AppContext {
    case email
    case chat
    case document
    case code(CodeProfile)
    case terminal
    /// No match found — caller falls back to the user's manually selected mode.
    case general
}

extension AppContext {
    /// The `DictationMode` to use for rule loading when this context is active.
    var dictationMode: DictationMode {
        switch self {
        case .email:    return .email
        case .chat:     return .chat
        case .document: return .markdown
        case .code:     return .code
        case .terminal: return .terminal
        case .general:  return .plainText
        }
    }

    /// The `CodeProfile` to use when `dictationMode == .code`.
    var codeProfile: CodeProfile {
        if case .code(let profile) = self { return profile }
        return .generic
    }

    /// Human-readable label for log messages.
    var displayName: String {
        switch self {
        case .email:           return "Email"
        case .chat:            return "Chat"
        case .document:        return "Document"
        case .code(let p):     return "Code (\(p.displayName))"
        case .terminal:        return "Terminal"
        case .general:         return "General"
        }
    }

    /// The raw YAML string that round-trips through `AppContext(yamlValue:)`.
    var yamlValue: String {
        switch self {
        case .email:    return "email"
        case .chat:     return "chat"
        case .document: return "document"
        case .terminal: return "terminal"
        case .general:  return "general"
        case .code(let profile):
            return profile == .generic ? "code" : "code/\(profile.rawValue)"
        }
    }

    // MARK: YAML parsing

    /// Parses a context string from `app-contexts.yaml`.
    ///
    /// Valid values:
    /// - `email`, `chat`, `document`, `terminal`, `general`
    /// - `code` (generic profile)
    /// - `code/swift`, `code/python`, `code/typescript`, `code/javascript`,
    ///   `code/go`, `code/rust`
    init?(yamlValue: String) {
        let v = yamlValue.trimmingCharacters(in: .whitespaces).lowercased()
        switch v {
        case "email":    self = .email
        case "chat":     self = .chat
        case "document": self = .document
        case "terminal": self = .terminal
        case "general":  self = .general
        case "code":     self = .code(.generic)
        default:
            guard v.hasPrefix("code/") else { return nil }
            let profileRaw = String(v.dropFirst("code/".count))
            self = .code(CodeProfile(rawValue: profileRaw) ?? .generic)
        }
    }
}

// MARK: - AppContextDetector

struct AppContextDetector {
    // MARK: Public API

    /// Maps a bundle identifier to an `AppContext`.
    ///
    /// Custom mappings from `~/.vx/app-contexts.yaml` take precedence over the
    /// built-in table, allowing users to override or extend the defaults.
    /// When `pid` is provided and the built-in lookup returns `.general`, the
    /// frontmost window title is read via the Accessibility API and matched
    /// against common keywords (e.g. "Gmail" → `.email`). This allows browsers
    /// to be classified without knowing the URL.
    static func detect(bundleID: String, pid: pid_t = 0) -> AppContext {
        if let custom = customMappings()[bundleID] {
            return custom
        }
        let ctx = builtIn(bundleID: bundleID)
        if case .general = ctx, pid > 0, isKnownBrowser(bundleID: bundleID) {
            if let title = windowTitle(pid: pid),
               let inferred = inferContext(fromTitle: title) {
                return inferred
            }
        }
        return ctx
    }

    // MARK: Window-title inference

    static let knownBrowserIDs: Set<String> = [
        "com.google.Chrome", "com.apple.Safari", "org.mozilla.firefox",
        "com.microsoft.edgemac", "com.brave.Browser", "com.operasoftware.Opera",
        "com.vivaldi.Vivaldi", "com.google.Chrome.canary",
    ]

    private static func isKnownBrowser(bundleID: String) -> Bool {
        knownBrowserIDs.contains(bundleID)
    }

    /// Reads the title of the frontmost window of the given process via the
    /// Accessibility API. Returns nil if permission is not granted or the title
    /// is unavailable.
    static func windowTitle(pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        let axApp = AXUIElementCreateApplication(pid)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &ref) == .success,
              let windowRef = ref else { return nil }
        // swiftlint:disable:next force_cast
        let axWindow = windowRef as! AXUIElement
        var titleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleRef) == .success,
              let title = titleRef as? String, !title.isEmpty else { return nil }
        return title
    }

    /// Matches common site names in a browser window title to an `AppContext`.
    static func inferContext(fromTitle title: String) -> AppContext? {
        let t = title.lowercased()
        // Email — check before generic "mail" to avoid false positives
        let emailSites = ["gmail", "google mail", "outlook.com", "yahoo mail",
                          "protonmail", "fastmail", "hey.com", "superhuman",
                          "apple mail", " mail -", "- mail"]
        if emailSites.contains(where: { t.contains($0) }) { return .email }

        // Chat
        let chatSites = ["slack", "discord", "telegram", "whatsapp", "linear",
                         "messenger", "teams.microsoft"]
        if chatSites.contains(where: { t.contains($0) }) { return .chat }

        // Document / notes
        let docSites = ["google docs", "docs.google", "notion", "confluence",
                        "quip", "coda.io", "dropbox paper", "github wiki",
                        "hackmd", "overleaf"]
        if docSites.contains(where: { t.contains($0) }) { return .document }

        // Code
        let codeSites = ["github", "gitlab", "bitbucket", "codepen", "replit",
                         "codesandbox", "stack overflow", "jsfiddle"]
        if codeSites.contains(where: { t.contains($0) }) { return .code(.generic) }

        return nil
    }

    /// Creates `~/.vx/app-contexts.yaml` with commented-out examples if it does
    /// not already exist. Called once at launch.
    static func createDefaultFileIfNeeded() {
        let url = configFileURL
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? defaultFileContents.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: Custom mappings

    /// Loads and parses `~/.vx/app-contexts.yaml`.
    ///
    /// The file is read fresh on each call (invoked once per recording session,
    /// so the overhead is negligible and edits take effect without restarting).
    static func customMappings() -> [String: AppContext] {
        guard let raw = try? String(contentsOf: configFileURL, encoding: .utf8) else {
            return [:]
        }
        var result: [String: AppContext] = [:]
        for line in raw.components(separatedBy: .newlines) {
            // Strip inline comments and skip blank / comment-only lines.
            let stripped = line.components(separatedBy: " #").first ?? line
            let trimmed = stripped.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }

            // Split on the first `: ` only.
            guard let colonRange = trimmed.range(of: ": ") else { continue }
            let bundleID = String(trimmed[trimmed.startIndex ..< colonRange.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            let valueStr = String(trimmed[colonRange.upperBound...])
                .trimmingCharacters(in: .whitespaces)

            guard !bundleID.isEmpty, let ctx = AppContext(yamlValue: valueStr) else { continue }
            result[bundleID] = ctx
        }
        return result
    }

    /// Returns raw (bundleID, contextValue) pairs from the config file, preserving
    /// the order and string form so the UI can round-trip without data loss.
    static func loadRawMappings() -> [(bundleID: String, contextValue: String)] {
        guard let raw = try? String(contentsOf: configFileURL, encoding: .utf8) else {
            return []
        }
        var result: [(bundleID: String, contextValue: String)] = []
        for line in raw.components(separatedBy: .newlines) {
            let stripped = line.components(separatedBy: " #").first ?? line
            let trimmed = stripped.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            guard let colonRange = trimmed.range(of: ": ") else { continue }
            let bundleID = String(trimmed[trimmed.startIndex ..< colonRange.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            let valueStr = String(trimmed[colonRange.upperBound...])
                .trimmingCharacters(in: .whitespaces)
            guard !bundleID.isEmpty, AppContext(yamlValue: valueStr) != nil else { continue }
            result.append((bundleID: bundleID, contextValue: valueStr))
        }
        return result
    }

    /// Writes the given mappings back to `~/.vx/app-contexts.yaml`, replacing the
    /// managed entries section while preserving the standard header comments.
    static func saveCustomMappings(_ entries: [(bundleID: String, contextValue: String)]) throws {
        let header = """
        # vx app context mappings
        # Maps macOS bundle IDs to dictation contexts.
        # Custom entries here override vx's built-in mappings.
        #
        # Contexts:
        #   email, chat, document, terminal, general
        #   code, code/swift, code/python, code/typescript, code/javascript, code/go, code/rust
        #
        # To find an app's bundle ID, run in Terminal:
        #   osascript -e 'id of app "AppName"'

        """
        let entryLines = entries
            .filter { !$0.bundleID.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { "\($0.bundleID): \($0.contextValue)" }
        let content = header + entryLines.joined(separator: "\n") + (entryLines.isEmpty ? "" : "\n")
        let url = configFileURL
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: Private helpers

    internal static var configFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".vx/app-contexts.yaml")
    }

    private static let defaultFileContents = """
    # vx app context mappings
    # Maps macOS bundle IDs to dictation contexts.
    # Custom entries here override vx's built-in mappings.
    #
    # Contexts:
    #   email     - professional prose, formal tone
    #   chat      - casual messaging, relaxed punctuation
    #   document  - structured prose, markdown formatting
    #   terminal  - shell commands, preserve syntax exactly
    #   code      - generic code mode
    #   code/swift, code/python, code/typescript, code/javascript,
    #   code/go, code/rust  - language-specific code mode
    #   general   - no override; falls back to your manually selected mode
    #
    # To find an app's bundle ID, run in Terminal:
    #   osascript -e 'id of app "AppName"'
    #
    # Examples (uncomment and edit as needed):
    #
    # com.google.Chrome: document
    # com.figma.Desktop: document
    # com.linear.linear: chat
    # com.superhuman.Superhuman: email
    # com.apple.Safari: general

    """

    // MARK: Built-in mappings

    private static func builtIn(bundleID: String) -> AppContext {
        switch bundleID {

        // Email
        case "com.apple.mail",
             "com.microsoft.Outlook",
             "com.microsoft.outlook",
             "com.airmail.airmail4",
             "com.mimestream.Mimestream",
             "com.readdle.smartemail-mac":
            return .email

        // Chat / messaging
        case "com.tinyspeck.slackmacgap",       // Slack
             "com.hnc.Discord",                  // Discord
             "com.apple.iChat",                  // Messages
             "com.apple.MobileSMS",              // Messages (alias)
             "com.microsoft.teams2",             // Microsoft Teams (new)
             "com.microsoft.teams",              // Microsoft Teams (old)
             "ru.keepcoder.Telegram",            // Telegram
             "org.telegram.desktop",             // Telegram Desktop
             "io.textsoapp.Texts",               // Texts
             "com.beeper.beeper",                // Beeper
             "com.facebook.archon",              // Messenger
             "com.facebook.archon.developerid",  // Messenger (alt)
             "com.whatsapp.WhatsApp",            // WhatsApp
             "com.skype.skype",                  // Skype
             "com.loom.desktop",                 // Loom (async video chat)
             "com.zoomus.xos.zoom":              // Zoom chat
            return .chat

        // Document / notes editors
        case "notion.id",                        // Notion
             "md.obsidian",                      // Obsidian
             "com.apple.Notes",                  // Apple Notes
             "net.shinyfrog.bear",               // Bear
             "com.craftdocs.craft",              // Craft
             "com.microsoft.Word",               // Microsoft Word
             "org.libreoffice.script",           // LibreOffice Writer
             "com.airtable.airtable",            // Airtable
             "com.github.atom",                  // Atom (markdown writing)
             "com.coteditor.CotEditor",          // CotEditor
             "com.multimarkdown-composer.MultiMarkdownComposer":
            return .document

        // Code editors / IDEs
        case "com.apple.dt.Xcode",
             "com.apple.dt.playground":
            return .code(.swift)

        case "com.microsoft.VSCode",
             "io.cursor.Cursor",             // Cursor (older builds)
             "com.todesktop.230313mzl4w4u92", // Cursor (ToDesktop distribution)
             "com.cursor.CursorAI":           // Cursor (alternate)
            return .code(.generic)

        case "com.jetbrains.pycharm",
             "com.jetbrains.pycharm.ce":
            return .code(.python)

        case "com.jetbrains.webstorm":
            return .code(.typescript)

        case "com.jetbrains.goland":
            return .code(.go)

        case "com.jetbrains.intellij",
             "com.jetbrains.intellij.ce",
             "com.jetbrains.AppCode",
             "com.jetbrains.rider",
             "com.jetbrains.clion",
             "com.jetbrains.rubymine",
             "com.jetbrains.dataspell",
             "com.sublimetext.4",
             "com.sublimetext.3",
             "org.vim.MacVim",
             "com.neovide.neovide",
             "com.github.github-mac",
             "dev.zed.Zed",    // Zed
             "rs.zed.Zed":     // Zed (alternate)
            return .code(.generic)

        // Terminals
        case "com.apple.Terminal",
             "com.googlecode.iterm2",
             "dev.warp.desktop",
             "com.github.wez.wezterm",
             "io.alacritty":
            return .terminal

        default:
            return .general
        }
    }
}
