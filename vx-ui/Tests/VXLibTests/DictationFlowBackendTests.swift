import Foundation
import XCTest
@testable import VXLib

/// Swift-side engine contract test: drives a whole Dictation Flow against the *real*
/// `vx-rs` subprocess and the Whisper and Parakeet models, replaying a WAV fixture through the
/// Audio Source seam instead of a microphone.
///
/// Opt-in (`VX_FLOW_BACKEND=1`) because it needs a built backend and takes seconds rather
/// than milliseconds. This is the test to extend when a second engine lands (Parakeet):
/// the assertions here are engine-agnostic — a real backend, real audio, real text — so a
/// new adapter proves itself by passing the same case.
@MainActor
final class DictationFlowBackendTests: XCTestCase {

    /// `<package>/Tests/VXLibTests/DictationFlowBackendTests.swift` -> `<package>`
    private static var packageDirectory: URL {
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { dir.deleteLastPathComponent() }
        return dir
    }

    private static var backendURL: URL {
        packageDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("vx-rs/target/release/vx-rs")
    }

    private static var modelURL: URL {
        packageDirectory.appendingPathComponent("Resources/Models/ggml-tiny.en.bin")
    }

    func testRealBackendTranscribesFixtureAndInsertsText() async throws {
        try await checkFixture(modelURL: Self.modelURL)
    }

    private static func parakeetURL(version: String) -> URL {
        let variable = version == "v2" ? "VX_PARAKEET_V2_MODEL_PATH" : "VX_PARAKEET_MODEL_PATH"
        if let path = ProcessInfo.processInfo.environment[variable] {
            return URL(fileURLWithPath: path)
        }
        let model = SpeechModel.find(id: "parakeet-tdt-0.6b-\(version)-int8")!
        return packageDirectory.appendingPathComponent("Resources/Models/\(model.fileName)")
    }

    func testParakeetTranscribesFixtureAndInsertsText() async throws {
        try await checkFixture(modelURL: Self.parakeetURL(version: "v3"))
    }

    func testParakeetGoModeInsertsBothUtterances() async throws {
        try await checkFixture(modelURL: Self.parakeetURL(version: "v3"), goMode: true)
    }

    func testParakeetV2TranscribesFixtureAndInsertsText() async throws {
        try await checkFixture(modelURL: Self.parakeetURL(version: "v2"))
    }

    func testParakeetV2GoModeInsertsBothUtterances() async throws {
        try await checkFixture(modelURL: Self.parakeetURL(version: "v2"), goMode: true)
    }

    private func checkFixture(modelURL: URL, goMode: Bool = false) async throws {
        guard ProcessInfo.processInfo.environment["VX_FLOW_BACKEND"] == "1" else {
            throw XCTSkip("Set VX_FLOW_BACKEND=1 to run the real-backend flow test.")
        }
        let backendURL = Self.backendURL
        let fixture = goMode ? "two-utterances" : "short-phrase"
        let fm = FileManager.default
        // Explicit backend runs must fail when resources are missing.
        XCTAssertTrue(fm.isExecutableFile(atPath: backendURL.path), "Build vx-rs before running backend flow tests.")
        XCTAssertTrue(fm.fileExists(atPath: modelURL.path), "Missing model at \(modelURL.path)")
        XCTAssertTrue(Fixtures.exists(fixture))
        guard fm.isExecutableFile(atPath: backendURL.path),
              fm.fileExists(atPath: modelURL.path), Fixtures.exists(fixture) else { return }

        let relay = DrainRelay()
        let source = WAVFileAudioSource(
            url: Fixtures.url(fixture),
            pacing: .immediate,
            onDrained: { relay.fire() }
        )
        let inserter = RecordingTextInserter()
        let suite = TestDefaults.makeSuite(prefix: "vx-flow-backend")
        let history = TranscriptionHistory(defaults: suite.defaults)
        defer { TestDefaults.destroy(suite.name) }

        let settings = DictationSettings(
            backendURL: backendURL,
            modelURL: modelURL,
            inputDeviceUID: nil,
            autoDetectMode: false,
            manualMode: .plainText,
            manualProfile: .generic,
            spokenSubmitPhrases: [],
            goModeSubmitDelay: 0,
            postProcessing: { _, _ in nil }
        )

        let flow = DictationFlow(dependencies: DictationFlow.Dependencies(
            audioSource: source,
            transcriber: SubprocessTranscriber(backendURL: backendURL),
            processor: DictationProcessor(store: .shared, postProcessor: PassthroughPostProcessor()),
            contextResolver: DictationContextResolver(),
            textInserter: inserter,
            history: history,
            settings: { settings },
            frontmostApp: { TargetApp(bundleID: "com.apple.TextEdit", name: "TextEdit", pid: 1) },
            validateResources: { try FileValidator.validate(backendURL: $0, modelURL: $1) },
            captureRetryDelay: 0,
            captureAttempts: 1
        ))
        let recorder = EventRecorder()
        flow.delegate = recorder
        relay.onDrain = { [weak flow] in Task { @MainActor in flow?.audioSourceDidDrain() } }

        if goMode {
            flow.startGoMode()
            try await recorder.wait(forEventNamed: "goModeStarted", timeout: 30)
        } else {
            flow.beginRecording()
            try await recorder.wait(forEventNamed: "recordingStarted", timeout: 30)
        }
        try await recorder.wait(forEventNamed: "audioSourceDrained", timeout: 30)
        if goMode {
            flow.stopGoMode(finishActive: true)
            try await recorder.wait(until: { inserter.insertions.count == 2 }, timeout: 120)
        } else {
            flow.finishRecording()
            try await recorder.wait(forEventNamed: "textInserted", timeout: 120)
        }
        await flow.waitForIdle()

        func normalized(_ text: String) -> String {
            text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }.joined(separator: " ")
        }
        let expected = goMode
            ? ["this is the first sentence", "this is the second sentence"]
            : ["the quick brown fox jumps over the lazy dog"]
        XCTAssertEqual(inserter.insertions.map { normalized($0.text) }, expected,
                       "Unexpected transcript. Events: \(recorder.names)")
        XCTAssertEqual(history.entries.map(\.text), inserter.insertions.reversed().map(\.text))
    }
}
