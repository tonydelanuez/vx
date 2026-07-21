import XCTest
@testable import VXLib

final class DictationProcessorTests: XCTestCase {

    // MARK: - Helpers

    private func makeStore(rules: [RuleDefinition]) -> RuleStore {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vx-processor-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: tempDir.appendingPathComponent("code"), withIntermediateDirectories: true)

        let yaml = "rules:\n" + rules.map { "  - trigger: \"\($0.trigger)\"\n    replace: \"\($0.replace)\"" }.joined(separator: "\n")
        try? yaml.write(to: tempDir.appendingPathComponent("global.yaml"), atomically: true, encoding: .utf8)
        for name in ["plain.yaml", "email.yaml", "chat.yaml", "markdown.yaml", "terminal.yaml",
                     "code/global.yaml", "code/generic.yaml", "code/swift.yaml"] {
            try? "rules: []".write(to: tempDir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        return RuleStore(rulesDirectory: tempDir)
    }

    private let plainSession = DictationSession(mode: .plainText, codeProfile: .generic)

    // MARK: - sanitize

    func testSanitizeStripsBracketedAnnotations() {
        XCTAssertEqual(DictationProcessor.sanitize("[BLANK_AUDIO] hello (laughs)"), "hello")
    }

    func testSanitizeStripsMusicNotes() {
        XCTAssertEqual(DictationProcessor.sanitize("\u{266A} hello \u{266B}"), "hello")
    }

    func testSanitizeCollapsesWhitespaceAndNewlines() {
        XCTAssertEqual(DictationProcessor.sanitize("hello\n  world   foo"), "hello world foo")
    }

    func testSanitizeDropsPunctuationOnlyOutput() {
        // Whisper occasionally emits a bare dash (or other punctuation) on quiet
        // audio. With no letters or digits it isn't speech, so it must not be pasted.
        for junk in ["-", "--", "...", " - ", "\u{2014}", "?!"] {
            XCTAssertEqual(DictationProcessor.sanitize(junk), "", "should drop: \(junk)")
        }
        // Real text with punctuation is untouched.
        XCTAssertEqual(DictationProcessor.sanitize("well - maybe"), "well - maybe")
    }

    // MARK: - process

    func testProcessReturnsNoSpeechWhenSanitizationEmpties() async {
        let processor = DictationProcessor(store: makeStore(rules: []))
        guard case .noSpeech = await processor.process("[BLANK_AUDIO] \u{266A}", session: plainSession) else {
            return XCTFail("expected .noSpeech")
        }
    }

    func testProcessReturnsSanitizedTextWhenNoRulesMatch() async {
        let processor = DictationProcessor(store: makeStore(rules: []))
        guard case .text(let output, _) = await processor.process("  hello   world ", session: plainSession) else {
            return XCTFail("expected .text")
        }
        XCTAssertEqual(output, "hello world")
    }

    func testProcessAppliesRulesToSanitizedText() async {
        let processor = DictationProcessor(store: makeStore(rules: [
            RuleDefinition(trigger: "open brace", replace: "{")
        ]))
        guard case .text(let output, let result) = await processor.process("[noise] open brace", session: plainSession) else {
            return XCTFail("expected .text")
        }
        XCTAssertEqual(output, "{")
        XCTAssertEqual(result.original, "open brace")  // post-sanitize input to the pipeline
        XCTAssertTrue(result.didTransform)
    }

    // MARK: - post-processing seam

    private func config() -> PostProcessingConfig {
        PostProcessingConfig(provider: .openAI, model: "gpt", apiKey: "k",
                             customBaseURL: "", customPrompt: "", customDictionary: [],
                             contextHint: "", smoothDisfluencies: false)
    }

    private func sessionWithPostProcessing() -> DictationSession {
        DictationSession(mode: .plainText, codeProfile: .generic, postProcessing: config())
    }

    /// Regression test for the rule-discard bug: post-processing must receive the
    /// rule-applied output, not the raw sanitized text.
    func testPostProcessorReceivesRuleAppliedTextNotSanitized() async {
        let fake = InMemoryPostProcessor(result: "CLEANED")
        let processor = DictationProcessor(
            store: makeStore(rules: [RuleDefinition(trigger: "open brace", replace: "{")]),
            postProcessor: fake
        )
        _ = await processor.process("open brace", session: sessionWithPostProcessing())
        XCTAssertEqual(fake.received, "{", "post-processor should get rule output, not 'open brace'")
    }

    func testSpokenSubmitIsRemovedBeforePostProcessing() async {
        let command = SpokenSubmitCommandDetector.detect(in: "Build this thing submit", phrases: ["submit"])
        XCTAssertTrue(command.shouldSubmit)

        let fake = InMemoryPostProcessor(result: "Build this thing.")
        let processor = DictationProcessor(store: makeStore(rules: []), postProcessor: fake)
        guard case .text(let output, _) = await processor.process(command.textToInsert, session: sessionWithPostProcessing()) else {
            return XCTFail("expected .text")
        }

        XCTAssertEqual(fake.received, "Build this thing")
        XCTAssertEqual(output, "Build this thing.")
    }

    func testPostProcessedTextIsReturned() async {
        let fake = InMemoryPostProcessor(result: "CLEANED")
        let processor = DictationProcessor(store: makeStore(rules: []), postProcessor: fake)
        guard case .text(let output, _) = await processor.process("hello", session: sessionWithPostProcessing()) else {
            return XCTFail("expected .text")
        }
        XCTAssertEqual(output, "CLEANED")
    }

    func testPostProcessorNotCalledWhenConfigIsNil() async {
        let fake = InMemoryPostProcessor(result: "CLEANED")
        let processor = DictationProcessor(store: makeStore(rules: []), postProcessor: fake)
        let outcome = await processor.process("hello", session: plainSession)
        XCTAssertFalse(fake.wasCalled)
        guard case .text("hello", _) = outcome else { return XCTFail("expected unmodified .text") }
    }

    func testEmptyPostProcessResultFallsBackToRuleOutput() async {
        let fake = InMemoryPostProcessor(result: "   ")
        let processor = DictationProcessor(store: makeStore(rules: []), postProcessor: fake)
        guard case .text(let output, _) = await processor.process("hello", session: sessionWithPostProcessing()) else {
            return XCTFail("expected .text fallback")
        }
        XCTAssertEqual(output, "hello")
    }

    func testEmptyPostProcessResultPreservesRuleAppliedText() async {
        let fake = InMemoryPostProcessor(result: "")
        let processor = DictationProcessor(
            store: makeStore(rules: [RuleDefinition(trigger: "open brace", replace: "{")]),
            postProcessor: fake
        )

        guard case .text(let output, _) = await processor.process("open brace", session: sessionWithPostProcessing()) else {
            return XCTFail("expected .text fallback")
        }
        XCTAssertEqual(fake.received, "{")
        XCTAssertEqual(output, "{")
    }

    func testModelCommentaryFallsBackToRuleOutput() async {
        // The model narrates instead of cleaning — must NOT be inserted.
        let refusal = """
        I cannot process this input as valid speech-to-text output. This appears to be \
        corrupted, repetitive text. Returning empty string as instructed for non-speech content.
        """
        let fake = InMemoryPostProcessor(result: refusal)
        let processor = DictationProcessor(
            store: makeStore(rules: [RuleDefinition(trigger: "open brace", replace: "{")]),
            postProcessor: fake
        )
        guard case .text(let output, _) = await processor.process("open brace", session: sessionWithPostProcessing()) else {
            return XCTFail("expected .text fallback")
        }
        XCTAssertEqual(output, "{", "model commentary should be discarded for the rule output")
    }

    func testPostProcessorCannotSilentlyDropMostOfASubstantiveTranscript() async {
        // Mirrors the observed report: a full dictation was reduced to its opening
        // sentence by the optional cleanup stage. The deterministic transcript is
        // safer than an LLM response that has lost a whole thought.
        let source = "I have an idea about the project setup and how we should merge the changes tomorrow."
        let fake = InMemoryPostProcessor(result: "I have an idea.")
        let processor = DictationProcessor(store: makeStore(rules: []), postProcessor: fake)

        guard case .text(let output, _) = await processor.process(source, session: sessionWithPostProcessing()) else {
            return XCTFail("expected deterministic fallback")
        }
        XCTAssertEqual(output, source)
    }

    func testPostProcessContentGuardAllowsNormalCleanup() {
        XCTAssertFalse(PostProcessOutputGuard.dropsSubstantialContent(
            from: "Um I think we should ship this change after lunch today.",
            to: "I think we should ship this change after lunch today."
        ))
        XCTAssertTrue(PostProcessOutputGuard.dropsSubstantialContent(
            from: "I have an idea about the project setup and how we should merge the changes tomorrow.",
            to: "I have an idea."
        ))
    }

    func testGuardDetectsRefusalsAndPassesCleanText() {
        XCTAssertTrue(PostProcessOutputGuard.looksLikeModelCommentary(
            "I cannot process this input as valid speech-to-text output."))
        XCTAssertTrue(PostProcessOutputGuard.looksLikeModelCommentary(
            "Returning empty string as instructed for non-speech content."))
        XCTAssertTrue(PostProcessOutputGuard.looksLikeModelCommentary(
            "I'm sorry, but I can't help with that."))
        XCTAssertFalse(PostProcessOutputGuard.looksLikeModelCommentary(
            "Let's meet at three tomorrow."))
        XCTAssertFalse(PostProcessOutputGuard.looksLikeModelCommentary(
            "The text-to-speech demo went well."))
    }

    func testPostProcessFailureFallsBackToRuleOutput() async {
        let fake = InMemoryPostProcessor(error: URLError(.timedOut))
        let processor = DictationProcessor(
            store: makeStore(rules: [RuleDefinition(trigger: "open brace", replace: "{")]),
            postProcessor: fake
        )
        guard case .text(let output, _) = await processor.process("open brace", session: sessionWithPostProcessing()) else {
            return XCTFail("expected .text fallback")
        }
        XCTAssertEqual(output, "{")
    }
}

/// In-memory `PostProcessor` fake: records the text it was handed and returns a
/// canned result (or throws a canned error).
final class InMemoryPostProcessor: PostProcessor {
    private let result: String?
    private let error: Error?
    private(set) var received: String?
    var wasCalled: Bool { received != nil }

    init(result: String) { self.result = result; self.error = nil }
    init(error: Error) { self.result = nil; self.error = error }

    func run(_ text: String, config: PostProcessingConfig) async throws -> String {
        received = text
        if let error { throw error }
        return result ?? ""
    }
}
