import XCTest
@testable import VXLib

/// Exercises the `Transcriber` / `TranscriptionSession` seam through its in-memory
/// adapter — no subprocess. These prove the seam is usable without the `vx-rs`
/// binary, which is the prerequisite for testing the dictation-processing flow.
final class TranscriberSeamTests: XCTestCase {

    private let model = URL(fileURLWithPath: "/tmp/ggml-test.bin")

    func testBeginReturnsSessionAndRecordsModel() throws {
        let transcriber = InMemoryTranscriber()
        let session = try transcriber.begin(model: model)
        XCTAssertEqual(transcriber.lastModel, model)
        XCTAssertTrue(session is InMemoryTranscriptionSession)
    }

    func testSessionAccumulatesFramesThenReturnsTranscript() async throws {
        let session = InMemoryTranscriptionSession(finalText: "hello world")
        let transcriber = InMemoryTranscriber(session: session)

        let live = try transcriber.begin(model: model)
        live.write(samples: [0.1, 0.2, 0.3])
        live.write(samples: [0.4, 0.5])

        let text = try await live.finish()
        XCTAssertEqual(text, "hello world")
        XCTAssertEqual(session.writtenSampleCount, 5)
        XCTAssertTrue(session.didFinish)
    }

    func testBeginSurfacesLaunchFailure() {
        let transcriber = InMemoryTranscriber()
        transcriber.beginError = TranscriberError.missingBinary

        XCTAssertThrowsError(try transcriber.begin(model: model)) { error in
            guard case TranscriberError.missingBinary = error else {
                return XCTFail("expected .missingBinary, got \(error)")
            }
        }
    }

    func testCancelMarksSessionCancelled() {
        let session = InMemoryTranscriptionSession()
        session.cancel()
        XCTAssertTrue(session.didCancel)
    }
}
