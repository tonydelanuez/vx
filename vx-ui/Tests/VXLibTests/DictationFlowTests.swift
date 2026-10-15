import Combine
import XCTest
@testable import VXLib

// MARK: - Event recorder

struct FlowEventTimeout: Error, CustomStringConvertible {
    let description: String
}

/// Collects every Flow Event and lets a test await a condition over the collected list
/// without polling or sleeping — each emission re-evaluates the pending conditions.
@MainActor
final class EventRecorder: DictationFlowDelegate {
    private(set) var events: [DictationFlowEvent] = []

    var names: [String] { events.map(\.name) }

    struct Waiter {
        let condition: () -> Bool
        let continuation: CheckedContinuation<Void, Error>
    }

    /// Pending waiters live in a reference box so they can be registered from inside the
    /// (non-async, non-isolated) continuation closure without an `inout` capture of `self`.
    final class WaiterStore {
        var waiters: [UUID: Waiter] = [:]
    }
    private let store = WaiterStore()

    func flow(_ flow: DictationFlow, didEmit event: DictationFlowEvent) {
        events.append(event)
        for (id, waiter) in store.waiters where waiter.condition() {
            store.waiters.removeValue(forKey: id)
            waiter.continuation.resume()
        }
    }

    func wait(until condition: @escaping () -> Bool, timeout: TimeInterval = 5) async throws {
        guard !condition() else { return }
        let id = UUID()
        let store = self.store
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            store.waiters[id] = Waiter(condition: condition, continuation: continuation)
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard let waiter = store.waiters.removeValue(forKey: id) else { return }
                waiter.continuation.resume(
                    throwing: FlowEventTimeout(description: "timed out after \(timeout)s; saw \(self?.names ?? [])")
                )
            }
        }
    }

    func wait(
        for predicate: @escaping (DictationFlowEvent) -> Bool,
        count: Int = 1,
        timeout: TimeInterval = 5
    ) async throws {
        try await wait(
            until: { [weak self] in (self?.events.filter(predicate).count ?? 0) >= count },
            timeout: timeout
        )
    }

    func wait(forEventNamed name: String, count: Int = 1, timeout: TimeInterval = 5) async throws {
        try await wait(for: { $0.name == name }, count: count, timeout: timeout)
    }

    func failureMessages() -> [String] {
        events.compactMap { if case .failed(let message) = $0 { return message } else { return nil } }
    }

    func insertedTexts() -> [(text: String, behavior: String)] {
        events.compactMap {
            if case .textInserted(let text, let behavior) = $0 { return (text, behavior) } else { return nil }
        }
    }
}

// MARK: - Audio Source doubles

/// Relays `WAVFileAudioSource.onDrained` (fired on the replay queue) to a handler that can
/// only be installed after the flow exists.
final class DrainRelay: @unchecked Sendable {
    var onDrain: (() -> Void)?
    func fire() { onDrain?() }
}

/// Audio Source that always fails to start — stands in for CoreAudio refusing the engine
/// while a Bluetooth device flips between A2DP and HFP.
final class FailingAudioSource: AudioSource {
    struct StartFailure: LocalizedError {
        var errorDescription: String? { "engine start failed" }
    }

    private(set) var startAttempts = 0
    private(set) var stopCount = 0
    private let subject = CurrentValueSubject<Double, Never>(0)

    var levelPublisher: AnyPublisher<Double, Never> { subject.eraseToAnyPublisher() }

    func start(deviceUID: String?, sink: @escaping ([Float]) -> Void) throws {
        startAttempts += 1
        throw StartFailure()
    }

    func stop() { stopCount += 1 }
}

// MARK: - Tests

@MainActor
final class DictationFlowTests: XCTestCase {

    private var tempDirectories: [URL] = []
    private var defaultsSuites: [String] = []

    override func tearDown() {
        for suite in defaultsSuites {
            TestDefaults.destroy(suite)
        }
        defaultsSuites.removeAll()
        for dir in tempDirectories {
            try? FileManager.default.removeItem(at: dir)
        }
        tempDirectories.removeAll()
        super.tearDown()
    }

    // MARK: - Harness

    struct Harness {
        let flow: DictationFlow
        let recorder: EventRecorder
        let inserter: RecordingTextInserter
        let transcriber: InMemoryTranscriber
        let session: InMemoryTranscriptionSession
        let history: TranscriptionHistory
    }

    private func makeTempDirectory(_ label: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vx-\(label)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirectories.append(dir)
        return dir
    }

    private func makeRuleStore(rules: [RuleDefinition]) -> RuleStore {
        let dir = makeTempDirectory("flow-rules")
        try? FileManager.default.createDirectory(
            at: dir.appendingPathComponent("code"),
            withIntermediateDirectories: true
        )
        let yaml = "rules:\n" + rules
            .map { "  - trigger: \"\($0.trigger)\"\n    replace: \"\($0.replace)\"" }
            .joined(separator: "\n")
        try? yaml.write(to: dir.appendingPathComponent("global.yaml"), atomically: true, encoding: .utf8)
        for name in ["plain.yaml", "email.yaml", "chat.yaml", "markdown.yaml", "terminal.yaml",
                     "code/global.yaml", "code/generic.yaml", "code/swift.yaml"] {
            try? "rules: []".write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        return RuleStore(rulesDirectory: dir)
    }

    /// A real file that `FileValidator` accepts as a model.
    private func makeModelFile() -> URL {
        let url = makeTempDirectory("flow-model").appendingPathComponent("ggml-test.bin")
        FileManager.default.createFile(atPath: url.path, contents: Data([0x00]))
        return url
    }

    private func makeHistory() -> TranscriptionHistory {
        let suite = TestDefaults.makeSuite(prefix: "vx-flow")
        defaultsSuites.append(suite.name)
        return TranscriptionHistory(defaults: suite.defaults)
    }

    private func makeFlow(
        transcript: String = "The quick brown fox jumps over the lazy dog.",
        fixture: String = "short-phrase",
        audioSource: AudioSource? = nil,
        transcriber providedTranscriber: InMemoryTranscriber? = nil,
        detect: @escaping (String, pid_t) -> AppContext = { _, _ in .general },
        rules: [RuleDefinition] = [],
        spokenSubmitPhrases: [String] = [],
        goModeSubmitDelay: TimeInterval = 0,
        postProcessor: PostProcessor = PassthroughPostProcessor(),
        postProcessing: PostProcessingConfig? = nil,
        backendURL: URL = URL(fileURLWithPath: "/usr/bin/true"),
        modelURL providedModel: URL? = nil,
        pacing: WAVFileAudioSource.Pacing = .immediate
    ) -> Harness {
        let relay = DrainRelay()
        let source = audioSource ?? WAVFileAudioSource(
            url: Fixtures.url(fixture),
            pacing: pacing,
            onDrained: { relay.fire() }
        )

        let session = InMemoryTranscriptionSession(finalText: transcript)
        let transcriber = providedTranscriber ?? InMemoryTranscriber(session: session)
        let inserter = RecordingTextInserter()
        let history = makeHistory()
        let modelURL = providedModel ?? makeModelFile()

        var resolver = DictationContextResolver()
        resolver.detect = detect

        let settings = DictationSettings(
            backendURL: backendURL,
            modelURL: modelURL,
            inputDeviceUID: nil,
            autoDetectMode: true,
            manualMode: .plainText,
            manualProfile: .generic,
            spokenSubmitPhrases: spokenSubmitPhrases,
            goModeSubmitDelay: goModeSubmitDelay,
            postProcessing: { _, _ in postProcessing }
        )

        let dependencies = DictationFlow.Dependencies(
            audioSource: source,
            transcriber: transcriber,
            processor: DictationProcessor(
                store: makeRuleStore(rules: rules),
                postProcessor: postProcessor
            ),
            contextResolver: resolver,
            textInserter: inserter,
            history: history,
            settings: { settings },
            frontmostApp: { TargetApp(bundleID: "com.apple.TextEdit", name: "TextEdit", pid: 1) },
            validateResources: { try FileValidator.validate(backendURL: $0, modelURL: $1) },
            captureRetryDelay: 0,
            captureAttempts: 3
        )

        let flow = DictationFlow(dependencies: dependencies)
        let recorder = EventRecorder()
        flow.delegate = recorder
        relay.onDrain = { [weak flow] in
            Task { @MainActor in flow?.audioSourceDidDrain() }
        }

        return Harness(
            flow: flow,
            recorder: recorder,
            inserter: inserter,
            transcriber: transcriber,
            session: transcriber.session,
            history: history
        )
    }

    /// Event names with `audioSourceDrained` removed: the replay source drains on its own
    /// queue, so its position relative to the lifecycle events is not deterministic.
    private func lifecycleNames(_ recorder: EventRecorder) -> [String] {
        recorder.names.filter { $0 != "audioSourceDrained" }
    }

    // MARK: - Happy path

    func testInsertsTranscriptAndRecordsHistoryInEventOrder() async throws {
        let h = makeFlow()

        h.flow.beginRecording()
        try await h.recorder.wait(forEventNamed: "audioSourceDrained")
        h.flow.finishRecording()
        try await h.recorder.wait(forEventNamed: "textInserted")
        await h.flow.waitForIdle()

        XCTAssertEqual(lifecycleNames(h.recorder), [
            "captureWillStart", "recordingStarted", "recordingWillStop", "transcribing",
            "transcriptReceived", "processed", "textInserted",
        ])
        XCTAssertEqual(h.recorder.events.first, .captureWillStart(goMode: false))
        XCTAssertEqual(h.inserter.insertions.count, 1)
        XCTAssertEqual(h.inserter.insertions.first?.text, "The quick brown fox jumps over the lazy dog.")
        XCTAssertEqual(h.inserter.insertions.first?.behavior, TextSubmitBehavior.none)
        XCTAssertEqual(h.recorder.insertedTexts().first?.behavior, TextSubmitBehavior.none.logName)
        XCTAssertEqual(h.history.entries.first?.text, "The quick brown fox jumps over the lazy dog.")
        XCTAssertFalse(h.flow.isRecording)
    }

    /// `isTranscribing` gates the processing-phase escape monitor and is what the test
    /// control channel reports, so it has to fall back to false once the transcription is
    /// done — and stay false across a second recording in the same session.
    func testIsTranscribingClearsAfterEachCompletedDictation() async throws {
        let h = makeFlow()

        XCTAssertFalse(h.flow.isTranscribing)
        h.flow.beginRecording()
        try await h.recorder.wait(forEventNamed: "audioSourceDrained")
        h.flow.finishRecording()
        XCTAssertTrue(h.flow.isTranscribing, "Transcription is in flight the moment capture stops")
        try await h.recorder.wait(forEventNamed: "textInserted")
        await h.flow.waitForIdle()
        XCTAssertFalse(h.flow.isTranscribing, "A finished transcription must release the task handle")

        h.flow.beginRecording()
        try await h.recorder.wait(forEventNamed: "audioSourceDrained", count: 2)
        h.flow.finishRecording()
        try await h.recorder.wait(forEventNamed: "textInserted", count: 2)
        await h.flow.waitForIdle()
        XCTAssertFalse(h.flow.isTranscribing)
    }

    func testTranscriptionSessionReceivesCapturedAudio() async throws {
        let h = makeFlow()

        h.flow.beginRecording()
        try await h.recorder.wait(forEventNamed: "audioSourceDrained")
        h.flow.finishRecording()
        try await h.recorder.wait(forEventNamed: "textInserted")
        await h.flow.waitForIdle()

        XCTAssertGreaterThan(h.session.writtenSampleCount, 0)
        XCTAssertTrue(h.session.didFinish)
        XCTAssertEqual(h.transcriber.beginCount, 1)
    }

    func testDrainNotificationEmitsAudioSourceDrained() async throws {
        let h = makeFlow()
        h.flow.audioSourceDidDrain()
        XCTAssertEqual(h.recorder.events, [.audioSourceDrained])
    }

    // MARK: - No speech

    func testBlankAudioTranscriptEmitsNoSpeechAndInsertsNothing() async throws {
        let h = makeFlow(transcript: "[BLANK_AUDIO]")

        h.flow.beginRecording()
        try await h.recorder.wait(forEventNamed: "audioSourceDrained")
        h.flow.finishRecording()
        try await h.recorder.wait(forEventNamed: "noSpeech")
        await h.flow.waitForIdle()

        XCTAssertTrue(h.inserter.insertions.isEmpty)
        XCTAssertTrue(h.history.entries.isEmpty)
        XCTAssertFalse(h.recorder.names.contains("textInserted"))
    }

    func testEmptyTranscriptEmitsNoSpeech() async throws {
        let h = makeFlow(transcript: "")

        h.flow.beginRecording()
        try await h.recorder.wait(forEventNamed: "audioSourceDrained")
        h.flow.finishRecording()
        try await h.recorder.wait(forEventNamed: "noSpeech")
        await h.flow.waitForIdle()

        XCTAssertTrue(h.inserter.insertions.isEmpty)
        XCTAssertTrue(h.history.entries.isEmpty)
    }

    // MARK: - Rules

    func testGlobalRuleIsAppliedBeforeInsertion() async throws {
        let h = makeFlow(
            transcript: "open brace",
            rules: [RuleDefinition(trigger: "open brace", replace: "{")]
        )

        h.flow.beginRecording()
        try await h.recorder.wait(forEventNamed: "audioSourceDrained")
        h.flow.finishRecording()
        try await h.recorder.wait(forEventNamed: "textInserted")
        await h.flow.waitForIdle()

        XCTAssertEqual(h.inserter.insertions.first?.text, "{")
        let processed = h.recorder.events.first { $0.name == "processed" }
        guard case .processed(let mode, _, _, _, let transformed)? = processed else {
            return XCTFail("expected a processed event, saw \(h.recorder.names)")
        }
        XCTAssertTrue(transformed)
        XCTAssertEqual(mode, DictationMode.plainText.rawValue)
    }

    // MARK: - Spoken submit

    func testSpokenSubmitInTerminalContextSubmitsWithTerminalReturnKey() async throws {
        let h = makeFlow(
            transcript: "send it submit",
            detect: { _, _ in .terminal },
            spokenSubmitPhrases: ["submit"]
        )

        h.flow.beginRecording()
        try await h.recorder.wait(forEventNamed: "audioSourceDrained")
        h.flow.finishRecording()
        try await h.recorder.wait(forEventNamed: "textInserted")
        await h.flow.waitForIdle()

        XCTAssertEqual(h.inserter.insertions.first?.text, "send it")
        XCTAssertEqual(h.inserter.insertions.first?.behavior, TextSubmitBehavior.terminalReturnKey)
        XCTAssertEqual(h.recorder.insertedTexts().first?.behavior, TextSubmitBehavior.terminalReturnKey.logName)
    }

    func testSpokenSubmitInChatContextSubmitsWithReturnKey() async throws {
        let h = makeFlow(
            transcript: "send it submit",
            detect: { _, _ in .chat },
            spokenSubmitPhrases: ["submit"]
        )

        h.flow.beginRecording()
        try await h.recorder.wait(forEventNamed: "audioSourceDrained")
        h.flow.finishRecording()
        try await h.recorder.wait(forEventNamed: "textInserted")
        await h.flow.waitForIdle()

        XCTAssertEqual(h.inserter.insertions.first?.behavior, TextSubmitBehavior.returnKey)
        XCTAssertEqual(h.recorder.insertedTexts().first?.behavior, TextSubmitBehavior.returnKey.logName)
    }

    func testTranscriptWithoutSpokenSubmitInsertsWithNoSubmitBehavior() async throws {
        let h = makeFlow(
            transcript: "just some words",
            detect: { _, _ in .terminal },
            spokenSubmitPhrases: ["submit"]
        )

        h.flow.beginRecording()
        try await h.recorder.wait(forEventNamed: "audioSourceDrained")
        h.flow.finishRecording()
        try await h.recorder.wait(forEventNamed: "textInserted")
        await h.flow.waitForIdle()

        XCTAssertEqual(h.inserter.insertions.first?.behavior, TextSubmitBehavior.none)
        XCTAssertEqual(h.recorder.insertedTexts().first?.behavior, TextSubmitBehavior.none.logName)
    }

    func testSpokenSubmitWithNoTextSubmitsWithoutInserting() async throws {
        let h = makeFlow(
            transcript: "submit",
            detect: { _, _ in .chat },
            spokenSubmitPhrases: ["submit"]
        )

        h.flow.beginRecording()
        try await h.recorder.wait(forEventNamed: "audioSourceDrained")
        h.flow.finishRecording()
        try await h.recorder.wait(forEventNamed: "submittedWithoutText")
        await h.flow.waitForIdle()

        XCTAssertEqual(h.inserter.submits.count, 1)
        XCTAssertEqual(h.inserter.submits.first, TextSubmitBehavior.returnKey)
        XCTAssertTrue(h.inserter.insertions.isEmpty)
        XCTAssertTrue(h.history.entries.isEmpty)
    }

    // MARK: - Cancellation

    func testCancelRecordingCancelsSessionAndInsertsNothing() async throws {
        let h = makeFlow()

        h.flow.beginRecording()
        try await h.recorder.wait(forEventNamed: "recordingStarted")
        h.flow.cancelRecording()
        try await h.recorder.wait(forEventNamed: "cancelled")
        await h.flow.waitForIdle()

        XCTAssertTrue(h.session.didCancel)
        XCTAssertFalse(h.session.didFinish)
        XCTAssertTrue(h.inserter.insertions.isEmpty)
        XCTAssertFalse(h.flow.isRecording)
    }

    func testCancelTranscriptionStopsBeforeInsertion() async throws {
        let session = BlockingTranscriptionSession()
        let h = makeBlockingHarness(session: session)

        h.flow.beginRecording()
        try await h.recorder.wait(forEventNamed: "recordingStarted")
        h.flow.finishRecording()
        try await h.recorder.wait(forEventNamed: "transcribing")
        h.flow.cancelTranscription()
        try await h.recorder.wait(forEventNamed: "cancelled")
        await h.flow.waitForIdle()

        XCTAssertTrue(session.didCancel)
        XCTAssertTrue(h.inserter.insertions.isEmpty)
        XCTAssertFalse(h.recorder.names.contains("textInserted"))
        XCTAssertFalse(h.recorder.names.contains("failed"))
    }

    /// Builds a flow whose transcription session never finishes on its own — it only
    /// resolves when the task awaiting it is cancelled, mirroring the subprocess adapter.
    private func makeBlockingHarness(session: BlockingTranscriptionSession) -> BlockingHarness {
        let relay = DrainRelay()
        let source = WAVFileAudioSource(
            url: Fixtures.url("short-phrase"),
            pacing: .immediate,
            onDrained: { relay.fire() }
        )
        let inserter = RecordingTextInserter()
        let history = makeHistory()
        let blocking = BlockingTranscriber(session: session)

        let settings = DictationSettings(
            backendURL: URL(fileURLWithPath: "/usr/bin/true"),
            modelURL: makeModelFile(),
            inputDeviceUID: nil,
            autoDetectMode: true,
            manualMode: .plainText,
            manualProfile: .generic,
            spokenSubmitPhrases: [],
            goModeSubmitDelay: 0,
            postProcessing: { _, _ in nil }
        )

        var resolver = DictationContextResolver()
        resolver.detect = { _, _ in .general }

        let flow = DictationFlow(dependencies: DictationFlow.Dependencies(
            audioSource: source,
            transcriber: blocking,
            processor: DictationProcessor(store: makeRuleStore(rules: []), postProcessor: PassthroughPostProcessor()),
            contextResolver: resolver,
            textInserter: inserter,
            history: history,
            settings: { settings },
            frontmostApp: { TargetApp(bundleID: "com.apple.TextEdit", name: "TextEdit", pid: 1) },
            validateResources: { try FileValidator.validate(backendURL: $0, modelURL: $1) },
            captureRetryDelay: 0,
            captureAttempts: 3
        ))
        let recorder = EventRecorder()
        flow.delegate = recorder
        relay.onDrain = { [weak flow] in Task { @MainActor in flow?.audioSourceDidDrain() } }

        return BlockingHarness(flow: flow, recorder: recorder, inserter: inserter, history: history)
    }

    struct BlockingHarness {
        let flow: DictationFlow
        let recorder: EventRecorder
        let inserter: RecordingTextInserter
        let history: TranscriptionHistory
    }

    // MARK: - Failures

    func testMissingBackendBinaryFailsBeforeStartingASession() async throws {
        let h = makeFlow(backendURL: URL(fileURLWithPath: "/definitely/not/here/vx-rs"))

        h.flow.beginRecording()
        try await h.recorder.wait(forEventNamed: "failed")

        XCTAssertEqual(h.recorder.failureMessages().first, TranscriberError.missingBinary.localizedDescription)
        XCTAssertEqual(h.transcriber.beginCount, 0)
        XCTAssertFalse(h.flow.isRecording)
        XCTAssertFalse(h.recorder.names.contains("captureWillStart"))
    }

    func testMissingModelFailsBeforeStartingASession() async throws {
        let h = makeFlow(modelURL: URL(fileURLWithPath: "/definitely/not/here/ggml.bin"))

        h.flow.beginRecording()
        try await h.recorder.wait(forEventNamed: "failed")

        XCTAssertEqual(h.recorder.failureMessages().first, TranscriberError.missingModel.localizedDescription)
        XCTAssertEqual(h.transcriber.beginCount, 0)
    }

    func testTranscriberLaunchFailureIsSurfaced() async throws {
        let h = makeFlow()
        h.transcriber.beginError = TranscriberError.processFailed("launch exploded")

        h.flow.beginRecording()
        try await h.recorder.wait(forEventNamed: "failed")

        XCTAssertEqual(h.recorder.failureMessages().first, "launch exploded")
        XCTAssertFalse(h.flow.isRecording)
        XCTAssertTrue(h.recorder.names.contains("captureWillStart"))
    }

    func testAudioStartFailureRetriesThenCancelsSessionAndReportsMicrophoneError() async throws {
        let audio = FailingAudioSource()
        let h = makeFlow(audioSource: audio)

        h.flow.beginRecording()
        try await h.recorder.wait(forEventNamed: "failed")

        XCTAssertEqual(audio.startAttempts, 3)
        XCTAssertTrue(h.session.didCancel)
        XCTAssertFalse(h.flow.isRecording)
        XCTAssertEqual(
            h.recorder.failureMessages().first,
            "Couldn’t start the microphone. If you’re on Bluetooth headphones it may be switching audio modes — try again in a moment."
        )
        XCTAssertFalse(h.recorder.names.contains("recordingStarted"))
    }

    func testTranscriptionFailureIsSurfaced() async throws {
        let h = makeFlow()
        h.session.finishError = TranscriberError.processFailed("boom")

        h.flow.beginRecording()
        try await h.recorder.wait(forEventNamed: "audioSourceDrained")
        h.flow.finishRecording()
        try await h.recorder.wait(forEventNamed: "failed")
        await h.flow.waitForIdle()

        XCTAssertEqual(h.recorder.failureMessages().first, "boom")
        XCTAssertTrue(h.inserter.insertions.isEmpty)
    }

    func testTextInserterFailureIsSurfaced() async throws {
        let h = makeFlow()
        h.inserter.insertError = TextInsertionError.emptyText

        h.flow.beginRecording()
        try await h.recorder.wait(forEventNamed: "audioSourceDrained")
        h.flow.finishRecording()
        try await h.recorder.wait(forEventNamed: "failed")
        await h.flow.waitForIdle()

        XCTAssertEqual(h.recorder.failureMessages().first, TextInsertionError.emptyText.localizedDescription)
        XCTAssertTrue(h.history.entries.isEmpty)
        XCTAssertTrue(h.recorder.names.contains("processed"))
    }

    // MARK: - Guards

    func testBeginRecordingWhileRecordingIsANoOp() async throws {
        let h = makeFlow()

        h.flow.beginRecording()
        try await h.recorder.wait(forEventNamed: "recordingStarted")
        h.flow.beginRecording()

        XCTAssertEqual(h.transcriber.beginCount, 1)
        XCTAssertEqual(h.recorder.names.filter { $0 == "recordingStarted" }.count, 1)

        h.flow.cancelRecording()
        await h.flow.waitForIdle()
    }

    func testFinishRecordingWithoutRecordingIsANoOp() async throws {
        let h = makeFlow()
        h.flow.finishRecording()
        XCTAssertTrue(h.recorder.events.isEmpty)
        XCTAssertFalse(h.flow.isTranscribing)
    }

    // MARK: - Go mode

    func testGoModeTranscribesEachUtteranceAndStopsCleanly() async throws {
        let counter = Counter()
        let transcriber = InMemoryTranscriber()
        transcriber.sessionFactory = {
            InMemoryTranscriptionSession(finalText: "utterance \(counter.next())")
        }
        let h = makeFlow(fixture: "two-utterances", transcriber: transcriber)

        h.flow.startGoMode()
        try await h.recorder.wait(forEventNamed: "goModeStarted")
        XCTAssertTrue(h.flow.isGoModeActive)

        try await h.recorder.wait(forEventNamed: "audioSourceDrained", timeout: 10)
        h.flow.stopGoMode(finishActive: true)
        try await h.recorder.wait(forEventNamed: "textInserted", count: 2, timeout: 20)
        await h.flow.waitForIdle()

        XCTAssertEqual(h.inserter.insertions.count, 2)
        XCTAssertEqual(h.inserter.insertions.map(\.text), ["utterance 1", "utterance 2"])
        XCTAssertTrue(h.recorder.events.contains(.goModeStopped(cancelled: false)))
        XCTAssertFalse(h.flow.isGoModeActive)
        XCTAssertEqual(h.history.entries.count, 2)
    }

    func testGoModeSerializesSlowCleanupAndInsertion() async throws {
        let counter = Counter()
        let transcriber = InMemoryTranscriber()
        transcriber.sessionFactory = {
            InMemoryTranscriptionSession(finalText: "utterance \(counter.next())")
        }
        let cleanup = SlowFirstCleanup()
        let config = PostProcessingConfig(provider: .openAI, model: "test", apiKey: "test",
            customBaseURL: "", customPrompt: "", customDictionary: [], contextHint: "",
            smoothDisfluencies: false)
        let h = makeFlow(fixture: "two-utterances", transcriber: transcriber,
                         postProcessor: cleanup, postProcessing: config)
        h.flow.startGoMode()
        try await h.recorder.wait(forEventNamed: "audioSourceDrained", timeout: 10)
        h.flow.stopGoMode(finishActive: true)
        try await h.recorder.wait(forEventNamed: "textInserted", count: 2, timeout: 10)
        await h.flow.waitForIdle()
        let maximumConcurrency = await cleanup.maximumConcurrency
        XCTAssertEqual(maximumConcurrency, 1)
        XCTAssertEqual(h.inserter.insertions.map(\.text), ["utterance 1", "utterance 2"])
    }

    func testStopGoModeCancelledDropsPendingInsertions() async throws {
        let counter = Counter()
        let transcriber = InMemoryTranscriber()
        transcriber.sessionFactory = {
            InMemoryTranscriptionSession(finalText: "utterance \(counter.next())")
        }
        // A submit delay keeps the segment's processing task parked, so the cancel has
        // something in flight to drop.
        let h = makeFlow(fixture: "two-utterances", transcriber: transcriber, goModeSubmitDelay: 2)

        h.flow.startGoMode()
        try await h.recorder.wait(forEventNamed: "processed", timeout: 20)
        h.flow.stopGoMode(finishActive: false)
        await h.flow.waitForIdle()

        XCTAssertTrue(h.inserter.insertions.isEmpty)
        XCTAssertTrue(h.history.entries.isEmpty)
        XCTAssertTrue(h.recorder.events.contains(.goModeStopped(cancelled: true)))
        XCTAssertFalse(h.flow.isGoModeActive)
    }

    func testStartGoModeWhileRecordingIsRefused() async throws {
        let h = makeFlow()

        h.flow.beginRecording()
        try await h.recorder.wait(forEventNamed: "recordingStarted")
        h.flow.startGoMode()

        XCTAssertFalse(h.flow.isGoModeActive)
        XCTAssertFalse(h.recorder.names.contains("goModeStarted"))

        h.flow.cancelRecording()
        await h.flow.waitForIdle()
    }

    func testBeginRecordingWhileGoModeActiveStopsGoModeFirst() async throws {
        let transcriber = InMemoryTranscriber()
        transcriber.sessionFactory = { InMemoryTranscriptionSession(finalText: "go mode text") }
        let h = makeFlow(fixture: "two-utterances", transcriber: transcriber)

        h.flow.startGoMode()
        try await h.recorder.wait(forEventNamed: "goModeStarted")
        h.flow.beginRecording()
        try await h.recorder.wait(forEventNamed: "goModeStopped")

        XCTAssertFalse(h.flow.isGoModeActive)
        XCTAssertTrue(h.recorder.events.contains(.goModeStopped(cancelled: true)))

        h.flow.cancelRecording()
        h.flow.invalidate()
        await h.flow.waitForIdle()
    }

    func testGoModeStartFailsWhenModelIsMissing() async throws {
        let h = makeFlow(modelURL: URL(fileURLWithPath: "/definitely/not/here/ggml.bin"))

        h.flow.startGoMode()
        try await h.recorder.wait(forEventNamed: "failed")

        XCTAssertEqual(h.recorder.failureMessages().first, TranscriberError.missingModel.localizedDescription)
        XCTAssertFalse(h.flow.isGoModeActive)
        XCTAssertFalse(h.recorder.names.contains("goModeStarted"))
    }
}

// MARK: - Local doubles

/// Counts up on each call. Lets an escaping session factory hand out distinct transcripts.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}

/// `PostProcessor` that returns its input untouched — the flow tests exercise the flow,
/// not the LLM seam.
struct PassthroughPostProcessor: PostProcessor {
    func run(_ text: String, config: PostProcessingConfig) async throws -> String { text }
}

/// A session whose `finish()` never resolves on its own. It only completes when the task
/// awaiting it is cancelled, exactly like the subprocess adapter's cancellation handler.
final class BlockingTranscriptionSession: TranscriptionSession, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, Error>?
    private var cancelled = false

    private(set) var writtenSampleCount = 0
    var didCancel: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func write(samples: [Float]) {
        lock.lock()
        writtenSampleCount += samples.count
        lock.unlock()
    }

    func finish() async throws -> String {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
                lock.lock()
                if cancelled {
                    lock.unlock()
                    cont.resume(throwing: CancellationError())
                    return
                }
                continuation = cont
                lock.unlock()
            }
        } onCancel: {
            self.cancel()
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume(throwing: CancellationError())
    }
}

/// Hands out one `BlockingTranscriptionSession`.
final class BlockingTranscriber: Transcriber {
    let session: BlockingTranscriptionSession
    init(session: BlockingTranscriptionSession) { self.session = session }
    func begin(model: URL) throws -> TranscriptionSession { session }
}

private actor SlowFirstCleanup: PostProcessor {
    private var active = 0
    private(set) var maximumConcurrency = 0
    func run(_ text: String, config: PostProcessingConfig) async throws -> String {
        active += 1
        maximumConcurrency = max(maximumConcurrency, active)
        defer { active -= 1 }
        if text == "utterance 1" { try await Task.sleep(nanoseconds: 200_000_000) }
        return text
    }
}
