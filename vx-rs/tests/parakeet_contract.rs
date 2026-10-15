//! Recorded-audio contracts for the model offered by the app's Parakeet picker.
mod common;

use common::*;
use std::path::PathBuf;
use std::process::{Command, Stdio};

fn model() -> Option<PathBuf> {
    let path = std::env::var_os("VX_PARAKEET_MODEL_PATH")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                .join("../vx-ui/Resources/Models/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8")
        });
    if path.join("encoder.int8.onnx").is_file() {
        return Some(path);
    }
    assert_ne!(
        std::env::var("VX_REQUIRE_PARAKEET").as_deref(),
        Ok("1"),
        "Parakeet is required but missing at {}. Run Scripts/ensure-parakeet-model.sh",
        path.display()
    );
    eprintln!("SKIP: Parakeet model missing at {}", path.display());
    None
}

const ENGINE: &str = "parakeet-tdt-0.6b-v3-int8";
const FIXTURES: [&str; 7] = [
    "short-phrase",
    "punctuation-numbers",
    "rule-trigger",
    "spoken-submit",
    "two-utterances",
    "long-45s",
    "long-60s",
];

#[test]
fn parakeet_stream_matches_recorded_audio() {
    let Some(model) = model() else { return };
    let _guard = model_guard();
    for name in FIXTURES {
        let output = run_stream(&model, &read_wav_f32(&fixture(name)));
        assert_golden(name, ENGINE, &stdout_text(&output));
    }
}

#[test]
fn parakeet_file_and_stream_agree() {
    let Some(model) = model() else { return };
    let _guard = model_guard();
    for name in ["short-phrase", "long-60s"] {
        let wav = fixture(name);
        let from_file = stdout_text(&run_file(&model, &wav));
        let from_stream = stdout_text(&run_stream(&model, &read_wav_f32(&wav)));
        assert_golden(name, ENGINE, &from_file);
        assert_eq!(normalize(&from_file), normalize(&from_stream));
        assert!(
            !from_stream.trim().contains('\n'),
            "stream must emit one line"
        );
    }
}

#[test]
fn parakeet_empty_and_silent_audio_produce_no_text() {
    let Some(model) = model() else { return };
    let _guard = model_guard();
    for samples in [vec![], vec![0.0; 5 * 16_000]] {
        assert!(stdout_text(&run_stream(&model, &samples)).is_empty());
    }
}

#[test]
fn incomplete_parakeet_directory_fails_clearly() {
    let directory =
        std::env::temp_dir().join(format!("vx-incomplete-parakeet-{}", std::process::id()));
    std::fs::create_dir_all(&directory).unwrap();
    let output = Command::new(vxrs_bin())
        .arg("stream")
        .arg(&directory)
        .stdin(Stdio::null())
        .output()
        .unwrap();
    std::fs::remove_dir(&directory).unwrap();
    assert!(!output.status.success());
    assert!(String::from_utf8_lossy(&output.stderr).contains("Parakeet model is incomplete"));
}
