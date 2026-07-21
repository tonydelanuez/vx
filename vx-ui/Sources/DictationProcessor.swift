import Foundation

// MARK: - PostProcessor seam

/// Configuration for one optional LLM post-processing pass. Assembled by the caller
/// (provider, key, the already-combined prompt, dictionary, context hint) and handed
/// to the `PostProcessor` adapter. `nil` on a `DictationSession` means "disabled".
struct PostProcessingConfig {
    let provider: PostProcessingProvider
    let model: String
    let apiKey: String
    let customBaseURL: String
    let customPrompt: String
    let customDictionary: [String]
    let contextHint: String
    /// Append the disfluency-smoothing instruction (remove filler, smooth stutters).
    let smoothDisfluencies: Bool
}

/// The seam for optional LLM cleanup, owned by `DictationProcessor`. Real LLM adapter
/// in production, fake in tests. Receiving the rule-applied output (not the raw
/// sanitized text) is part of its contract.
protocol PostProcessor {
    func run(_ text: String, config: PostProcessingConfig) async throws -> String
}

/// Production `PostProcessor`: delegates to `TextPostProcessor`'s HTTP clients.
struct LLMPostProcessor: PostProcessor {
    func run(_ text: String, config: PostProcessingConfig) async throws -> String {
        try await TextPostProcessor.postProcess(
            text,
            provider: config.provider,
            model: config.model,
            apiKey: config.apiKey,
            customBaseURL: config.customBaseURL,
            customPrompt: config.customPrompt,
            customDictionary: config.customDictionary,
            contextHint: config.contextHint,
            smoothDisfluencies: config.smoothDisfluencies
        )
    }
}

// MARK: - DictationSession

/// The flat input to `DictationProcessor` for one recording.
///
/// Carries the resolved dictation mode and code profile — the coordinator (or, later,
/// a context-resolution module) decides these and hands over a value. The processor
/// holds no `AppState` reference and does no context detection itself.
struct DictationSession {
    let mode: DictationMode
    let codeProfile: CodeProfile
    /// `nil` when AI post-processing is disabled or unconfigured.
    let postProcessing: PostProcessingConfig?

    init(mode: DictationMode, codeProfile: CodeProfile, postProcessing: PostProcessingConfig? = nil) {
        self.mode = mode
        self.codeProfile = codeProfile
        self.postProcessing = postProcessing
    }

    var ruleContext: RuleContext {
        RuleContext(mode: mode, codeProfile: codeProfile)
    }
}

// MARK: - Outcome

/// The result of `DictationProcessor.process`. The coordinator acts on it (insert,
/// history, HUD); the processor itself performs no IO.
enum DictationOutcome {
    /// Text to insert, paired with the full transformation trace for logging/telemetry.
    case text(String, result: TransformationResult)
    /// Nothing real remained after sanitization.
    case noSpeech
}

// MARK: - PostProcessOutputGuard

/// Detects when the post-processing model returned commentary *about* the task
/// (refusing, explaining, narrating) instead of a cleaned transcript.
///
/// Detection can be reasonably aggressive: on a hit the processor falls back to
/// the deterministic rule-applied transcript, so a false positive only costs a
/// little LLM polish — it never produces wrong output.
enum PostProcessOutputGuard {
    /// Phrases that essentially only occur when the model describes the task
    /// rather than returning a transcript. High precision.
    private static let metaMarkers: [String] = [
        "speech-to-text", "speech to text",
        "returning empty string", "empty string as instructed",
        "as instructed for non-speech", "non-speech content",
        "does not represent coherent", "coherent spoken language",
        "valid speech-to-text", "i cannot process this input",
        "appears to be corrupted", "i cannot process this",
    ]

    /// Assistant/refusal openers, matched only at the very start of the output.
    private static let refusalOpeners: [String] = [
        "i cannot ", "i can't ", "i can not ", "i'm unable", "i am unable",
        "i'm sorry", "i am sorry", "i apologize", "as an ai", "unfortunately, i",
        "i'm not able", "i am not able", "sorry, i",
    ]

    static func looksLikeModelCommentary(_ output: String) -> Bool {
        let lower = output.lowercased()
        if metaMarkers.contains(where: { lower.contains($0) }) { return true }
        let trimmed = lower.trimmingCharacters(in: .whitespacesAndNewlines)
        if refusalOpeners.contains(where: { trimmed.hasPrefix($0) }) { return true }
        return false
    }

    /// The post-processor is optional polish, not an authority allowed to silently
    /// turn a multi-sentence dictation into its opening fragment. We deliberately
    /// use a conservative word-count check rather than trying to judge semantic
    /// equivalence: corrections, punctuation, and modest filler removal remain
    /// valid, while losing roughly half of a substantive transcript falls back to
    /// the deterministic Whisper/rule result.
    static func dropsSubstantialContent(from input: String, to output: String) -> Bool {
        let inputCount = wordCount(in: input)
        let outputCount = wordCount(in: output)
        guard inputCount >= 8 else { return false }
        return outputCount < inputCount - 4 && Double(outputCount) / Double(inputCount) < 0.60
    }

    static func wordCount(in text: String) -> Int {
        text.split { !$0.isLetter && !$0.isNumber }.count
    }
}

// MARK: - DictationProcessor

/// Turns a raw transcript into the text to insert.
///
/// Owns the transcript→text path: sanitize → mode-aware normalization → rule
/// application. This is the single interface the dictation flow is tested through;
/// the coordinator becomes IO wiring around it.
struct DictationProcessor {
    let store: RuleStore
    let postProcessor: PostProcessor

    init(store: RuleStore = .shared, postProcessor: PostProcessor = LLMPostProcessor()) {
        self.store = store
        self.postProcessor = postProcessor
    }

    func process(_ rawTranscript: String, session: DictationSession) async -> DictationOutcome {
        let sanitized = Self.sanitize(rawTranscript)
        guard !sanitized.isEmpty else { return .noSpeech }

        let result = TransformationPipeline.run(
            transcript: sanitized,
            context: session.ruleContext,
            store: store
        )

        // Rules can strip a non-empty transcript down to nothing (e.g. a filler-word
        // rule matching the whole utterance) — bypass post-processing rather than
        // asking the LLM to clean up an empty string.
        guard !result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .noSpeech
        }

        vxLog("[dictation-integrity] whisperWords=\(PostProcessOutputGuard.wordCount(in: sanitized)) ruleWords=\(PostProcessOutputGuard.wordCount(in: result.output))")

        guard let config = session.postProcessing else {
            return .text(result.output, result: result)
        }

        // Feed the rule-applied output — never the raw sanitized text — to the LLM so
        // rule transformations survive post-processing.
        do {
            vxLog("[processor/postprocess] Running via \(config.provider.rawValue)")
            let cleaned = try await postProcessor.run(result.output, config: config)
            if cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // The raw transcript already passed deterministic sanitization. An
                // optional remote model is not authoritative enough to erase it:
                // timeouts/errors already fall back, and an empty response must be
                // handled the same way.
                vxLog("[processor/postprocess] Empty result, using rule output")
                return .text(result.output, result: result)
            }
            // Guard: if the model narrated/refused instead of cleaning, never insert
            // that — fall back to the deterministic rule-applied transcript.
            if PostProcessOutputGuard.looksLikeModelCommentary(cleaned) {
                vxLog("[processor/postprocess] Output looks like model commentary; using rule output instead")
                return .text(result.output, result: result)
            }
            if PostProcessOutputGuard.dropsSubstantialContent(from: result.output, to: cleaned) {
                vxLog("[processor/postprocess] Output dropped substantial content (ruleWords=\(PostProcessOutputGuard.wordCount(in: result.output)), outputWords=\(PostProcessOutputGuard.wordCount(in: cleaned))); using rule output")
                return .text(result.output, result: result)
            }
            vxLog("[processor/postprocess] Complete")
            return .text(cleaned, result: result)
        } catch {
            vxLog("[processor/postprocess] Failed, using rule output: \(error)")
            return .text(result.output, result: result)
        }
    }

    // MARK: - Sanitization

    /// Strips Whisper's non-speech output markers, collapses whitespace, and returns
    /// a single clean line of text. Returns empty string if nothing real remains.
    static func sanitize(_ text: String) -> String {
        var result = text
        // Bracketed/parenthesised annotations Whisper emits for non-speech audio
        let bracketed = try? NSRegularExpression(pattern: "\\[.*?\\]|\\(.*?\\)", options: .caseInsensitive)
        if let re = bracketed {
            result = re.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
        }
        // Music note characters Whisper uses for background music
        result = result.unicodeScalars.filter { scalar in
            scalar.value != 0x266A &&  // ♪
            scalar.value != 0x266B &&  // ♫
            scalar.value != 0x266C &&  // ♬
            scalar.value != 0x266D     // ♭
        }.reduce("") { $0 + String($1) }
        // Collapse all newlines and runs of whitespace into single spaces —
        // speech transcription is always a single flow of text
        result = result.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        // Punctuation-only output (a bare dash, "...", music left-overs) isn't
        // speech — drop it so it's never pasted.
        guard result.contains(where: { $0.isLetter || $0.isNumber }) else { return "" }
        return result
    }
}
