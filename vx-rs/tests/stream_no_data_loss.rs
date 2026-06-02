/// Integration test: stream mode must not lose audio from the beginning of
/// long recordings.
///
/// The bug this guards against: the stream buffer was once capped at a 30-second
/// rolling window, which silently drained the oldest samples — so recordings
/// longer than 30 seconds lost everything spoken before `(duration − 30 s)`.
/// Stream mode now retains the entire recording (AudioBuffer with no cap).
///
/// This test feeds a ~117-second WAV into `vx-rs stream` and asserts that words
/// from both the beginning AND the end of the recording appear in the transcript.
/// Without the fix, only the last 30 seconds would survive, so the opening lines
/// would be absent.
///
/// Requires: test_sarahs_gone.wav (117 s) and the tiny.en model in their normal
/// repo locations. The test skips gracefully if either file is missing (e.g. in CI).
/// On Apple Silicon the full inference completes in ~2-3 seconds.
/// Run explicitly with:
///   cargo test --test stream_no_data_loss -- --include-ignored
use std::io::Write;
use std::path::PathBuf;
use std::process::{Command, Stdio};

fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("CARGO_MANIFEST_DIR has no parent")
        .to_path_buf()
}

/// Convert a WAV file to raw f32 LE 16 kHz mono using afconvert (ships with macOS).
///
/// `afconvert -f raw` is broken on some macOS versions for WAV inputs (returns 'typ?').
/// Workaround: convert to an intermediate Float32 WAVE file, then extract the raw
/// PCM bytes by parsing the RIFF/WAVE data chunk.
///
/// Returns the raw bytes, or None if afconvert is unavailable or conversion fails.
fn convert_to_raw_f32(wav_path: &PathBuf) -> Option<Vec<u8>> {
    let tmp_wav = std::env::temp_dir().join("vx_test_stream_input_f32.wav");

    // Step 1: resample + downmix to a Float32 16 kHz mono WAVE file (always works).
    let status = Command::new("afconvert")
        .args([
            "-f", "WAVE",
            "-d", "LEF32@16000",
            "-c", "1",
            wav_path.to_str()?,
            tmp_wav.to_str()?,
        ])
        .status()
        .ok()?;

    if !status.success() {
        return None;
    }

    // Step 2: read the WAVE file and extract the raw PCM from the 'data' chunk.
    let wav_bytes = std::fs::read(&tmp_wav).ok();
    std::fs::remove_file(&tmp_wav).ok();
    let wav_bytes = wav_bytes?;

    extract_wav_data_chunk(&wav_bytes)
}

/// Parse a RIFF/WAVE file and return the raw bytes of the first 'data' chunk.
fn extract_wav_data_chunk(wav: &[u8]) -> Option<Vec<u8>> {
    if wav.len() < 12 || &wav[0..4] != b"RIFF" || &wav[8..12] != b"WAVE" {
        return None;
    }
    let mut i = 12usize;
    while i + 8 <= wav.len() {
        let chunk_id = &wav[i..i + 4];
        let chunk_size = u32::from_le_bytes(wav[i + 4..i + 8].try_into().ok()?) as usize;
        if chunk_id == b"data" {
            let start = i + 8;
            let end = start.saturating_add(chunk_size).min(wav.len());
            return Some(wav[start..end].to_vec());
        }
        i += 8 + chunk_size;
        // Chunks are word-aligned.
        if chunk_size % 2 != 0 {
            i += 1;
        }
    }
    None
}

#[test]
#[ignore = "slow (~2 min); requires test_sarahs_gone.wav and ggml-tiny.en.bin. \
            Run with: cargo test --test stream_no_data_loss -- --include-ignored"]
fn stream_mode_preserves_beginning_of_long_recording() {
    let root = repo_root();
    let wav_path = root.join("test_sarahs_gone.wav");
    let model_path = root.join("vx-ui/Resources/Models/ggml-tiny.en.bin");
    let bin_path = PathBuf::from(env!("CARGO_BIN_EXE_vx-rs"));

    // Skip rather than fail if fixtures are absent (e.g. in CI without LFS).
    if !wav_path.exists() {
        eprintln!("SKIP: {} not found", wav_path.display());
        return;
    }
    if !model_path.exists() {
        eprintln!("SKIP: {} not found", model_path.display());
        return;
    }

    // Convert the WAV to raw f32 16 kHz mono — the format vx-rs stream expects.
    let raw_audio = match convert_to_raw_f32(&wav_path) {
        Some(b) => b,
        None => {
            eprintln!("SKIP: afconvert not available or conversion failed");
            return;
        }
    };

    // The recording is ~117 seconds. Without the fix the buffer cap (30 s) would
    // discard the first ~87 seconds, so words appearing in the first 30 seconds
    // would be absent from the transcript.
    let mut child = Command::new(&bin_path)
        .args(["stream", model_path.to_str().unwrap()])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .expect("Failed to spawn vx-rs");

    child
        .stdin
        .take()
        .unwrap()
        .write_all(&raw_audio)
        .expect("Failed to write audio to vx-rs stdin");

    let output = child.wait_with_output().expect("Failed to wait for vx-rs");
    assert!(
        output.status.success(),
        "vx-rs stream exited with error: {:?}",
        output.status
    );

    let transcript = String::from_utf8_lossy(&output.stdout).to_lowercase();

    // Words from the opening lines of the poem (within the first ~15 seconds).
    // If the buffer cap bug is present these will be missing.
    let has_opening = ["sarah", "house", "walls", "light", "strange"]
        .iter()
        .any(|w| transcript.contains(w));

    // Words from the closing lines (last 30 seconds — always present even with the bug).
    let has_closing = ["fifty", "earth", "sun", "worlds", "scrubbing"]
        .iter()
        .any(|w| transcript.contains(w));

    assert!(
        has_opening,
        "Transcript is missing words from the first 30 seconds of a 117-second recording.\n\
         This is the buffer-cap data-loss regression: oldest audio is being dropped.\n\
         Transcript:\n{}",
        transcript
    );

    assert!(
        has_closing,
        "Transcript is missing words from the end of the recording.\n\
         Transcript:\n{}",
        transcript
    );
}
