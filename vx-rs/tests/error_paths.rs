/// Integration tests for error paths: missing model, missing audio, missing stdin.
///
/// These tests verify that vx-rs exits with a non-zero status when given bad
/// inputs, and exits cleanly (zero) when given empty or silent input.
use std::process::Command;

fn vxrs_bin() -> std::path::PathBuf {
    std::path::PathBuf::from(env!("CARGO_BIN_EXE_vx-rs"))
}

fn model_path() -> std::path::PathBuf {
    std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent().unwrap()
        .join("vx-ui/Resources/Models/ggml-tiny.en.bin")
}

#[test]
fn file_mode_missing_model_exits_nonzero() {
    let status = Command::new(vxrs_bin())
        .args(["file", "/nonexistent/model.bin", "/nonexistent/audio.wav"])
        .status()
        .expect("failed to launch vx-rs");
    assert!(!status.success(), "Expected non-zero exit for missing model");
}

#[test]
fn file_mode_missing_audio_exits_nonzero() {
    let model = model_path();
    if !model.exists() {
        eprintln!("SKIP: model not found");
        return;
    }
    let status = Command::new(vxrs_bin())
        .args(["file", model.to_str().unwrap(), "/nonexistent/audio.wav"])
        .status()
        .expect("failed to launch vx-rs");
    assert!(!status.success(), "Expected non-zero exit for missing audio");
}

#[test]
fn stream_mode_missing_model_exits_nonzero() {
    use std::process::Stdio;
    let mut child = Command::new(vxrs_bin())
        .args(["stream", "/nonexistent/model.bin"])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .expect("failed to launch vx-rs");
    let status = child.wait().expect("failed to wait");
    assert!(!status.success(), "Expected non-zero exit for missing model");
}

#[test]
fn stream_mode_empty_stdin_exits_cleanly() {
    use std::process::Stdio;
    let model = model_path();
    if !model.exists() {
        eprintln!("SKIP: model not found");
        return;
    }
    let output = Command::new(vxrs_bin())
        .args(["stream", model.to_str().unwrap()])
        .stdin(Stdio::null())
        .output()
        .expect("failed to launch vx-rs");
    assert!(output.status.success(), "Empty stdin must exit 0");
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(
        stdout.trim().is_empty(),
        "Empty stdin must produce no output, got: {:?}",
        stdout
    );
}

#[test]
fn stream_mode_silence_produces_no_output() {
    use std::io::Write;
    use std::process::Stdio;
    let model = model_path();
    if !model.exists() {
        eprintln!("SKIP: model not found");
        return;
    }
    // 5 seconds of silence at 16 kHz
    let silence: Vec<u8> = vec![0u8; 5 * 16_000 * 4]; // 4 bytes per f32
    let mut child = Command::new(vxrs_bin())
        .args(["stream", model.to_str().unwrap()])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .expect("failed to launch vx-rs");

    child.stdin.as_mut().unwrap().write_all(&silence).ok();
    let output = child.wait_with_output().expect("failed to wait");
    assert!(output.status.success(), "Silence input must exit 0");
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(
        stdout.trim().is_empty(),
        "Silence must produce no transcript output, got: {:?}",
        stdout
    );
}
