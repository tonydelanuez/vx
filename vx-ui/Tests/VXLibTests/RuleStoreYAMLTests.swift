import XCTest
@testable import VXLib

final class RuleStoreYAMLTests: XCTestCase {

    // Use a shared instance with access to the internal parsing methods
    private let store = RuleStore.shared

    // MARK: - parseYAML

    func testParseDoubleQuotedValue() {
        let yaml = """
        rules:
          - trigger: "hello world"
            replace: "goodbye"
        """
        let rules = store.parseYAML(yaml)
        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(rules[0].trigger, "hello world")
        XCTAssertEqual(rules[0].replace, "goodbye")
    }

    func testParseDoubleQuotedEscapeNewline() {
        let yaml = """
        rules:
          - trigger: "new line"
            replace: "\\n"
        """
        let rules = store.parseYAML(yaml)
        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(rules[0].replace, "\n")
    }

    func testParseDoubleQuotedEscapeTab() {
        let yaml = """
        rules:
          - trigger: "tab key"
            replace: "\\t"
        """
        let rules = store.parseYAML(yaml)
        XCTAssertEqual(rules[0].replace, "\t")
    }

    func testParseDoubleQuotedEscapeBackslash() {
        let yaml = """
        rules:
          - trigger: "backslash"
            replace: "\\\\"
        """
        let rules = store.parseYAML(yaml)
        XCTAssertEqual(rules[0].replace, "\\")
    }

    func testParseSingleQuotedValue() {
        let yaml = """
        rules:
          - trigger: 'it''s fine'
            replace: 'ok'
        """
        let rules = store.parseYAML(yaml)
        XCTAssertEqual(rules[0].trigger, "it's fine")
    }

    func testParseUnquotedStripsInlineComment() {
        let yaml = """
        rules:
          - trigger: value # this is a comment
            replace: result
        """
        let rules = store.parseYAML(yaml)
        XCTAssertEqual(rules[0].trigger, "value")
        XCTAssertEqual(rules[0].replace, "result")
    }

    func testParseEmptyRulesSection() {
        let yaml = "rules: []"
        let rules = store.parseYAML(yaml)
        XCTAssertTrue(rules.isEmpty)
    }

    func testParseMultipleRulesProducesCorrectCount() {
        let yaml = """
        rules:
          - trigger: "a"
            replace: "1"
          - trigger: "b"
            replace: "2"
          - trigger: "c"
            replace: "3"
        """
        let rules = store.parseYAML(yaml)
        XCTAssertEqual(rules.count, 3)
    }

    func testParseMissingRulesSection() {
        let yaml = "# just a comment\n"
        let rules = store.parseYAML(yaml)
        XCTAssertTrue(rules.isEmpty, "No rules section -> empty array, no crash")
    }

    func testParseMissingReplace() {
        // A trigger without replace should be skipped (pendingTrigger never emits)
        let yaml = """
        rules:
          - trigger: "orphan"
          - trigger: "complete"
            replace: "ok"
        """
        let rules = store.parseYAML(yaml)
        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(rules[0].trigger, "complete")
    }

    func testParseEmptyTriggerSkipped() {
        let yaml = """
        rules:
          - trigger: ""
            replace: "something"
          - trigger: "valid"
            replace: "ok"
        """
        let rules = store.parseYAML(yaml)
        // Empty trigger should be skipped
        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(rules[0].trigger, "valid")
    }

    func testParseUnknownKeysIgnored() {
        let yaml = """
        rules:
          - trigger: "test"
            replace: "ok"
            kind: regex
            condition: someCondition
        """
        let rules = store.parseYAML(yaml)
        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(rules[0].trigger, "test")
    }
}
