import XCTest
@testable import VXLib

final class GoModeSegmenterTests: XCTestCase {
    private let model = URL(fileURLWithPath: "/tmp/ggml-test.bin")

    func testSilenceDoesNotStartTranscriptionSession() {
        let transcriber = InMemoryTranscriber()
        let segmenter = GoModeSegmenter(
            transcriber: transcriber,
            modelURL: model,
            onTranscript: { _ in XCTFail("Silence should not produce a transcript") },
            onFailure: { error in XCTFail("Unexpected failure: \(error)") }
        )

        segmenter.ingest(samples: audioChunk(seconds: 1.2, value: 0))
        segmenter.stop(finishActive: false)

        let noStart = expectation(description: "no backend start")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { noStart.fulfill() }
        wait(for: [noStart], timeout: 1.0)

        XCTAssertEqual(transcriber.beginCount, 0)
    }

    func testSpeechFollowedBySilenceEmitsTranscript() {
        let session = InMemoryTranscriptionSession(finalText: "ship it")
        let transcriber = InMemoryTranscriber(session: session)
        let emitted = expectation(description: "transcript emitted")
        var transcript: String?

        let segmenter = GoModeSegmenter(
            transcriber: transcriber,
            modelURL: model,
            onTranscript: { text in
                transcript = text
                emitted.fulfill()
            },
            onFailure: { error in XCTFail("Unexpected failure: \(error)") }
        )

        segmenter.ingest(samples: audioChunk(seconds: 0.2, value: 0))
        segmenter.ingest(samples: audioChunk(seconds: 0.5, value: 0.05))
        segmenter.ingest(samples: audioChunk(seconds: 1.0, value: 0))

        wait(for: [emitted], timeout: 2.0)

        XCTAssertEqual(transcript, "ship it")
        XCTAssertEqual(transcriber.beginCount, 1)
        XCTAssertTrue(session.didFinish)
        XCTAssertGreaterThan(session.writtenSampleCount, 0)
    }

    private func audioChunk(seconds: Double, value: Float) -> [Float] {
        Array(repeating: value, count: Int(seconds * 16_000))
    }
}
