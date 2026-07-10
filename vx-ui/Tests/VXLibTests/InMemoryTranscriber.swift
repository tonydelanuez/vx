import Foundation
@testable import VXLib

/// In-memory `TranscriptionSession` fake. Ignores the audio frames it is given
/// (recording only their count) and returns a canned transcript from `finish()`.
///
/// This is the second adapter behind the `Transcriber` seam — its existence is
/// what justifies the seam: subprocess in production, this in tests.
final class InMemoryTranscriptionSession: TranscriptionSession {
    /// Text `finish()` resolves to.
    var finalText: String
    /// Error `finish()` throws instead of returning, when set.
    var finishError: Error?

    private(set) var writtenSampleCount = 0
    private(set) var didFinish = false
    private(set) var didCancel = false

    init(finalText: String = "") {
        self.finalText = finalText
    }

    // MARK: TranscriptionSession

    func write(samples: [Float]) {
        writtenSampleCount += samples.count
    }

    func finish() async throws -> String {
        didFinish = true
        if let finishError { throw finishError }
        return finalText
    }

    func cancel() {
        didCancel = true
    }
}

/// In-memory `Transcriber` fake. Hands out a preconfigured session and records the
/// model it was asked for. Set `beginError` to exercise the launch-failure path.
final class InMemoryTranscriber: Transcriber {
    let session: InMemoryTranscriptionSession
    var beginError: Error?
    private(set) var lastModel: URL?
    private(set) var beginCount = 0

    init(session: InMemoryTranscriptionSession = InMemoryTranscriptionSession()) {
        self.session = session
    }

    func begin(model: URL) throws -> TranscriptionSession {
        lastModel = model
        beginCount += 1
        if let beginError { throw beginError }
        return session
    }
}
