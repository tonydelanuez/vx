import XCTest
@testable import VXLib

final class GoModeSubmitStrategyTests: XCTestCase {
    func testTerminalTargetUsesTerminalReturnEvenWhenRulesArePlainText() {
        let behavior = GoModeSubmitStrategy.behavior(
            targetContext: .terminal,
            ruleContext: RuleContext(mode: .plainText, codeProfile: .generic)
        )

        XCTAssertEqual(behavior, .terminalReturnKey)
    }

    func testTerminalRuleModeUsesTerminalReturnWhenTargetIsUnknown() {
        let behavior = GoModeSubmitStrategy.behavior(
            targetContext: nil,
            ruleContext: RuleContext(mode: .terminal, codeProfile: .generic)
        )

        XCTAssertEqual(behavior, .terminalReturnKey)
    }

    func testNonTerminalTargetUsesReturnKey() {
        let behavior = GoModeSubmitStrategy.behavior(
            targetContext: .chat,
            ruleContext: RuleContext(mode: .chat, codeProfile: .generic)
        )

        XCTAssertEqual(behavior, .returnKey)
    }
}
