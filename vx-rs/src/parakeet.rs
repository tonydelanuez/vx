//! Local Parakeet TDT inference. The native runtime is linked statically so the
//! packaged backend needs no Python installation or external ONNX Runtime dylib.
use std::{error::Error, path::Path};

use sherpa_onnx::{OfflineRecognizer, OfflineRecognizerConfig, OfflineTransducerModelConfig};

pub const REQUIRED_FILES: [&str; 4] = [
    "encoder.int8.onnx",
    "decoder.int8.onnx",
    "joiner.int8.onnx",
    "tokens.txt",
];

pub struct Parakeet(OfflineRecognizer);

impl Parakeet {
    pub fn load(directory: &Path, threads: usize) -> Result<Self, Box<dyn Error>> {
        for name in REQUIRED_FILES {
            let path = directory.join(name);
            if !path.is_file() || path.metadata()?.len() == 0 {
                return Err(format!(
                    "Parakeet model is incomplete: {} is missing or empty",
                    path.display()
                )
                .into());
            }
        }
        let file = |name: &str| Some(directory.join(name).to_string_lossy().into_owned());
        let mut config = OfflineRecognizerConfig::default();
        config.model_config.transducer = OfflineTransducerModelConfig {
            encoder: file(REQUIRED_FILES[0]),
            decoder: file(REQUIRED_FILES[1]),
            joiner: file(REQUIRED_FILES[2]),
        };
        config.model_config.tokens = file("tokens.txt");
        config.model_config.model_type = Some("nemo_transducer".into());
        config.model_config.provider = Some("cpu".into());
        config.model_config.num_threads = threads.clamp(1, i32::MAX as usize) as i32;
        config.decoding_method = Some("greedy_search".into());
        OfflineRecognizer::create(&config).map(Self).ok_or_else(|| {
            format!("Failed to load Parakeet model at {}", directory.display()).into()
        })
    }

    pub fn transcribe(&self, audio: &[f32]) -> Result<String, Box<dyn Error>> {
        if audio.len() < super::MIN_TRANSCRIBE_SAMPLES
            || super::AudioActivity::measure(audio).is_digital_silence()
        {
            return Ok(String::new());
        }
        let stream = self.0.create_stream();
        stream.accept_waveform(super::TARGET_SAMPLE_RATE as i32, audio);
        self.0.decode(&stream);
        let result = stream
            .get_result()
            .ok_or("Parakeet returned no recognition result")?;
        // Keep the one-line stdout protocol used by Swift and Go Mode.
        Ok(result.text.split_whitespace().collect::<Vec<_>>().join(" "))
    }
}
