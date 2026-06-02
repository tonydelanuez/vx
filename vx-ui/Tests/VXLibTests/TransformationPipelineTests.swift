import XCTest
@testable import VXLib

final class TransformationPipelineTests: XCTestCase {

    // MARK: - normalize

    func testNormalizeCodeCollapsesInternalWhitespace() {
        let result = TransformationPipeline.normalize("hello   world", mode: .code)
        XCTAssertEqual(result, "hello world")
    }

    func testNormalizeCodeCollapsesNewlines() {
        let result = TransformationPipeline.normalize("hello\nworld\n  foo", mode: .code)
        XCTAssertEqual(result, "hello world foo")
    }

    func testNormalizePlainTextPassthrough() {
        let input = "hello   world\n  foo"
        XCTAssertEqual(TransformationPipeline.normalize(input, mode: .plainText), input)
    }

    func testNormalizeMarkdownPassthrough() {
        let input = "# heading\n\nparagraph"
        XCTAssertEqual(TransformationPipeline.normalize(input, mode: .markdown), input)
    }

    func testNormalizeTerminalTrimsLeadingTrailingOnly() {
        let input = "  git commit -m 'hello world'  "
        let result = TransformationPipeline.normalize(input, mode: .terminal)
        XCTAssertEqual(result, "git commit -m 'hello world'")
    }

    func testNormalizeTerminalPreservesInteriorSpaces() {
        let input = "  ls   -la  "
        let result = TransformationPipeline.normalize(input, mode: .terminal)
        XCTAssertEqual(result, "ls   -la")
    }

    // MARK: - run

    private func makeStore(rules: [RuleDefinition], for mode: DictationMode = .plainText) -> RuleStore {
        // Use a temp dir with a seeded global.yaml
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vx-pipeline-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: tempDir.appendingPathComponent("code"), withIntermediateDirectories: true)

        let yaml = "rules:\n" + rules.map { "  - trigger: \"\($0.trigger)\"\n    replace: \"\($0.replace)\"" }.joined(separator: "\n")
        try? yaml.write(to: tempDir.appendingPathComponent("global.yaml"), atomically: true, encoding: .utf8)
        // Write empty files for other modes
        for name in ["plain.yaml", "email.yaml", "chat.yaml", "markdown.yaml", "terminal.yaml",
                     "code/global.yaml", "code/generic.yaml", "code/swift.yaml"] {
            try? "rules: []".write(to: tempDir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }

        return RuleStore(rulesDirectory: tempDir)
    }

    func testRunProducesTransformedOutput() {
        let store = makeStore(rules: [RuleDefinition(trigger: "open brace", replace: "{")])
        let context = RuleContext(mode: .plainText, codeProfile: .generic)
        let result = TransformationPipeline.run(transcript: "open brace", context: context, store: store)
        XCTAssertEqual(result.transformed, "{")
    }

    func testRunDidTransformFalseWhenNoRulesMatch() {
        let store = makeStore(rules: [RuleDefinition(trigger: "xyz", replace: "999")])
        let context = RuleContext(mode: .plainText, codeProfile: .generic)
        let result = TransformationPipeline.run(transcript: "hello", context: context, store: store)
        XCTAssertFalse(result.didTransform)
    }

    func testRunDidTransformTrueWhenRuleMatches() {
        let store = makeStore(rules: [RuleDefinition(trigger: "slash", replace: "/")])
        let context = RuleContext(mode: .plainText, codeProfile: .generic)
        let result = TransformationPipeline.run(transcript: "slash", context: context, store: store)
        XCTAssertTrue(result.didTransform)
    }

    func testRunPreservesOriginalInResult() {
        let store = makeStore(rules: [RuleDefinition(trigger: "new line", replace: "\n")])
        let context = RuleContext(mode: .plainText, codeProfile: .generic)
        let result = TransformationPipeline.run(transcript: "new line", context: context, store: store)
        XCTAssertEqual(result.original, "new line")
    }

    func testRunRuleCountMatchesLoadedRules() {
        let rules = [
            RuleDefinition(trigger: "a", replace: "1"),
            RuleDefinition(trigger: "b", replace: "2"),
        ]
        let store = makeStore(rules: rules)
        let context = RuleContext(mode: .plainText, codeProfile: .generic)
        let result = TransformationPipeline.run(transcript: "a b", context: context, store: store)
        XCTAssertEqual(result.ruleCount, rules.count)
    }
}
