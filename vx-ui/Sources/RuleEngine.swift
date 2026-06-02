import Foundation

// MARK: - Trace model

/// Records that a specific rule fired during a transformation pass.
struct RuleMatchTrace: Identifiable {
    let id: Int  // stable identity for SwiftUI ForEach; equals `order`

    /// The YAML file the rule was loaded from (e.g. "global.yaml", "code.yaml").
    let source: String

    /// The trigger phrase that matched (preserves original case from the rule file).
    let trigger: String

    /// The replacement string that was substituted.
    let replacement: String

    /// Zero-based position in the merged (global + mode) rule list.
    let order: Int

    /// Human-readable replacement string suitable for display: special characters
    /// are shown as escape sequences so whitespace and control chars are visible.
    var replacementPreview: String {
        replacement
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
            .replacingOccurrences(of: "\r", with: "\\r")
    }
}

// MARK: - Engine

/// Applies a list of `RuleDefinition`s to a text string.
///
/// Rules are applied in declaration order (global rules first, then mode rules).
/// Each rule performs a case-insensitive whole-phrase search-and-replace; the
/// output of one rule is the input of the next.
struct RuleEngine {
    let rules: [RuleDefinition]

    /// Transforms `text` by applying all rules in order.
    /// Returns the original string unchanged if the rule list is empty.
    /// Use `applyWithTrace` when you also need to know which rules matched.
    func apply(to text: String) -> String {
        guard !rules.isEmpty else { return text }
        var result = text
        for rule in rules {
            result = result.replacingOccurrences(
                of: rule.trigger,
                with: rule.replace,
                options: [.caseInsensitive]
            )
        }
        return result
    }

    /// Transforms `text` using source-tagged rules and returns both the output
    /// and a trace of every rule that produced a change.
    ///
    /// Only rules that actually modified the running text are recorded — rules
    /// whose trigger does not appear in the current text are omitted.
    ///
    /// - Parameter taggedRules: pairs of (rule, source filename), already in
    ///   application order (global first, then mode-specific).
    /// - Returns: the transformed string and an ordered list of match traces.
    static func applyWithTrace(
        to text: String,
        taggedRules: [(rule: RuleDefinition, source: String)]
    ) -> (output: String, matches: [RuleMatchTrace]) {
        guard !taggedRules.isEmpty else { return (text, []) }

        var result = text
        var matches: [RuleMatchTrace] = []

        for (index, tagged) in taggedRules.enumerated() {
            let before = result
            result = result.replacingOccurrences(
                of: tagged.rule.trigger,
                with: tagged.rule.replace,
                options: [.caseInsensitive]
            )
            if result != before {
                matches.append(RuleMatchTrace(
                    id: index,
                    source: tagged.source,
                    trigger: tagged.rule.trigger,
                    replacement: tagged.rule.replace,
                    order: index
                ))
            }
        }

        return (result, matches)
    }
}
