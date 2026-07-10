import Foundation

enum GoModeSubmitStrategy {
    static func behavior(targetContext: AppContext?, ruleContext: RuleContext) -> TextSubmitBehavior {
        if isTerminal(targetContext) || ruleContext.mode == .terminal {
            return .terminalReturnKey
        }
        return .returnKey
    }

    private static func isTerminal(_ context: AppContext?) -> Bool {
        guard let context else { return false }
        if case .terminal = context {
            return true
        }
        return false
    }
}
