import XCTest
@testable import VXLib

final class TextInserterTests: XCTestCase {
    func testReturnKeySubmitDoesNotAlterPasteboardPayload() {
        XCTAssertEqual(
            TextInserter.pasteboardPayload(for: "Just testing something out", submitBehavior: .returnKey),
            "Just testing something out"
        )
    }

    func testTerminalSubmitDoesNotPasteTrailingLineBreak() {
        XCTAssertEqual(
            TextInserter.pasteboardPayload(for: "Just testing something out", submitBehavior: .terminalReturnKey),
            "Just testing something out"
        )
    }
}
