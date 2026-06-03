use std::error::Error;
use std::io::{self, Read, Write};
use std::path::PathBuf;
use std::time::Duration;

use clap::{Args, Parser, Subcommand};
use crossbeam_channel;
use hound::WavReader;
use whisper_rs::{
    FullParams, SamplingStrategy, WhisperContext, WhisperContextParameters, WhisperError,
    WhisperState,
};

/// Target Whisper sample rate in hertz.
const TARGET_SAMPLE_RATE: u32 = 16_000;
/// Maximum amount of audio represented by a single inference pass.
const MAX_BUFFER_SECONDS: usize = 30;
/// Maximum number of samples per Whisper inference pass (30 seconds at 16 kHz).
/// Passing more than this to whisper.cpp causes super-linear decode time; chunking keeps each
/// call within the model's native context window.
const CHUNK_SAMPLES: usize = MAX_BUFFER_SECONDS * TARGET_SAMPLE_RATE as usize;
/// Minimum number of samples required before attempting an inference (~500 ms).
const MIN_TRANSCRIBE_SAMPLES: usize = TARGET_SAMPLE_RATE as usize / 2; // ~500ms
/// Default probability threshold used to distinguish speech from silence inside Whisper.
const DEFAULT_NO_SPEECH_THRESHOLD: f32 = 0.6;

/// Returns the default number of inference threads, clamped to at least one.
///
/// On Apple Silicon, whisper.cpp slows down sharply when work spills onto the
/// efficiency cores. Measured tiny.en inference on an M4 Max (12 P + 4 E cores)
/// was ~2x slower at 16 threads (all physical cores, the old default) than at the
/// 12 performance cores. So we target the performance-core count when we can
/// detect it, falling back to the physical core count elsewhere.
fn default_threads() -> usize {
    performance_core_count()
        .unwrap_or_else(num_cpus::get_physical)
        .max(1)
}

/// Number of performance ("P") cores on Apple Silicon, read from the
/// `hw.perflevel0.physicalcpu` sysctl. Returns `None` on non-macOS, or on Macs
/// without a performance/efficiency split (e.g. Intel), where the sysctl is absent.
#[cfg(target_os = "macos")]
fn performance_core_count() -> Option<usize> {
    let mut value: libc::c_uint = 0;
    let mut size = std::mem::size_of::<libc::c_uint>();
    // NUL-terminated sysctl name.
    let name = b"hw.perflevel0.physicalcpu\0";
    // SAFETY: `name` is a valid NUL-terminated C string; `value` and `size` point
    // to a live c_uint and its byte length. sysctlbyname writes at most `size`
    // bytes into `value` and updates `size` with the bytes written.
    let rc = unsafe {
        libc::sysctlbyname(
            name.as_ptr() as *const libc::c_char,
            &mut value as *mut _ as *mut libc::c_void,
            &mut size,
            std::ptr::null_mut(),
            0,
        )
    };
    (rc == 0 && value > 0).then_some(value as usize)
}

#[cfg(not(target_os = "macos"))]
fn performance_core_count() -> Option<usize> {
    None
}

#[derive(Parser, Debug)]
#[command(name = "vx-rs", version, about = "Transcribe audio with whisper.cpp")]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand, Debug)]
enum Command {
    #[command(about = "Transcribe a WAV file from disk")]
    File(FileArgs),
    #[command(about = "Transcribe raw f32 LE audio streamed on stdin (16 kHz mono)")]
    Stream(StreamArgs),
}

#[derive(Args, Debug)]
struct FileArgs {
    /// Path to the GGML model (e.g. ggml-tiny.en.bin)
    #[arg(value_name = "MODEL")]
    model: PathBuf,
    /// Path to a 16 kHz, mono WAV file
    #[arg(value_name = "AUDIO")]
    audio: PathBuf,
    /// Number of inference threads to use
    #[arg(long, default_value_t = default_threads())]
    threads: usize,
    /// Minimum probability for classifying speech vs. silence
    #[arg(long, default_value_t = DEFAULT_NO_SPEECH_THRESHOLD)]
    no_speech_threshold: f32,
}

#[derive(Args, Debug)]
struct StreamArgs {
    /// Path to the GGML model (e.g. ggml-tiny.en.bin)
    #[arg(value_name = "MODEL")]
    model: PathBuf,
    /// Number of inference threads to use
    #[arg(long, default_value_t = default_threads())]
    threads: usize,
    /// Minimum probability for classifying speech vs. silence
    #[arg(long, default_value_t = DEFAULT_NO_SPEECH_THRESHOLD)]
    no_speech_threshold: f32,
}

/// Configuration for streaming stdin transcription.
struct StdinStreamConfig {
    model: PathBuf,
    inference: InferenceSettings,
}

impl From<StreamArgs> for StdinStreamConfig {
    fn from(args: StreamArgs) -> Self {
        StdinStreamConfig {
            model: args.model,
            inference: InferenceSettings {
                threads: args.threads.max(1),
                no_speech_threshold: args.no_speech_threshold.clamp(0.0, 1.0),
            },
        }
    }
}

fn main() -> Result<(), Box<dyn Error>> {
    let cli = Cli::parse();
    match cli.command {
        Command::File(args) => run_file(FileConfig::from(args))?,
        Command::Stream(args) => run_stream(StdinStreamConfig::from(args))?,
    }
    Ok(())
}

/// Shared inference parameters accepted by both file and stream modes.
struct InferenceSettings {
    threads: usize,
    no_speech_threshold: f32,
}

/// Configuration required to run an offline transcription against a WAV file.
struct FileConfig {
    model: PathBuf,
    audio: PathBuf,
    inference: InferenceSettings,
}

impl From<FileArgs> for FileConfig {
    fn from(args: FileArgs) -> Self {
        FileConfig {
            model: args.model,
            audio: args.audio,
            inference: InferenceSettings {
                threads: args.threads.max(1),
                no_speech_threshold: args.no_speech_threshold.clamp(0.0, 1.0),
            },
        }
    }
}

/// Rolling buffer of streamed 16 kHz mono f32 audio. Retains up to `max_samples`,
/// dropping the oldest samples first on overflow. Stream mode passes usize::MAX so
/// the entire recording is kept for the final inference pass.
struct AudioBuffer {
    samples: Vec<f32>,
    max_samples: usize,
}

impl AudioBuffer {
    fn new(max_samples: usize) -> Self {
        AudioBuffer { samples: Vec::new(), max_samples }
    }

    fn ingest(&mut self, chunk: &[f32]) {
        if chunk.is_empty() {
            return;
        }
        self.samples.extend_from_slice(chunk);
        if self.samples.len() > self.max_samples {
            let overflow = self.samples.len() - self.max_samples;
            self.samples.drain(..overflow);
        }
    }

    fn buffer(&self) -> &[f32] {
        &self.samples
    }
}

/// Performs an offline transcription of a single WAV file and prints the full result.
fn run_file(cfg: FileConfig) -> Result<(), Box<dyn Error>> {
    let audio_data = load_mono_audio(&cfg.audio)?;

    let model_path = cfg.model.to_string_lossy().to_string();
    let mut ctx_params = WhisperContextParameters::default();
    ctx_params.use_gpu(true); // Metal GPU on Apple Silicon; whisper.cpp falls back to CPU if unavailable.
    let ctx = WhisperContext::new_with_params(&model_path, ctx_params)
        .map_err(|e| format!("failed to load model {}: {e}", cfg.model.display()))?;
    let mut state = ctx.create_state()?;

    let mut parts: Vec<String> = Vec::new();
    for chunk in audio_data.chunks(CHUNK_SAMPLES) {
        let text = transcribe(&mut state, &cfg.inference, chunk)?;
        let trimmed = text.trim().to_string();
        if !trimmed.is_empty() && !is_silence_hallucination(&trimmed) {
            parts.push(trimmed);
        }
    }
    let transcript = parts.join(" ");
    for line in transcript.lines() {
        println!("{}", line);
    }

    Ok(())
}

/// Reads raw f32 LE samples from stdin, buffers the full recording, and prints the
/// transcript when stdin closes (EOF = recording done).
fn run_stream(cfg: StdinStreamConfig) -> Result<(), Box<dyn Error>> {
    let model_path = cfg.model.to_string_lossy().to_string();
    let mut ctx_params = WhisperContextParameters::default();
    ctx_params.use_gpu(true); // Metal GPU on Apple Silicon; whisper.cpp falls back to CPU if unavailable.
    let ctx = WhisperContext::new_with_params(&model_path, ctx_params)
        .map_err(|e| format!("failed to load model {}: {e}", cfg.model.display()))?;
    let mut state = ctx.create_state()?;

    // Spawn a reader thread that converts stdin bytes → f32 chunks → channel.
    let (sender, receiver) = crossbeam_channel::unbounded::<Option<Vec<f32>>>();
    std::thread::spawn(move || {
        let stdin = io::stdin();
        let mut handle = stdin.lock();
        let mut buf = [0u8; 4096];
        loop {
            match handle.read(&mut buf) {
                Ok(0) => {
                    // EOF — signal done
                    let _ = sender.send(None);
                    break;
                }
                Ok(n) => {
                    // Convert complete f32 values; ignore trailing partial bytes.
                    let complete = (n / 4) * 4;
                    let mut samples = Vec::with_capacity(complete / 4);
                    for chunk in buf[..complete].chunks_exact(4) {
                        samples.push(f32::from_le_bytes([chunk[0], chunk[1], chunk[2], chunk[3]]));
                    }
                    if !samples.is_empty() {
                        let _ = sender.send(Some(samples));
                    }
                }
                Err(_) => {
                    let _ = sender.send(None);
                    break;
                }
            }
        }
    });

    // Buffer the whole recording; the single final inference below produces the
    // transcript. The buffer is unbounded so it holds the complete recording —
    // stdin streaming covers a finite user-initiated recording and must retain
    // every sample so the final transcript is complete.
    let mut session = AudioBuffer::new(usize::MAX);
    loop {
        match receiver.recv_timeout(Duration::from_millis(50)) {
            Ok(Some(samples)) => {
                session.ingest(&samples);
            }
            Ok(None) => {
                // EOF from stdin — do final inference and exit.
                break;
            }
            Err(crossbeam_channel::RecvTimeoutError::Timeout) => {}
            Err(_) => break,
        }
    }

    // Final inference on the full buffer — this is the transcript Swift inserts.
    //
    // Whisper's context window is 30 seconds, so we chunk identically to run_file
    // to avoid truncating long recordings.
    if session.buffer().len() >= MIN_TRANSCRIBE_SAMPLES {
        let mut parts: Vec<String> = Vec::new();
        for chunk in session.buffer().chunks(CHUNK_SAMPLES) {
            match transcribe(&mut state, &cfg.inference, chunk) {
                Ok(transcript) => {
                    let trimmed = transcript.trim().to_string();
                    if !trimmed.is_empty() && !is_silence_hallucination(&trimmed) {
                        parts.push(trimmed);
                    }
                }
                Err(err) => match err.downcast::<WhisperError>() {
                    Ok(_) => {} // ignore spectrogram / model errors on individual chunks
                    Err(other_err) => return Err(other_err),
                },
            }
        }
        let text = parts.join(" ");
        if !text.is_empty() {
            println!("{}", text);
            io::stdout().flush().ok();
        }
    }

    Ok(())
}

/// Returns true if the text is a known Whisper hallucination produced on silent or very short audio.
/// Applied to each final transcript chunk before insertion.
fn is_silence_hallucination(text: &str) -> bool {
    let lower = text.trim().to_lowercase();

    // No letters or digits — a bare dash, "...", music notes, etc. Whisper emits
    // these on near-silent audio; they are never real speech.
    if !lower.chars().any(|c| c.is_alphanumeric()) {
        return true;
    }

    // Strip leading/trailing punctuation for exact-match checks.
    let normalized: &str = lower
        .trim_matches(|c: char| c.is_ascii_punctuation() || c.is_whitespace());

    // Exact matches — short stock phrases Whisper emits on silence.
    if matches!(
        normalized,
        "you"
            | "thank you"
            | "thanks"
            | "thanks for watching"
            | "thank you for watching"
            | "bye"
            | "bye bye"
            | "goodbye"
            | "please subscribe"
            | "subscribe"
            | "like and subscribe"
            | "see you next time"
            | "see you in the next video"
            | "we'll see you in the next video"
            | "i'll see you in the next video"
    ) {
        return true;
    }

    // Substring matches — catch longer variants like "So we'll see you in the next video, bye!"
    // These phrases are distinctive enough that false-positives in genuine dictation are unlikely.
    lower.contains("see you in the next video")
        || lower.contains("don't forget to subscribe")
        || lower.contains("like and subscribe")
}

/// Runs Whisper end-to-end for the supplied audio slice and returns the concatenated transcript.
fn transcribe(
    state: &mut WhisperState,
    settings: &InferenceSettings,
    audio: &[f32],
) -> Result<String, Box<dyn Error>> {
    let mut params = FullParams::new(SamplingStrategy::Greedy { best_of: 5 });
    params.set_n_threads(settings.threads as i32);
    params.set_translate(false);
    params.set_language(Some("en"));
    params.set_print_progress(false);
    params.set_print_special(false);
    params.set_print_realtime(false);
    params.set_no_speech_thold(settings.no_speech_threshold);
    params.set_suppress_blank(true);
    params.set_suppress_nst(true);
    params.set_initial_prompt(
        "Transcribe clearly written English with full punctuation, proper capitalization, and line breaks. \
        If the speaker lists multiple items, separate them with commas or the word 'and'."
    );

    state.full(params, audio)?;

    let segments: usize = state.full_n_segments().try_into().unwrap();
    let mut transcript = String::new();
    for i in 0..segments {
        let segment = state.get_segment(i as i32).ok_or("Failed to get segment")?.to_str()?.to_string();
        if !transcript.is_empty() {
            transcript.push(' ');
        }
        transcript.push_str(segment.trim());
    }

    Ok(transcript)
}

/// Loads a 16 kHz mono f32 buffer from a WAV file, validating the expected format.
fn load_mono_audio(path: &PathBuf) -> Result<Vec<f32>, Box<dyn Error>> {
    let mut reader = WavReader::open(path)
        .map_err(|e| format!("failed to open audio file {}: {e}", path.display()))?;
    let spec = reader.spec();

    if spec.sample_format != hound::SampleFormat::Int || spec.bits_per_sample != 16 {
        return Err(format!(
            "unsupported WAV format: expected 16-bit signed PCM, got {:?} with {} bits",
            spec.sample_format, spec.bits_per_sample
        )
        .into());
    }

    if spec.sample_rate != TARGET_SAMPLE_RATE {
        eprintln!(
            "warning: expected 16 kHz audio, found {} Hz. Results may be degraded.",
            spec.sample_rate
        );
    }

    let channels = spec.channels as usize;
    if channels == 0 {
        return Err("WAV file reports zero channels".into());
    }

    let mut mono = Vec::new();
    mono.reserve(reader.len() as usize / channels);

    let mut frame_acc = 0.0f32;
    let mut samples_in_frame = 0usize;

    for sample in reader.samples::<i16>() {
        let s = sample? as f32 / 32768.0;
        frame_acc += s;
        samples_in_frame += 1;

        if samples_in_frame == channels {
            mono.push(frame_acc / channels as f32);
            frame_acc = 0.0;
            samples_in_frame = 0;
        }
    }

    if samples_in_frame != 0 {
        mono.push(frame_acc / channels as f32);
    }

    Ok(mono)
}

#[cfg(test)]
mod tests {
    use super::*;

    // ── helpers ─────────────────────────────────────────────────────────────

    /// Return a chunk of `seconds` worth of audio at TARGET_SAMPLE_RATE with
    /// every sample set to `value`.
    fn audio_chunk(seconds: f32, value: f32) -> Vec<f32> {
        let n = (seconds * TARGET_SAMPLE_RATE as f32) as usize;
        vec![value; n]
    }

    // ── unit tests: AudioBuffer behaviour ────────────────────────────────────

    /// Regression test for the data-loss bug introduced with streaming.
    ///
    /// In stream mode (max_samples = usize::MAX) the buffer must grow without
    /// bound so that every sample the user speaks is available for the final
    /// inference pass. Before the fix, the buffer used a 30-second rolling
    /// window, silently discarding audio from the beginning of any recording
    /// longer than 30 seconds.
    #[test]
    fn stream_session_retains_all_audio_beyond_30_seconds() {
        let mut session = AudioBuffer::new(usize::MAX);

        // 35 seconds of audio in 500 ms chunks — 5 seconds past the old cap.
        let chunk = audio_chunk(0.5, 0.5);
        let total_chunks = 70usize; // 70 × 0.5 s = 35 s
        for _ in 0..total_chunks {
            session.ingest(&chunk);
        }

        let expected = chunk.len() * total_chunks;
        assert_eq!(
            session.buffer().len(),
            expected,
            "Stream mode must retain all {} samples ({} s); \
             buffer was drained — data loss regression",
            expected,
            expected / TARGET_SAMPLE_RATE as usize
        );
    }

    /// Verify that a configured cap is enforced so the sliding-window behaviour
    /// still works.
    #[test]
    fn audio_buffer_caps_at_configured_limit() {
        let cap = MAX_BUFFER_SECONDS * TARGET_SAMPLE_RATE as usize; // 480_000 samples
        let mut session = AudioBuffer::new(cap);

        // Feed 35 seconds — 5 seconds beyond the 30-second cap.
        let chunk = audio_chunk(0.5, 0.5);
        for _ in 0..70 {
            session.ingest(&chunk);
        }

        assert!(
            session.buffer().len() <= cap,
            "Buffer exceeded cap: {} > {} samples",
            session.buffer().len(),
            cap
        );
    }

    /// When the buffer overflows its cap, the *oldest* samples (front) must be
    /// drained, not the newest. This ensures recent audio is always preserved
    /// in the sliding window.
    #[test]
    fn buffer_cap_drops_oldest_samples_first() {
        // Use a 1-second cap for speed.
        let cap = TARGET_SAMPLE_RATE as usize;
        let mut session = AudioBuffer::new(cap);

        // 0.8 s of "early" audio at 1.0, then 0.8 s of "late" audio at 0.25.
        // Total = 1.6 s > 1 s cap, so 0.6 s of early audio should be drained.
        let early = audio_chunk(0.8, 1.0);
        let late = audio_chunk(0.8, 0.25);
        session.ingest(&early);
        session.ingest(&late);

        let buf = session.buffer();
        assert!(buf.len() <= cap, "Buffer exceeded cap after overflow");

        // The tail of the buffer must be entirely from the late chunk (0.25).
        // If oldest-first draining is broken, some 1.0 values would appear here.
        let tail = &buf[buf.len().saturating_sub(late.len())..];
        assert!(
            tail.iter().all(|&s| (s - 0.25).abs() < 1e-6),
            "Expected tail to contain only late-chunk samples (0.25); \
             oldest samples were not drained from the front"
        );
    }

    /// A cap of zero samples is nonsensical but must not panic.
    #[test]
    fn zero_cap_does_not_panic() {
        let mut session = AudioBuffer::new(0);
        let chunk = audio_chunk(1.0, 0.5);
        session.ingest(&chunk); // must not panic
        assert_eq!(session.buffer().len(), 0);
    }

    // ── hallucination filter ─────────────────────────────────────────────────

    #[test]
    fn hallucination_filter_catches_known_phrases() {
        let phrases = [
            "Thank you",
            "thank you.",
            "Thanks for watching",
            "Thanks for watching!",
            "Thank you for watching.",
            "Bye",
            "bye bye",
            "Please subscribe",
            "Subscribe",
            "Like and subscribe",
            "See you next time",
            "See you in the next video",
            "We'll see you in the next video",
            "So we'll see you in the next video, bye!",
            "Don't forget to subscribe",
            "Like and subscribe!",
        ];
        for phrase in &phrases {
            assert!(
                is_silence_hallucination(phrase),
                "Expected hallucination for: {:?}",
                phrase
            );
        }
    }

    #[test]
    fn hallucination_filter_catches_punctuation_only() {
        // Whisper sometimes emits a bare dash (or other punctuation) on near-silent
        // audio. With nothing but punctuation/whitespace it isn't speech, so it must
        // be filtered rather than pasted as a stray "-".
        let junk = ["-", "--", "...", ".", " - ", "—", "?!"];
        for s in &junk {
            assert!(
                is_silence_hallucination(s),
                "Expected punctuation-only output to be filtered: {:?}",
                s
            );
        }
    }

    #[test]
    fn hallucination_filter_passes_real_speech() {
        let phrases = [
            "Hello, how are you doing today?",
            "Let me open the terminal.",
            "The meeting is at 3pm.",
            "I want to say thank you to everyone on the team.",
        ];
        for phrase in &phrases {
            assert!(
                !is_silence_hallucination(phrase),
                "Incorrectly flagged as hallucination: {:?}",
                phrase
            );
        }
    }
}
