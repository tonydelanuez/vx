import XCTest
@testable import VXLib

final class TranscriptLineParserTests: XCTestCase {

    func testWhisperPrefixedLineIsDiscarded() {
        let result = TranscriptLineParser.parse("whisper_init: loading model")
        if case .whisperDiagnostic = result { } else {
            XCTFail("Expected .whisperDiagnostic, got \(result)")
        }
    }

    func testWhisperPrefixCaseInsensitive() {
        let result = TranscriptLineParser.parse("WHISPER_model_load: something")
        if case .whisperDiagnostic = result { } else {
            XCTFail("Expected .whisperDiagnostic for uppercase prefix")
        }
    }

    func testInfoPrefixedLineIsDiscarded() {
        let result = TranscriptLineParser.parse("[info] some diagnostic")
        if case .whisperDiagnostic = result { } else {
            XCTFail("Expected .whisperDiagnostic for [info] prefix")
        }
    }

    func testInfoPrefixCaseInsensitive() {
        let result = TranscriptLineParser.parse("[INFO] some diagnostic")
        if case .whisperDiagnostic = result { } else {
            XCTFail("Expected .whisperDiagnostic for [INFO] prefix")
        }
    }

    func testPlainLineIsTranscript() {
        let result = TranscriptLineParser.parse("Hello, world.")
        if case .transcript(let text) = result {
            XCTAssertEqual(text, "Hello, world.")
        } else {
            XCTFail("Expected .transcript, got \(result)")
        }
    }
}
