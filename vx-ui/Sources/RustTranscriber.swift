import Foundation

// MARK: - Transcriber seam

/// The seam between the app and the `vx-rs` backend. Begins a `TranscriptionSession`
/// for a model. Satisfied by a subprocess adapter in production and an in-memory
/// adapter in tests.
///
/// The backend executable is an implementation detail of the adapter (injected at
/// init), so callers only supply the model they want to transcribe with.
protocol Transcriber {
    func begin(model: URL) throws -> TranscriptionSession
}

/// One in-flight transcription.
///
/// Audio frames are pushed in via `write(samples:)` from the capture thread;
/// `finish()` returns the final text. The subprocess pipe is hidden entirely —
/// callers pass audio frames, never file descriptors.
protocol TranscriptionSession: AnyObject {
    /// Appends 16 kHz mono f32 audio frames.
    ///
    /// Contract: cheap, non-blocking, and safe to call from the realtime audio
    /// thread. Adapters must not take a lock the audio thread can contend on.
    func write(samples: [Float])

    /// Signals end-of-audio, waits for final inference, returns the transcript.
    /// Supports Swift task cancellation (terminates the work and throws `CancellationError`).
    func finish() async throws -> String

    /// Terminates the session immediately (used when recording is cancelled).
    func cancel()
}

// MARK: - TranscriptLineParser

/// Classifies a single line of stdout from vx-rs.
///
/// Extracted from StreamingTranscription so that the classification logic can
/// be tested independently without running a subprocess.
struct TranscriptLineParser {
    enum ParsedLine {
        case whisperDiagnostic   // starts with "whisper_" or "[info]" — discard
        case transcript(String)  // everything else — collect for insertion
    }

    static func parse(_ raw: String) -> ParsedLine {
        let lower = raw.lowercased()
        if lower.hasPrefix("whisper_") || lower.hasPrefix("[info]") {
            return .whisperDiagnostic
        }
        return .transcript(stripLeadingHyphen(raw))
    }

    private static func stripLeadingHyphen(_ s: String) -> String {
        // Whisper commonly prefixes output with "- " or " - "; strip it.
        if s.hasPrefix("- ") { return String(s.dropFirst(2)) }
        if s.hasPrefix(" - ") { return String(s.dropFirst(3)) }
        return s
    }
}

// MARK: - TranscriberError

enum TranscriberError: LocalizedError {
    case missingBinary
    case missingModel
    case processFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingBinary:
            return "vx-rs executable not found or not executable."
        case .missingModel:
            return "Model file not found."
        case .processFailed(let message):
            return message.isEmpty ? "Transcription failed." : message
        }
    }
}

/// Represents a long-running vx-rs stream process. The caller writes f32 audio to
/// `stdinHandle` and calls `finish()` when recording is done.
///
/// Stdout is consumed live via `readabilityHandler`. `finish()` closes stdin
/// (triggering vx-rs's final inference), waits for the process to exit, then
/// returns the accumulated transcript.
final class StreamingTranscription: TranscriptionSession {
    /// The subprocess stdin pipe. Fully private — callers push audio via `write(samples:)`.
    private let stdinHandle: FileHandle

    // MARK: TranscriptionSession

    /// Serializes f32 frames to raw little-endian bytes and writes them to the
    /// subprocess stdin pipe. `FileHandle.write` does not block on the audio thread
    /// for a pipe with buffer space, satisfying the session's write contract.
    func write(samples: [Float]) {
        guard !samples.isEmpty else { return }
        let data = samples.withUnsafeBytes { Data($0) }
        stdinHandle.write(data)
    }

    private let process: Process
    private let stderrPipe: Pipe
    private let launchStart: Date

    // Protects mutable state accessed from both the readabilityHandler thread and callers.
    private let lock = NSLock()
    private var stdoutBuffer = Data()
    // Accumulated transcript lines for text insertion.
    private var finalLines: [String] = []
    // Callback invoked on stdout EOF to resume finish().
    private var onEOF: ((String) -> Void)?
    // Stored continuation for finish() — guarded by lock.
    private var pendingContinuation: CheckedContinuation<String, Error>?
    // Set by onCancel if it fires before the continuation is stored.
    private var finishCancelled = false

    init(process: Process, stdinHandle: FileHandle, stdoutPipe: Pipe, stderrPipe: Pipe) {
        self.process = process
        self.stdinHandle = stdinHandle
        self.stderrPipe = stderrPipe
        self.launchStart = Date()

        // Install live reader. Fires on a background thread whenever data is available.
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                self?.handleStdoutEOF()
            } else {
                self?.processStdoutData(data)
            }
        }
    }

    /// Closes stdin (signals EOF to vx-rs), waits for the process to exit,
    /// and returns the full accumulated transcript.
    ///
    /// Supports Swift task cancellation: if the enclosing Task is cancelled,
    /// the vx-rs process is terminated immediately and `CancellationError` is thrown.
    func finish() async throws -> String {
        return try await withTaskCancellationHandler(
            operation: {
                try await withCheckedThrowingContinuation { continuation in
                    self.lock.lock()
                    // If onCancel already fired before we stored the continuation, bail immediately.
                    if self.finishCancelled {
                        self.lock.unlock()
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    self.pendingContinuation = continuation
                    self.onEOF = { [self] text in
                        Task.detached { [self] in
                            self.process.waitUntilExit()
                            let elapsed = Date().timeIntervalSince(self.launchStart)
                            vxLog("[transcriber/stream] Exited with status \(self.process.terminationStatus) (total: \(String(format: "%.1f", elapsed * 1000))ms)")

                            self.lock.lock()
                            let cont = self.pendingContinuation
                            self.pendingContinuation = nil
                            self.lock.unlock()

                            guard let cont else { return }
                            if self.process.terminationStatus == 0 {
                                cont.resume(returning: text)
                            } else {
                                let stderrData = self.stderrPipe.fileHandleForReading.readDataToEndOfFile()
                                let msg = String(decoding: stderrData, as: UTF8.self)
                                    .trimmingCharacters(in: .whitespacesAndNewlines)
                                if !msg.isEmpty { vxLog("[transcriber/stream] Stderr: \(msg)") }
                                cont.resume(throwing: TranscriberError.processFailed(msg))
                            }
                        }
                    }
                    self.lock.unlock()

                    // Close stdin — vx-rs will run final inference and exit.
                    try? self.stdinHandle.close()
                }
            },
            onCancel: {
                // May be called from any thread, possibly before the continuation is stored.
                self.lock.lock()
                let cont = self.pendingContinuation
                self.pendingContinuation = nil
                if cont == nil {
                    // Continuation not yet stored — flag it so the operation closure handles it.
                    self.finishCancelled = true
                }
                self.onEOF = nil
                self.lock.unlock()

                vxLog("[transcriber/stream] Cancellation requested — terminating process")
                self.process.terminate()
                try? self.stdinHandle.close()
                cont?.resume(throwing: CancellationError())
            }
        )
    }

    /// Terminates the process immediately (used when recording is cancelled).
    func cancel() {
        process.terminate()
        try? stdinHandle.close()
        lock.lock()
        onEOF = nil
        lock.unlock()
    }

    // MARK: - Private stdout handling

    private func processStdoutData(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }

        stdoutBuffer.append(data)

        while let newlineRange = stdoutBuffer.range(of: Data([UInt8(ascii: "\n")])) {
            let lineData = stdoutBuffer[..<newlineRange.lowerBound]
            stdoutBuffer.removeSubrange(..<newlineRange.upperBound)

            guard let raw = String(data: lineData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty else { continue }

            switch TranscriptLineParser.parse(raw) {
            case .whisperDiagnostic:
                break
            case .transcript(let line):
                // Final transcript line — collect for insertion.
                finalLines.append(line)
            }
        }
    }

    private func handleStdoutEOF() {
        lock.lock()
        // Drain any final bytes that arrived without a trailing newline.
        if !stdoutBuffer.isEmpty,
           let raw = String(data: stdoutBuffer, encoding: .utf8)?
               .trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            switch TranscriptLineParser.parse(raw) {
            case .whisperDiagnostic:
                break
            case .transcript(let line):
                finalLines.append(line)
            }
        }
        stdoutBuffer = Data()
        let text = finalLines.joined(separator: " ")
        let callback = onEOF
        onEOF = nil
        lock.unlock()

        callback?(text)
    }
}

/// Production `Transcriber` adapter: launches `vx-rs stream` as a subprocess and
/// wraps it in a `StreamingTranscription` session.
struct SubprocessTranscriber: Transcriber {
    /// The `vx-rs` executable. Stable per launch (resolved by `ResourceLocator`), so
    /// it is injected once here rather than passed per transcription.
    let backendURL: URL

    init(backendURL: URL = ResourceLocator.backendExecutableURL()) {
        self.backendURL = backendURL
    }

    // MARK: Transcriber

    func begin(model: URL) throws -> TranscriptionSession {
        try beginStreaming(backendURL: backendURL, modelURL: model)
    }

    private func beginStreaming(backendURL: URL, modelURL: URL) throws -> StreamingTranscription {
        let fm = FileManager.default
        let backendPath = backendURL.path
        let modelPath = modelURL.path

        guard fm.isExecutableFile(atPath: backendPath) else {
            throw TranscriberError.missingBinary
        }
        guard fm.fileExists(atPath: modelPath) else {
            throw TranscriberError.missingModel
        }

        let process = Process()
        process.executableURL = backendURL
        process.arguments = ["stream", modelPath]

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.currentDirectoryURL = backendURL.deletingLastPathComponent()

        vxLog("[transcriber/stream] Launching: \(backendPath)")
        do {
            try process.run()
        } catch {
            vxLog("[transcriber/stream] Failed to launch: \(error.localizedDescription)")
            throw TranscriberError.processFailed(error.localizedDescription)
        }
        vxLog("[transcriber/stream] Process started (PID \(process.processIdentifier))")

        return StreamingTranscription(
            process: process,
            stdinHandle: stdinPipe.fileHandleForWriting,
            stdoutPipe: stdoutPipe,
            stderrPipe: stderrPipe
        )
    }
}
