import Foundation

// MARK: - ResolvedContext

/// The dictation context settled for one recording: the resolved mode and code
/// profile, plus the detected `AppContext` (for telemetry/debug display) when
/// auto-detection produced a real match.
struct ResolvedContext {
    /// The auto-detected context, or `nil` when auto-detect is off or found no match
    /// (in which case the manual mode/profile were used).
    let detectedContext: AppContext?
    let mode: DictationMode
    let codeProfile: CodeProfile

    var ruleContext: RuleContext {
        RuleContext(mode: mode, codeProfile: codeProfile)
    }
}

// MARK: - DictationContextResolver

/// Decides which dictation mode and code profile a recording should use.
///
/// Concentrates the auto-detect fallback rule that used to live inline in
/// `AppCoordinator`: when auto-detect is on, infer the context from the frontmost
/// app; a `.general` (no-match) result falls back to the user's manual selection.
///
/// Detection itself is a seam (`detect`) so tests resolve without touching the
/// Accessibility API or `~/.vx/app-contexts.yaml`.
struct DictationContextResolver {
    /// Maps a bundle ID + pid to an `AppContext`. Defaults to `AppContextDetector`.
    var detect: (_ bundleID: String, _ pid: pid_t) -> AppContext = { bundleID, pid in
        AppContextDetector.detect(bundleID: bundleID, pid: pid)
    }

    func resolve(
        autoDetect: Bool,
        bundleID: String?,
        pid: pid_t,
        manualMode: DictationMode,
        manualProfile: CodeProfile
    ) -> ResolvedContext {
        let detected: AppContext? = {
            guard autoDetect, let bundleID else { return nil }
            let ctx = detect(bundleID, pid)
            guard case .general = ctx else { return ctx }
            return nil  // .general → fall back to manual selection
        }()

        if let ctx = detected {
            return ResolvedContext(detectedContext: ctx, mode: ctx.dictationMode, codeProfile: ctx.codeProfile)
        }
        return ResolvedContext(detectedContext: nil, mode: manualMode, codeProfile: manualProfile)
    }
}
