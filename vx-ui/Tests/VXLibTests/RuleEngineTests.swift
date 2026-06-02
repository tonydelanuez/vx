import XCTest
@testable import VXLib

final class RuleEngineTests: XCTestCase {

    func testApplyEmptyRulesReturnsOriginal() {
        let engine = RuleEngine(rules: [])
        XCTAssertEqual(engine.apply(to: "hello world"), "hello world")
    }

    func testApplySimpleSubstitution() {
        let rules = [RuleDefinition(trigger: "new line", replace: "\n")]
        let engine = RuleEngine(rules: rules)
        XCTAssertEqual(engine.apply(to: "press new line here"), "press \n here")
    }

    func testApplyCaseInsensitiveMatching() {
        let rules = [RuleDefinition(trigger: "open brace", replace: "{")]
        let engine = RuleEngine(rules: rules)
        XCTAssertEqual(engine.apply(to: "OPEN BRACE"), "{")
        XCTAssertEqual(engine.apply(to: "Open Brace"), "{")
        XCTAssertEqual(engine.apply(to: "open brace"), "{")
    }

    func testApplyMultipleRulesChained() {
        // Output of rule A is input to rule B
        let rules = [
            RuleDefinition(trigger: "new line", replace: "\n"),
            RuleDefinition(trigger: "tab key", replace: "\t"),
        ]
        let engine = RuleEngine(rules: rules)
        let result = engine.apply(to: "new line tab key")
        XCTAssertEqual(result, "\n \t")
    }

    func testApplyNonMatchingRuleSkipped() {
        let rules = [RuleDefinition(trigger: "xyz", replace: "abc")]
        let engine = RuleEngine(rules: rules)
        XCTAssertEqual(engine.apply(to: "hello"), "hello")
    }

    func testApplyWithTraceEmptyRulesReturnsEmptyMatches() {
        let (output, matches) = RuleEngine.applyWithTrace(to: "hello", taggedRules: [])
        XCTAssertEqual(output, "hello")
        XCTAssertTrue(matches.isEmpty)
    }

    func testApplyWithTraceRecordsOnlyFiredRules() {
        let tagged: [(rule: RuleDefinition, source: String)] = [
            (rule: RuleDefinition(trigger: "open brace", replace: "{"), source: "code/global.yaml"),
            (rule: RuleDefinition(trigger: "xyz", replace: "999"), source: "global.yaml"),
        ]
        let (output, matches) = RuleEngine.applyWithTrace(to: "open brace", taggedRules: tagged)
        XCTAssertEqual(output, "{")
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].trigger, "open brace")
    }

    func testApplyWithTracePreservesSourceFilenames() {
        let tagged: [(rule: RuleDefinition, source: String)] = [
            (rule: RuleDefinition(trigger: "slash", replace: "/"), source: "global.yaml"),
        ]
        let (_, matches) = RuleEngine.applyWithTrace(to: "slash", taggedRules: tagged)
        XCTAssertEqual(matches.first?.source, "global.yaml")
    }

    func testApplyWithTraceMatchOrderMatchesRuleOrder() {
        let tagged: [(rule: RuleDefinition, source: String)] = [
            (rule: RuleDefinition(trigger: "a", replace: "1"), source: "global.yaml"),
            (rule: RuleDefinition(trigger: "b", replace: "2"), source: "global.yaml"),
        ]
        let (_, matches) = RuleEngine.applyWithTrace(to: "a b", taggedRules: tagged)
        XCTAssertEqual(matches.count, 2)
        XCTAssertEqual(matches[0].order, 0)
        XCTAssertEqual(matches[1].order, 1)
    }

    func testApplyWithTraceMultipleOccurrencesSingleEntry() {
        // Even if a trigger appears twice in the text, it produces one trace entry
        let tagged: [(rule: RuleDefinition, source: String)] = [
            (rule: RuleDefinition(trigger: "slash", replace: "/"), source: "global.yaml"),
        ]
        let (output, matches) = RuleEngine.applyWithTrace(to: "slash slash", taggedRules: tagged)
        XCTAssertEqual(output, "/ /")
        XCTAssertEqual(matches.count, 1, "One rule = one trace entry, regardless of occurrence count")
    }

    func testRuleMatchTraceReplacementPreviewEscapesNewline() {
        let trace = RuleMatchTrace(id: 0, source: "global.yaml", trigger: "new line", replacement: "\n", order: 0)
        XCTAssertEqual(trace.replacementPreview, "\\n")
    }

    func testRuleMatchTraceReplacementPreviewEscapesTab() {
        let trace = RuleMatchTrace(id: 0, source: "global.yaml", trigger: "tab key", replacement: "\t", order: 0)
        XCTAssertEqual(trace.replacementPreview, "\\t")
    }
}
