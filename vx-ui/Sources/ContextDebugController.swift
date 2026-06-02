import AppKit
import Combine
import SwiftUI

// MARK: - ContextDebugModel

/// Observable model for the Context Inspector window.
///
/// Monitors the frontmost app continuously (via NSWorkspace notifications) and
/// stores a snapshot of the most recent recording session. Updated by
/// AppCoordinator after each recording.
@MainActor
final class ContextDebugModel: ObservableObject {
    // Live: updated whenever the frontmost app changes
    @Published var frontmostBundleID: String = ""
    @Published var frontmostAppName: String = ""
    @Published var frontmostWindowTitle: String? = nil
    @Published var detectedContext: AppContext = .general
    @Published var isCustomMapping: Bool = false
    @Published var isTitleInferred: Bool = false

    // Last recording snapshot: set by AppCoordinator after finishRecording()
    @Published var lastRecordingBundleID: String? = nil
    @Published var lastRecordingAppName: String? = nil
    @Published var lastRecordingContext: AppContext? = nil
    @Published var lastRecordingMode: DictationMode? = nil
    @Published var lastRuleCount: Int? = nil

    private var observation: NSObjectProtocol?

    init() {
        observation = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication else { return }
            let bundleID = app.bundleIdentifier ?? "unknown"
            let name = app.localizedName ?? "Unknown"
            let pid = app.processIdentifier
            Task { @MainActor [weak self] in self?.updateFrom(bundleID: bundleID, name: name, pid: pid) }
        }
        if let app = NSWorkspace.shared.frontmostApplication {
            updateFrom(bundleID: app.bundleIdentifier ?? "unknown",
                       name: app.localizedName ?? "Unknown",
                       pid: app.processIdentifier)
        }
    }

    deinit {
        if let observation {
            NSWorkspace.shared.notificationCenter.removeObserver(observation)
        }
    }

    func updateLastRecording(
        bundleID: String?,
        appName: String?,
        context: AppContext?,
        mode: DictationMode,
        ruleCount: Int
    ) {
        lastRecordingBundleID = bundleID
        lastRecordingAppName = appName
        lastRecordingContext = context
        lastRecordingMode = mode
        lastRuleCount = ruleCount
    }

    private func updateFrom(bundleID: String, name: String, pid: pid_t) {
        frontmostBundleID = bundleID
        frontmostAppName = name
        let customs = AppContextDetector.customMappings()
        isCustomMapping = customs[bundleID] != nil
        let isBrowser = AppContextDetector.knownBrowserIDs.contains(bundleID)
        frontmostWindowTitle = isBrowser ? AppContextDetector.windowTitle(pid: pid) : nil
        let ctxBeforeTitle = isCustomMapping ? customs[bundleID]! : AppContextDetector.detect(bundleID: bundleID, pid: 0)
        detectedContext = AppContextDetector.detect(bundleID: bundleID, pid: pid)
        // Inferred from title when: browser, no custom mapping, built-in returns .general, title matched
        if case .general = ctxBeforeTitle, case .general = (customs[bundleID] ?? .general) {
            if case .general = detectedContext {
                isTitleInferred = false
            } else {
                isTitleInferred = true
            }
        } else {
            isTitleInferred = false
        }
    }
}

// MARK: - ContextDebugView

struct ContextDebugView: View {
    @ObservedObject var model: ContextDebugModel
    @ObservedObject var appState: AppState

    private var effectiveMode: DictationMode {
        guard appState.autoDetectMode else { return appState.currentMode }
        if case .general = model.detectedContext { return appState.currentMode }
        return model.detectedContext.dictationMode
    }

    private var effectiveProfile: CodeProfile {
        guard appState.autoDetectMode else { return appState.currentCodeProfile }
        return model.detectedContext.codeProfile
    }

    private var rulePaths: [String] {
        RuleStore.shared.resolutionPaths(for: RuleContext(mode: effectiveMode, codeProfile: effectiveProfile))
    }

    private var isBrowser: Bool {
        let browsers = ["com.google.Chrome", "com.apple.Safari", "org.mozilla.firefox",
                        "com.microsoft.edgemac", "com.brave.Browser", "com.operasoftware.Opera"]
        return browsers.contains(model.frontmostBundleID)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {

                // MARK: Live section
                sectionHeader("Live")

                infoGrid {
                    row("App", primary: model.frontmostAppName, secondary: model.frontmostBundleID)
                    row("Mapping",
                        primary: model.isCustomMapping ? "custom override" : contextLabel(model.detectedContext),
                        badge: model.isCustomMapping ? "custom" : nil,
                        secondaryColor: contextColor(model.detectedContext))
                    row("Auto-detect", primary: appState.autoDetectMode ? "ON" : "off")
                    row("Mode", primary: effectiveMode.displayName,
                        secondary: appState.autoDetectMode
                            ? (effectiveMode == model.detectedContext.dictationMode ? "auto" : "manual fallback")
                            : "manual")
                }

                if !rulePaths.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Rule files")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                        ForEach(rulePaths, id: \.self) { path in
                            Text(path)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.primary)
                        }
                    }
                }

                if isBrowser {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.secondary)
                        Text("Browsers are not mapped by default — vx cannot read the URL. Add an entry to ~/.vx/app-contexts.yaml to override, or select a mode manually.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(8)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }

                Divider()

                // MARK: Last recording section
                sectionHeader("Last Recording")

                if model.lastRecordingBundleID != nil || model.lastRecordingMode != nil {
                    infoGrid {
                        if let name = model.lastRecordingAppName, let bid = model.lastRecordingBundleID {
                            row("App", primary: name, secondary: bid)
                        }
                        if let ctx = model.lastRecordingContext {
                            row("Context", primary: contextLabel(ctx),
                                secondaryColor: contextColor(ctx))
                        } else {
                            row("Context", primary: "none (auto-detect off)")
                        }
                        if let mode = model.lastRecordingMode {
                            row("Mode", primary: mode.displayName)
                        }
                        if let count = model.lastRuleCount {
                            row("Rules", primary: "\(count) loaded")
                        }
                    }
                } else {
                    Text("No recording yet this session.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(16)
        }
        .frame(minWidth: 320, minHeight: 300)
    }

    // MARK: Helpers

    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .padding(.bottom, -8)
    }

    @ViewBuilder
    private func infoGrid<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            content()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func row(
        _ label: String,
        primary: String,
        secondary: String? = nil,
        badge: String? = nil,
        secondaryColor: Color = .secondary
    ) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(primary)
                        .font(.system(size: 11))
                        .foregroundStyle(.primary)
                    if let badge {
                        Text(badge)
                            .font(.system(size: 9, weight: .medium))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.15))
                            .foregroundStyle(Color.accentColor)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                }
                if let secondary {
                    Text(secondary)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(secondaryColor)
                }
            }
        }
    }

    private func contextLabel(_ ctx: AppContext) -> String {
        switch ctx {
        case .general: return "General (no match)"
        default:       return ctx.displayName
        }
    }

    private func contextColor(_ ctx: AppContext) -> Color {
        switch ctx {
        case .general: return .secondary
        default:       return .primary
        }
    }
}

// MARK: - ContextDebugController

@MainActor
final class ContextDebugController {
    let model = ContextDebugModel()
    private weak var window: NSWindow?

    func show(appState: AppState) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = ContextDebugView(model: model, appState: appState)
        let hosting = NSHostingController(rootView: view)
        let win = NSWindow(contentViewController: hosting)
        win.title = "vx Context Inspector"
        win.styleMask = [.titled, .closable, .miniaturizable]
        win.setContentSize(NSSize(width: 340, height: 480))
        win.setFrameAutosaveName("ContextInspectorWindow")
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = win
    }

    func close() {
        window?.close()
        window = nil
    }
}
