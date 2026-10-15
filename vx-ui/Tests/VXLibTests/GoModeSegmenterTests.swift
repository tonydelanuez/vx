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
        // Retain prior silence and write each speech frame exactly once.
        XCTAssertEqual(session.writtenSampleCount, Int(1.7 * 16_000))
    }

    func testTranscriptsRetainRecordingOrderWhenFirstPhraseFinishesLater() {
        let transcriber = DelayedTranscriber()
        let emitted = expectation(description: "both phrases delivered")
        emitted.expectedFulfillmentCount = 2
        var transcripts: [String] = []
        let segmenter = GoModeSegmenter(transcriber: transcriber, modelURL: model,
            onTranscript: { text in transcripts.append(text); emitted.fulfill() },
            onFailure: { XCTFail("Unexpected failure: \($0)") })
        for _ in 0..<2 {
            segmenter.ingest(samples: audioChunk(seconds: 0.5, value: 0.05))
            segmenter.ingest(samples: audioChunk(seconds: 1.0, value: 0))
        }
        wait(for: [emitted], timeout: 3)
        XCTAssertEqual(transcripts, ["first phrase", "second phrase"])
    }

    private func audioChunk(seconds: Double, value: Float) -> [Float] {
        Array(repeating: value, count: Int(seconds * 16_000))
    }
}

private final class DelayedTranscriber: Transcriber {
    private var sessions = [
        DelayedSession(text: "first phrase", delay: 200_000_000),
        DelayedSession(text: "second phrase", delay: 0),
    ]
    func begin(model: URL) throws -> TranscriptionSession { sessions.removeFirst() }
}

private final class DelayedSession: TranscriptionSession {
    let text: String
    let delay: UInt64
    init(text: String, delay: UInt64) { self.text = text; self.delay = delay }
    func write(samples: [Float]) {}
    func cancel() {}
    func finish() async throws -> String {
        try await Task.sleep(nanoseconds: delay)
        return text
    }
}
