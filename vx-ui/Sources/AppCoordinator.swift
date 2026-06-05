import AppKit
import AVFoundation
import Carbon
import Combine
import Foundation
import SwiftUI

@MainActor
public final class AppCoordinator: NSObject {
    private let appState: AppState
    private lazy var overlay = OverlayWindow(idleMessage: idleMessage)
    private let hud = DictationHUDController()
    private let audioCapture = AudioCapture()
    private let transcriber = SubprocessTranscriber()
    private let dictationProcessor = DictationProcessor()
    private let contextResolver = DictationContextResolver()
    private let preferencesController = PreferencesController()
    private let debugLogController = DebugLogController()
    private let historyController = TranscriptionHistoryController()
    private let volumeController = SystemVolumeController()

    private let updateChecker = UpdateChecker()
    private let soundPlayer = SoundPlayer()
    private let contextDebugController = ContextDebugController()

    private var statusItem: NSStatusItem?
    private var updateMenuView: UpdateMenuItemView?
    private var historyMenuItem: NSMenuItem?

    private var autoDetectModeMenuItem: NSMenuItem?
    private var detectionStatusMenuItem: NSMenuItem?
    private var modeParentMenuItem: NSMenuItem?
    private var modeMenuItems: [DictationMode: NSMenuItem] = [:]
    private var profileMenuItem: NSMenuItem?
    private var profileMenuItems: [CodeProfile: NSMenuItem] = [:]
    /// Bundle ID, name, and PID of the frontmost app at the moment recording began.
    private var recordingTargetBundleID: String?
    private var recordingTargetAppName: String?
    private var recordingTargetPID: pid_t = 0
    private var shortcutMonitor: GlobalShortcutMonitor?
    private var doubleTapMonitor: DoubleTapMonitor?
    private var modifierMonitor: ModifierKeyMonitor?
    private var copyLastMonitor: GlobalShortcutMonitor?
    private var transcriptionTask: Task<Void, Never>?
    private var currentRecordingURL: URL?
    private var activeStream: TranscriptionSession?
    private var isRecording = false
    private var cancellables = Set<AnyCancellable>()
    private var accessibilityAlertShown = false
    private var escapeGlobalMonitor: Any?
    private var escapeLocalMonitor: Any?

    @MainActor
    private func logFailure(_ message: String, dismissAfter: TimeInterval = 2.5) {
        vxLog("[coordinator/error] \(message)")
        overlay.present(.failure(message))
        overlay.dismiss(after: dismissAfter)
        hud.flashStatus(.error, duration: dismissAfter + 0.75)
    }

    private var idleMessage: String {
        switch appState.activationMode {
        case .holdToTalk:
            return "Hold \(appState.shortcut.displayName) to dictate"
        case .toggle:
            return "Press \(appState.shortcut.displayName) to toggle dictation"
        }
    }

    public init(appState: AppState) {
        self.appState = appState
        super.init()
        setupStatusItem()
        setupShortcut()
        setupCopyLastShortcut()
        observeAppState()
        hud.updateHint(idleMessage)
        hud.isDebugMode = appState.isDebugMode
        if appState.isDebugMode {
            debugLogController.show()
            contextDebugController.show(appState: appState)
        }
        hud.showHint()
        preflightResources()
        AppContextDetector.createDefaultFileIfNeeded()
        ContextPromptStore.createDefaultFilesIfNeeded()
        requestMicrophonePermission()
        vxLog("[coordinator/init] Debug log: \(DebugLogger.shared.logFileURL.path)")
        updateChecker.onUpdateAvailable = { [weak self] update in
            self?.promptToInstall(update)
        }
        updateChecker.onNoUpdateAvailable = { [weak self] in
            self?.updateMenuView?.setState(.result("No updates available."))
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.updateMenuView?.setState(.idle)
            }
        }
        updateChecker.onCheckFailed = { [weak self] in
            self?.updateMenuView?.setState(.result("Could not check for updates."))
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.updateMenuView?.setState(.idle)
            }
        }
        updateChecker.onProgress = { [weak self] fraction in
            let pct = Int(fraction * 100)
            self?.updateMenuView?.setState(.result("Downloading… \(pct)%"))
        }
        Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            updateChecker.checkForUpdates()
        }
    }

    public func invalidate() {
        shortcutMonitor?.stop()
        doubleTapMonitor?.stop()
        modifierMonitor?.stop()
        copyLastMonitor?.stop()
        transcriptionTask?.cancel()
        FnKeyTap.shared.deactivate()
    }

    private func observeAppState() {
        let configPublisher = Publishers.CombineLatest(appState.$shortcut, appState.$activationMode)

        configPublisher
            .dropFirst()
            .sink { [weak self] _ in self?.restartShortcutMonitor() }
            .store(in: &cancellables)
        configPublisher
            .sink { [weak self] _ in
                guard let self else { return }
                self.overlay.updateIdleMessage(self.idleMessage)
                self.hud.updateHint(self.idleMessage)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .vxPauseShortcut)
            .sink { [weak self] _ in
                self?.shortcutMonitor?.stop()
                self?.shortcutMonitor = nil
                self?.doubleTapMonitor?.stop()
                self?.doubleTapMonitor = nil
                self?.modifierMonitor?.stop()
                self?.modifierMonitor = nil
                self?.copyLastMonitor?.stop()
                self?.copyLastMonitor = nil
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .vxResumeShortcut)
            .sink { [weak self] _ in
                self?.restartShortcutMonitor()
                // Always tear down and recreate the copy-last monitor so it picks up any
                // shortcut change that occurred while shortcuts were paused.
                self?.copyLastMonitor?.stop()
                self?.copyLastMonitor = nil
                self?.setupCopyLastShortcut()
            }
            .store(in: &cancellables)

        appState.$copyLastShortcut
            .dropFirst()
            .sink { [weak self] newShortcut in
                // @Published fires in willSet, so appState.copyLastShortcut still holds the old
                // value here. Use the publisher-supplied newShortcut directly so the monitor is
                // set up for the new binding, not the old one.
                guard let self else { return }
                self.copyLastMonitor?.stop()
                self.copyLastMonitor = nil
                guard case .combo(let keyCode, let modifiers) = newShortcut else { return }
                let monitor = GlobalShortcutMonitor(keyCode: keyCode, modifiers: modifiers) { [weak self] event in
                    guard event == .keyDown else { return }
                    DispatchQueue.main.async { self?.copyLastTranscription() }
                }
                monitor.start()
                self.copyLastMonitor = monitor
            }
            .store(in: &cancellables)

        audioCapture.levelPublisher
            .sink { [weak self] in self?.hud.updateLevel($0) }
            .store(in: &cancellables)

        appState.$autoDetectMode
            .dropFirst()
            .sink { [weak self] enabled in
                guard let self else { return }
                self.autoDetectModeMenuItem?.state = enabled ? .on : .off
                let currentMode = self.appState.currentMode
                for (mode, item) in self.modeMenuItems {
                    item.state = (!enabled && mode == currentMode) ? .on : .off
                }
                vxLog("[coordinator] Auto-detect mode: \(enabled)")
            }
            .store(in: &cancellables)

        appState.$currentMode
            .dropFirst()
            .sink { [weak self] newMode in
                guard let self else { return }
                for (mode, item) in self.modeMenuItems {
                    item.state = (!self.appState.autoDetectMode && mode == newMode) ? .on : .off
                }
                self.profileMenuItem?.isEnabled = newMode == .code
                RuleStore.shared.reload()
                vxLog("[coordinator] Dictation mode changed to: \(newMode.rawValue)")
            }
            .store(in: &cancellables)

        appState.$currentCodeProfile
            .dropFirst()
            .sink { [weak self] newProfile in
                guard let self else { return }
                for (profile, item) in self.profileMenuItems {
                    item.state = profile == newProfile ? .on : .off
                }
                RuleStore.shared.reload()
                vxLog("[coordinator] Code profile changed to: \(newProfile.rawValue)")
            }
            .store(in: &cancellables)

        appState.$isDebugMode
            .dropFirst()
            .sink { [weak self] enabled in
                guard let self else { return }
                self.hud.isDebugMode = enabled
                if enabled {
                    self.debugLogController.show()
                    self.contextDebugController.show(appState: self.appState)
                } else {
                    self.debugLogController.close()
                    self.contextDebugController.close()
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .vxShowDebugLog)
            .sink { [weak self] _ in self?.debugLogController.show() }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .vxInstallVersion)
            .sink { [weak self] notification in
                guard let version = notification.userInfo?["version"] as? String,
                      let urlString = notification.userInfo?["url"] as? String,
                      let url = URL(string: urlString) else { return }
                let update = AvailableUpdate(version: version, downloadURL: url)
                self?.promptToInstall(update, isRollback: true)
            }
            .store(in: &cancellables)
    }

    private func restartShortcutMonitor() {
        shortcutMonitor?.stop()
        shortcutMonitor = nil
        doubleTapMonitor?.stop()
        doubleTapMonitor = nil
        modifierMonitor?.stop()
        modifierMonitor = nil
        FnKeyTap.shared.deactivate()
        setupShortcut()
    }

    private func setupCopyLastShortcut() {
        guard copyLastMonitor == nil else { return }
        guard case .combo(let keyCode, let modifiers) = appState.copyLastShortcut else { return }
        let monitor = GlobalShortcutMonitor(keyCode: keyCode, modifiers: modifiers) { [weak self] event in
            guard event == .keyDown else { return }
            DispatchQueue.main.async { self?.copyLastTranscription() }
        }
        monitor.start()
        copyLastMonitor = monitor
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "waveform.circle.fill", accessibilityDescription: "vx")
        item.button?.imagePosition = .imageOnly
        item.button?.alphaValue = 0.55

        let menu = NSMenu()
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let versionItem = NSMenuItem(title: "Version \(version)", action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(versionItem)
        menu.addItem(NSMenuItem.separator())

        let detectionItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        detectionItem.isEnabled = false
        detectionItem.isHidden = !appState.autoDetectMode
        menu.addItem(detectionItem)
        detectionStatusMenuItem = detectionItem

        menu.addItem(withTitle: "Preferences", action: #selector(openPreferences), keyEquivalent: "")
        menu.items.last?.target = self

        // Mode submenu
        let modeItem = NSMenuItem(title: "Mode", action: nil, keyEquivalent: "")
        let modeSubmenu = NSMenu(title: "Mode")
        let autoItem = NSMenuItem(title: "Auto-detect", action: #selector(toggleAutoDetectMode), keyEquivalent: "")
        autoItem.target = self
        autoItem.state = appState.autoDetectMode ? .on : .off
        modeSubmenu.addItem(autoItem)
        autoDetectModeMenuItem = autoItem
        modeSubmenu.addItem(NSMenuItem.separator())
        for mode in DictationMode.allCases {
            let item = NSMenuItem(title: mode.displayName, action: #selector(setDictationMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode
            item.state = (!appState.autoDetectMode && appState.currentMode == mode) ? .on : .off
            modeSubmenu.addItem(item)
            modeMenuItems[mode] = item
        }
        modeItem.submenu = modeSubmenu
        menu.addItem(modeItem)
        modeParentMenuItem = modeItem

        // Code Profile submenu — visible always, enabled only in code mode
        let profileItem = NSMenuItem(title: "Code Profile", action: nil, keyEquivalent: "")
        let profileSubmenu = NSMenu(title: "Code Profile")
        for profile in CodeProfile.allCases {
            let item = NSMenuItem(title: profile.displayName, action: #selector(setCodeProfile(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = profile
            item.state = appState.currentCodeProfile == profile ? .on : .off
            profileSubmenu.addItem(item)
            profileMenuItems[profile] = item
        }
        profileItem.submenu = profileSubmenu
        profileItem.isEnabled = appState.currentMode == .code
        menu.addItem(profileItem)
        profileMenuItem = profileItem

        let historyItem = NSMenuItem(title: "History", action: nil, keyEquivalent: "")
        historyItem.submenu = NSMenu(title: "History")
        menu.addItem(historyItem)
        historyMenuItem = historyItem
        menu.addItem(NSMenuItem.separator())
        let updateItem = NSMenuItem()
        let updateView = UpdateMenuItemView(frame: NSRect(x: 0, y: 0, width: 220, height: 22))
        updateView.onTrigger = { [weak self] in self?.triggerUpdateCheck() }
        updateItem.view = updateView
        menu.addItem(updateItem)
        updateMenuView = updateView
        menu.addItem(withTitle: "Relaunch vx", action: #selector(relaunchApp), keyEquivalent: "")
        menu.items.last?.target = self
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Quit vx", action: #selector(quit), keyEquivalent: "")
        menu.items.last?.target = self

        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    private func setupShortcut() {
        FnKeyTap.shared.deactivate()

        switch appState.shortcut {
        case .combo(let keyCode, _) where keyCode == CGKeyCode(kVK_Function):
            let success: Bool
            if appState.activationMode == .holdToTalk {
                success = FnKeyTap.shared.activate(
                    onPress: { [weak self] in self?.beginRecording() },
                    onRelease: { [weak self] in self?.finishRecording() }
                )
            } else {
                success = FnKeyTap.shared.activate(
                    onPress: { [weak self] in self?.toggleRecording() },
                    onRelease: { }
                )
            }
            if !success { promptForAccessibilityPermission() }

        case .combo(let keyCode, let modifiers):
            let monitor = GlobalShortcutMonitor(keyCode: keyCode, modifiers: modifiers) { [weak self] event in
                guard let self else { return }
                switch (self.appState.activationMode, event) {
                case (.holdToTalk, .keyDown): DispatchQueue.main.async { self.beginRecording() }
                case (.holdToTalk, .keyUp):   DispatchQueue.main.async { self.finishRecording() }
                case (.toggle,     .keyDown): DispatchQueue.main.async { self.toggleRecording() }
                case (.toggle,     .keyUp):   break
                }
            }
            monitor.start()
            shortcutMonitor = monitor

        case .doubleTap(let modifier):
            // Double-tap is toggle-only; AppState guarantees it never pairs with hold-to-talk.
            let monitor = DoubleTapMonitor(modifier: modifier) { [weak self] event in
                guard event == .keyDown else { return }
                DispatchQueue.main.async { self?.toggleRecording() }
            }
            monitor.start()
            doubleTapMonitor = monitor

        case .modifier(let modifier):
            let monitor = ModifierKeyMonitor(modifier: modifier) { [weak self] event in
                guard let self else { return }
                switch (self.appState.activationMode, event) {
                case (.holdToTalk, .keyDown): DispatchQueue.main.async { self.beginRecording() }
                case (.holdToTalk, .keyUp):   DispatchQueue.main.async { self.finishRecording() }
                case (.toggle,     .keyDown): DispatchQueue.main.async { self.toggleRecording() }
                case (.toggle,     .keyUp):   break
                }
            }
            monitor.start()
            modifierMonitor = monitor
        }
    }

    private func toggleRecording() {
        if isRecording {
            finishRecording()
        } else {
            beginRecording()
        }
    }

    @objc private func openPreferences() {
        preferencesController.show(appState: appState)
    }

    @objc private func openHistory() {
        historyController.show()
    }

    private func triggerUpdateCheck() {
        if let update = updateChecker.availableUpdate {
            promptToInstall(update)
        } else {
            updateMenuView?.setState(.checking)
            updateChecker.checkForUpdates()
        }
    }

    private func promptToInstall(_ update: AvailableUpdate, isRollback: Bool = false) {
        let alert = NSAlert()
        if isRollback {
            alert.messageText = "Install vx \(update.version)?"
            alert.informativeText = "This will replace the current version (\(updateChecker.currentVersion)) and restart the app."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Install and Relaunch")
        } else {
            alert.messageText = "vx \(update.version) is available"
            alert.informativeText = "Would you like to update now? The app will restart automatically."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Update Now")
        }
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else {
            if !isRollback { updateMenuView?.setState(.idle) }
            return
        }
        if !isRollback { updateMenuView?.setState(.result("Downloading… 0%")) }
        updateChecker.installUpdate(update)
    }

    @objc private func relaunchApp() {
        let bundlePath = Bundle.main.bundleURL.path
        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = ["-c", "sleep 0.5 && open '\(bundlePath)'"]
        task.launch()
        NSApp.terminate(nil)
    }

    @objc private func copyLastTranscription() {
        guard let text = TranscriptionHistory.shared.entries.first?.text else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        vxLog("[coordinator] Copied last transcription to clipboard")
        hud.showHint("Copied to clipboard", after: 0.0, duration: 1.5)
    }

    @objc private func toggleAutoDetectMode() {
        appState.autoDetectMode.toggle()
    }

    @objc private func setDictationMode(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? DictationMode else { return }
        // Selecting a mode manually turns off auto-detect.
        appState.autoDetectMode = false
        appState.currentMode = mode
    }

    @objc private func setCodeProfile(_ sender: NSMenuItem) {
        guard let profile = sender.representedObject as? CodeProfile else { return }
        appState.currentCodeProfile = profile
    }

    @objc private func toggleDebugMode() {
        appState.isDebugMode.toggle()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func beginRecording() {
        guard !isRecording else { return }

        // Capture the frontmost app before the HUD shows. The HUD is a
        // non-activating panel so focus stays on the target app, but we store
        // the bundle ID now so finishRecording() can use it without a race.
        let targetApp = NSWorkspace.shared.frontmostApplication
        recordingTargetBundleID = targetApp?.bundleIdentifier
        recordingTargetAppName = targetApp?.localizedName
        recordingTargetPID = targetApp?.processIdentifier ?? 0

        let backendURL = appState.backendURL
        let modelURL = appState.modelURL

        do {
            try FileValidator.validate(backendURL: backendURL, modelURL: modelURL)
        } catch {
            logFailure(error.localizedDescription, dismissAfter: 2.0)
            return
        }

        // AudioObjectSetPropertyData on a Bluetooth output device races with AVAudioEngine's
        // installTap and causes an uncatchable NSException. Duck non-BT devices before engine
        // setup (so the fade starts immediately on key press); for BT, defer until after
        // engine.start() when the tap is already installed and the race window is closed.
        let duckEnabled = appState.duckAudioWhileRecording
        let bluetoothOutput = AudioCapture.isBluetoothDefaultOutput()
        if duckEnabled && !bluetoothOutput {
            let t0 = Date()
            volumeController.duck(to: Float(appState.duckVolume))
            vxLog("[coordinator/beginRecording] duck: \(String(format: "%.1f", Date().timeIntervalSince(t0) * 1000))ms")
        }

        // Launch the streaming vx-rs session before starting the engine so audio arrives
        // from the very first tap callback. There is no file-mode fallback: if the session
        // can't start, the backend is genuinely broken, so surface it and abort.
        let stream: TranscriptionSession
        do {
            stream = try transcriber.begin(model: modelURL)
        } catch {
            if duckEnabled && !bluetoothOutput { volumeController.restore() }
            vxLog("[coordinator/beginRecording] Streaming launch failed: \(error.localizedDescription)")
            logFailure(error.localizedDescription, dismissAfter: 2.0)
            return
        }

        // Start the audio engine, retrying a few times. When a Bluetooth output device
        // (e.g. WH-1000XM3) flips between A2DP and HFP/SCO as input capture begins,
        // engine.start() intermittently fails with kAudioUnitErr_FormatNotSupported (-10868).
        // A short settle delay plus a fresh engine usually succeeds, and each failed attempt
        // tears itself down cleanly (AudioCapture.startRecording), so retries don't leak or
        // wedge CoreAudio.
        let engineStartTime = Date()
        let maxAttempts = 3
        var startError: Error?
        var started = false
        for attempt in 1...maxAttempts {
            do {
                currentRecordingURL = try audioCapture.startRecording(
                    deviceUID: appState.selectedInputDeviceUID,
                    session: stream
                )
                started = true
                if attempt > 1 { vxLog("[coordinator/beginRecording] start succeeded on attempt \(attempt)/\(maxAttempts)") }
                break
            } catch {
                startError = error
                vxLog("[coordinator/beginRecording] start attempt \(attempt)/\(maxAttempts) failed: \(error.localizedDescription)")
                if attempt < maxAttempts { Thread.sleep(forTimeInterval: 0.25) }
            }
        }

        if started {
            // Engine is running and tap is installed — safe to duck BT devices now.
            if duckEnabled && bluetoothOutput {
                let t0 = Date()
                volumeController.duck(to: Float(appState.duckVolume))
                vxLog("[coordinator/beginRecording] duck (BT, post-engine): \(String(format: "%.1f", Date().timeIntervalSince(t0) * 1000))ms")
            }
            activeStream = stream
            vxLog("[coordinator/beginRecording] startRecording: \(String(format: "%.1f", Date().timeIntervalSince(engineStartTime) * 1000))ms")
            isRecording = true
            if appState.soundEffectsEnabled { soundPlayer.play("start.mp3") }
            updateStatusItemAppearance(isActive: true)
            installEscapeMonitorIfNeeded()
            hud.showListening(
                onCancel: { [weak self] in self?.cancelRecording() },
                onStop: { [weak self] in self?.finishRecording() }
            )
        } else {
            // Couldn't start after retries — kill the streaming process and undo any duck.
            stream.cancel()
            if duckEnabled { volumeController.restore() }
            vxLog("[coordinator/beginRecording] giving up after \(maxAttempts) attempts: \(startError?.localizedDescription ?? "unknown error")")
            logFailure("Couldn’t start the microphone. If you’re on Bluetooth headphones it may be switching audio modes — try again in a moment.", dismissAfter: 3.0)
        }

        vxLog("[coordinator/beginRecording] Backend: \(backendURL.path)")
        vxLog("[coordinator/beginRecording] Model: \(modelURL.path)")
    }

    private func finishRecording() {
        guard isRecording else { return }
        isRecording = false
        removeEscapeMonitor()
        updateStatusItemAppearance(isActive: false)

        // Play before stopping the engine — on Bluetooth devices (AirPods) the device
        // transitions from SCO/HFP back to A2DP after engine.stop(), and during that
        // handoff the device reports as muted, silencing any sound played after stop.
        if appState.soundEffectsEnabled { soundPlayer.play("transcribe.mp3") }

        // Stop engine first — engine.stop() blocks the main thread while audio buffers
        // drain. Starting the restore fade after teardown means the timer fires cleanly
        // without that blocking window interfering.
        let stopStart = Date()
        let recordingURL = audioCapture.stopRecording() ?? currentRecordingURL
        vxLog("[coordinator/finishRecording] stopRecording: \(String(format: "%.1f", Date().timeIntervalSince(stopStart) * 1000))ms")
        currentRecordingURL = nil

        if appState.duckAudioWhileRecording {
            let t0 = Date()
            volumeController.restore()
            vxLog("[coordinator/finishRecording] restore: \(String(format: "%.1f", Date().timeIntervalSince(t0) * 1000))ms")
        }

        guard let recordingURL else {
            logFailure("No audio captured.", dismissAfter: 2.0)
            return
        }

        hud.flashStatus(.processing, duration: 1.5, autoHide: false)

        transcriptionTask?.cancel()
        let transcribeStart = Date()
        let capturedStream = activeStream
        activeStream = nil
        // Install escape monitor for the processing phase so the user can bail
        // while transcription is running (works for both hold-to-talk and toggle).
        installProcessingEscapeMonitor()
        transcriptionTask = Task { [weak self] in
            guard let self else { return }
            do {
                guard let stream = capturedStream else {
                    // Recording only starts once a live session exists, so this is unreachable
                    // in practice; treat a lost session as a surfaced failure rather than crash.
                    try? FileManager.default.removeItem(at: recordingURL)
                    await MainActor.run {
                        self.removeEscapeMonitor()
                        self.logFailure("Transcription session was lost.", dismissAfter: 2.0)
                    }
                    return
                }
                // Closing stdin triggers final inference in vx-rs.
                let text = try await stream.finish()
                vxLog("[coordinator/finishRecording] stream finish: \(String(format: "%.1f", Date().timeIntervalSince(transcribeStart) * 1000))ms")
                // No WAV file to clean up in streaming mode.
                try? FileManager.default.removeItem(at: recordingURL)

                guard !Task.isCancelled else { return }

                // Resolve the dictation context for this recording session. When auto-detect
                // is enabled, the frontmost app's bundle ID (captured at beginRecording time)
                // is mapped to a mode/profile; a no-match falls back to the manual selection.
                let resolved = self.contextResolver.resolve(
                    autoDetect: self.appState.autoDetectMode,
                    bundleID: self.recordingTargetBundleID,
                    pid: self.recordingTargetPID,
                    manualMode: self.appState.currentMode,
                    manualProfile: self.appState.currentCodeProfile
                )
                let detectedContext = resolved.detectedContext
                let ruleContext = resolved.ruleContext
                if let ctx = detectedContext {
                    vxLog("[coordinator/finishRecording] Auto-detected context: \(ctx.displayName) for \(self.recordingTargetBundleID ?? "unknown")")
                }
                // Assemble the optional post-processing config from AppState. The per-context
                // prompt comes first so the global custom prompt can override it on conflict.
                let postProcessing: PostProcessingConfig? = {
                    guard self.appState.isPostProcessingEnabled,
                          !self.appState.postProcessingAPIKey.isEmpty else { return nil }
                    let perContextPrompt = ContextPromptStore.load(contextID: ruleContext.mode.promptID)
                    let combinedCustomPrompt = [perContextPrompt, self.appState.postProcessingCustomPrompt]
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                        .joined(separator: "\n\n")
                    return PostProcessingConfig(
                        provider: self.appState.postProcessingProvider,
                        model: self.appState.postProcessingModel,
                        apiKey: self.appState.postProcessingAPIKey,
                        customBaseURL: self.appState.postProcessingCustomBaseURL,
                        customPrompt: combinedCustomPrompt,
                        customDictionary: self.appState.customDictionary,
                        contextHint: ruleContext.mode.postProcessingHint,
                        smoothDisfluencies: self.appState.smoothDisfluencies
                    )
                }()

                // Sanitize → rules → (optional) post-process, all behind one interface.
                // .noSpeech means nothing real survived sanitization or post-processing.
                let session = DictationSession(
                    mode: ruleContext.mode,
                    codeProfile: ruleContext.codeProfile,
                    postProcessing: postProcessing
                )
                guard case .text(let finalText, let pipelineResult) = await self.dictationProcessor.process(text, session: session) else {
                    vxLog("[coordinator/finishRecording] No speech after processing, raw: \(text.debugDescription)")
                    await MainActor.run {
                        self.removeEscapeMonitor()
                        self.logFailure("No speech detected.", dismissAfter: 2.0)
                    }
                    return
                }
                guard !Task.isCancelled else { return }
                let profileSuffix = ruleContext.mode == .code ? "/\(ruleContext.codeProfile.rawValue)" : ""
                vxLog("[coordinator/finishRecording] Mode: \(ruleContext.mode.rawValue)\(profileSuffix), rules loaded: \(pipelineResult.ruleCount), transformed: \(pipelineResult.didTransform)")
                await MainActor.run {
                    self.contextDebugController.model.updateLastRecording(
                        bundleID: self.recordingTargetBundleID,
                        appName: self.recordingTargetAppName,
                        context: detectedContext,
                        mode: ruleContext.mode,
                        ruleCount: pipelineResult.ruleCount
                    )
                }

                await MainActor.run {
                    self.removeEscapeMonitor()
                    do {
                        try TextInserter.insert(finalText)
                        TranscriptionHistory.shared.append(finalText)
                        self.hud.completeProcessing()
                    } catch {
                        self.logFailure(error.localizedDescription, dismissAfter: 2.5)
                    }
                }
            } catch {
                try? FileManager.default.removeItem(at: recordingURL)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.removeEscapeMonitor()
                    self.logFailure(error.localizedDescription, dismissAfter: 2.5)
                }
            }
        }
    }

    private func cancelRecording() {
        guard isRecording else { return }
        isRecording = false
        removeEscapeMonitor()
        updateStatusItemAppearance(isActive: false)
        activeStream?.cancel()
        activeStream = nil
        if let url = audioCapture.stopRecording() ?? currentRecordingURL {
            try? FileManager.default.removeItem(at: url)
        }
        currentRecordingURL = nil
        if appState.duckAudioWhileRecording {
            volumeController.restore()
        }
        hud.flashStatus(.cancelled, duration: 1.0)
    }

    private func updateStatusItemAppearance(isActive: Bool) {
        guard let button = statusItem?.button else { return }
        button.alphaValue = isActive ? 1.0 : 0.55
    }

    private func promptForAccessibilityPermission() {
        guard !accessibilityAlertShown else { return }
        accessibilityAlertShown = true
        hud.showHint("Enable Accessibility in Settings to use fn hotkey", after: 0.0, duration: 4.0)

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Enable Accessibility Permissions"
        alert.informativeText = "vx needs Accessibility permission to capture the fn key for push-to-talk. Grant permission in System Settings → Privacy & Security → Accessibility."
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Later")

        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func installEscapeMonitorIfNeeded() {
        guard appState.activationMode == .toggle, escapeGlobalMonitor == nil, escapeLocalMonitor == nil else { return }

        let handler: (NSEvent) -> NSEvent? = { [weak self] event in
            guard event.keyCode == CGKeyCode(kVK_Escape) else { return event }
            DispatchQueue.main.async {
                guard let self, self.isRecording else { return }
                self.cancelRecording()
            }
            return nil
        }

        escapeLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: handler)
        escapeGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == CGKeyCode(kVK_Escape) else { return }
            DispatchQueue.main.async {
                guard let self, self.isRecording else { return }
                self.cancelRecording()
            }
        }
    }

    private func removeEscapeMonitor() {
        if let monitor = escapeLocalMonitor {
            NSEvent.removeMonitor(monitor)
            escapeLocalMonitor = nil
        }
        if let monitor = escapeGlobalMonitor {
            NSEvent.removeMonitor(monitor)
            escapeGlobalMonitor = nil
        }
    }

    /// Installs an escape key monitor for the processing phase (works regardless of activation mode).
    /// Call this after recording stops and transcriptionTask is about to start.
    private func installProcessingEscapeMonitor() {
        guard escapeGlobalMonitor == nil, escapeLocalMonitor == nil else { return }

        let handler: (NSEvent) -> NSEvent? = { [weak self] event in
            guard event.keyCode == CGKeyCode(kVK_Escape) else { return event }
            DispatchQueue.main.async {
                guard let self, self.transcriptionTask != nil else { return }
                self.cancelTranscription()
            }
            return nil
        }

        escapeLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: handler)
        escapeGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == CGKeyCode(kVK_Escape) else { return }
            DispatchQueue.main.async {
                guard let self, self.transcriptionTask != nil else { return }
                self.cancelTranscription()
            }
        }
    }

    /// Cancels an in-progress transcription task (called by the processing-phase escape monitor).
    private func cancelTranscription() {
        vxLog("[coordinator/cancelTranscription] Transcription cancelled by user")
        transcriptionTask?.cancel()
        transcriptionTask = nil
        removeEscapeMonitor()
        hud.flashStatus(.cancelled, duration: 1.0)
    }

    private func requestMicrophonePermission() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        guard status == .notDetermined else {
            vxLog("[coordinator/permission] Already determined: \(status.rawValue)")
            return
        }
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            vxLog("[coordinator/permission] Granted: \(granted)")
        }
    }

    private func preflightResources() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let backendURL = self.appState.backendURL
            let modelURL = self.appState.modelURL
            do {
                try FileValidator.validate(backendURL: backendURL, modelURL: modelURL)
            } catch {
                DispatchQueue.main.async {
                    self.logFailure(error.localizedDescription, dismissAfter: 4.0)
                }
            }
        }
    }
}

private enum FileValidator {
    static func validate(backendURL: URL, modelURL: URL) throws {
        let fm = FileManager.default
        let backendPath = backendURL.path
        let modelPath = modelURL.path

        if !fm.fileExists(atPath: backendPath) || !fm.isExecutableFile(atPath: backendPath) {
            throw TranscriberError.missingBinary
        }

        if !fm.fileExists(atPath: modelPath) {
            throw TranscriberError.missingModel
        }
    }
}

private final class PreferencesController {
    private weak var window: NSWindow?

    func show(appState: AppState) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(rootView: PreferencesView(appState: appState))
        hosting.sizingOptions = []
        let window = NSWindow(contentViewController: hosting)
        window.title = "vx Preferences"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.minSize = NSSize(width: 480, height: 460)
        window.setContentSize(NSSize(width: 480, height: 600))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }
}

extension Notification.Name {
    static let vxPauseShortcut = Notification.Name("voice.vx.pauseShortcut")
    static let vxResumeShortcut = Notification.Name("voice.vx.resumeShortcut")
    static let vxShowDebugLog = Notification.Name("voice.vx.showDebugLog")
    static let vxInstallVersion = Notification.Name("voice.vx.installVersion")
}

extension AppCoordinator: NSMenuDelegate {
    public func menuWillOpen(_ menu: NSMenu) {
        rebuildHistorySubmenu()
        updateDynamicMenuLabels()
    }

    private func updateDynamicMenuLabels() {
        // Detection status item: show frontmost app and detected context.
        detectionStatusMenuItem?.isHidden = !appState.autoDetectMode
        if appState.autoDetectMode {
            let appName = contextDebugController.model.frontmostAppName
            let detectedCtxForStatus = contextDebugController.model.detectedContext
            if case .general = detectedCtxForStatus {
                detectionStatusMenuItem?.title = "\(appName) — no match"
            } else {
                detectionStatusMenuItem?.title = "\(appName) — \(detectedCtxForStatus.displayName)"
            }
        }

        // Auto-detect item: show the currently detected mode in parens.
        let detectedCtx = contextDebugController.model.detectedContext
        if case .general = detectedCtx {
            autoDetectModeMenuItem?.title = "Auto-detect (no match)"
        } else {
            autoDetectModeMenuItem?.title = "Auto-detect (\(detectedCtx.dictationMode.displayName))"
        }

        // Mode parent: show the effective mode — auto-detected or manually selected.
        let effectiveMode: DictationMode
        if appState.autoDetectMode, case .general = detectedCtx {
            effectiveMode = appState.currentMode
        } else if appState.autoDetectMode {
            effectiveMode = detectedCtx.dictationMode
        } else {
            effectiveMode = appState.currentMode
        }
        if effectiveMode == .code {
            let profile = appState.currentCodeProfile
            modeParentMenuItem?.title = "Mode (\(effectiveMode.displayName) / \(profile.displayName))"
        } else {
            modeParentMenuItem?.title = "Mode (\(effectiveMode.displayName))"
        }

        // Code Profile parent: always show the current profile.
        profileMenuItem?.title = "Code Profile (\(appState.currentCodeProfile.displayName))"
    }

    private func rebuildHistorySubmenu() {
        guard let submenu = historyMenuItem?.submenu else { return }
        submenu.removeAllItems()

        let entries = Array(TranscriptionHistory.shared.entries.prefix(5))
        if entries.isEmpty {
            let empty = NSMenuItem(title: "No history yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        } else {
            for entry in entries {
                let maxLen = 40
                let preview = entry.text.count > maxLen ? String(entry.text.prefix(maxLen)) + "…" : entry.text
                let item = NSMenuItem(title: preview, action: #selector(copyHistoryEntry(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = entry.text
                submenu.addItem(item)
            }
        }

        submenu.addItem(NSMenuItem.separator())
        let showAll = NSMenuItem(title: "Show All", action: #selector(openHistory), keyEquivalent: "")
        showAll.target = self
        submenu.addItem(showAll)
    }

    @objc private func copyHistoryEntry(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        vxLog("[coordinator] Copied history entry to clipboard")
        hud.showHint("Copied to clipboard", after: 0.0, duration: 1.5)
    }
}

// MARK: - UpdateMenuItemView

/// Custom NSMenuItem view for "Check for Updates…". Keeps the status bar menu open while
/// a check is in progress so the user gets inline feedback without a separate window.
final class UpdateMenuItemView: NSView {
    enum State {
        case idle
        case checking
        case result(String)
    }

    var onTrigger: (() -> Void)?

    private let label: NSTextField
    private let highlight: NSVisualEffectView
    private var spinnerTimer: Timer?
    private var spinnerPhase = 0
    private var state: State = .idle

    private static let spinnerFrames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

    override init(frame: NSRect) {
        label = NSTextField(labelWithString: "Check for Updates…")
        label.font = NSFont.menuFont(ofSize: 0)
        label.textColor = .labelColor
        label.drawsBackground = false

        highlight = NSVisualEffectView()
        highlight.material = .selection
        highlight.state = .active
        highlight.isHidden = true
        highlight.autoresizingMask = [.width, .height]

        super.init(frame: frame)
        autoresizingMask = .width
        addSubview(highlight)
        addSubview(label)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.inVisibleRect, .activeAlways, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        ))
    }

    required init?(coder: NSCoder) { fatalError() }

    func setState(_ newState: State) {
        state = newState
        spinnerTimer?.invalidate()
        spinnerTimer = nil
        switch newState {
        case .idle:
            label.stringValue = "Check for Updates…"
        case .checking:
            spinnerPhase = 0
            label.stringValue = "\(Self.spinnerFrames[0])  Checking…"
            let timer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.spinnerPhase = (self.spinnerPhase + 1) % Self.spinnerFrames.count
                self.label.stringValue = "\(Self.spinnerFrames[self.spinnerPhase])  Checking…"
            }
            RunLoop.main.add(timer, forMode: .common)
            spinnerTimer = timer
        case .result(let message):
            label.stringValue = message
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        highlight.frame = bounds
        let padding: CGFloat = 14
        label.sizeToFit()
        label.frame = NSRect(
            x: padding,
            y: (bounds.height - label.frame.height) / 2,
            width: bounds.width - padding * 2,
            height: label.frame.height
        )
    }

    override func mouseEntered(with event: NSEvent) {
        highlight.isHidden = false
        label.textColor = .selectedMenuItemTextColor
    }

    override func mouseExited(with event: NSEvent) {
        highlight.isHidden = true
        label.textColor = .labelColor
    }

    override func mouseUp(with event: NSEvent) {
        // Only trigger when idle — ignore clicks during an in-progress check or result display.
        guard case .idle = state else { return }
        onTrigger?()
    }
}
