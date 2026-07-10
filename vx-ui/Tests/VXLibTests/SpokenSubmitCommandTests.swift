import XCTest
@testable import VXLib

final class SpokenSubmitCommandTests: XCTestCase {
    func testSubmitAloneBecomesSubmitOnlyCommand() {
        let result = SpokenSubmitCommandDetector.detect(in: "Submit.", phrases: ["submit"])

        XCTAssertTrue(result.shouldSubmit)
        XCTAssertEqual(result.textToInsert, "")
    }

    func testTrailingSubmitIsRemovedFromInsertedText() {
        let result = SpokenSubmitCommandDetector.detect(
            in: "Build this thing submit",
            phrases: ["submit"]
        )

        XCTAssertTrue(result.shouldSubmit)
        XCTAssertEqual(result.textToInsert, "Build this thing")
    }

    func testTrailingSubmitRemovesCommaSeparator() {
        let result = SpokenSubmitCommandDetector.detect(
            in: "Build this thing, submit",
            phrases: ["submit"]
        )

        XCTAssertTrue(result.shouldSubmit)
        XCTAssertEqual(result.textToInsert, "Build this thing")
    }

    func testRepeatedTrailingSubmitOnlyTreatsFinalWordAsCommand() {
        let result = SpokenSubmitCommandDetector.detect(
            in: "It should actually submit submit",
            phrases: ["submit"]
        )

        XCTAssertTrue(result.shouldSubmit)
        XCTAssertEqual(result.textToInsert, "It should actually submit")
    }

    func testDoesNotMatchSubmitWhenNotAtEnd() {
        let result = SpokenSubmitCommandDetector.detect(
            in: "Tap the submit button",
            phrases: ["submit"]
        )

        XCTAssertFalse(result.shouldSubmit)
        XCTAssertEqual(result.textToInsert, "Tap the submit button")
    }

    func testSupportsMultiWordPhrases() {
        let result = SpokenSubmitCommandDetector.detect(
            in: "Build this thing send it",
            phrases: ["send it", "submit"]
        )

        XCTAssertTrue(result.shouldSubmit)
        XCTAssertEqual(result.textToInsert, "Build this thing")
    }

    func testParsesCommaSeparatedPhrases() {
        XCTAssertEqual(
            SpokenSubmitCommandDetector.parsePhrases("submit, send it\nship it"),
            ["submit", "send it", "ship it"]
        )
    }
}
