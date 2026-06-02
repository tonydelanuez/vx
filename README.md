# vx

Offline voice-to-text for macOS. Hold a hotkey, speak, and your words are typed
into whatever app is focused. Transcription runs entirely on-device via
whisper.cpp — **no audio ever leaves your machine.**

## Components

- **`vx-ui/`** — SwiftUI menu-bar app (Swift Package Manager, macOS 13+)
- **`vx-rs/`** — Rust CLI backend wrapping whisper.cpp via [`whisper-rs`](https://github.com/tazz4843/whisper-rs), with Metal GPU acceleration on Apple Silicon

The app shells out to the `vx-rs` binary for each transcription, streaming
16 kHz mono audio to it over stdin and reading back the transcript.

## Requirements

- macOS 13 or later (Apple Silicon recommended — the GPU path uses Metal)
- [Xcode](https://developer.apple.com/xcode/) 15+ (the `VXLib` scheme is needed for SwiftUI `#Preview`)
- A [Rust](https://rustup.rs) toolchain (nightly — see `vx-rs/rust-toolchain.toml`)

## Build & run from source

```bash
# 1. Build the Rust backend first (the app looks for it at ../vx-rs/target/release)
cd vx-rs && cargo build --release

# 2. Run the menu-bar app in debug
cd ../vx-ui && swift run vx-ui
```

`ResourceLocator` resolves the backend from the sibling `vx-rs` build when
running from source, so no packaging step is needed for development.

## Whisper models

vx uses GGML-format Whisper models (`.bin`). **Models are not checked into the
repo.** On first launch, download one from **Preferences → Configuration →
Transcription Model**, or drop a `ggml-*.bin` into `vx-ui/Resources/Models/`
(e.g. `ggml-tiny.en.bin`). Downloaded models are stored in
`~/Library/Application Support/vx/Models/`.

| Model | Size    | Notes                                   |
|-------|---------|-----------------------------------------|
| Tiny  | ~78 MB  | Fastest, least accurate                 |
| Base  | ~142 MB | Good balance of speed and accuracy      |
| Small | ~466 MB | Slower, noticeably better accuracy      |

All models come from [ggerganov/whisper.cpp](https://huggingface.co/ggerganov/whisper.cpp)
and run on-device. To add one, append an entry to `WhisperModel.catalog` in
`vx-ui/Sources/WhisperModel.swift`.

## How it works

1. A global hotkey starts recording; audio is captured at 16 kHz mono.
2. Frames stream to `vx-rs stream <model>` over stdin.
3. On release, `vx-rs` runs a final Whisper pass and returns the transcript.
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
cd vx-rs && cargo test --bin vx-rs   # Rust unit tests
cd vx-ui && swift build              # Swift build check
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
