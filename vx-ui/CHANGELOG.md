# Changelog

All notable changes to this project will be documented in this file.

## [v1.0.39] - 2026-06-05

### Fixed
- Function keys (F1–F20) now work as shortcuts. On Macs where the top row defaults to media keys, F1 only emits its key code while fn is held, so the binding picked up the fn flag and showed up as just "fn". Function-key bindings now display correctly (e.g. `F1`) and trigger whether or not fn is held, regardless of the "Use F1, F2, etc. as standard function keys" setting.

### Added
- You can now bind a single modifier key (e.g. Right Option) as the shortcut. In hold-to-talk mode you hold it to dictate; in toggle mode you press it to start and stop. A held modifier emits no key code, so it previously did nothing when bound — now it works. The key is passed through, so it keeps functioning normally elsewhere (Right Option is a good pick since it stays out of the way of typing).

### Changed
- Shortcut labels are clearer and match the activation mode: a single modifier shows as e.g. `⌥ Right Option` and a double-tap as `⌥ ⌥ Right Option`, with the surrounding text supplying "Hold…" or "Press…" so it always reads correctly.
- Double-tap shortcuts are now correctly treated as toggle-only. Switching to hold-to-talk while a double-tap shortcut is set clears it (reverting to the default) and explains why, since you can't hold a double-tap.

### Fixed
- Recording the shortcut no longer produces a dead modifier-only binding that silently did nothing.

### Fixed
- Dictation now works when an external microphone is used while audio output is routed to Bluetooth headphones (e.g. a Blue Yeti while listening on WH-1000XM3). Previously the audio engine failed to start with a "The operation couldn't be completed" error because macOS can't run split input/output through the same audio unit. vx now captures from the chosen input device independently of the output device.
- The app no longer hangs requiring Activity Monitor to force-quit when audio capture fails repeatedly. Recording start is retried briefly, surfaces a friendly message on failure, and a main-thread watchdog terminates the process if it ever wedges for more than a few seconds.
- Fresh installs no longer crash on launch when no Whisper model is bundled. vx now bundles `ggml-tiny.en` and falls back gracefully to the downloaded-models directory.

### Changed
- vx is now signed with a Developer ID certificate and notarized by Apple, so it launches without the "unidentified developer" / Gatekeeper warning.

## [v1.0.36] - 2026-06-03

### Changed
- Auto-updates are now cryptographically verified. Each release is signed with an Ed25519 key, and vx checks the signature against a key built into the app before installing an update — so a tampered or spoofed download (even from a compromised release host) is refused. Applies to both normal updates and version-history rollbacks.

## [v1.0.35] - 2026-06-02

### Changed
- Edits to your rule files (`~/.vx/rules/*.yaml`) now take effect immediately on your next dictation — no need to switch dictation modes or restart the app. (Prompt and app-context files already updated live.)
- **Faster transcription.** Transcription now runs on the Apple Silicon GPU (Metal) instead of CPU-only, and no longer oversubscribes efficiency cores. The wait after you stop recording is noticeably shorter — the bigger your model, the bigger the speedup.

### Removed
- The experimental "Live Preview" option (Preferences → Configuration) is gone. It showed words above the recording capsule while you spoke, but the preview was unreliable and often differed from the final transcript. Removing it also means the backend no longer runs throwaway transcription passes mid-recording, so recording is a touch lighter on CPU. Your final transcript is unchanged.

## [v1.0.34] - 2026-05-29

### Fixed
- AI post-processing no longer occasionally "answers" your dictation instead of transcribing it. If you dictated something phrased like a question or request, the AI could reply conversationally and insert its reply. The transcript is now fenced and clearly marked as text to clean, not a prompt to respond to.
- AI post-processing never inserts the model's own commentary or refusals (e.g. "I cannot process this input..."). When the model narrates instead of cleaning, vx now falls back to your transcript so you always get your words.

### Added
- **Rule validation warnings** — the Rules tab now flags rules that loaded but probably won't work as intended: curly/smart quotes (a common copy-paste/autocorrect trap that silently breaks matching), empty triggers, and duplicate triggers.
- **"Remove filler words & smooth speech" toggle** (Preferences → Configuration, under AI Post-processing). When on, the AI strips filler (um, uh, "you know", etc.) and cleans up stutters, false starts, and repeated phrases. Turn it off for verbatim transcription. On by default.

## [v1.0.33] - 2026-05-29

### Fixed
- Your custom dictation rules are no longer discarded when AI post-processing is enabled. Previously, with post-processing on, vx sent the raw transcript to the AI and threw away every rule substitution (spoken symbols, replacements, snippets). Rules now apply first, and the AI cleans up the rule-applied text.

### Changed
- If the transcription engine fails to start, vx now shows a clear error instead of failing silently.

## [v1.0.32] - 2026-04-17

### Fixed
- Transcription no longer hangs indefinitely — if vx-rs takes too long or gets stuck, cancelling now immediately terminates the backend process and resets the app.
- Press Escape during transcription (the "Transcribing..." phase) to cancel and dismiss the HUD. Previously, Escape only worked during recording, leaving no way to bail out of a stuck transcription.
- Transcribed text no longer starts with a stray hyphen. Whisper sometimes prefixes output with "- " and vx now strips it.

## [v1.0.31] - 2026-03-15

### Added
- **Version History in Developer tab** — tap the version number 5 times in Configuration to reveal the Developer tab, which now includes a Version History section. You can see all published releases and install any of them with one click (useful for rolling back if a release causes issues).

## [v1.0.30] - 2026-03-15

### Fixed
- Changing the "Copy Last" shortcut in Preferences now takes effect immediately without restarting the app.
- Selecting a specific microphone now works correctly when a Bluetooth device (e.g. AirPods) is the system audio output. Previously, VX ignored the chosen input device and fell back to system default whenever any Bluetooth output was detected.
- Whisper hallucinations ("Thank you", "So we'll see you in the next video, bye", etc.) no longer get inserted into your text. The filter now covers more YouTube-style closings and applies to the final transcript, not just the live preview.

## [v1.0.29] - 2026-03-14

### Fixed
- "Relaunch vx" in the menu bar now correctly relaunches the app instead of just quitting

### Changed
- Debug Mode is no longer visible in the status bar menu; it can be enabled from the Developer tab in Preferences
- Developer tab in Preferences is hidden by default; tap the version string in the Configuration tab 5 times to reveal it
- Live Preview is now labeled "Live Preview (Experimental)" to reflect that preview text may differ from the final transcription

## [v1.0.28] - 2026-03-13

### Fixed
- Fixed the integration test for the long-recording data-loss regression — it was silently skipping on some macOS versions due to an `afconvert` bug with raw output format; the test now correctly runs full Whisper inference on the 117-second fixture.

## [v1.0.27] - 2026-03-13

### Fixed
- **Critical:** Recordings longer than 30 seconds were silently losing everything spoken in the first part of the session. The streaming transcription pipeline used a 30-second rolling buffer, so a 60-second recording would only transcribe the last 30 seconds. The full recording is now retained and chunked correctly for inference.

## [v1.0.26] - 2026-03-13

### Changed
- "Check for Updates…" now shows a live spinner and result directly in the menu without closing it. After checking, "No updates available." (or an error message) appears in place and clears itself after a few seconds.

## [v1.0.25] - 2026-03-13

### Fixed
- Volume ducking now works correctly for Bluetooth output devices (AirPods, etc.) — previously the volume percentage setting had no effect on Bluetooth because ducking was skipped entirely to avoid a CoreAudio crash. The duck is now applied after the audio engine starts, when it is safe to do so.
- Checking for updates now shows a dialog immediately when a new version is found, rather than silently changing the menu item text and requiring a second click to trigger the download.

## [v1.0.24] - 2026-03-13

### Added
- Context detection: vx now auto-detects the frontmost app (Mail, Slack, Xcode, browsers, etc.) and switches the dictation mode and AI instructions automatically
- App Mappings editor in the AI tab: add, edit, and remove custom app → context mappings without touching any YAML files
- Context Detection toggle in the AI tab (also available from the Mode submenu)
- Status bar menu shows the currently detected app and context when auto-detect is enabled (e.g. "Mail — Email")
- Mode and Code Profile menu items now show the currently active selection in parentheses
- Browser window title inference: when a browser is frontmost, vx reads the tab title to infer context (Gmail → Email, Google Docs → Document, GitHub → Code, etc.)
- Built-in mappings for Cursor (all distribution variants), Zed, and more editors and chat apps
- Context Inspector debug window (debug mode only): shows live detected app, context, mode, and rule files, plus a snapshot of the last recording
- Per-context AI prompt files in ~/.vx/prompts/ — customize AI instructions per mode (email, chat, code, etc.) from the AI tab
- Email and Chat are now first-class dictation modes with their own rule files and AI hints

## [v1.0.23] - 2026-03-12

### Added
- Live preview: words appear above the recording capsule as you speak, fading out as you continue
- Live preview can be enabled in the Configuration tab (off by default)

### Fixed
- Reduced post-recording latency by ~50% for typical dictations using streaming inference
- Fixed spurious "you" appearing at the start of a live preview
- Fixed ellipses showing in live preview when pausing mid-sentence

## [v1.0.22] - 2026-03-12

### Added
- Inline rules editor in the Rules tab: browse all rule files in a sidebar and edit them directly without leaving the app. Saving auto-reloads the rule cache.
- Double-tap modifier key shortcuts: set any modifier key (left or right Option, Command, Control, Shift) as a double-tap trigger. Press the same modifier key twice quickly to activate. Capture works the same way — double-tap in the shortcut dialog to set it.

### Fixed
- Paste (Cmd+V), copy, cut, undo, and select-all now work correctly in all text fields across Preferences (API key, model field, rules editor, Try Rules, custom prompt).

### Changed
- Preferences window is now resizable. Opens at a sensible default height and can be dragged taller. The tab bar stays pinned to the top and fills the full width at any size.

## [v1.0.21] - 2026-03-11

### Added
- Transcription model selection in Preferences (Configuration tab). Choose between Tiny (bundled, fastest), Base (balanced), and Small (slower, better accuracy). Missing models can be downloaded from inside the app with a live progress indicator, and non-active downloaded models can be removed.
- Rules engine: transcribed text is now run through a user-editable rule pipeline before insertion. Rules live in `~/.vx/rules/` as human-readable YAML files and are created with sensible defaults on first launch.
- Dictation modes: Plain Text, Code, Markdown, and Terminal. Each mode loads its own rule file on top of the shared `global.yaml`, so you can have context-specific phrase expansions (e.g. "open brace" → `{` only in Code mode).
- Code profiles: within Code mode, select a language-specific rule pack (Generic, Swift, JavaScript, TypeScript, Python, Go, Rust). Each profile loads `code/global.yaml` plus its own `code/<language>.yaml` file.
- Mode and Code Profile switchers in the status bar menu (submenus with checkmarks on the active selection).
- Rules tab in Preferences with a mode picker, a Code Profile picker (shown when Code mode is active), an "Open Folder" button, and a "Reload Rules" button.
- Try Rules panel in the Rules tab: paste a sample transcript, click Apply Rules, and see the transformed output with a per-rule match trace showing which file each rule came from.
- Default starter rule files for all modes and all code profiles with practical language-specific snippets.

## [v1.0.20] - 2026-03-11

### Added
- Dictation HUD now pops in with a short spring animation when you start recording (scale and opacity) instead of simply appearing
- After transcription is inserted, a brief "Inserted" confirmation with a checkmark appears for about half a second before the HUD dismisses, so you get clear feedback that the action completed
- When Reduce Motion is enabled in system accessibility settings, the HUD uses simpler animations (opacity-only, no scale) and toned-down motion in the transcribing state
- Recording state shows a subtle glow behind the widget so it’s clear the mic is live, without blocking clicks or the cursor in that area

### Changed
- Dictation HUD dismisses with a smooth scale-and-fade-out animation instead of disappearing abruptly
- Transition from recording to transcribing is a smooth crossfade: the level meter fades out and the blue "Transcribing..." state (with animated dots) fades in, so it’s obvious recording stopped and transcription is in progress
- Audio level meter during recording is now a segmented bar that responds smoothly and feels more responsive
- Transcribing state uses a blue accent and a subtle pulse so it’s visually distinct from recording

### Fixed
- The glow around the recording HUD no longer clips at the top of the window; space is reserved so the full effect is visible
- The shadow and empty area around the HUD no longer block the cursor or clicks — you can hover and click on apps underneath the glow; only the capsule (cancel, stop, meter) accepts input
- Dragging the dictation HUD now follows the cursor correctly instead of jumping
- Cancel (X) and Stop buttons on the dictation HUD work again when recording

## [v1.0.19] - 2026-03-10

### Changed
- Menu now shows the current version number at the top so you always know what you're running
- Reordered status bar menu: version, separator, Preferences, History, separator, Check for Updates, Relaunch vx, Debug Mode, Quit
- Update available now shows "New version available" instead of "Update to vX.Y.Z →"
- Download progress now shows a live percentage ("Downloading… 45%") instead of a static label
- Added "Relaunch vx" menu item
- "Check for Updates" now reads "Check for Updates…"

## [v1.0.18] - 2026-03-10

### Fixed
- Recording with AirPods or other Bluetooth headphones is more reliable — audio format is now determined from the real hardware buffer on the first callback, rather than pre-queried before the engine starts (which could return a stale format and crash)
- Volume ducking is properly skipped when the default output is a Bluetooth device, preventing a CoreAudio crash that could occur during engine setup

## [v1.0.17] - 2026-03-10

### Changed
- Preferences window is now resizable vertically (400–900px) so the AI tab content is always reachable

## [v1.0.16] - 2026-03-10

### Added
- New AI tab in Preferences consolidates all post-processing settings in one place
- Custom Dictionary — add proper nouns, brand names, or unusual terms so the AI always treats them as valid
- Text Shortcuts — speak a short cue phrase and the AI replaces it with the full expansion (useful for email addresses, signatures, boilerplate)
- Improved AI post-processing: handles self-corrections ("let's meet at 2, actually 3" → "let's meet at 3"), spoken numbered lists, better punctuation inference, and developer/technical jargon recognition
- Dictionary and shortcut lists scroll within a fixed-height area so the preferences window never grows unboundedly

### Changed
- Preference tab buttons now respond to clicks anywhere in their square, not just on the icon or label text

## [v1.0.15] - 2026-03-10

### Fixed
- Recording with Bluetooth headphones (AirPods, etc.) no longer crashes the app — the audio engine now handles Bluetooth output correctly by deferring format negotiation until the first audio buffer arrives
- Selecting a specific input device (e.g. MacBook Pro microphone) while using Bluetooth output no longer fails with a format error — device selection is skipped automatically and CoreAudio handles the configuration
- Volume ducking no longer causes a 6-second hang when Bluetooth is the output device — ducking is skipped entirely for Bluetooth output
- The "transcribing" sound effect now plays reliably with Bluetooth headphones — it is triggered before the audio engine stops, avoiding the silent window during the Bluetooth codec handoff
- AI post-processing now correctly handles questions and commands — previously, spoken questions were sometimes refused with a meta-comment instead of being corrected and returned

## [v1.0.14] - 2026-03-10

### Fixed
- Transcriptions no longer paste as multiple lines — speech output is always collapsed to a single line
- AI post-processing no longer returns meta-commentary (e.g. "Okay, show me what text you want me to read") — the prompt now explicitly instructs the model to treat input as speech, never as a directive
- HUD pill shadow removed — no longer clips at window edges or takes up invisible space outside the pill
- "Recording" and "Transcribing..." labels now have a matching pill-shaped background instead of floating as bare text

## [v1.0.13] - 2026-03-10

### Added
- "Recording" and "Transcribing..." labels now appear below the HUD pill during each state
- Sound effects play at the start of recording and when transcription begins — can be disabled in the new Sound preferences tab
- New Sound tab in Preferences groups sound effect and volume controls together

### Fixed
- Preferences window no longer flashes when switching tabs
- AI model field now shows a friendly dropdown (Claude Haiku, Sonnet, Opus / GPT-4o) for Anthropic and OpenAI; free-text input for OpenRouter and Custom
- Removed keyboard shortcuts (⌘, and ⌘Q) from the status bar menu that appeared but didn't work

### Changed
- Helper text throughout Preferences rewritten to be shorter and friendlier

## [v1.0.12] - 2026-03-10

### Fixed
- Input Device dropdown in Preferences no longer appears blank — it now always shows "System Default" when no device is selected or when the previously-selected device is unavailable

### Added
- "Copied to clipboard" toast now appears in the HUD when copying from the History submenu or using the Copy Last Shortcut

## [v1.0.11] - 2026-03-10

### Added
- Optional AI post-processing for transcriptions — enable in Preferences to have an LLM fix punctuation, capitalization, and remove filler words before text is inserted
- Supports Anthropic, OpenRouter, OpenAI, or any custom OpenAI-compatible endpoint
- Configurable model name per provider
- Custom rules field to append your own instructions (e.g. "Always use British spelling")
- Falls back to raw transcription silently if the API call fails

## [v1.0.10] - 2026-03-10

### Changed
- The "History" menu item now opens a submenu showing your last 5 transcriptions — click any entry to copy it directly to the clipboard
- "Show All" at the bottom of the History submenu opens the full history window
- Removed the separate "Copy Last Transcription" menu item (superseded by the submenu)

## [v1.0.9] - 2026-03-09

### Added
- The app now checks for updates automatically on launch and shows an "Update to vX.Y.Z →" item in the menu bar when a new version is available — clicking it downloads and installs the update in the background, then relaunches

## [v1.0.8] - 2026-03-09

### Added
- New "Copy Last Transcription" item in the status bar menu — shows a live preview of the most recent transcription text when the menu is open
- Global keyboard shortcut (default ⌘⇧C) to instantly copy the last transcription to your clipboard without opening any menu
- The copy shortcut is configurable from Preferences → Copy Last Shortcut
- A brief "Copied to clipboard" toast appears in the HUD after copying

## [v1.0.7] - 2026-03-09

### Changed
- Releases are now also distributed via Google Drive for easier sharing

## [v1.0.6] - 2026-03-09

### Fixed
- High CPU usage when debug mode was enabled — every keystroke on the machine was being logged by the fn key event tap, triggering expensive log writes and SwiftUI re-renders in the debug log window

## [v1.0.5] - 2026-03-09

### Fixed
- The dictation HUD window was blocking mouse clicks and hover over a large invisible area around the capsule — it now occupies only the space the capsule actually takes up
- Pressing cancel/Escape would cause the HUD to abruptly snap away instead of animating out smoothly

### Added
- In debug mode, the HUD window background turns red to visualize its bounds

## [v1.0.4] - 2026-02-27

### Fixed
- Clicking on anything beneath the hint bubble was blocked — the HUD window was intercepting mouse events even when only the hint text was showing

## [v1.0.3] - 2026-02-27

### Fixed
- A blank window would sometimes appear (or reappear) on startup due to a stale SwiftUI settings scene

## [v1.0.2] - 2026-02-27

### Fixed
- Transcribing long recordings (>30 seconds) was extremely slow. Transcription time now scales linearly with audio length.

## [v1.0.1] - 2026-02-27

### Changed
- Improved internal transcription timing logs to help diagnose slow transcription

## [v1.0.0] - 2026-02-27

Initial release.
