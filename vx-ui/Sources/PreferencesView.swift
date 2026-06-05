import SwiftUI
import AppKit
import Carbon
import AVFoundation
import ApplicationServices
import IOKit.hid

private struct MappingEntry: Identifiable {
    var id = UUID()
    var bundleID: String
    var contextValue: String
}

private struct GithubRelease: Decodable, Identifiable {
    let tagName: String

    var id: String { tagName }

    /// Constructs the expected vx.zip asset URL from the tag name.
    var downloadURL: URL {
        DistributionConfig.releaseDownloadURL(tag: tagName)
    }

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
    }
}

struct PreferencesView: View {
    @ObservedObject var appState: AppState
    @State private var selectedTab = "config"
    @State private var microphoneState: PermissionState = .unknown
    @State private var accessibilityState: PermissionState = .unknown
    @State private var automationState: PermissionState = .unknown
    @State private var keyboardMonitorState: PermissionState = .unknown
    @State private var availableAudioDevices: [AudioInputDevice] = []
    @State private var showAPIKey = false
    @State private var newDictionaryWord = ""
    @State private var selectedPromptContext: String = "general"
    @State private var promptEditorContent: String = ""
    @State private var loadedPromptContent: String = ""
    @State private var promptSaveStatus: RulesReloadStatus? = nil
    @State private var tryRulesInput: String = ""
    @State private var tryRulesResult: TransformationResult? = nil
    @State private var rulesReloadStatus: RulesReloadStatus? = nil
    @State private var selectedRuleFile: String? = nil
    @State private var ruleFileContent: String = ""
    @State private var loadedRuleFileContent: String = ""
    @State private var ruleSaveStatus: RulesReloadStatus? = nil
    @State private var mappingEntries: [MappingEntry] = []
    @State private var mappingNewBundleID: String = ""
    @State private var mappingNewContext: String = "general"
    @State private var mappingSaveStatus: RulesReloadStatus? = nil
    @ObservedObject private var modelManager = ModelManager.shared
    @State private var developerTapCount: Int = 0
    @State private var showDeveloperTab: Bool = false
    @State private var availableReleases: [GithubRelease] = []
    @State private var isLoadingReleases = false
    @State private var releaseFetchError: String? = nil

    private let contextOptions: [(value: String, label: String)] = [
        ("general",            "General (no override)"),
        ("email",              "Email"),
        ("chat",               "Chat"),
        ("document",           "Document"),
        ("terminal",           "Terminal"),
        ("code",               "Code"),
        ("code/swift",         "Code / Swift"),
        ("code/python",        "Code / Python"),
        ("code/typescript",    "Code / TypeScript"),
        ("code/javascript",    "Code / JavaScript"),
        ("code/go",            "Code / Go"),
        ("code/rust",          "Code / Rust"),
    ]

    private var tabs: [(id: String, icon: String, label: String)] {
        var result: [(id: String, icon: String, label: String)] = [
            ("config",      "gear",            "Configuration"),
            ("rules",       "wand.and.rays",   "Rules"),
            ("ai",          "sparkles",        "AI"),
            ("sound",       "speaker.wave.2",  "Sound"),
            ("permissions", "lock.shield",     "Permissions"),
        ]
        if showDeveloperTab || appState.isDebugMode {
            result.append(("developer", "hammer", "Developer"))
        }
        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(tabs, id: \.id) { tab in
                    Button {
                        selectedTab = tab.id
                    } label: {
                        VStack(spacing: 3) {
                            Image(systemName: tab.icon)
                                .font(.system(size: 18))
                            Text(tab.label)
                                .font(.system(size: 11))
                        }
                        .foregroundStyle(selectedTab == tab.id ? Color.accentColor : Color.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            Group {
                switch selectedTab {
                case "rules":       rulesTab
                case "ai":          aiTab
                case "sound":       soundTab
                case "permissions": permissionsTab
                case "developer":   developerTab
                default:            configTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .transaction { $0.animation = nil }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            refreshPermissionStates()
            availableAudioDevices = AudioCapture.availableInputDevices()
            loadPromptFile(contextID: selectedPromptContext)
            loadMappings()
        }
    }

    private var inputDeviceSelection: Binding<String?> {
        Binding(
            get: {
                guard let uid = appState.selectedInputDeviceUID,
                      availableAudioDevices.contains(where: { $0.uid == uid }) else {
                    return nil
                }
                return uid
            },
            set: { appState.selectedInputDeviceUID = $0 }
        )
    }

    private var configTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Input Device")
                        .font(.headline)
                    HStack(spacing: 8) {
                        Picker("", selection: inputDeviceSelection) {
                            Text("System Default").tag(String?.none)
                            ForEach(availableAudioDevices) { device in
                                Text(device.name).tag(String?.some(device.uid))
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .leading)

                        Button {
                            availableAudioDevices = AudioCapture.availableInputDevices()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless)
                        .help("Refresh device list")
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Activation Mode")
                        .font(.headline)
                    Picker("", selection: $appState.activationMode) {
                        ForEach(ActivationMode.allCases) { mode in
                            Text(mode.description).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }
                .alert("Shortcut reset", isPresented: Binding(
                    get: { appState.shortcutNotice != nil },
                    set: { if !$0 { appState.shortcutNotice = nil } }
                ), presenting: appState.shortcutNotice) { _ in
                    Button("OK", role: .cancel) { appState.shortcutNotice = nil }
                } message: { notice in
                    Text(notice)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Shortcut")
                        .font(.headline)
                    HStack {
                        Text(appState.shortcut.displayName)
                            .frame(width: 140, alignment: .leading)
                        Button("Change…") {
                            captureShortcut()
                        }
                    }
                    Text(appState.activationMode == .holdToTalk ? "Hold the keys to dictate." : "Press once to start, press again to stop.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(appState.activationMode == .holdToTalk
                         ? "Use a single modifier or a key combo (e.g. ⌘Z). Right Option stays out of the way of typing."
                         : "Use a single modifier, a double-tap of one, or a key combo. Right Option stays out of the way of typing.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Copy Last Shortcut")
                        .font(.headline)
                    HStack {
                        Text(appState.copyLastShortcut.displayName)
                            .frame(width: 140, alignment: .leading)
                        Button("Change…") {
                            captureShortcutForCopy()
                        }
                    }
                    Text("Copies your most recent transcription to the clipboard.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Transcription Model")
                        .font(.headline)
                    VStack(spacing: 0) {
                        ForEach(Array(WhisperModel.catalog.enumerated()), id: \.element.id) { index, model in
                            ModelRow(
                                model: model,
                                state: modelManager.states[model.id] ?? .notInstalled,
                                isActive: appState.selectedModelName == model.id,
                                isBundledOnly: modelManager.isBundledOnly(model),
                                onSelect: { appState.selectedModelName = model.id },
                                onDownload: { modelManager.download(model) },
                                onCancel: { modelManager.cancelDownload(for: model) },
                                onRemove: { modelManager.remove(model, activeModelId: appState.selectedModelName) }
                            )
                            if index < WhisperModel.catalog.count - 1 {
                                Divider().padding(.leading, 32)
                            }
                        }
                    }
                    .padding(12)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
                Text("vx \(version)")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.quaternary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .onTapGesture {
                        developerTapCount += 1
                        if developerTapCount >= 5 {
                            showDeveloperTab = true
                        }
                    }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
    }

    private var rulesTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {

                // MARK: Mode picker
                VStack(alignment: .leading, spacing: 8) {
                    Text("Dictation Mode")
                        .font(.headline)
                    Picker("", selection: $appState.currentMode) {
                        ForEach(DictationMode.allCases) { mode in
                            Label(mode.displayName, systemImage: mode.systemSymbol).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: appState.currentMode) { _ in
                        tryRulesResult = nil
                        rulesReloadStatus = nil
                    }
                    Text("Global rules apply in every mode. Code mode also loads a language-specific profile.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // MARK: Code profile picker (only shown in code mode)
                if appState.currentMode == .code {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Code Profile")
                            .font(.headline)
                        Picker("", selection: $appState.currentCodeProfile) {
                            ForEach(CodeProfile.allCases) { profile in
                                Text(profile.displayName).tag(profile)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .onChange(of: appState.currentCodeProfile) { _ in
                            tryRulesResult = nil
                            rulesReloadStatus = nil
                        }
                        Text("Loads global.yaml + code/global.yaml + code/\(appState.currentCodeProfile.rawValue).yaml")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                // MARK: Edit Rules
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .center) {
                        Text("Edit Rules")
                            .font(.headline)
                        Spacer()
                        Button("Open Folder") {
                            RuleStore.shared.openRulesDirectory()
                        }
                        .buttonStyle(.bordered)
                        Button("Reload") {
                            reloadRules()
                        }
                        .buttonStyle(.bordered)
                        .help("Clears the rule cache so edits to YAML files take effect immediately.")
                    }

                    HStack(alignment: .top, spacing: 0) {
                        // File list sidebar
                        ScrollView {
                            VStack(alignment: .leading, spacing: 1) {
                                ForEach(ruleFileList, id: \.self) { file in
                                    Button(action: { selectRuleFile(file) }) {
                                        Text(file)
                                            .font(.system(size: 11, design: .monospaced))
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 3)
                                            .background(
                                                selectedRuleFile == file
                                                    ? Color.accentColor.opacity(0.15)
                                                    : Color.clear
                                            )
                                            .cornerRadius(3)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(4)
                        }
                        .frame(width: 148)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                        Color(nsColor: .separatorColor)
                            .frame(width: 1)
                            .padding(.horizontal, 6)

                        // Editor pane
                        VStack(alignment: .leading, spacing: 4) {
                            if selectedRuleFile != nil {
                                TextEditor(text: $ruleFileContent)
                                    .font(.system(size: 11, design: .monospaced))
                                    .scrollContentBackground(.hidden)
                                    .padding(4)
                                    .background(Color(nsColor: .textBackgroundColor))
                                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                                    )
                                    .onChange(of: ruleFileContent) { _ in
                                        ruleSaveStatus = nil
                                    }
                                HStack(spacing: 8) {
                                    Button("Save") { saveRuleFile() }
                                        .buttonStyle(.borderedProminent)
                                        .disabled(!ruleFileIsDirty)
                                    if let status = ruleSaveStatus {
                                        HStack(spacing: 4) {
                                            Image(systemName: status.icon)
                                                .foregroundStyle(status.color)
                                            Text(status.message)
                                                .foregroundStyle(status.color)
                                        }
                                        .font(.caption)
                                    } else if ruleFileIsDirty {
                                        Text("Unsaved changes")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                            } else {
                                Color.clear
                                    .overlay(
                                        Text("Select a file to edit")
                                            .font(.caption)
                                            .foregroundStyle(.tertiary)
                                    )
                            }
                        }
                    }
                    .frame(height: 220)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                    )

                    // Reload status feedback
                    if let status = rulesReloadStatus {
                        HStack(spacing: 4) {
                            Image(systemName: status.icon)
                                .foregroundStyle(status.color)
                            Text(status.message)
                                .foregroundStyle(status.color)
                        }
                        .font(.caption)
                    }
                    // Load errors for the current context
                    let errors = RuleStore.shared.relevantLoadErrors(for: currentRuleContext)
                    if !errors.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(errors, id: \.file) { error in
                                HStack(alignment: .top, spacing: 4) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundStyle(.orange)
                                    Text("Could not load \(error.file): \(error.message)")
                                        .foregroundStyle(.orange)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .font(.caption)
                            }
                        }
                    }
                    // Non-fatal lint warnings for the current context
                    let warnings = RuleStore.shared.relevantWarnings(for: currentRuleContext)
                    if !warnings.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(warnings.enumerated()), id: \.offset) { _, warning in
                                HStack(alignment: .top, spacing: 4) {
                                    Image(systemName: "exclamationmark.triangle")
                                        .foregroundStyle(.yellow)
                                    Text("\(warning.file): \(warning.message)")
                                        .foregroundStyle(.yellow)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .font(.caption)
                            }
                        }
                    }
                }

                Divider()

                // MARK: Try Rules
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Try Rules")
                            .font(.headline)
                        Text("Test how the current rules transform a transcript before insertion. Applies: \(currentRuleContext.descriptionForDisplay).")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    // Input
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $tryRulesInput)
                            .font(.system(.body, design: .monospaced))
                            .frame(height: 72)
                            .scrollContentBackground(.hidden)
                            .padding(4)
                            .background(Color(nsColor: .textBackgroundColor))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                            )
                        if tryRulesInput.isEmpty {
                            Text("e.g. open brace new line close brace")
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 12)
                                .allowsHitTesting(false)
                        }
                    }

                    // Actions
                    HStack(spacing: 8) {
                        Button("Apply Rules") {
                            applyTryRules()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(tryRulesInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        if let result = tryRulesResult {
                            Button("Copy Output") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(result.output, forType: .string)
                            }
                            .buttonStyle(.bordered)
                        }

                        Spacer()

                        if let result = tryRulesResult {
                            Text("\(result.ruleCount) rule\(result.ruleCount == 1 ? "" : "s") loaded")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }

                    // Output + trace
                    if let result = tryRulesResult {
                        // Output field
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Output")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            ScrollView {
                                Text(outputDisplayText(result.output))
                                    .font(.system(.body, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                                    .padding(8)
                            }
                            .frame(maxHeight: 80)
                            .background(Color(nsColor: .controlBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                            )
                        }

                        // Matched rules trace
                        VStack(alignment: .leading, spacing: 4) {
                            if result.matchedRules.isEmpty {
                                HStack(spacing: 4) {
                                    Image(systemName: "info.circle")
                                        .foregroundStyle(.secondary)
                                    Text("No rules matched. Output is unchanged.")
                                        .foregroundStyle(.secondary)
                                }
                                .font(.caption)
                            } else {
                                Text("Matched \(result.matchedRules.count) rule\(result.matchedRules.count == 1 ? "" : "s")")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    ForEach(result.matchedRules) { trace in
                                        RuleTraceRow(trace: trace)
                                    }
                                }
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(nsColor: .controlBackgroundColor))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                        }
                    }
                }

                Divider()

                // MARK: Format reference
                VStack(alignment: .leading, spacing: 8) {
                    Text("Rule Format")
                        .font(.headline)
                    Text("Each rule file contains a list of trigger/replace pairs. Triggers are matched case-insensitively against the final transcript before insertion.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 2) {
                        ForEach([
                            "rules:",
                            "  - trigger: \"open brace\"",
                            "    replace: \"{\"",
                            "  - trigger: \"new line\"",
                            "    replace: \"\\n\"",
                        ], id: \.self) { line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(10)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                    Text("Resolution order: global.yaml → <mode>.yaml (or code/global.yaml + code/<profile>.yaml for code mode).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
    }

    /// The active `RuleContext` derived from current AppState.
    private var currentRuleContext: RuleContext {
        RuleContext(mode: appState.currentMode, codeProfile: appState.currentCodeProfile)
    }

    private func applyTryRules() {
        let input = tryRulesInput
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        tryRulesResult = TransformationPipeline.run(
            transcript: input,
            context: currentRuleContext,
            store: RuleStore.shared
        )
    }

    private func reloadRules() {
        let context = currentRuleContext
        RuleStore.shared.reload()
        // Eagerly load to surface errors immediately.
        _ = RuleStore.shared.taggedRules(for: context)
        let errors = RuleStore.shared.relevantLoadErrors(for: context)
        if errors.isEmpty {
            let count = RuleStore.shared.taggedRules(for: context).count
            rulesReloadStatus = .ok("Reloaded — \(count) rule\(count == 1 ? "" : "s") for \(context.descriptionForDisplay)")
        } else {
            rulesReloadStatus = .error("\(errors.count) file\(errors.count == 1 ? "" : "s") failed to load")
        }
        tryRulesResult = nil
    }

    private var ruleFileList: [String] {
        let dir = RuleStore.shared.rulesDirectory
        let fm = FileManager.default
        var result: [String] = []
        if let items = try? fm.contentsOfDirectory(atPath: dir.path) {
            for item in items.sorted() where item.hasSuffix(".yaml") {
                let url = dir.appendingPathComponent(item)
                var isDir: ObjCBool = false
                fm.fileExists(atPath: url.path, isDirectory: &isDir)
                if !isDir.boolValue { result.append(item) }
            }
        }
        let codeDir = dir.appendingPathComponent("code")
        if let items = try? fm.contentsOfDirectory(atPath: codeDir.path) {
            for item in items.sorted() where item.hasSuffix(".yaml") {
                result.append("code/\(item)")
            }
        }
        return result
    }

    private var ruleFileIsDirty: Bool { ruleFileContent != loadedRuleFileContent }

    private func selectRuleFile(_ relativePath: String) {
        let url = RuleStore.shared.rulesDirectory.appendingPathComponent(relativePath)
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return }
        selectedRuleFile = relativePath
        ruleFileContent = content
        loadedRuleFileContent = content
        ruleSaveStatus = nil
    }

    private func saveRuleFile() {
        guard let relativePath = selectedRuleFile else { return }
        let url = RuleStore.shared.rulesDirectory.appendingPathComponent(relativePath)
        do {
            try ruleFileContent.write(to: url, atomically: true, encoding: .utf8)
            loadedRuleFileContent = ruleFileContent
            ruleSaveStatus = .ok("Saved")
            RuleStore.shared.reload()
            vxLog("[rules/editor] Saved \(relativePath)")
        } catch {
            ruleSaveStatus = .error("Save failed: \(error.localizedDescription)")
            vxLog("[rules/editor] Failed to save \(relativePath): \(error)")
        }
    }

    /// Converts the output string to a display-friendly form: actual newlines become
    /// a visible "↵" marker followed by a real newline so line breaks are evident.
    private func outputDisplayText(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ↵\n")
            .replacingOccurrences(of: "\t", with: "→\t")
    }

    private var aiTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {

                // MARK: Context Detection
                VStack(alignment: .leading, spacing: 8) {
                    Text("Context Detection")
                        .font(.headline)
                    Toggle("Automatically detect app context", isOn: $appState.autoDetectMode)
                    Text("Detects the frontmost app (Mail, Slack, Xcode, etc.) and switches the dictation mode and AI instructions automatically.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                // MARK: App Mappings
                VStack(alignment: .leading, spacing: 8) {
                    Text("App Mappings")
                        .font(.headline)
                    Text("Override or extend the built-in app → context mappings. Find a bundle ID by running: osascript -e 'id of app \"AppName\"'")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(spacing: 0) {
                        ForEach($mappingEntries) { $entry in
                            HStack(spacing: 8) {
                                TextField("com.example.App", text: $entry.bundleID)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 11, design: .monospaced))
                                    .frame(maxWidth: .infinity)
                                    .onChange(of: entry.bundleID) { _ in mappingSaveStatus = nil }

                                Picker("", selection: $entry.contextValue) {
                                    ForEach(contextOptions, id: \.value) { opt in
                                        Text(opt.label).tag(opt.value)
                                    }
                                }
                                .labelsHidden()
                                .frame(width: 160)
                                .onChange(of: entry.contextValue) { _ in mappingSaveStatus = nil }

                                Button {
                                    mappingEntries.removeAll { $0.id == entry.id }
                                    mappingSaveStatus = nil
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.borderless)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(Color(nsColor: .controlBackgroundColor))

                            if entry.id != mappingEntries.last?.id {
                                Divider().padding(.leading, 8)
                            }
                        }

                        // Add-new row
                        HStack(spacing: 8) {
                            TextField("com.example.NewApp", text: $mappingNewBundleID)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11, design: .monospaced))
                                .frame(maxWidth: .infinity)
                                .onSubmit { addMappingEntry() }

                            Picker("", selection: $mappingNewContext) {
                                ForEach(contextOptions, id: \.value) { opt in
                                    Text(opt.label).tag(opt.value)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 160)

                            Button { addMappingEntry() } label: {
                                Image(systemName: "plus.circle.fill")
                                    .foregroundStyle(Color.accentColor)
                            }
                            .buttonStyle(.borderless)
                            .disabled(mappingNewBundleID.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color(nsColor: .controlBackgroundColor))
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                    )

                    HStack(spacing: 8) {
                        Button("Save") { saveMappings() }
                            .buttonStyle(.borderedProminent)
                        if let status = mappingSaveStatus {
                            HStack(spacing: 4) {
                                Image(systemName: status.icon)
                                    .foregroundStyle(status.color)
                                Text(status.message)
                                    .foregroundStyle(status.color)
                            }
                            .font(.caption)
                        }
                        Spacer()
                        Button("Reload") { loadMappings() }
                            .buttonStyle(.bordered)
                    }
                }

                Divider()

                // MARK: Post-processing
                VStack(alignment: .leading, spacing: 8) {
                    Text("AI Post-processing")
                        .font(.headline)
                    Toggle("AI post-processing", isOn: $appState.isPostProcessingEnabled)
                    Text("Cleans up punctuation, removes filler words, and applies your instructions and dictionary after each dictation.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Provider", selection: $appState.postProcessingProvider) {
                            ForEach(PostProcessingProvider.allCases) { provider in
                                Text(provider.rawValue).tag(provider)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .onChange(of: appState.postProcessingProvider) { newProvider in
                            appState.postProcessingModel = newProvider.defaultModel
                        }

                        if let models = appState.postProcessingProvider.namedModels {
                            Picker("", selection: $appState.postProcessingModel) {
                                ForEach(models) { model in
                                    Text(model.displayName).tag(model.id)
                                }
                            }
                            .labelsHidden()
                            .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            TextField(appState.postProcessingProvider.modelInputPlaceholder, text: $appState.postProcessingModel)
                                .textFieldStyle(.roundedBorder)
                        }

                        HStack(spacing: 6) {
                            Group {
                                if showAPIKey {
                                    TextField("API key", text: $appState.postProcessingAPIKey)
                                } else {
                                    SecureField("API key", text: $appState.postProcessingAPIKey)
                                }
                            }
                            .textFieldStyle(.roundedBorder)

                            Button {
                                showAPIKey.toggle()
                            } label: {
                                Image(systemName: showAPIKey ? "eye.slash" : "eye")
                            }
                            .buttonStyle(.borderless)
                            .help(showAPIKey ? "Hide API key" : "Show API key")
                        }

                        if appState.postProcessingProvider == .custom {
                            TextField("Base URL (e.g. https://...)", text: $appState.postProcessingCustomBaseURL)
                                .textFieldStyle(.roundedBorder)
                        }

                        Divider()

                        Toggle("Remove filler words & smooth speech", isOn: $appState.smoothDisfluencies)
                        Text("Removes um/uh and verbal tics, and cleans up stutters, false starts, and repeated phrases. Turn off for verbatim transcription.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .opacity(appState.isPostProcessingEnabled ? 1 : 0.4)
                    .disabled(!appState.isPostProcessingEnabled)
                }

                Divider()

                // MARK: Context Instructions
                VStack(alignment: .leading, spacing: 8) {
                    Text("Context Instructions")
                        .font(.headline)
                    Text("Per-context instructions appended to the AI prompt when auto-detect matches that context. Files are stored in ~/.vx/prompts/.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(alignment: .top, spacing: 0) {
                        // Context list sidebar
                        ScrollView {
                            VStack(alignment: .leading, spacing: 1) {
                                ForEach(ContextPromptStore.allContexts) { ctx in
                                    Button(action: { selectPromptContext(ctx.id) }) {
                                        Text(ctx.displayName)
                                            .font(.system(size: 11))
                                            .lineLimit(1)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 3)
                                            .background(
                                                selectedPromptContext == ctx.id
                                                    ? Color.accentColor.opacity(0.15)
                                                    : Color.clear
                                            )
                                            .cornerRadius(3)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(4)
                        }
                        .frame(width: 96)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                        Color(nsColor: .separatorColor)
                            .frame(width: 1)
                            .padding(.horizontal, 6)

                        // Editor pane
                        VStack(alignment: .leading, spacing: 4) {
                            TextEditor(text: $promptEditorContent)
                                .font(.system(size: 11, design: .monospaced))
                                .scrollContentBackground(.hidden)
                                .padding(4)
                                .background(Color(nsColor: .textBackgroundColor))
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                                )
                                .onChange(of: promptEditorContent) { _ in
                                    promptSaveStatus = nil
                                }

                            HStack(spacing: 8) {
                                Button("Save") { savePromptFile() }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(!promptIsDirty)
                                if let status = promptSaveStatus {
                                    HStack(spacing: 4) {
                                        Image(systemName: status.icon)
                                            .foregroundStyle(status.color)
                                        Text(status.message)
                                            .foregroundStyle(status.color)
                                    }
                                    .font(.caption)
                                } else if promptIsDirty {
                                    Text("Unsaved changes")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                        }
                    }
                    .frame(height: 200)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                    )
                    Text("Lines beginning with # are treated as comments and are not sent to the AI.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .opacity(appState.isPostProcessingEnabled ? 1 : 0.4)
                .disabled(!appState.isPostProcessingEnabled)

                Divider()

                // MARK: Global Instructions
                VStack(alignment: .leading, spacing: 8) {
                    Text("Global Instructions")
                        .font(.headline)
                    Text("Always appended to the AI prompt, regardless of context.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    TextEditor(text: $appState.postProcessingCustomPrompt)
                        .font(.body)
                        .frame(height: 72)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                        )
                        .overlay(alignment: .topLeading) {
                            if appState.postProcessingCustomPrompt.isEmpty {
                                Text("e.g. Always use British spelling. Keep technical jargon as-is.")
                                    .font(.body)
                                    .foregroundStyle(.tertiary)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 8)
                                    .allowsHitTesting(false)
                            }
                        }
                }
                .opacity(appState.isPostProcessingEnabled ? 1 : 0.4)
                .disabled(!appState.isPostProcessingEnabled)

                Divider()

                // MARK: Custom Dictionary
                VStack(alignment: .leading, spacing: 8) {
                    Text("Custom Dictionary")
                        .font(.headline)
                    Text("Words and terms the AI will always treat as valid — proper nouns, brand names, jargon, unusual spellings.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if !appState.customDictionary.isEmpty {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(appState.customDictionary, id: \.self) { word in
                                    HStack {
                                        Text(word)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        Button {
                                            appState.customDictionary.removeAll { $0 == word }
                                        } label: {
                                            Image(systemName: "minus.circle.fill")
                                                .foregroundStyle(.secondary)
                                        }
                                        .buttonStyle(.borderless)
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color(nsColor: .controlBackgroundColor))
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 108)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                        )
                    }

                    HStack(spacing: 6) {
                        TextField("Add term…", text: $newDictionaryWord)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { addDictionaryWord() }
                        Button("Add") { addDictionaryWord() }
                            .buttonStyle(.bordered)
                            .disabled(newDictionaryWord.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .opacity(appState.isPostProcessingEnabled ? 1 : 0.4)
                .disabled(!appState.isPostProcessingEnabled)

            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
    }

    // MARK: Context prompt helpers

    private var promptIsDirty: Bool { promptEditorContent != loadedPromptContent }

    private func selectPromptContext(_ contextID: String) {
        selectedPromptContext = contextID
        loadPromptFile(contextID: contextID)
    }

    private func loadPromptFile(contextID: String) {
        let url = ContextPromptStore.promptURL(contextID: contextID)
        let content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        promptEditorContent = content
        loadedPromptContent = content
        promptSaveStatus = nil
    }

    private func savePromptFile() {
        do {
            try ContextPromptStore.save(promptEditorContent, contextID: selectedPromptContext)
            loadedPromptContent = promptEditorContent
            promptSaveStatus = .ok("Saved")
        } catch {
            promptSaveStatus = .error("Save failed: \(error.localizedDescription)")
        }
    }

    private func addDictionaryWord() {
        let word = newDictionaryWord.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else { return }
        appState.customDictionary.append(word)
        newDictionaryWord = ""
    }

    // MARK: App mapping helpers

    private func loadMappings() {
        let raw = AppContextDetector.loadRawMappings()
        mappingEntries = raw.map { MappingEntry(bundleID: $0.bundleID, contextValue: $0.contextValue) }
        mappingSaveStatus = nil
    }

    private func addMappingEntry() {
        let bid = mappingNewBundleID.trimmingCharacters(in: .whitespaces)
        guard !bid.isEmpty else { return }
        mappingEntries.append(MappingEntry(bundleID: bid, contextValue: mappingNewContext))
        mappingNewBundleID = ""
        mappingNewContext = "general"
        mappingSaveStatus = nil
    }

    private func saveMappings() {
        let entries = mappingEntries.map { (bundleID: $0.bundleID, contextValue: $0.contextValue) }
        do {
            try AppContextDetector.saveCustomMappings(entries)
            mappingSaveStatus = .ok("Saved")
        } catch {
            mappingSaveStatus = .error("Save failed: \(error.localizedDescription)")
        }
    }

    private var soundTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Sound Effects")
                    .font(.headline)
                Toggle("Play sounds during dictation", isOn: $appState.soundEffectsEnabled)
                Text("Plays a sound when recording starts and when transcription begins.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Volume")
                    .font(.headline)
                Toggle("Lower volume while recording", isOn: $appState.duckAudioWhileRecording)
                if appState.duckAudioWhileRecording {
                    HStack(spacing: 8) {
                        Text("Volume during recording")
                            .foregroundStyle(.secondary)
                        Slider(value: $appState.duckVolume, in: 0.0...0.8)
                        Text("\(Int(appState.duckVolume * 100))%")
                            .frame(width: 36, alignment: .trailing)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(24)
    }

    private var permissionsTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            PermissionRow(
                title: "Microphone",
                detail: "Required to capture your speech during dictation.",
                status: microphoneState,
                primaryTitle: microphoneState == .granted ? "Granted" : "Request",
                primaryEnabled: microphoneState != .granted,
                secondaryTitle: "Open Settings",
                onPrimary: requestMicrophonePermission,
                onSecondary: { openPrivacyPane(anchor: "Privacy_Microphone") }
            )

            PermissionRow(
                title: "Accessibility",
                detail: "Needed to intercept the fn/globe key for push‑to‑talk.",
                status: accessibilityState,
                primaryTitle: accessibilityState == .granted ? "Granted" : "Request",
                primaryEnabled: accessibilityState != .granted,
                secondaryTitle: "Open Settings",
                onPrimary: requestAccessibilityPermission,
                onSecondary: { openPrivacyPane(anchor: "Privacy_Accessibility") }
            )

            PermissionRow(
                title: "Input Monitoring",
                detail: "Required to monitor global keyboard shortcuts when accessibility alone isn't enough.",
                status: keyboardMonitorState,
                primaryTitle: keyboardMonitorState == .granted ? "Granted" : "Request",
                primaryEnabled: keyboardMonitorState != .granted,
                secondaryTitle: "Open Settings",
                onPrimary: requestKeyboardMonitoringPermission,
                onSecondary: { openPrivacyPane(anchor: "Privacy_ListenEvent") }
            )

            Text("Tip: Use the buttons above to re‑prompt or jump directly to the relevant Privacy & Security panes after reinstalling the app.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(24)
    }

    private var developerTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Debug")
                    .font(.headline)
                Toggle("Debug Mode", isOn: $appState.isDebugMode)
                HStack(spacing: 8) {
                    Button("Show Log…") {
                        NotificationCenter.default.post(name: .vxShowDebugLog, object: nil)
                    }
                    .buttonStyle(.bordered)
                    Button("Reveal Log File") {
                        NSWorkspace.shared.activateFileViewerSelecting(
                            [DebugLogger.shared.logFileURL]
                        )
                    }
                    .buttonStyle(.bordered)
                }
                Text(DebugLogger.shared.logFileURL.path)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Divider()

            versionHistorySection

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Resources")
                    .font(.headline)
                ResourcePathRow(label: "Backend", path: appState.backendURL.path)
                ResourcePathRow(label: "Whisper Model", path: appState.modelURL.path)
                Text("Files are loaded from the app bundle via Bundle.main.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(24)
    }

    private var versionHistorySection: some View {
        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        return VStack(alignment: .leading, spacing: 8) {
            Text("Version History")
                .font(.headline)
            Text("Running v\(currentVersion)")
                .foregroundStyle(.secondary)
                .font(.subheadline)

            if isLoadingReleases {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.7)
                    Text("Fetching releases…").foregroundStyle(.secondary)
                }
            } else {
                VStack(spacing: 2) {
                    ForEach(availableReleases.prefix(10)) { release in
                        HStack {
                            Text(release.tagName)
                                .font(.system(.body, design: .monospaced))
                            if release.tagName == "v\(currentVersion)" {
                                Text("current")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(.secondary.opacity(0.15), in: Capsule())
                            }
                            Spacer()
                            Button("Install") {
                                NotificationCenter.default.post(
                                    name: .vxInstallVersion,
                                    object: nil,
                                    userInfo: [
                                        "version": release.tagName,
                                        "url": release.downloadURL.absoluteString
                                    ]
                                )
                            }
                            .buttonStyle(.bordered)
                            .disabled(release.tagName == "v\(currentVersion)")
                        }
                        .padding(.vertical, 2)
                    }
                }

                if let error = releaseFetchError {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.caption)
                }

                Button(availableReleases.isEmpty ? "Fetch Releases…" : "Refresh") {
                    Task { await loadReleases() }
                }
                .buttonStyle(.bordered)
            }
        }
        .task {
            if availableReleases.isEmpty && !isLoadingReleases {
                await loadReleases()
            }
        }
    }

    private func loadReleases() async {
        isLoadingReleases = true
        releaseFetchError = nil
        do {
            let url = DistributionConfig.releasesAPIURL
            var request = URLRequest(url: url)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, _) = try await URLSession.shared.data(for: request)
            let decoded = try JSONDecoder().decode([GithubRelease].self, from: data)
            availableReleases = decoded
        } catch {
            releaseFetchError = "Could not fetch releases: \(error.localizedDescription)"
        }
        isLoadingReleases = false
    }

    private func captureShortcut() {
        guard let window = NSApp.mainWindow else { return }

        let alert = NSAlert()
        alert.messageText = "Press the new shortcut"
        alert.informativeText = "Press a key combination to update the dictation shortcut."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Cancel")

        NotificationCenter.default.post(name: .vxPauseShortcut, object: nil)

        let monitor = ShortcutCaptureMonitor(activationMode: appState.activationMode) { shortcut in
            DispatchQueue.main.async {
                self.appState.shortcut = shortcut
                alert.window.sheetParent?.endSheet(alert.window)
            }
        }
        monitor.start()

        alert.beginSheetModal(for: window) { _ in
            monitor.stop()
            NotificationCenter.default.post(name: .vxResumeShortcut, object: nil)
        }
    }

    private func captureShortcutForCopy() {
        guard let window = NSApp.mainWindow else { return }

        let alert = NSAlert()
        alert.messageText = "Press the new shortcut"
        alert.informativeText = "Press a key combination to set the shortcut for copying the last transcription."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Cancel")

        NotificationCenter.default.post(name: .vxPauseShortcut, object: nil)

        let monitor = ShortcutCaptureMonitor { shortcut in
            DispatchQueue.main.async {
                self.appState.copyLastShortcut = shortcut
                alert.window.sheetParent?.endSheet(alert.window)
            }
        }
        monitor.start()

        alert.beginSheetModal(for: window) { _ in
            monitor.stop()
            NotificationCenter.default.post(name: .vxResumeShortcut, object: nil)
        }
    }

    private func refreshPermissionStates() {
        microphoneState = PermissionState(AVCaptureDevice.authorizationStatus(for: .audio))
        accessibilityState = AXIsProcessTrusted() ? .granted : .denied
        automationState = .unknown
        let listenType = kIOHIDRequestTypeListenEvent
        let postType = kIOHIDRequestTypePostEvent
        let hasPostAccess = IOHIDCheckAccess(postType) == kIOHIDAccessTypeGranted
        let listenAccess = IOHIDCheckAccess(listenType)
        keyboardMonitorState = PermissionState(hidAccess: listenAccess, requiresPostAccess: hasPostAccess)
    }

    private func requestMicrophonePermission() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                DispatchQueue.main.async {
                    refreshPermissionStates()
                }
            }
        } else {
            openPrivacyPane(anchor: "Privacy_Microphone")
        }
    }

    private func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            refreshPermissionStates()
        }
    }

    private func requestKeyboardMonitoringPermission() {
        let postType = kIOHIDRequestTypePostEvent
        let listenType = kIOHIDRequestTypeListenEvent

        var hasPostAccess = IOHIDCheckAccess(postType) == kIOHIDAccessTypeGranted
        if !hasPostAccess {
            hasPostAccess = IOHIDRequestAccess(postType)
        }

        let listenGranted = IOHIDRequestAccess(listenType)
        if !(hasPostAccess && listenGranted) {
            openPrivacyPane(anchor: "Privacy_ListenEvent")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            refreshPermissionStates()
        }
    }

    private func openPrivacyPane(anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return }
        NSWorkspace.shared.open(url)
    }
}

#if DEBUG
#Preview {
    PreferencesView(appState: AppState())
}
#endif

private struct ModelRow: View {
    let model: WhisperModel
    let state: ModelInstallState
    let isActive: Bool
    let isBundledOnly: Bool
    let onSelect: () -> Void
    let onDownload: () -> Void
    let onCancel: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            // Selection indicator
            Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isActive ? Color.accentColor : (state.isInstalled ? Color.secondary : Color.secondary.opacity(0.4)))
                .font(.system(size: 16))
                .frame(width: 20)
                .onTapGesture { if state.isInstalled { onSelect() } }

            // Model info
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(model.displayName)
                        .fontWeight(.medium)
                    Text("—")
                        .foregroundStyle(.tertiary)
                    Text(model.detail)
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 13))
                Text(model.fileName)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            // Action area
            actionView
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var actionView: some View {
        switch state {
        case .installed:
            if isActive {
                Text("Active")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 6) {
                    Button("Use") { onSelect() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    if !isBundledOnly {
                        Button(role: .destructive, action: onRemove) {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .foregroundStyle(.secondary)
                        .help("Remove downloaded model")
                    }
                }
            }

        case .downloading(let progress):
            HStack(spacing: 8) {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(width: 72)
                Text("\(Int(progress * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(width: 28, alignment: .trailing)
                Button("Cancel", action: onCancel)
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .foregroundStyle(.secondary)
            }

        case .notInstalled:
            Button("Download (\(model.sizeLabel))", action: onDownload)
                .buttonStyle(.bordered)
                .controlSize(.small)

        case .failed:
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.caption)
                Button("Retry", action: onDownload)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }
}

private struct ResourcePathRow: View {
    let label: String
    let path: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(path)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    let status: PermissionState
    let primaryTitle: String
    let primaryEnabled: Bool
    let secondaryTitle: String?
    let onPrimary: () -> Void
    let onSecondary: (() -> Void)?

    init(
        title: String,
        detail: String,
        status: PermissionState,
        primaryTitle: String,
        primaryEnabled: Bool,
        secondaryTitle: String? = nil,
        onPrimary: @escaping () -> Void,
        onSecondary: (() -> Void)? = nil
    ) {
        self.title = title
        self.detail = detail
        self.status = status
        self.primaryTitle = primaryTitle
        self.primaryEnabled = primaryEnabled
        self.secondaryTitle = secondaryTitle
        self.onPrimary = onPrimary
        self.onSecondary = onSecondary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.subheadline)
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 8) {
                    Button(primaryTitle) {
                        onPrimary()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!primaryEnabled)

                    if let secondaryTitle, let onSecondary {
                        Button(secondaryTitle) {
                            onSecondary()
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            Text(status.label)
                .font(.caption)
                .foregroundColor(status.color)
        }
        .padding(12)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private enum PermissionState {
    case granted
    case denied
    case notDetermined
    case restricted
    case unknown

    init(_ status: AVAuthorizationStatus) {
        switch status {
        case .authorized:
            self = .granted
        case .denied:
            self = .denied
        case .restricted:
            self = .restricted
        case .notDetermined:
            self = .notDetermined
        @unknown default:
            self = .unknown
        }
    }

    init(fromBool granted: Bool) {
        self = granted ? .granted : .denied
    }

    init(hidAccess: IOHIDAccessType, requiresPostAccess: Bool) {
        guard requiresPostAccess else {
            self = .denied
            return
        }
        switch hidAccess {
        case kIOHIDAccessTypeGranted:
            self = .granted
        case kIOHIDAccessTypeDenied:
            self = .denied
        case kIOHIDAccessTypeUnknown:
            self = .notDetermined
        default:
            self = .unknown
        }
    }

    var label: String {
        switch self {
        case .granted: return "Granted"
        case .denied: return "Denied"
        case .notDetermined: return "Not requested"
        case .restricted: return "Restricted"
        case .unknown: return "Unknown"
        }
    }

    var color: Color {
        switch self {
        case .granted: return .green
        case .denied: return .red
        case .restricted: return .orange
        case .notDetermined, .unknown: return .secondary
        }
    }
}

private let kTypeWildCard: AEEventClass = 0x2A2A2A2A

private final class ShortcutCaptureMonitor {
    private let handler: (Shortcut) -> Void
    /// Determines what a lone modifier becomes: a hold-to-talk binding when the
    /// user is in hold-to-talk mode, or a double-tap binding in toggle mode
    /// (a single bare-modifier press would toggle far too easily).
    private let activationMode: ActivationMode
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var pendingShortcut: Shortcut?
    private let modifierMask: CGEventFlags = [
        .maskCommand,
        .maskShift,
        .maskAlternate,
        .maskControl,
        .maskSecondaryFn
    ]

    // Double-tap detection state
    private var firstTapReleasedAt: Date? = nil
    private var firstTapKeyCode: CGKeyCode? = nil
    private var firstTapShortcut: Shortcut? = nil
    private var doubleTapTimer: DispatchWorkItem? = nil
    private let doubleTapWindow: TimeInterval = 0.4

    init(activationMode: ActivationMode = .holdToTalk, handler: @escaping (Shortcut) -> Void) {
        self.activationMode = activationMode
        self.handler = handler
    }

    func start() {
        let mask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<ShortcutCaptureMonitor>.fromOpaque(userInfo).takeUnretainedValue()
            monitor.handle(event: event, type: type)
            return Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        ) else { return }

        self.tap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let source = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    func stop() {
        doubleTapTimer?.cancel()
        doubleTapTimer = nil
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        tap = nil
        runLoopSource = nil
        pendingShortcut = nil
        firstTapReleasedAt = nil
        firstTapKeyCode = nil
        firstTapShortcut = nil
    }

    private func handle(event: CGEvent, type: CGEventType) {
        let modifiers = event.flags.intersection(modifierMask)
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))

        switch type {
        case .keyDown:
            // Any regular key press cancels double-tap tracking
            cancelDoubleTapTracking()
            pendingShortcut = Shortcut(keyCode: keyCode, modifiers: modifiers)
        case .keyUp:
            let shortcut = pendingShortcut ?? Shortcut(keyCode: keyCode, modifiers: modifiers)
            cancelDoubleTapTracking()
            emit(shortcut)
        case .flagsChanged:
            guard let flag = modifierFlag(for: keyCode) else { return }
            let isPressed = modifiers.contains(flag)
            if isPressed {
                // Check for double-tap: same key released recently within window
                if let releasedAt = firstTapReleasedAt,
                   firstTapKeyCode == keyCode,
                   Date().timeIntervalSince(releasedAt) < doubleTapWindow,
                   let dtModifier = modifierKey(for: keyCode) {
                    cancelDoubleTapTracking()
                    pendingShortcut = nil
                    emit(.doubleTap(dtModifier))
                    return
                }
                // First tap press — reset any stale tracking
                cancelDoubleTapTracking()
                pendingShortcut = Shortcut(keyCode: keyCode, modifiers: modifiers)
            } else if case .combo(let pk, _) = pendingShortcut, pk == keyCode {
                if let modKey = modifierKey(for: keyCode) {
                    // A bare modifier was pressed and released.
                    if activationMode == .holdToTalk {
                        // Hold-to-talk binds the single modifier (hold it to dictate).
                        // There is no double-tap in hold-to-talk, so commit immediately.
                        pendingShortcut = nil
                        emit(.modifier(modKey))
                    } else {
                        // Toggle accepts either a single press or a double-tap of the same
                        // modifier. Wait one window to see if a second tap arrives; if not,
                        // commit the single-modifier binding.
                        let savedKeyCode = keyCode
                        pendingShortcut = nil
                        firstTapReleasedAt = Date()
                        firstTapKeyCode = savedKeyCode
                        firstTapShortcut = .modifier(modKey)
                        let work = DispatchWorkItem { [weak self] in
                            guard let self, self.firstTapKeyCode == savedKeyCode else { return }
                            let s = self.firstTapShortcut
                            self.firstTapReleasedAt = nil
                            self.firstTapKeyCode = nil
                            self.firstTapShortcut = nil
                            if let s { self.emit(s) }
                        }
                        doubleTapTimer = work
                        DispatchQueue.main.asyncAfter(deadline: .now() + doubleTapWindow, execute: work)
                    }
                } else {
                    // Non-modifier-only key (e.g. fn alone) — emit immediately
                    let shortcut = pendingShortcut!
                    pendingShortcut = nil
                    emit(shortcut)
                }
            }
        default:
            break
        }
    }

    private func cancelDoubleTapTracking() {
        doubleTapTimer?.cancel()
        doubleTapTimer = nil
        firstTapReleasedAt = nil
        firstTapKeyCode = nil
        firstTapShortcut = nil
    }

    private func emit(_ shortcut: Shortcut) {
        pendingShortcut = nil
        handler(shortcut)
    }

    private func modifierFlag(for keyCode: CGKeyCode) -> CGEventFlags? {
        switch Int(keyCode) {
        case kVK_Command: return .maskCommand
        case kVK_Shift, kVK_RightShift: return .maskShift
        case kVK_Option, kVK_RightOption: return .maskAlternate
        case kVK_Control, kVK_RightControl: return .maskControl
        case kVK_Function: return .maskSecondaryFn
        default: return nil
        }
    }

    private func modifierKey(for keyCode: CGKeyCode) -> ModifierKey? {
        switch Int(keyCode) {
        case kVK_Option:       return .leftOption
        case kVK_RightOption:  return .rightOption
        case kVK_Command:      return .leftCommand
        case kVK_RightCommand: return .rightCommand
        case kVK_Control:      return .leftControl
        case kVK_RightControl: return .rightControl
        case kVK_Shift:        return .leftShift
        case kVK_RightShift:   return .rightShift
        default:               return nil
        }
    }
}

// MARK: - Rules tab supporting types

/// Status displayed after a manual rule reload.
private enum RulesReloadStatus {
    case ok(String)
    case error(String)

    var message: String {
        switch self {
        case .ok(let msg):    return msg
        case .error(let msg): return msg
        }
    }

    var icon: String {
        switch self {
        case .ok:    return "checkmark.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    var color: Color {
        switch self {
        case .ok:    return .green
        case .error: return .orange
        }
    }
}

/// A single row in the matched-rules trace list.
private struct RuleTraceRow: View {
    let trace: RuleMatchTrace

    var body: some View {
        HStack(spacing: 0) {
            Text(trace.source)
                .foregroundStyle(.secondary)
            Text("  —  ")
                .foregroundStyle(.tertiary)
            Text("\"\(trace.trigger)\"")
                .foregroundStyle(.primary)
            Text("  →  ")
                .foregroundStyle(.tertiary)
            Text(trace.replacementPreview.isEmpty ? "(empty)" : "\"\(trace.replacementPreview)\"")
                .foregroundStyle(.primary)
        }
        .font(.system(.caption, design: .monospaced))
        .lineLimit(1)
        .truncationMode(.tail)
    }
}
