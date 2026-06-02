import XCTest
@testable import VXLib

final class TextPostProcessorPromptTests: XCTestCase {

    func testDisfluencyInstructionExcludedByDefault() {
        let prompt = TextPostProcessor.effectiveSystemPrompt(customPrompt: "")
        XCTAssertFalse(prompt.contains("DISFLUENCY SMOOTHING"))
    }

    func testDisfluencyInstructionIncludedWhenEnabled() {
        let prompt = TextPostProcessor.effectiveSystemPrompt(customPrompt: "", smoothDisfluencies: true)
        XCTAssertTrue(prompt.contains("DISFLUENCY SMOOTHING"))
        XCTAssertTrue(prompt.contains(TextPostProcessor.disfluencyInstruction))
    }

    func testBasePromptAlwaysPresent() {
        let off = TextPostProcessor.effectiveSystemPrompt(customPrompt: "")
        let on = TextPostProcessor.effectiveSystemPrompt(customPrompt: "", smoothDisfluencies: true)
        XCTAssertTrue(off.hasPrefix(TextPostProcessor.baseSystemPrompt))
        XCTAssertTrue(on.hasPrefix(TextPostProcessor.baseSystemPrompt))
    }

    func testCustomPromptStillAppended() {
        let prompt = TextPostProcessor.effectiveSystemPrompt(customPrompt: "Use British spelling.",
                                                             smoothDisfluencies: true)
        XCTAssertTrue(prompt.contains("Use British spelling."))
        XCTAssertTrue(prompt.contains("DISFLUENCY SMOOTHING"))
    }

    // MARK: - transcript wrapping (don't-answer-the-transcript hardening)

    func testUserMessageFencesTranscriptBetweenMarkers() {
        let msg = TextPostProcessor.userMessage(forTranscript: "how should I handle vocabulary")
        XCTAssertTrue(msg.contains(TextPostProcessor.transcriptStartMarker))
        XCTAssertTrue(msg.contains(TextPostProcessor.transcriptEndMarker))
        // The transcript sits between the two markers.
        let start = msg.range(of: TextPostProcessor.transcriptStartMarker)!
        let end = msg.range(of: TextPostProcessor.transcriptEndMarker)!
        let between = msg[start.upperBound..<end.lowerBound]
        XCTAssertTrue(between.contains("how should I handle vocabulary"))
    }

    func testUserMessageInstructsNotToAnswer() {
        let msg = TextPostProcessor.userMessage(forTranscript: "anything").lowercased()
        XCTAssertTrue(msg.contains("only the corrected transcript"))
        XCTAssertTrue(msg.contains("never") && msg.contains("directed at you"))
    }
}
