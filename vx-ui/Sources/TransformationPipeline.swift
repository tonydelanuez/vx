import Foundation

// MARK: - Result type

/// The outcome of running a transcript through the transformation pipeline.
///
/// All intermediate stages are preserved so callers can log, display, or diff them.
/// The `matchedRules` array powers the "Try Rules" trace display in Preferences.
struct TransformationResult {
    let original: String
    let normalized: String

    /// After rule application. This is the value inserted into the active app,
    /// unless AI post-processing is also enabled (which runs after the pipeline).
    let transformed: String

    /// Total number of rules that were loaded (not necessarily the number that matched).
    let ruleCount: Int

    /// Rules that actually fired, in application order.
    let matchedRules: [RuleMatchTrace]

    var output: String { transformed }
    var didTransform: Bool { transformed != original }
}

// MARK: - Pipeline

/// Orchestrates the transcript → normalize → apply rules → output stages.
///
/// Sits between sanitization and optional AI post-processing in the recording flow:
/// it normalizes the sanitized transcript for the active mode, then applies the
/// resolved rule list, returning the result for insertion.
enum TransformationPipeline {

    /// Runs the full pipeline for `context` using rules from `store`.
    static func run(
        transcript: String,
        context: RuleContext,
        store: RuleStore
    ) -> TransformationResult {
        // Stage 1: Mode-aware normalization
        let normalized = normalize(transcript, mode: context.mode)

        // Stage 2: Load source-tagged rules in resolution order
        let tagged = store.taggedRules(for: context)

        // Stage 3: Apply rules, collecting match trace
        let (transformed, matches) = RuleEngine.applyWithTrace(to: normalized, taggedRules: tagged)

        return TransformationResult(
            original: transcript,
            normalized: normalized,
            transformed: transformed,
            ruleCount: tagged.count,
            matchedRules: matches
        )
    }

    // MARK: - Normalization

    /// Mode-aware normalization applied before rule matching.
    static func normalize(_ text: String, mode: DictationMode) -> String {
        switch mode {
        case .plainText, .email, .chat, .markdown:
            return text

        case .code:
            // Collapse runs of whitespace introduced by the transcriber.
            // A single space between tokens is correct for rule matching.
            return text
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")

        case .terminal:
            // Terminal commands are whitespace-sensitive; preserve interior spaces,
            // trim leading/trailing only.
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
