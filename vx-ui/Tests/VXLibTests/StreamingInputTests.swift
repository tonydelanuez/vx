import Darwin
import XCTest
@testable import VXLib

final class StreamingInputTests: XCTestCase {
    override func setUp() {
        super.setUp()
        // Match VXApp startup: a dead backend must report EPIPE, not kill vx.
        signal(SIGPIPE, SIG_IGN)
    }

    func testSlowBackendDoesNotBlockCaptureAndReceivesAllQueuedFramesBeforeEOF() async throws {
        let gate = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: gate) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Keep stdin unread until the test releases the gate, like a cold model load.
        process.arguments = ["-c", "while [ ! -f \"$1\" ]; do sleep 0.01; done; /usr/bin/wc -c", "vx-test", gate.path]
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        let session = StreamingTranscription(process: process, stdinHandle: input.fileHandleForWriting,
                                             stdoutPipe: output, stderrPipe: errors)
        let returned = expectation(description: "capture callback returns while backend cannot read")
        let samples = [Float](repeating: 0.125, count: 131_072)
        DispatchQueue.global().async {
            session.write(samples: samples)
            session.write(samples: samples)
            returned.fulfill()
        }
        await fulfillment(of: [returned], timeout: 1)
        try Data().write(to: gate)
        let transcript = try await session.finish()
        XCTAssertEqual(Int(transcript.trimmingCharacters(in: .whitespacesAndNewlines)),
                       samples.count * 2 * MemoryLayout<Float>.size)
    }
    func testCancellationTerminatesBackendWhileQueuedInputCannotDrain() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        let session = StreamingTranscription(process: process, stdinHandle: input.fileHandleForWriting,
                                             stdoutPipe: output, stderrPipe: errors)
        session.write(samples: [Float](repeating: 0.125, count: 262_144))
        let finishing = Task { try await session.finish() }
        finishing.cancel()
        do {
            _ = try await finishing.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        process.waitUntilExit()
        XCTAssertFalse(process.isRunning)
    }

}
