struct ProviderModel: Identifiable {
    let id: String          // actual API model string
    let displayName: String
}

enum PostProcessingProvider: String, CaseIterable, Identifiable {
    case anthropic   = "Anthropic"
    case openRouter  = "OpenRouter"
    case openAI      = "OpenAI"
    case custom      = "Custom"

    var id: String { rawValue }

    var defaultModel: String {
        switch self {
        case .anthropic:  return "claude-haiku-4-5-20251001"
        case .openRouter: return "anthropic/claude-haiku-4-5"
        case .openAI:     return "gpt-4o-mini"
        case .custom:     return ""
        }
    }

    /// Non-nil when the model field should be a dropdown; nil means free-text input.
    var namedModels: [ProviderModel]? {
        switch self {
        case .anthropic:
            return [
                ProviderModel(id: "claude-haiku-4-5-20251001", displayName: "Claude Haiku (fastest)"),
                ProviderModel(id: "claude-sonnet-4-6",         displayName: "Claude Sonnet (balanced)"),
                ProviderModel(id: "claude-opus-4-6",           displayName: "Claude Opus (most capable)"),
            ]
        case .openAI:
            return [
                ProviderModel(id: "gpt-4o-mini", displayName: "GPT-4o mini (fast)"),
                ProviderModel(id: "gpt-4o",      displayName: "GPT-4o (balanced)"),
            ]
        case .openRouter, .custom:
            return nil
        }
    }

    /// Placeholder text for free-text model input (OpenRouter / Custom only).
    var modelInputPlaceholder: String {
        switch self {
        case .openRouter: return "e.g. anthropic/claude-haiku-4-5"
        case .custom:     return "Enter model name"
        default:          return ""
        }
    }

    var baseURL: String? {
        switch self {
        case .anthropic:  return nil
        case .openRouter: return "https://openrouter.ai/api/v1"
        case .openAI:     return "https://api.openai.com/v1"
        case .custom:     return nil
        }
    }
}

enum ActivationMode: String, CaseIterable, Identifiable {
    case holdToTalk
    case toggle

    var id: String { rawValue }

    var description: String {
        switch self {
        case .holdToTalk: return "Hold to talk"
        case .toggle: return "Toggle to start/stop"
        }
    }
}

import Foundation
import Combine

public final class AppState: ObservableObject {
    @Published var shortcut: Shortcut {
        didSet { saveShortcut() }
    }

    @Published var activationMode: ActivationMode {
        didSet {
            saveActivationMode()
            // Double-tap is a toggle-only gesture — you can't "hold" a double-tap. If the
            // user switches to hold-to-talk while a double-tap binding is set, clear it
            // (revert to the default) and surface a notice explaining why.
            if activationMode == .holdToTalk, case .doubleTap = shortcut {
                shortcut = .optionSpace
                shortcutNotice = "Double-tap shortcuts only work in toggle mode, so your shortcut was reset to \(Shortcut.optionSpace.displayName). Pick a key combo or a single modifier to hold."
            }
        }
    }

    /// A transient, user-facing notice about an automatic shortcut change. Set by
    /// AppState when it has to adjust a binding; the UI presents and clears it.
    @Published var shortcutNotice: String?

    @Published var isDebugMode: Bool {
        didSet { defaults.set(isDebugMode, forKey: "vx.debug-mode") }
    }

    @Published var selectedInputDeviceUID: String? {
        didSet { defaults.set(selectedInputDeviceUID, forKey: "vx.input-device-uid") }
    }

    @Published var soundEffectsEnabled: Bool {
        didSet { defaults.set(soundEffectsEnabled, forKey: "vx.sound-effects-enabled") }
    }

    @Published var duckAudioWhileRecording: Bool {
        didSet { defaults.set(duckAudioWhileRecording, forKey: "vx.duck-audio") }
    }

    /// Target volume level (0.0–1.0) to fade to while recording.
    @Published var duckVolume: Double {
        didSet { defaults.set(duckVolume, forKey: "vx.duck-volume") }
    }

    @Published var copyLastShortcut: Shortcut {
        didSet { defaults.set(copyLastShortcut.serialize(), forKey: "vx.copy-last-shortcut") }
    }

    @Published var isPostProcessingEnabled: Bool {
        didSet { defaults.set(isPostProcessingEnabled, forKey: "vx.ai-post-processing-enabled") }
    }

    @Published var postProcessingProvider: PostProcessingProvider {
        didSet { defaults.set(postProcessingProvider.rawValue, forKey: "vx.ai-post-processing-provider") }
    }

    @Published var postProcessingAPIKey: String {
        didSet { defaults.set(postProcessingAPIKey, forKey: "vx.ai-api-key") }
    }

    @Published var postProcessingCustomBaseURL: String {
        didSet { defaults.set(postProcessingCustomBaseURL, forKey: "vx.ai-custom-url") }
    }

    @Published var postProcessingModel: String {
        didSet { defaults.set(postProcessingModel, forKey: "vx.ai-model") }
    }

    @Published var postProcessingCustomPrompt: String {
        didSet { defaults.set(postProcessingCustomPrompt, forKey: "vx.ai-custom-prompt") }
    }

    /// When enabled (and post-processing is on), the LLM removes filler words and
    /// smooths stutters/false starts/repetitions. Off = faithful, verbatim output.
    @Published var smoothDisfluencies: Bool {
        didSet { defaults.set(smoothDisfluencies, forKey: "vx.ai-smooth-disfluencies") }
    }

    @Published var customDictionary: [String] {
        didSet {
            if let data = try? JSONEncoder().encode(customDictionary) {
                defaults.set(data, forKey: "vx.custom-dictionary")
            }
        }
    }

    @Published var autoDetectMode: Bool {
        didSet { defaults.set(autoDetectMode, forKey: "vx.auto-detect-mode") }
    }

    @Published var currentMode: DictationMode {
        didSet { defaults.set(currentMode.rawValue, forKey: "vx.dictation-mode") }
    }

    @Published var currentCodeProfile: CodeProfile {
        didSet { defaults.set(currentCodeProfile.rawValue, forKey: "vx.code-profile") }
    }

    @Published var selectedModelName: String {
        didSet { defaults.set(selectedModelName, forKey: "vx.selected-model") }
    }

    private let defaults = UserDefaults.standard
    private let shortcutKey = "vx.shortcut"
    private let activationKey = "vx.activation-mode"

    public init() {
        shortcut = AppState.loadShortcut(from: defaults.string(forKey: shortcutKey))
        activationMode = ActivationMode(rawValue: defaults.string(forKey: activationKey) ?? "") ?? .holdToTalk
        isDebugMode = defaults.bool(forKey: "vx.debug-mode")
        selectedInputDeviceUID = defaults.string(forKey: "vx.input-device-uid")
        soundEffectsEnabled = defaults.object(forKey: "vx.sound-effects-enabled") as? Bool ?? true
        duckAudioWhileRecording = defaults.bool(forKey: "vx.duck-audio")
        duckVolume = defaults.object(forKey: "vx.duck-volume") as? Double ?? 0.2
        copyLastShortcut = defaults.string(forKey: "vx.copy-last-shortcut").flatMap(Shortcut.deserialize) ?? .commandShiftC
        isPostProcessingEnabled = defaults.bool(forKey: "vx.ai-post-processing-enabled")
        let storedProvider = PostProcessingProvider(rawValue: defaults.string(forKey: "vx.ai-post-processing-provider") ?? "") ?? .anthropic
        postProcessingProvider = storedProvider
        postProcessingAPIKey = defaults.string(forKey: "vx.ai-api-key") ?? ""
        postProcessingCustomBaseURL = defaults.string(forKey: "vx.ai-custom-url") ?? ""
        postProcessingModel = defaults.string(forKey: "vx.ai-model") ?? storedProvider.defaultModel
        postProcessingCustomPrompt = defaults.string(forKey: "vx.ai-custom-prompt") ?? ""
        smoothDisfluencies = defaults.object(forKey: "vx.ai-smooth-disfluencies") as? Bool ?? true
        customDictionary = (defaults.data(forKey: "vx.custom-dictionary")
            .flatMap { try? JSONDecoder().decode([String].self, from: $0) }) ?? []
        autoDetectMode = defaults.bool(forKey: "vx.auto-detect-mode")
        currentMode = DictationMode(rawValue: defaults.string(forKey: "vx.dictation-mode") ?? "") ?? .plainText
        currentCodeProfile = CodeProfile(rawValue: defaults.string(forKey: "vx.code-profile") ?? "") ?? .generic
        selectedModelName = defaults.string(forKey: "vx.selected-model") ?? WhisperModel.defaultModel.id

        // Remove legacy overrides that pointed to build-relative paths.
        defaults.removeObject(forKey: "vx.cli-path")
        defaults.removeObject(forKey: "vx.model-path")

        // Enforce the invariant that hold-to-talk never pairs with a double-tap binding
        // (e.g. from an older persisted state). didSet doesn't fire during init, so do it
        // here and persist the corrected value.
        if activationMode == .holdToTalk, case .doubleTap = shortcut {
            shortcut = .optionSpace
            defaults.set(shortcut.serialize(), forKey: shortcutKey)
        }
    }

    public var backendURL: URL {
        ResourceLocator.backendExecutableURL()
    }

    public var modelURL: URL {
        if let model = WhisperModel.find(id: selectedModelName),
           let url = ModelManager.resolvedModelURL(fileName: model.fileName) {
            return url
        }
        // Selected model not found — fall back to bundled default.
        if let url = ModelManager.resolvedModelURL(fileName: WhisperModel.defaultModel.fileName) {
            return url
        }
        return ResourceLocator.modelURL()
    }

    private func saveShortcut() {
        defaults.set(shortcut.serialize(), forKey: shortcutKey)
    }

    private func saveActivationMode() {
        defaults.set(activationMode.rawValue, forKey: activationKey)
    }

    private static func loadShortcut(from value: String?) -> Shortcut {
        guard let value else { return .optionSpace }
        return Shortcut.deserialize(value) ?? .optionSpace
    }
}
