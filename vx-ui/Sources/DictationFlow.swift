import Combine
import Foundation

// MARK: - TargetApp

/// Identity of the app a dictation is aimed at, captured once when capture begins so the
/// insertion path never has to re-read the frontmost app and race the HUD.
struct TargetApp: Equatable {
    let bundleID: String?
    let name: String?
    let pid: pid_t

    init(bundleID: String?, name: String?, pid: pid_t) {
        self.bundleID = bundleID
        self.name = name
        self.pid = pid
    }
}

// MARK: - DictationSettings

/// The flat snapshot of user preferences one dictation runs against. Taken at each
/// `beginRecording` / `startGoMode` and once per Go-mode segment, so a preference change
/// mid-recording can never half-apply.
struct DictationSettings {
    var backendURL: URL
    var modelURL: URL
    var inputDeviceUID: String?
    var autoDetectMode: Bool
    var manualMode: DictationMode
    var manualProfile: CodeProfile
    var spokenSubmitPhrases: [String]
    var goModeSubmitDelay: TimeInterval
    /// Builds the optional LLM post-processing config for a resolved rule context.
    /// `goMode` distinguishes the two enablement switches the app exposes.
    var postProcessing: (RuleContext, _ goMode: Bool) -> PostProcessingConfig?
}

// MARK: - DictationFlowDelegate

/// Receives every Flow Event. The coordinator implements this to drive AppKit — sounds,
/// ducking, HUD, status item, escape monitors — none of which the flow knows about.
@MainActor
protocol DictationFlowDelegate: AnyObject {
    func flow(_ flow: DictationFlow, didEmit event: DictationFlowEvent)
}

// MARK: - DictationFlow

/// Dictation Flow: orchestration of one dictation from capture start to inserted text,
/// plus Go mode's continuous variant.
///
/// Owns `isRecording` / `isGoModeActive` and drives Audio Source → Transcription Session →
/// Dictation Processor → Text Inserter, emitting a Flow Event at every step. It performs
/// no AppKit UI: the delegate turns events into sounds, ducking, HUD, and monitors. That
/// split is what makes the whole dictation path testable without a microphone, a backend
/// subprocess, or a window server.
@MainActor
final class DictationFlow {

    // MARK: Dependencies

    struct Dependencies {
        var audioSource: AudioSource
        var transcriber: Transcriber
        var processor: DictationProcessor
        var contextResolver: DictationContextResolver
        var textInserter: TextInserting
        var history: TranscriptionHistory
        /// Re-read at each begin so the flow never holds a stale preference snapshot.
        var settings: () -> DictationSettings
        var frontmostApp: () -> TargetApp?
        /// Backend + model existence check. `FileValidator.validate` in production.
        var validateResources: (URL, URL) throws -> Void
        /// Settle delay between failed capture-start attempts. 0 in tests.
        var captureRetryDelay: TimeInterval = 0.25
        var captureAttempts: Int = 3
    }

    /// Side channel for the details a `DictationFlowEvent` payload cannot carry: which app
    /// the text is going to, the resolved `AppContext`, and whether this is Go mode.
    ///
    /// Set before `.processed` and still valid for the insertion events that follow it, and
    /// reset at each begin so a `.failed` before any processing still reports the right mode.
    struct EventContext {
        var target: TargetApp?
        var detectedContext: AppContext?
        var goMode: Bool
    }

    private let deps: Dependencies
    weak var delegate: DictationFlowDelegate?

    /// Exposed so the coordinator can subscribe to levels for the HUD.
    var audioSource: AudioSource { deps.audioSource }

    private(set) var isRecording = false
    private(set) var isGoModeActive = false
    var isTranscribing: Bool { transcriptionTask != nil }

    /// How long the delegate should keep the most recent `.failed` message on screen.
    /// Set immediately before the event is emitted; the enum itself carries only the text.
    private(set) var lastFailureDismissAfter: TimeInterval = 2.5
    private(set) var eventContext = EventContext(target: nil, detectedContext: nil, goMode: false)

    private var activeSession: TranscriptionSession?
    private var transcribingSession: TranscriptionSession?
    private var transcriptionTask: Task<Void, Never>?
    /// Identifies the transcription currently owning `transcriptionTask`, so a task that
    /// finishes late can only clear its own handle and never a newer recording's.
    private var transcriptionToken = 0
    private var goModeProcessingTasks: [UUID: Task<Void, Never>] = [:]
    private var goModeProcessingTail: Task<Void, Never>?
    private var goModeSegmenter: GoModeSegmenter?

    private var recordingSettings: DictationSettings?
    private var recordingTarget: TargetApp?
    private var goModeTarget: TargetApp?

    init(dependencies: Dependencies) {
        self.deps = dependencies
    }

    // MARK: - Events

    private func emit(_ event: DictationFlowEvent) {
        delegate?.flow(self, didEmit: event)
    }

    private func fail(_ message: String, dismissAfter: TimeInterval) {
        lastFailureDismissAfter = dismissAfter
        emit(.failed(message))
    }

    /// Called by whoever owns a replay Audio Source when it runs out of audio. The
    /// `AudioSource` seam has no drain concept — a microphone never drains — so the
    /// notification comes from outside rather than from a protocol requirement.
    func audioSourceDidDrain() {
        emit(.audioSourceDrained)
    }

    // MARK: - Recording lifecycle

    func toggleRecording() {
        if isRecording {
            finishRecording()
        } else {
            beginRecording()
        }
    }

    func beginRecording() {
        guard !isRecording else { return }
        if isGoModeActive {
            stopGoMode(finishActive: false)
        }

        // Capture the frontmost app before the HUD shows. The HUD is a
        // non-activating panel so focus stays on the target app, but we store
        // the bundle ID now so finishRecording() can use it without a race.
        let target = deps.frontmostApp()
        recordingTarget = target
        eventContext = EventContext(target: target, detectedContext: nil, goMode: false)

        let settings = deps.settings()
        recordingSettings = settings

        do {
            try deps.validateResources(settings.backendURL, settings.modelURL)
        } catch {
            fail(error.localizedDescription, dismissAfter: 2.0)
            return
        }

        // The delegate ducks non-Bluetooth output here: AudioObjectSetPropertyData on a
        // Bluetooth output device races with AVAudioEngine's installTap and causes an
        // uncatchable NSException, so Bluetooth ducking waits for `.recordingStarted`.
        emit(.captureWillStart(goMode: false))

        // Launch the streaming vx-rs session before starting capture so audio arrives
        // from the very first tap callback. There is no file-mode fallback: if the session
        // can't start, the backend is genuinely broken, so surface it and abort.
        let session: TranscriptionSession
        do {
            session = try deps.transcriber.begin(model: settings.modelURL)
        } catch {
            vxLog("[flow/beginRecording] Streaming launch failed: \(error.localizedDescription)")
            fail(error.localizedDescription, dismissAfter: 2.0)
            return
        }

        // Start the audio source, retrying a few times. When a Bluetooth output device
        // (e.g. WH-1000XM3) flips between A2DP and HFP/SCO as input capture begins,
        // engine.start() intermittently fails with kAudioUnitErr_FormatNotSupported (-10868).
        // A short settle delay plus a fresh engine usually succeeds, and each failed attempt
        // tears itself down cleanly, so retries don't leak or wedge CoreAudio.
        let engineStartTime = Date()
        let maxAttempts = max(1, deps.captureAttempts)
        var startError: Error?
        var started = false
        for attempt in 1...maxAttempts {
            do {
                try deps.audioSource.start(deviceUID: settings.inputDeviceUID) { samples in
                    session.write(samples: samples)
                }
                started = true
                if attempt > 1 { vxLog("[flow/beginRecording] start succeeded on attempt \(attempt)/\(maxAttempts)") }
                break
            } catch {
                startError = error
                vxLog("[flow/beginRecording] start attempt \(attempt)/\(maxAttempts) failed: \(error.localizedDescription)")
                if attempt < maxAttempts, deps.captureRetryDelay > 0 {
                    Thread.sleep(forTimeInterval: deps.captureRetryDelay)
                }
            }
        }

        if started {
            activeSession = session
            vxLog("[flow/beginRecording] startRecording: \(String(format: "%.1f", Date().timeIntervalSince(engineStartTime) * 1000))ms")
            isRecording = true
            // Capture is running and the tap is installed — safe for the delegate to duck
            // Bluetooth output now.
            emit(.recordingStarted)
        } else {
            // Couldn't start after retries — kill the streaming process and let the
            // delegate undo any duck.
            session.cancel()
            vxLog("[flow/beginRecording] giving up after \(maxAttempts) attempts: \(startError?.localizedDescription ?? "unknown error")")
            fail("Couldn’t start the microphone. If you’re on Bluetooth headphones it may be switching audio modes — try again in a moment.", dismissAfter: 3.0)
        }

        vxLog("[flow/beginRecording] Backend: \(settings.backendURL.path)")
        vxLog("[flow/beginRecording] Model: \(settings.modelURL.path)")
    }

    func finishRecording() {
        guard isRecording else { return }
        isRecording = false

        // Emitted before the source stops: on Bluetooth devices (AirPods) the device
        // transitions from SCO/HFP back to A2DP after teardown, and during that handoff
        // the device reports as muted, silencing any sound played after stop.
        emit(.recordingWillStop)

        // Stop capture first — engine.stop() blocks the main thread while audio buffers
        // drain. Starting the restore fade after teardown means the timer fires cleanly
        // without that blocking window interfering.
        let stopStart = Date()
        deps.audioSource.stop()
        vxLog("[flow/finishRecording] stopRecording: \(String(format: "%.1f", Date().timeIntervalSince(stopStart) * 1000))ms")

        emit(.transcribing)

        transcriptionTask?.cancel()
        let transcribeStart = Date()
        let capturedSession = activeSession
        activeSession = nil
        transcribingSession = capturedSession
        let settings = recordingSettings ?? deps.settings()
        let target = recordingTarget

        transcriptionToken += 1
        let token = transcriptionToken
        transcriptionTask = Task { [weak self] in
            guard let self else { return }
            // The handle is the only thing `isTranscribing` reads, so a finished
            // transcription has to drop it — otherwise the flow reports "transcribing"
            // forever after the first successful dictation.
            defer { if self.transcriptionToken == token { self.transcriptionTask = nil } }
            do {
                guard let session = capturedSession else {
                    // Recording only starts once a live session exists, so this is unreachable
                    // in practice; treat a lost session as a surfaced failure rather than crash.
                    self.fail("Transcription session was lost.", dismissAfter: 2.0)
                    return
                }
                // Closing stdin triggers final inference in vx-rs.
                let text = try await session.finish()
                vxLog("[flow/finishRecording] stream finish: \(String(format: "%.1f", Date().timeIntervalSince(transcribeStart) * 1000))ms")
                self.transcribingSession = nil

                guard !Task.isCancelled else { return }
                self.emit(.transcriptReceived(text))

                // Resolve the dictation context for this recording session. When auto-detect
                // is enabled, the frontmost app's bundle ID (captured at beginRecording time)
                // is mapped to a mode/profile; a no-match falls back to the manual selection.
                let resolved = self.deps.contextResolver.resolve(
                    autoDetect: settings.autoDetectMode,
                    bundleID: target?.bundleID,
                    pid: target?.pid ?? 0,
                    manualMode: settings.manualMode,
                    manualProfile: settings.manualProfile
                )
                let detectedContext = resolved.detectedContext
                let ruleContext = resolved.ruleContext
                let targetPID = target?.pid ?? 0
                let submitTargetContext = target?.bundleID.map {
                    self.deps.contextResolver.detect($0, targetPID)
                }
                if let ctx = detectedContext {
                    vxLog("[flow/finishRecording] Auto-detected context: \(ctx.displayName) for \(target?.bundleID ?? "unknown")")
                }
                let postProcessing = settings.postProcessing(ruleContext, false)
                let spokenSubmitCommand = SpokenSubmitCommandDetector.detect(
                    in: text,
                    phrases: settings.spokenSubmitPhrases
                )
                let textForProcessing = spokenSubmitCommand.shouldSubmit ? spokenSubmitCommand.textToInsert : text

                // Sanitize → rules → (optional) post-process, all behind one interface.
                // .noSpeech means nothing real survived sanitization or post-processing.
                let dictationSession = DictationSession(
                    mode: ruleContext.mode,
                    codeProfile: ruleContext.codeProfile,
                    postProcessing: postProcessing
                )
                let processingOutcome: DictationOutcome
                if spokenSubmitCommand.shouldSubmit, textForProcessing.isEmpty {
                    processingOutcome = .noSpeech
                } else {
                    processingOutcome = await self.deps.processor.process(textForProcessing, session: dictationSession)
                }

                let finalText: String
                let pipelineResult: TransformationResult?
                switch processingOutcome {
                case .text(let output, let result):
                    finalText = output
                    pipelineResult = result
                case .noSpeech:
                    guard spokenSubmitCommand.shouldSubmit else {
                        vxLog("[flow/finishRecording] No speech after processing, raw: \(text.debugDescription)")
                        self.emit(.noSpeech)
                        return
                    }
                    finalText = ""
                    pipelineResult = nil
                }
                guard !Task.isCancelled else { return }

                let profileSuffix = ruleContext.mode == .code ? "/\(ruleContext.codeProfile.rawValue)" : ""
                vxLog("[flow/finishRecording] Mode: \(ruleContext.mode.rawValue)\(profileSuffix), rules loaded: \(pipelineResult?.ruleCount ?? 0), transformed: \(pipelineResult?.didTransform ?? false)")

                self.eventContext = EventContext(target: target, detectedContext: detectedContext, goMode: false)
                self.emit(.processed(
                    mode: ruleContext.mode.rawValue,
                    profile: ruleContext.codeProfile.rawValue,
                    detectedContext: detectedContext?.displayName,
                    ruleCount: pipelineResult?.ruleCount ?? 0,
                    transformed: pipelineResult?.didTransform ?? false
                ))

                do {
                    let submitBehavior = GoModeSubmitStrategy.behavior(
                        targetContext: submitTargetContext,
                        ruleContext: ruleContext
                    )
                    if spokenSubmitCommand.shouldSubmit {
                        vxLog("[flow/finishRecording] Spoken submit detected, behavior: \(submitBehavior.logName), inserted text empty: \(finalText.isEmpty)")
                        if finalText.isEmpty {
                            self.deps.textInserter.submit(behavior: submitBehavior)
                            self.emit(.submittedWithoutText(behavior: submitBehavior.logName))
                        } else {
                            try self.deps.textInserter.insert(finalText, submitBehavior: submitBehavior)
                            self.deps.history.append(finalText)
                            self.emit(.textInserted(finalText, behavior: submitBehavior.logName))
                        }
                    } else {
                        try self.deps.textInserter.insert(finalText, submitBehavior: .none)
                        self.deps.history.append(finalText)
                        self.emit(.textInserted(finalText, behavior: TextSubmitBehavior.none.logName))
                    }
                } catch {
                    self.fail(error.localizedDescription, dismissAfter: 2.5)
                }
            } catch {
                self.transcribingSession = nil
                guard !Task.isCancelled else { return }
                self.fail(error.localizedDescription, dismissAfter: 2.5)
            }
        }
    }

    func cancelRecording() {
        guard isRecording else { return }
        isRecording = false
        activeSession?.cancel()
        activeSession = nil
        deps.audioSource.stop()
        emit(.cancelled)
    }

    /// Cancels an in-progress transcription (called by the processing-phase escape monitor).
    func cancelTranscription() {
        vxLog("[flow/cancelTranscription] Transcription cancelled by user")
        transcriptionTask?.cancel()
        transcriptionTask = nil
        // Cancelling the task alone already terminates the subprocess through the session's
        // cancellation handler; killing the session directly makes that guaranteed rather
        // than dependent on when the task next reaches a suspension point.
        transcribingSession?.cancel()
        transcribingSession = nil
        emit(.cancelled)
    }

    // MARK: - Go mode

    func toggleGoMode() {
        if isGoModeActive {
            stopGoMode(finishActive: true)
        } else {
            startGoMode()
        }
    }

    func startGoMode() {
        guard !isGoModeActive, !isRecording else { return }

        let target = deps.frontmostApp()
        goModeTarget = target
        eventContext = EventContext(target: target, detectedContext: nil, goMode: true)

        let settings = deps.settings()

        do {
            try deps.validateResources(settings.backendURL, settings.modelURL)
        } catch {
            fail(error.localizedDescription, dismissAfter: 2.0)
            return
        }

        emit(.captureWillStart(goMode: true))

        let segmenter = GoModeSegmenter(
            transcriber: deps.transcriber,
            modelURL: settings.modelURL,
            onTranscript: { [weak self] text in
                self?.processGoModeTranscript(text)
            },
            onFailure: { [weak self] error in
                guard let self else { return }
                self.fail(error.localizedDescription, dismissAfter: 2.5)
                self.stopGoMode(finishActive: false)
            }
        )

        let startTime = Date()
        let maxAttempts = max(1, deps.captureAttempts)
        var startError: Error?
        var started = false
        for attempt in 1...maxAttempts {
            do {
                try deps.audioSource.start(deviceUID: settings.inputDeviceUID) { [weak segmenter] samples in
                    segmenter?.ingest(samples: samples)
                }
                started = true
                if attempt > 1 { vxLog("[go-mode/start] capture succeeded on attempt \(attempt)/\(maxAttempts)") }
                break
            } catch {
                startError = error
                vxLog("[go-mode/start] capture attempt \(attempt)/\(maxAttempts) failed: \(error.localizedDescription)")
                if attempt < maxAttempts, deps.captureRetryDelay > 0 {
                    Thread.sleep(forTimeInterval: deps.captureRetryDelay)
                }
            }
        }

        guard started else {
            segmenter.stop(finishActive: false)
            fail("Couldn’t start Go mode microphone capture: \(startError?.localizedDescription ?? "unknown error")", dismissAfter: 3.0)
            return
        }

        goModeSegmenter = segmenter
        isGoModeActive = true
        emit(.goModeStarted)
        vxLog("[go-mode/start] Active: capture \(String(format: "%.1f", Date().timeIntervalSince(startTime) * 1000))ms")
        vxLog("[go-mode/start] Backend: \(settings.backendURL.path)")
        vxLog("[go-mode/start] Model: \(settings.modelURL.path)")
    }

    func stopGoMode(finishActive: Bool) {
        guard isGoModeActive || goModeSegmenter != nil else { return }
        isGoModeActive = false

        goModeSegmenter?.stop(finishActive: finishActive)
        goModeSegmenter = nil

        deps.audioSource.stop()

        if finishActive {
            vxLog("[go-mode/stop] Stopped")
        } else {
            for task in goModeProcessingTasks.values { task.cancel() }
            goModeProcessingTasks.removeAll()
            vxLog("[go-mode/stop] Cancelled")
        }

        emit(.goModeStopped(cancelled: !finishActive))
    }

    private func processGoModeTranscript(_ rawText: String) {
        let settings = deps.settings()
        let storedTarget = goModeTarget
        let taskID = UUID()
        let previous = goModeProcessingTail
        let task = Task { [weak self] in
            guard let self else { return }
            defer { self.goModeProcessingTasks[taskID] = nil }
            // Serialize rule-store access and optional cleanup through text insertion.
            await previous?.value
            guard !Task.isCancelled else { return }

            let liveTarget = self.deps.frontmostApp()
            let targetBundleID = liveTarget?.bundleID ?? storedTarget?.bundleID
            let targetPID = liveTarget?.pid ?? storedTarget?.pid ?? 0
            let targetAppName = liveTarget?.name ?? storedTarget?.name ?? "unknown"
            let targetContext = targetBundleID.map { self.deps.contextResolver.detect($0, targetPID) }
            let resolved = self.deps.contextResolver.resolve(
                autoDetect: settings.autoDetectMode,
                bundleID: targetBundleID,
                pid: targetPID,
                manualMode: settings.manualMode,
                manualProfile: settings.manualProfile
            )
            let ruleContext = resolved.ruleContext
            let postProcessing = settings.postProcessing(ruleContext, true)
            let dictationSession = DictationSession(
                mode: ruleContext.mode,
                codeProfile: ruleContext.codeProfile,
                postProcessing: postProcessing
            )

            self.eventContext = EventContext(
                target: TargetApp(bundleID: targetBundleID, name: targetAppName, pid: targetPID),
                detectedContext: resolved.detectedContext,
                goMode: true
            )

            guard case .text(let finalText, let pipelineResult) = await self.deps.processor.process(rawText, session: dictationSession) else {
                vxLog("[go-mode/process] No speech after processing, raw: \(rawText.debugDescription)")
                self.emit(.noSpeech)
                return
            }
            guard !Task.isCancelled else { return }

            let profileSuffix = ruleContext.mode == .code ? "/\(ruleContext.codeProfile.rawValue)" : ""
            vxLog("[go-mode/process] Mode: \(ruleContext.mode.rawValue)\(profileSuffix), rules loaded: \(pipelineResult.ruleCount), transformed: \(pipelineResult.didTransform)")

            self.emit(.processed(
                mode: ruleContext.mode.rawValue,
                profile: ruleContext.codeProfile.rawValue,
                detectedContext: resolved.detectedContext?.displayName,
                ruleCount: pipelineResult.ruleCount,
                transformed: pipelineResult.didTransform
            ))

            let submitDelay = min(max(settings.goModeSubmitDelay, 0), 2)
            if submitDelay > 0 {
                vxLog("[go-mode/submit] Waiting \(String(format: "%.2f", submitDelay))s before submit")
                do {
                    try await Task.sleep(nanoseconds: UInt64(submitDelay * 1_000_000_000))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
            }

            do {
                let submitBehavior = GoModeSubmitStrategy.behavior(
                    targetContext: targetContext,
                    ruleContext: ruleContext
                )
                vxLog("[go-mode/submit] Target: \(targetAppName) (\(targetBundleID ?? "unknown")), context: \(targetContext?.displayName ?? "unknown"), behavior: \(submitBehavior.logName)")
                try self.deps.textInserter.insert(finalText, submitBehavior: submitBehavior)
                self.deps.history.append(finalText)
                self.emit(.textInserted(finalText, behavior: submitBehavior.logName))
            } catch {
                self.fail(error.localizedDescription, dismissAfter: 2.5)
            }
        }
        goModeProcessingTasks[taskID] = task
        goModeProcessingTail = task
    }

    // MARK: - Teardown / test support

    /// Awaits the transcription task and every in-flight Go-mode segment. Test-only helper:
    /// production never needs to block on the flow.
    func waitForIdle() async {
        await transcriptionTask?.value
        while true {
            let tasks = Array(goModeProcessingTasks.values)
            if tasks.isEmpty { return }
            for task in tasks { await task.value }
            await Task.yield()
        }
    }

    func invalidate() {
        transcriptionTask?.cancel()
        transcriptionTask = nil
        for task in goModeProcessingTasks.values { task.cancel() }
        goModeProcessingTasks.removeAll()
        goModeSegmenter?.stop(finishActive: false)
        goModeSegmenter = nil
        activeSession?.cancel()
        activeSession = nil
        transcribingSession = nil
    }
}
