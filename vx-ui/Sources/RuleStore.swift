import AppKit
import Foundation

// MARK: - Rule model

/// A single transformation rule: if the trigger phrase appears in the transcript,
/// replace it with the replacement string.
struct RuleDefinition: Equatable {
    let trigger: String
    let replace: String
}

// MARK: - RuleStore

/// Loads and caches rules from `~/.vx/rules/`.
///
/// Resolution order:
///
///   plainText / markdown / terminal modes:
///     1. global.yaml
///     2. <mode>.yaml          e.g. markdown.yaml
///
///   code mode (any profile):
///     1. global.yaml          — universal symbols, shared across everything
///     2. code/global.yaml     — symbols shared across all code profiles
///     3. code/<profile>.yaml  — language-specific rules  e.g. code/go.yaml
///
///   Rules within each file are applied top-to-bottom.
///   Files at higher precedence positions cannot be overridden by lower ones —
///   all rules are concatenated and applied in load order.
///
/// Files are loaded lazily and cached until `reload()` is called.
/// Starter files are written on first launch if they do not already exist.
/// An existing `code.yaml` at the root (from the previous single-file layout)
/// is left untouched but is no longer loaded by the new resolution logic.
final class RuleStore {
    static let shared = RuleStore()

    /// Exposed for display in Preferences.
    let rulesDirectory: URL

    private var cache: [String: [RuleDefinition]] = [:]
    /// Modification time of each file when it was cached. A file is re-read when its
    /// on-disk mtime no longer matches, so edits are picked up without an explicit
    /// reload() or app restart.
    private var cacheMTimes: [String: Date?] = [:]

    /// Maps relative path → human-readable error for files that failed to load.
    /// Cleared on `reload()`. Read by the Rules preferences tab.
    private(set) var loadErrors: [String: String] = [:]

    /// Maps relative path → non-fatal lint warnings for rules that loaded but look
    /// wrong (e.g. smart quotes, empty trigger, duplicate triggers). Cleared on
    /// `reload()`. Read by the Rules preferences tab.
    private(set) var loadWarnings: [String: [String]] = [:]

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        rulesDirectory = home.appendingPathComponent(".vx/rules", isDirectory: true)
        createDefaultFilesIfNeeded()
    }

    /// Test-only initializer that points the store at an arbitrary directory.
    /// Does not bootstrap default files, so the test controls the directory contents.
    init(rulesDirectory: URL) {
        self.rulesDirectory = rulesDirectory
    }

    // MARK: - Public API

    /// Returns the merged rule list for `context`, in resolution order.
    func rules(for context: RuleContext) -> [RuleDefinition] {
        taggedRules(for: context).map(\.rule)
    }

    /// Returns rules paired with their relative source path, in application order.
    /// The `source` string is suitable for display in trace output, e.g. "code/go.yaml".
    func taggedRules(for context: RuleContext) -> [(rule: RuleDefinition, source: String)] {
        var result: [(rule: RuleDefinition, source: String)] = []

        // Tier 1: global rules (every mode)
        result += load("global.yaml")

        switch context.mode {
        case .plainText:
            result += load("plain.yaml")

        case .email:
            result += load("email.yaml")

        case .chat:
            result += load("chat.yaml")

        case .markdown:
            result += load("markdown.yaml")

        case .terminal:
            result += load("terminal.yaml")

        case .code:
            // Tier 2: shared code rules (all profiles)
            result += load("code/global.yaml")
            // Tier 3: language-specific profile rules
            result += load("code/\(context.codeProfile.ruleFileName)")
        }

        return result
    }

    /// Returns load errors for the files involved in resolving `context`.
    /// Empty means all files loaded cleanly (or haven't been tried yet).
    func relevantLoadErrors(for context: RuleContext) -> [(file: String, message: String)] {
        resolutionPaths(for: context).compactMap { path in
            loadErrors[path].map { (file: path, message: $0) }
        }
    }

    /// Clears the rule cache and all recorded load errors.
    /// Call after the user edits rule files.
    func reload() {
        cache.removeAll()
        cacheMTimes.removeAll()
        loadErrors.removeAll()
        loadWarnings.removeAll()
        vxLog("[rules/store] Cache cleared — rules will reload on next use")
    }

    /// Returns lint warnings for the files involved in resolving `context`.
    /// Empty means every relevant file is clean (or hasn't been loaded yet).
    func relevantWarnings(for context: RuleContext) -> [(file: String, message: String)] {
        resolutionPaths(for: context).flatMap { path in
            (loadWarnings[path] ?? []).map { (file: path, message: $0) }
        }
    }

    /// Opens `~/.vx/rules/` in Finder.
    func openRulesDirectory() {
        NSWorkspace.shared.open(rulesDirectory)
    }

    // MARK: - Path helpers

    /// Ordered list of relative file paths consulted for `context`.
    /// Matches the order in `taggedRules(for:)` exactly.
    func resolutionPaths(for context: RuleContext) -> [String] {
        switch context.mode {
        case .plainText: return ["global.yaml", "plain.yaml"]
        case .email:     return ["global.yaml", "email.yaml"]
        case .chat:      return ["global.yaml", "chat.yaml"]
        case .markdown:  return ["global.yaml", "markdown.yaml"]
        case .terminal:  return ["global.yaml", "terminal.yaml"]
        case .code:      return ["global.yaml", "code/global.yaml", "code/\(context.codeProfile.ruleFileName)"]
        }
    }

    // MARK: - File loading

    /// Loads `relativePath` under `rulesDirectory`, caching the result.
    /// On error, records to `loadErrors` and returns an empty tagged list.
    private func load(_ relativePath: String) -> [(rule: RuleDefinition, source: String)] {
        let rules = loadFile(relativePath)
        return rules.map { (rule: $0, source: relativePath) }
    }

    private func loadFile(_ relativePath: String) -> [RuleDefinition] {
        let url = rulesDirectory.appendingPathComponent(relativePath)
        let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        // Serve the cache only while the file is unchanged since we cached it.
        if let cached = cache[relativePath], let cachedMTime = cacheMTimes[relativePath], cachedMTime == mtime {
            return cached
        }
        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            let rules = parseYAML(content)
            cache[relativePath] = rules
            cacheMTimes[relativePath] = mtime
            loadErrors.removeValue(forKey: relativePath)
            let warnings = RuleStore.lint(rules)
            if warnings.isEmpty {
                loadWarnings.removeValue(forKey: relativePath)
            } else {
                loadWarnings[relativePath] = warnings
                for w in warnings { vxLog("[rules/store] Warning in \(relativePath): \(w)") }
            }
            vxLog("[rules/store] Loaded \(rules.count) rule(s) from \(relativePath)")
            return rules
        } catch {
            let message = error.localizedDescription
            loadErrors[relativePath] = message
            loadWarnings.removeValue(forKey: relativePath)
            vxLog("[rules/store] Could not load \(relativePath): \(message)")
            cache[relativePath] = []
            cacheMTimes[relativePath] = mtime
            return []
        }
    }

    // MARK: - Lint

    /// Non-fatal checks for rules that parsed but probably won't behave as the user
    /// intends. Generic and additive — each check appends a human-readable warning.
    static func lint(_ rules: [RuleDefinition]) -> [String] {
        var warnings: [String] = []
        let smartQuotes = CharacterSet(charactersIn: "\u{201C}\u{201D}\u{2018}\u{2019}")
        var seenTriggers = Set<String>()

        for rule in rules {
            let label = rule.trigger.isEmpty ? "(empty)" : "\"\(rule.trigger)\""

            if rule.trigger.rangeOfCharacter(from: smartQuotes) != nil
                || rule.replace.rangeOfCharacter(from: smartQuotes) != nil {
                warnings.append("Rule \(label) uses curly/smart quotes (\u{201C} \u{201D} \u{2018} \u{2019}); they are matched literally and won't behave as quotes. Use straight \" or '.")
            }

            if rule.trigger.trimmingCharacters(in: .whitespaces).isEmpty {
                warnings.append("A rule has an empty or whitespace-only trigger; it will never match.")
            }

            let key = rule.trigger.lowercased()
            if !key.isEmpty, !seenTriggers.insert(key).inserted {
                warnings.append("Duplicate trigger \(label); only the first occurrence takes effect.")
            }
        }
        return warnings
    }

    // MARK: - YAML parser
    //
    // Parses a strict subset of YAML sufficient for our rule format:
    //
    //   rules:
    //     - trigger: "some phrase"
    //       replace: "replacement"
    //
    // Supported value quoting:
    //   double-quoted  → escape sequences \n \t \\ \" processed
    //   single-quoted  → '' becomes '
    //   unquoted       → inline # comments stripped
    //
    // Unknown keys are silently skipped so future fields are forward-compatible.

    func parseYAML(_ content: String) -> [RuleDefinition] {
        var rules: [RuleDefinition] = []
        var pendingTrigger: String?
        var inRulesSection = false

        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            if trimmed == "rules:" || trimmed == "rules: []" {
                inRulesSection = true
                continue
            }
            guard inRulesSection else { continue }

            if trimmed.hasPrefix("- trigger:") {
                pendingTrigger = extractValue(from: trimmed, key: "- trigger:")
            } else if trimmed.hasPrefix("trigger:") {
                pendingTrigger = extractValue(from: trimmed, key: "trigger:")
            } else if trimmed.hasPrefix("replace:") {
                let replacement = extractValue(from: trimmed, key: "replace:") ?? ""
                if let trigger = pendingTrigger, !trigger.isEmpty {
                    rules.append(RuleDefinition(trigger: trigger, replace: replacement))
                }
                pendingTrigger = nil
            }
            // Unknown keys are skipped here.
        }

        return rules
    }

    func extractValue(from line: String, key: String) -> String? {
        guard let range = line.range(of: key) else { return nil }
        let remainder = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        return unquote(remainder)
    }

    func unquote(_ s: String) -> String {
        if s.hasPrefix("\"") && s.hasSuffix("\"") && s.count >= 2 {
            let inner = String(s.dropFirst().dropLast())
            return inner
                .replacingOccurrences(of: "\\\\", with: "\u{FFFE}")
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\n",  with: "\n")
                .replacingOccurrences(of: "\\t",  with: "\t")
                .replacingOccurrences(of: "\\r",  with: "\r")
                .replacingOccurrences(of: "\u{FFFE}", with: "\\")
        }
        if s.hasPrefix("'") && s.hasSuffix("'") && s.count >= 2 {
            return String(s.dropFirst().dropLast())
                .replacingOccurrences(of: "''", with: "'")
        }
        if let commentRange = s.range(of: " #") {
            return String(s[s.startIndex..<commentRange.lowerBound])
                .trimmingCharacters(in: .whitespaces)
        }
        return s
    }

    // MARK: - Default file bootstrapping

    private func createDefaultFilesIfNeeded() {
        let fm = FileManager.default

        // Create top-level and code/ subdirectory
        let codeDir = rulesDirectory.appendingPathComponent("code", isDirectory: true)
        for dir in [rulesDirectory, codeDir] {
            do { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
            catch { vxLog("[rules/store] Could not create directory \(dir.path): \(error)"); return }
        }

        let files: [(path: String, content: String)] = [
            // Top-level files
            ("global.yaml",   Self.defaultGlobal),
            ("plain.yaml",    Self.defaultPlain),
            ("email.yaml",    Self.defaultEmail),
            ("chat.yaml",     Self.defaultChat),
            ("markdown.yaml", Self.defaultMarkdown),
            ("terminal.yaml", Self.defaultTerminal),
            // code/ subdirectory
            ("code/global.yaml",     Self.defaultCodeGlobal),
            ("code/generic.yaml",    Self.defaultCodeGeneric),
            ("code/swift.yaml",      Self.defaultCodeSwift),
            ("code/javascript.yaml", Self.defaultCodeJavaScript),
            ("code/typescript.yaml", Self.defaultCodeTypeScript),
            ("code/python.yaml",     Self.defaultCodePython),
            ("code/go.yaml",         Self.defaultCodeGo),
            ("code/rust.yaml",       Self.defaultCodeRust),
        ]

        for (path, content) in files {
            let url = rulesDirectory.appendingPathComponent(path)
            guard !fm.fileExists(atPath: url.path) else { continue }
            do {
                try content.write(to: url, atomically: true, encoding: .utf8)
                vxLog("[rules/store] Created default file: \(path)")
            } catch {
                vxLog("[rules/store] Could not write \(path): \(error)")
            }
        }
    }
}

// MARK: - Default rule file content

private extension RuleStore {

    // -------------------------------------------------------------------------
    // global.yaml — universal dictation helpers, applied in every mode
    // -------------------------------------------------------------------------
    static let defaultGlobal = """
# Global rules — applied in every mode before any mode-specific rules.
# Rules are matched case-insensitively and applied top-to-bottom.
#
# Format:
#   rules:
#     - trigger: "spoken phrase"
#       replace: "inserted text"
#
# Double-quoted values support escape sequences: \\n  \\t  \\\\  \\"

rules:
  - trigger: "new line"
    replace: "\\n"
  - trigger: "new paragraph"
    replace: "\\n\\n"
  - trigger: "tab key"
    replace: "\\t"
  - trigger: "percent sign"
    replace: "%"
  - trigger: "at sign"
    replace: "@"
  - trigger: "hash sign"
    replace: "#"
  - trigger: "ampersand"
    replace: "&"
  - trigger: "asterisk"
    replace: "*"
  - trigger: "plus sign"
    replace: "+"
  - trigger: "minus sign"
    replace: "-"
  - trigger: "equals sign"
    replace: "="
  - trigger: "slash"
    replace: "/"
  - trigger: "backslash"
    replace: "\\\\"
  - trigger: "underscore"
    replace: "_"
  - trigger: "pipe"
    replace: "|"
  - trigger: "tilde"
    replace: "~"
  - trigger: "backtick"
    replace: "`"
  - trigger: "single quote"
    replace: "'"
  - trigger: "double quote"
    replace: "\\""
"""

    // -------------------------------------------------------------------------
    // plain.yaml — minimal; intentionally sparse
    // -------------------------------------------------------------------------
    static let defaultPlain = """
# Plain text mode rules.
# Intentionally sparse — plain dictation needs minimal transformation.
# Add personal shortcuts here, e.g.:
#
#   - trigger: "my email"
#     replace: "you@example.com"

rules: []
"""

    // -------------------------------------------------------------------------
    // email.yaml
    // -------------------------------------------------------------------------
    static let defaultEmail = """
# Email mode rules — applied after global.yaml.
# Formatting is primarily handled by AI post-processing.
# Add shortcuts specific to email composition here, e.g.:
#
#   - trigger: "best regards"
#     replace: "Best regards,"
#
#   - trigger: "my email address"
#     replace: "you@example.com"

rules: []
"""

    // -------------------------------------------------------------------------
    // chat.yaml
    // -------------------------------------------------------------------------
    static let defaultChat = """
# Chat mode rules — applied after global.yaml.
# Formatting is primarily handled by AI post-processing.
# Add shortcuts specific to chat messaging here, e.g.:
#
#   - trigger: "thumbs up"
#     replace: "👍"
#
#   - trigger: "laugh out loud"
#     replace: "lol"

rules: []
"""

    // -------------------------------------------------------------------------
    // markdown.yaml
    // -------------------------------------------------------------------------
    static let defaultMarkdown = """
# Markdown mode rules — applied after global.yaml.

rules:
  # Headings
  - trigger: "heading one"
    replace: "# "
  - trigger: "heading two"
    replace: "## "
  - trigger: "heading three"
    replace: "### "
  - trigger: "heading four"
    replace: "#### "

  # Inline formatting
  - trigger: "bold"
    replace: "**"
  - trigger: "italic"
    replace: "_"
  - trigger: "inline code"
    replace: "`"
  - trigger: "strikethrough"
    replace: "~~"

  # Block elements
  - trigger: "bullet point"
    replace: "- "
  - trigger: "numbered item"
    replace: "1. "
  - trigger: "code block"
    replace: "```"
  - trigger: "blockquote"
    replace: "> "
  - trigger: "horizontal rule"
    replace: "---"
  - trigger: "task item"
    replace: "- [ ] "
  - trigger: "checked task"
    replace: "- [x] "

  # Links / images
  - trigger: "link text"
    replace: "[]()"
  - trigger: "image"
    replace: "![]()"
"""

    // -------------------------------------------------------------------------
    // terminal.yaml
    // -------------------------------------------------------------------------
    static let defaultTerminal = """
# Terminal mode rules — applied after global.yaml.

rules:
  # Redirection and logic
  - trigger: "redirect"
    replace: ">"
  - trigger: "append"
    replace: ">>"
  - trigger: "redirect error"
    replace: "2>"
  - trigger: "redirect all"
    replace: "&>"
  - trigger: "background"
    replace: "&"
  - trigger: "and and"
    replace: "&&"
  - trigger: "or or"
    replace: "||"

  # Paths
  - trigger: "dollar sign"
    replace: "$"
  - trigger: "tilde slash"
    replace: "~/"
  - trigger: "dot slash"
    replace: "./"
  - trigger: "dot dot slash"
    replace: "../"
  - trigger: "dev null"
    replace: "/dev/null"

  # Git shortcuts
  - trigger: "git checkout branch"
    replace: "git checkout -b "
  - trigger: "git status"
    replace: "git status"
  - trigger: "git add all"
    replace: "git add -A"
  - trigger: "git push origin"
    replace: "git push origin "

  # Common flags
  - trigger: "flag recursive"
    replace: "-r"
  - trigger: "flag force"
    replace: "-f"
  - trigger: "flag verbose"
    replace: "-v"
  - trigger: "flag all"
    replace: "-a"
"""

    // -------------------------------------------------------------------------
    // code/global.yaml — shared across all code profiles
    // -------------------------------------------------------------------------
    static let defaultCodeGlobal = """
# Code rules shared across all language profiles.
# Loaded after global.yaml, before the profile-specific file.
# Put bracket/operator shortcuts here so every language gets them.

rules:
  # Brackets and delimiters
  - trigger: "open brace"
    replace: "{"
  - trigger: "close brace"
    replace: "}"
  - trigger: "open bracket"
    replace: "["
  - trigger: "close bracket"
    replace: "]"
  - trigger: "open paren"
    replace: "("
  - trigger: "close paren"
    replace: ")"
  - trigger: "open angle"
    replace: "<"
  - trigger: "close angle"
    replace: ">"

  # Operators
  - trigger: "equals equals"
    replace: "=="
  - trigger: "triple equals"
    replace: "==="
  - trigger: "not equals"
    replace: "!="
  - trigger: "strict not equals"
    replace: "!=="
  - trigger: "less than or equal"
    replace: "<="
  - trigger: "greater than or equal"
    replace: ">="
  - trigger: "arrow"
    replace: "->"
  - trigger: "fat arrow"
    replace: "=>"
  - trigger: "double colon"
    replace: "::"
  - trigger: "bang"
    replace: "!"
  - trigger: "double ampersand"
    replace: "&&"
  - trigger: "double pipe"
    replace: "||"
  - trigger: "dot dot dot"
    replace: "..."
  - trigger: "dot dot"
    replace: ".."
"""

    // -------------------------------------------------------------------------
    // code/generic.yaml — language-agnostic code snippets
    // -------------------------------------------------------------------------
    static let defaultCodeGeneric = """
# Generic code profile — language-agnostic snippets.
# Loaded after code/global.yaml.
# A good place for patterns that work across multiple languages.

rules:
  - trigger: "semicolon"
    replace: ";"
  - trigger: "colon colon"
    replace: "::"
  - trigger: "question mark"
    replace: "?"
  - trigger: "null check"
    replace: "!= null"
  - trigger: "not null"
    replace: "!= null"
  - trigger: "todo comment"
    replace: "// TODO: "
  - trigger: "fixme comment"
    replace: "// FIXME: "
"""

    // -------------------------------------------------------------------------
    // code/swift.yaml
    // -------------------------------------------------------------------------
    static let defaultCodeSwift = """
# Swift code profile.
# Loaded after global.yaml and code/global.yaml.

rules:
  # Types and optionals
  - trigger: "optional type"
    replace: "?"
  - trigger: "force unwrap"
    replace: "!"
  - trigger: "nil coalescing"
    replace: " ?? "
  - trigger: "if let"
    replace: "if let  = "
  - trigger: "guard let"
    replace: "guard let  = "

  # Common patterns
  - trigger: "returns void"
    replace: "-> Void"
  - trigger: "return nil"
    replace: "return nil"
  - trigger: "throws error"
    replace: "throws"
  - trigger: "async await"
    replace: "async"
  - trigger: "main actor"
    replace: "@MainActor"
  - trigger: "published"
    replace: "@Published"
  - trigger: "observed object"
    replace: "@ObservedObject"
  - trigger: "state object"
    replace: "@StateObject"
  - trigger: "environment object"
    replace: "@EnvironmentObject"

  # Logging (matches vx's own convention)
  - trigger: "v x log"
    replace: "vxLog(\\"[\\")"
"""

    // -------------------------------------------------------------------------
    // code/javascript.yaml
    // -------------------------------------------------------------------------
    static let defaultCodeJavaScript = """
# JavaScript code profile.
# Loaded after global.yaml and code/global.yaml.

rules:
  # Declarations
  - trigger: "const"
    replace: "const "
  - trigger: "let var"
    replace: "let "
  - trigger: "arrow function"
    replace: "() => "
  - trigger: "async function"
    replace: "async function "
  - trigger: "await"
    replace: "await "

  # Common expressions
  - trigger: "console log"
    replace: "console.log()"
  - trigger: "console error"
    replace: "console.error()"
  - trigger: "strict mode"
    replace: "'use strict';"
  - trigger: "undefined check"
    replace: "=== undefined"
  - trigger: "null check"
    replace: "=== null"
  - trigger: "spread operator"
    replace: "..."
  - trigger: "template literal"
    replace: "``"
  - trigger: "optional chain"
    replace: "?."
  - trigger: "nullish"
    replace: " ?? "

  # Modules
  - trigger: "export default"
    replace: "export default "
  - trigger: "named export"
    replace: "export "
"""

    // -------------------------------------------------------------------------
    // code/typescript.yaml
    // -------------------------------------------------------------------------
    static let defaultCodeTypeScript = """
# TypeScript code profile.
# Loaded after global.yaml and code/global.yaml.
# Inherits all JavaScript patterns — duplicate common ones here if needed.

rules:
  # Types
  - trigger: "type alias"
    replace: "type  = "
  - trigger: "interface"
    replace: "interface  {}"
  - trigger: "readonly"
    replace: "readonly "
  - trigger: "optional field"
    replace: "?: "
  - trigger: "as type"
    replace: " as "
  - trigger: "generic type"
    replace: "<>"
  - trigger: "unknown type"
    replace: "unknown"
  - trigger: "never type"
    replace: "never"
  - trigger: "void type"
    replace: "void"

  # Utility types
  - trigger: "partial type"
    replace: "Partial<>"
  - trigger: "required type"
    replace: "Required<>"
  - trigger: "record type"
    replace: "Record<string, >"
  - trigger: "pick type"
    replace: "Pick<>"
  - trigger: "omit type"
    replace: "Omit<>"

  # Declarations (same as JS but worth keeping here)
  - trigger: "const"
    replace: "const "
  - trigger: "async function"
    replace: "async function "
  - trigger: "await"
    replace: "await "
  - trigger: "console log"
    replace: "console.log()"
"""

    // -------------------------------------------------------------------------
    // code/python.yaml
    // -------------------------------------------------------------------------
    static let defaultCodePython = """
# Python code profile.
# Loaded after global.yaml and code/global.yaml.

rules:
  # Structure
  - trigger: "main guard"
    replace: "if __name__ == '__main__':"
  - trigger: "self dot"
    replace: "self."
  - trigger: "class init"
    replace: "def __init__(self):"
  - trigger: "class method"
    replace: "def (self):"

  # Builtins
  - trigger: "print"
    replace: "print()"
  - trigger: "print f"
    replace: "print(f'')"
  - trigger: "range"
    replace: "range()"
  - trigger: "enumerate"
    replace: "enumerate()"
  - trigger: "zip"
    replace: "zip()"
  - trigger: "list comprehension"
    replace: "[x for x in ]"
  - trigger: "dict comprehension"
    replace: "{k: v for k, v in }"

  # Type hints
  - trigger: "optional hint"
    replace: "Optional[]"
  - trigger: "list hint"
    replace: "list[]"
  - trigger: "dict hint"
    replace: "dict[str, ]"
  - trigger: "returns none"
    replace: "-> None:"

  # Error handling
  - trigger: "try except"
    replace: "try:\\n    \\nexcept Exception as e:\\n    "
  - trigger: "raise error"
    replace: "raise ValueError()"
"""

    // -------------------------------------------------------------------------
    // code/go.yaml
    // -------------------------------------------------------------------------
    static let defaultCodeGo = """
# Go code profile.
# Loaded after global.yaml and code/global.yaml.

rules:
  # Error handling (the most common Go pattern)
  - trigger: "error check"
    replace: "if err != nil {\\n\\treturn err\\n}"
  - trigger: "error check log"
    replace: "if err != nil {\\n\\tlog.Fatal(err)\\n}"
  - trigger: "returns error"
    replace: "error"

  # fmt package
  - trigger: "print line"
    replace: "fmt.Println()"
  - trigger: "print f"
    replace: "fmt.Printf(\\"\\\\n\\")"
  - trigger: "format string"
    replace: "fmt.Sprintf(\\"\\", )"
  - trigger: "error f"
    replace: "fmt.Errorf(\\"\\", )"

  # Context
  - trigger: "context background"
    replace: "context.Background()"
  - trigger: "context todo"
    replace: "context.TODO()"
  - trigger: "with context"
    replace: "ctx context.Context"

  # Channels and goroutines
  - trigger: "make channel"
    replace: "make(chan , )"
  - trigger: "go routine"
    replace: "go func() {\\n\\t\\n}()"
  - trigger: "defer close"
    replace: "defer close()"
  - trigger: "wait group"
    replace: "var wg sync.WaitGroup"

  # Slices and maps
  - trigger: "make slice"
    replace: "make([], 0)"
  - trigger: "make map"
    replace: "make(map[])"
  - trigger: "append"
    replace: "append(, )"

  # Common patterns
  - trigger: "short declare"
    replace: " := "
  - trigger: "var declare"
    replace: "var  "
  - trigger: "interface any"
    replace: "interface{}"
  - trigger: "log fatal"
    replace: "log.Fatal()"
"""

    // -------------------------------------------------------------------------
    // code/rust.yaml
    // -------------------------------------------------------------------------
    static let defaultCodeRust = """
# Rust code profile.
# Loaded after global.yaml and code/global.yaml.

rules:
  # Attributes
  - trigger: "derive debug"
    replace: "#[derive(Debug)]"
  - trigger: "derive clone"
    replace: "#[derive(Debug, Clone)]"
  - trigger: "derive serialize"
    replace: "#[derive(Debug, Serialize, Deserialize)]"
  - trigger: "allow dead code"
    replace: "#[allow(dead_code)]"
  - trigger: "test attribute"
    replace: "#[test]"
  - trigger: "cfg test"
    replace: "#[cfg(test)]"

  # Types
  - trigger: "result type"
    replace: "Result<(), Error>"
  - trigger: "option type"
    replace: "Option<>"
  - trigger: "box type"
    replace: "Box<>"
  - trigger: "arc type"
    replace: "Arc<>"
  - trigger: "string type"
    replace: "String"
  - trigger: "str slice"
    replace: "&str"
  - trigger: "vec type"
    replace: "Vec<>"

  # Error handling
  - trigger: "question mark"
    replace: "?"
  - trigger: "unwrap or"
    replace: ".unwrap_or()"
  - trigger: "unwrap or else"
    replace: ".unwrap_or_else(|e| )"
  - trigger: "ok or"
    replace: ".ok_or()"
  - trigger: "map error"
    replace: ".map_err(|e| )"

  # Closures and iterators
  - trigger: "closure"
    replace: "|x| "
  - trigger: "map iter"
    replace: ".iter().map(|x| ).collect::<Vec<_>>()"
  - trigger: "filter iter"
    replace: ".iter().filter(|x| ).collect::<Vec<_>>()"

  # I/O
  - trigger: "println"
    replace: "println!(\\"{\\")"
  - trigger: "eprintln"
    replace: "eprintln!(\\"{\\")"
  - trigger: "format macro"
    replace: "format!(\\"{\\")"
"""
}
