//! Recorded-audio contracts for both models offered by the app's Parakeet picker.
mod common;

use common::*;
use std::path::PathBuf;
use std::process::{Command, Stdio};

fn model(engine: &str, override_variable: &str) -> Option<PathBuf> {
    let path = std::env::var_os(override_variable)
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            PathBuf::from(env!("CARGO_MANIFEST_DIR")).join(format!(
                "../vx-ui/Resources/Models/sherpa-onnx-nemo-{engine}"
            ))
        });
    if path.join("encoder.int8.onnx").is_file() {
        return Some(path);
    }
    assert_ne!(
        std::env::var("VX_REQUIRE_PARAKEET").as_deref(),
        Ok("1"),
        "{engine} is required but missing at {}. Run Scripts/ensure-parakeet-model.sh v2 and v3",
        path.display()
    );
    eprintln!("SKIP: {engine} model missing at {}", path.display());
    None
}

const MODELS: [(&str, &str); 2] = [
    ("parakeet-tdt-0.6b-v2-int8", "VX_PARAKEET_V2_MODEL_PATH"),
    ("parakeet-tdt-0.6b-v3-int8", "VX_PARAKEET_MODEL_PATH"),
];
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
    let _guard = model_guard();
    for (engine, override_variable) in MODELS {
        let Some(model) = model(engine, override_variable) else {
            continue;
        };
        for name in FIXTURES {
            let output = run_stream(&model, &read_wav_f32(&fixture(name)));
            assert_golden(name, engine, &stdout_text(&output));
        }
    }
}

#[test]
fn parakeet_file_and_stream_agree() {
    let _guard = model_guard();
    for (engine, override_variable) in MODELS {
        let Some(model) = model(engine, override_variable) else {
            continue;
        };
        for name in ["short-phrase", "long-60s"] {
            let wav = fixture(name);
            let from_file = stdout_text(&run_file(&model, &wav));
            let from_stream = stdout_text(&run_stream(&model, &read_wav_f32(&wav)));
            assert_golden(name, engine, &from_file);
            assert_eq!(
                normalize(&from_file),
                normalize(&from_stream),
                "{engine}/{name}"
            );
            assert!(
                !from_stream.trim().contains('\n'),
                "stream must emit one line"
            );
        }
    }
}

#[test]
fn parakeet_empty_and_silent_audio_produce_no_text() {
    let _guard = model_guard();
    for (engine, override_variable) in MODELS {
        let Some(model) = model(engine, override_variable) else {
            continue;
        };
        for samples in [vec![], vec![0.0; 5 * 16_000]] {
            assert!(
                stdout_text(&run_stream(&model, &samples)).is_empty(),
                "{engine}"
            );
        }
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
