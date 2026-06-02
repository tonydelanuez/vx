import XCTest
@testable import VXLib

final class RuleStoreLintTests: XCTestCase {

    func testCleanRulesProduceNoWarnings() {
        let rules = [
            RuleDefinition(trigger: "new line", replace: "\n"),
            RuleDefinition(trigger: "raw deployment", replace: "RawDeployment"),
        ]
        XCTAssertTrue(RuleStore.lint(rules).isEmpty)
    }

    func testSmartQuotesInTriggerFlagged() {
        let rules = [RuleDefinition(trigger: "\u{201C}merge\u{201D}", replace: "/merge")]
        let warnings = RuleStore.lint(rules)
        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings[0].lowercased().contains("curly"))
    }

    func testSmartQuotesInReplaceFlagged() {
        let rules = [RuleDefinition(trigger: "merge", replace: "\u{201C}/merge\u{201D}")]
        XCTAssertTrue(RuleStore.lint(rules).contains { $0.lowercased().contains("curly") })
    }

    func testWhitespaceOnlyTriggerFlagged() {
        let rules = [RuleDefinition(trigger: "   ", replace: "x")]
        XCTAssertTrue(RuleStore.lint(rules).contains { $0.lowercased().contains("never match") })
    }

    func testDuplicateTriggerFlagged() {
        let rules = [
            RuleDefinition(trigger: "slash", replace: "/"),
            RuleDefinition(trigger: "Slash", replace: "\\"),  // case-insensitive dup
        ]
        XCTAssertTrue(RuleStore.lint(rules).contains { $0.lowercased().contains("duplicate") })
    }
}
