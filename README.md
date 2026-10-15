# vx

Offline voice-to-text for macOS. Hold a hotkey, speak, and your words are typed
into whatever app is focused. Transcription runs entirely on-device via
Whisper or Parakeet. Speech inference stays on your machine.

## Components

- **`vx-ui/`** — SwiftUI menu-bar app (Swift Package Manager, macOS 13+)
- **`vx-rs/`** — Rust CLI backend wrapping whisper.cpp via [`whisper-rs`](https://github.com/tazz4843/whisper-rs), with Metal GPU acceleration on Apple Silicon, plus Parakeet through statically linked sherpa-onnx

The app shells out to the `vx-rs` binary for each transcription, streaming
16 kHz mono audio to it over stdin and reading back the transcript.

## Requirements

- macOS 13 or later (Apple Silicon recommended — the GPU path uses Metal)
- [Xcode](https://developer.apple.com/xcode/) 15+ (the `VXLib` scheme is needed for SwiftUI `#Preview`)
- A [Rust](https://rustup.rs) toolchain (Rust 1.88 or later; nightly, see `vx-rs/rust-toolchain.toml`)

## Build & run from source

```bash
# 1. Build the Rust backend first (the app looks for it at ../vx-rs/target/release)
cd vx-rs && cargo build --release

# 2. Run the menu-bar app in debug
cd ../vx-ui && swift run vx-ui
```

`ResourceLocator` resolves the backend from the sibling `vx-rs` build when
running from source, so no packaging step is needed for development.

## Speech models

Choose a model in **Preferences → Configuration → Transcription Model**.
Download it, then select its row. Existing Whisper selections remain valid.
Downloads go to `~/Library/Application Support/vx/Models/`.

| Model | Download | Engine |
|-------|----------|--------|
| Whisper Tiny | ~78 MB | Whisper, English |
| Whisper Base | ~142 MB | Whisper, English |
| Whisper Small | ~466 MB | Whisper, English |
| Parakeet v3 | ~487 MB | Parakeet TDT 0.6b v3 INT8, 25 languages |

Whisper uses GGML `.bin` files from
[ggerganov/whisper.cpp](https://huggingface.co/ggerganov/whisper.cpp).
Parakeet uses an ONNX directory from
[sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx/releases/tag/asr-models).
The app checks its pinned SHA-256 before extraction and makes it selectable
only after all four required files are present. Parakeet runs on the CPU.
It needs no Python installation or external ONNX Runtime library.

The catalogue lives in `vx-ui/Sources/SpeechModel.swift`. Models are not
checked into Git. Packaging includes Whisper models from Resources and leaves
Parakeet as an optional download. For local verification, run
`Scripts/ensure-model.sh` and `Scripts/ensure-parakeet-model.sh` from this directory.

The [NVIDIA model](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3)
uses [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
See `vx-ui/Resources/Licenses/` for attribution and runtime license texts.

## How it works

1. A global hotkey starts recording; audio is captured at 16 kHz mono.
2. Frames stream to `vx-rs stream <model>` over stdin.
3. On release, `vx-rs` runs the selected speech engine and returns the transcript.
4. Optional rule substitutions and AI cleanup are applied, then the text is
   pasted into the focused app.

The backend has two subcommands: `file <model> <audio.wav>` for batch
transcription and `stream <model>` for the stdin streaming path the app uses.

## Architecture notes

`vx-ui` is a two-target Swift package:

- **VXLib** — a dynamic library holding all views, models, and logic (this is
  the target that enables Xcode Previews; select the **VXLib** scheme).
- **vx-ui** — a thin executable entry point that imports VXLib.

## Testing

```bash
# From the parent vx workspace, run both engines with recorded audio.
./Scripts/verify.sh voice

# Or run quick tests from this repository:
cd vx-rs && cargo test
cd ../vx-ui && swift test
```

## Verify release signatures

Each release artifact is signed with [minisign](https://jedisct1.github.io/minisign/).
A detached `vx.zip.minisig` is published next to `vx.zip` on every release. To
verify a download independently:

```bash
minisign -Vm vx.zip -P RWQn1pVfmKzclqRWukQ62JMfw+Z/0QGe3IVXWKHx623s7F25aRBa2F5P
```

Separately, the app verifies every auto-update against an Ed25519 key built into
the binary before installing it, so a tampered or spoofed download is refused
even if the release host is compromised.

## License

[MIT](LICENSE).
