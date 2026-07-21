use std::error::Error;
use std::io::{self, Read, Write};
use std::path::PathBuf;
use std::time::Duration;

use clap::{Args, Parser, Subcommand, ValueEnum};
use crossbeam_channel;
use hound::WavReader;
use whisper_rs::{
    FullParams, SamplingStrategy, WhisperContext, WhisperContextParameters, WhisperState,
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
/// The prompt used by released builds before prompt-mode evaluation existed.
const CURRENT_INITIAL_PROMPT: &str = "Transcribe clearly written English with full punctuation, proper capitalization, and line breaks. If the speaker lists multiple items, separate them with commas or the word 'and'.";
/// A deliberately minimal alternative for evaluating whether the longer prompt is helping.
const SHORT_INITIAL_PROMPT: &str = "English transcription with punctuation.";

#[derive(Clone, Copy, Debug, Eq, PartialEq, ValueEnum)]
enum PromptMode {
    /// Preserve the established prompt behavior used by released builds.
    Current,
    /// Use a shorter style hint that has less text available for Whisper to echo.
    Short,
    /// Decode with no initial prompt.
    None,
}

impl PromptMode {
    fn initial_prompt(self) -> &'static str {
        match self {
            Self::Current => CURRENT_INITIAL_PROMPT,
            Self::Short => SHORT_INITIAL_PROMPT,
            // whisper-rs exposes only a string setter; an empty prompt is its
            // no-prompt equivalent.
            Self::None => "",
        }
    }
}

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
    /// Initial-prompt variant. `current` preserves release behavior; `short` and `none` are for evaluation.
    #[arg(long, value_enum, default_value_t = PromptMode::Current)]
    prompt_mode: PromptMode,
    /// Emit per-chunk audio activity metrics to stderr for prompt/VAD evaluation.
    #[arg(long)]
    report_audio_metrics: bool,
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
    /// Initial-prompt variant. `current` preserves release behavior; `short` and `none` are for evaluation.
    #[arg(long, value_enum, default_value_t = PromptMode::Current)]
    prompt_mode: PromptMode,
    /// Emit per-chunk audio activity metrics to stderr for prompt/VAD evaluation.
    #[arg(long)]
    report_audio_metrics: bool,
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
                prompt_mode: args.prompt_mode,
                report_audio_metrics: args.report_audio_metrics,
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
    prompt_mode: PromptMode,
    report_audio_metrics: bool,
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
                prompt_mode: args.prompt_mode,
                report_audio_metrics: args.report_audio_metrics,
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

/// Reassembles little-endian f32 samples across arbitrary stdin read boundaries.
/// A pipe read is not guaranteed to end on a four-byte sample boundary.
struct F32StreamDecoder {
    remainder: Vec<u8>,
}

impl F32StreamDecoder {
    fn new() -> Self {
        Self {
            remainder: Vec::with_capacity(3),
        }
    }

    fn decode(&mut self, bytes: &[u8]) -> Vec<f32> {
        self.remainder.extend_from_slice(bytes);
        let complete = (self.remainder.len() / 4) * 4;
        let mut samples = Vec::with_capacity(complete / 4);
        for chunk in self.remainder[..complete].chunks_exact(4) {
            samples.push(f32::from_le_bytes([chunk[0], chunk[1], chunk[2], chunk[3]]));
        }
        self.remainder.drain(..complete);
        samples
    }

    fn finish(self) -> Result<(), io::Error> {
        if self.remainder.is_empty() {
            Ok(())
        } else {
            Err(io::Error::new(
                io::ErrorKind::UnexpectedEof,
                format!(
                    "stdin ended with {} incomplete byte(s) of a Float32 sample",
                    self.remainder.len()
                ),
            ))
        }
    }
}

impl AudioBuffer {
    fn new(max_samples: usize) -> Self {
        AudioBuffer {
            samples: Vec::new(),
            max_samples,
        }
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

    let parts =
        collect_chunk_transcripts(&audio_data, cfg.inference.report_audio_metrics, |chunk| {
            transcribe(&mut state, &cfg.inference, chunk)
        })?;
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
    // Reads can split one Float32 across calls, so framing is preserved explicitly.
    enum StdinEvent {
        Samples(Vec<f32>),
        End,
        Error(String),
    }
    let (sender, receiver) = crossbeam_channel::unbounded::<StdinEvent>();
    std::thread::spawn(move || {
        let stdin = io::stdin();
        let mut handle = stdin.lock();
        let mut buf = [0u8; 4096];
        let mut decoder = F32StreamDecoder::new();
        loop {
            match handle.read(&mut buf) {
                Ok(0) => {
                    // EOF — reject a malformed trailing sample instead of silently
                    // shifting subsequent audio or accepting a truncated recording.
                    let event = match decoder.finish() {
                        Ok(()) => StdinEvent::End,
                        Err(error) => StdinEvent::Error(error.to_string()),
                    };
                    let _ = sender.send(event);
                    break;
                }
                Ok(n) => {
                    let samples = decoder.decode(&buf[..n]);
                    if !samples.is_empty() {
                        let _ = sender.send(StdinEvent::Samples(samples));
                    }
                }
                Err(error) => {
                    let _ =
                        sender.send(StdinEvent::Error(format!("failed to read stdin: {error}")));
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
            Ok(StdinEvent::Samples(samples)) => {
                session.ingest(&samples);
            }
            Ok(StdinEvent::End) => {
                // EOF from stdin — do final inference and exit.
                break;
            }
            Ok(StdinEvent::Error(message)) => return Err(io::Error::other(message).into()),
            Err(crossbeam_channel::RecvTimeoutError::Timeout) => {}
            Err(_) => break,
        }
    }

    // Final inference on the full buffer — this is the transcript Swift inserts.
    // Whisper's context window is 30 seconds, so we chunk identically to run_file
    // to avoid truncating long recordings. A chunk failure must fail the session:
    // returning a partial transcript silently deletes what the speaker said.
    if session.buffer().len() >= MIN_TRANSCRIBE_SAMPLES {
        let parts = collect_chunk_transcripts(
            session.buffer(),
            cfg.inference.report_audio_metrics,
            |chunk| transcribe(&mut state, &cfg.inference, chunk),
        )?;
        let text = parts.join(" ");
        if !text.is_empty() {
            println!("{}", text);
            io::stdout().flush().ok();
        }
    }

    Ok(())
}

/// Summarized audio activity for one decode chunk. This is deliberately transparent
/// instrumentation, not a claim that RMS alone is a full voice activity detector.
#[derive(Debug, PartialEq)]
struct AudioActivity {
    rms: f32,
    peak: f32,
    active_fraction: f32,
}

impl AudioActivity {
    /// Samples quieter than this are effectively zero in the 16 kHz f32 stream.
    /// The gate is intentionally conservative: it only skips digital/near-digital
    /// silence and never decides whether quiet human speech is present.
    const DIGITAL_SILENCE_PEAK: f32 = 0.0005;
    const ACTIVE_SAMPLE_THRESHOLD: f32 = 0.01;

    fn measure(samples: &[f32]) -> Self {
        if samples.is_empty() {
            return Self {
                rms: 0.0,
                peak: 0.0,
                active_fraction: 0.0,
            };
        }

        let mut sum_squares = 0.0f64;
        let mut peak = 0.0f32;
        let mut active = 0usize;
        for &sample in samples {
            let amplitude = sample.abs();
            sum_squares += f64::from(sample) * f64::from(sample);
            peak = peak.max(amplitude);
            if amplitude >= Self::ACTIVE_SAMPLE_THRESHOLD {
                active += 1;
            }
        }

        Self {
            rms: (sum_squares / samples.len() as f64).sqrt() as f32,
            peak,
            active_fraction: active as f32 / samples.len() as f32,
        }
    }

    fn is_digital_silence(&self) -> bool {
        self.peak <= Self::DIGITAL_SILENCE_PEAK
    }
}

/// Decode every Whisper-sized audio chunk. A chunk error is fatal: partial output
/// is indistinguishable from a user report that vx dropped a sentence.
fn collect_chunk_transcripts<F>(
    audio: &[f32],
    report_audio_metrics: bool,
    mut decode: F,
) -> Result<Vec<String>, Box<dyn Error>>
where
    F: FnMut(&[f32]) -> Result<String, Box<dyn Error>>,
{
    let chunk_count = audio.chunks(CHUNK_SAMPLES).len();
    let mut parts = Vec::new();

    for (index, chunk) in audio.chunks(CHUNK_SAMPLES).enumerate() {
        let activity = AudioActivity::measure(chunk);
        if report_audio_metrics {
            eprintln!(
                "[vx/audio] chunk {}/{}: {:.2}s rms={:.5} peak={:.5} active={:.1}%",
                index + 1,
                chunk_count,
                chunk.len() as f32 / TARGET_SAMPLE_RATE as f32,
                activity.rms,
                activity.peak,
                activity.active_fraction * 100.0,
            );
        }
        if activity.is_digital_silence() {
            if report_audio_metrics {
                eprintln!(
                    "[vx/audio] chunk {}/{} skipped: digital silence",
                    index + 1,
                    chunk_count
                );
            }
            continue;
        }

        let transcript = decode(chunk).map_err(|error| {
            io::Error::other(format!(
                "Whisper failed while decoding chunk {}/{}: {error}",
                index + 1,
                chunk_count
            ))
        })?;
        if let Some(cleaned) = filter_transcript_chunk(&transcript) {
            parts.push(cleaned);
        }
    }

    Ok(parts)
}

/// Removes only output we can identify as non-speech without sacrificing neighboring
/// speech. In particular, prompt echoes are stripped only as a complete trailing
/// suffix; a substring match must never discard a whole 30-second transcript.
fn filter_transcript_chunk(text: &str) -> Option<String> {
    let trimmed = text.trim();
    if !trimmed.chars().any(|c| c.is_alphanumeric()) {
        return None;
    }

    let without_prompt_echo = strip_trailing_prompt_echo(trimmed);
    let normalized = normalize_for_exact_match(&without_prompt_echo);
    if normalized.is_empty() || is_known_pure_hallucination(normalized) {
        return None;
    }
    Some(without_prompt_echo)
}

fn normalize_for_exact_match(text: &str) -> &str {
    text.trim_matches(|c: char| c.is_ascii_punctuation() || c.is_whitespace())
}

fn is_known_pure_hallucination(normalized: &str) -> bool {
    matches!(
        normalized.to_lowercase().as_str(),
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
            | "so we'll see you in the next video, bye"
            | "don't forget to subscribe"
    )
}

fn strip_trailing_prompt_echo(text: &str) -> String {
    // These are full prompt sentences, not short fragments users may naturally say.
    // The second entry covers the malformed echo observed in the v1.0.40 regression.
    const ECHO_SUFFIXES: [&str; 2] = [
        "transcribe clearly written english with full punctuation, proper capitalization, and line breaks. if the speaker lists multiple items, separate them with commas or the word 'and'.",
        "if the speaker lists multiple items, separate them with commas or the word and line breaks, separate them with commas or the word.",
    ];

    // ASCII lowercasing preserves byte positions, so the suffix index can safely
    // slice the original UTF-8 text even when the spoken prefix contains Unicode.
    let lower = text.to_ascii_lowercase();
    for suffix in ECHO_SUFFIXES {
        let suffix = suffix.trim_matches(|c: char| c.is_ascii_punctuation() || c.is_whitespace());
        let candidate =
            lower.trim_end_matches(|c: char| c.is_ascii_punctuation() || c.is_whitespace());
        if candidate.ends_with(suffix) {
            let start = candidate.len() - suffix.len();
            let Some(prefix) = text.get(..start) else {
                return text.to_string();
            };
            // A prompt echo begins a new generated sentence. Do not strip a
            // matching phrase merely because the user naturally ended their
            // own sentence with it (for example, "remember that if the
            // speaker lists multiple items...").
            if !starts_at_sentence_boundary(prefix) {
                continue;
            }
            return prefix
                .trim_end_matches(|c: char| c.is_ascii_punctuation() || c.is_whitespace())
                .to_string();
        }
    }
    text.to_string()
}

fn starts_at_sentence_boundary(prefix: &str) -> bool {
    let trimmed = prefix.trim_end();
    trimmed.is_empty()
        || trimmed
            .chars()
            .last()
            .is_some_and(|character| matches!(character, '.' | '!' | '?' | '\n' | '\r'))
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
    params.set_initial_prompt(settings.prompt_mode.initial_prompt());

    state.full(params, audio)?;

    let segments: usize = state.full_n_segments().try_into().unwrap();
    let mut transcript = String::new();
    for i in 0..segments {
        let segment = state
            .get_segment(i as i32)
            .ok_or("Failed to get segment")?
            .to_str()?
            .to_string();
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

    // ── audio activity and chunk handling ───────────────────────────────────

    #[test]
    fn audio_activity_reports_digital_silence_without_calling_it_voice_activity() {
        let silence = AudioActivity::measure(&[0.0; 320]);
        assert!(silence.is_digital_silence());
        assert_eq!(silence.active_fraction, 0.0);

        let audible = AudioActivity::measure(&[0.02; 320]);
        assert!(!audible.is_digital_silence());
        assert_eq!(audible.active_fraction, 1.0);
    }

    #[test]
    fn digital_silence_does_not_reach_the_decoder() {
        let audio = vec![0.0; MIN_TRANSCRIBE_SAMPLES];
        let mut calls = 0;
        let parts = collect_chunk_transcripts(&audio, false, |_| {
            calls += 1;
            Ok("should not decode".to_string())
        })
        .expect("digital silence should be a successful no-speech result");

        assert!(parts.is_empty());
        assert_eq!(calls, 0);
    }

    #[test]
    fn decode_error_names_the_missing_chunk_instead_of_returning_partial_text() {
        let audio = vec![0.1; CHUNK_SAMPLES + MIN_TRANSCRIBE_SAMPLES];
        let mut calls = 0;
        let error = collect_chunk_transcripts(&audio, false, |_| {
            calls += 1;
            if calls == 1 {
                Ok("first chunk".to_string())
            } else {
                Err(whisper_rs::WhisperError::UnableToCalculateSpectrogram.into())
            }
        })
        .expect_err("a failed second chunk must not silently return the first chunk");

        assert!(error.to_string().contains("chunk 2/2"));
    }

    #[test]
    fn f32_stream_decoder_preserves_samples_across_unaligned_read_boundaries() {
        let expected = [0.25f32, -0.5, 1.0, -0.125];
        let bytes: Vec<u8> = expected
            .iter()
            .flat_map(|sample| sample.to_le_bytes())
            .collect();
        // None of these boundaries except the final one align with a Float32.
        let mut decoder = F32StreamDecoder::new();
        let mut decoded = Vec::new();
        let mut offset = 0;
        for width in [1usize, 2, 5, 3, 5] {
            let end = (offset + width).min(bytes.len());
            decoded.extend(decoder.decode(&bytes[offset..end]));
            offset = end;
            if offset == bytes.len() {
                break;
            }
        }

        assert_eq!(decoded, expected);
        assert!(decoder.finish().is_ok());
    }

    #[test]
    fn f32_stream_decoder_rejects_a_truncated_final_sample() {
        let mut decoder = F32StreamDecoder::new();
        decoder.decode(&[0, 1, 2]);

        assert!(
            decoder
                .finish()
                .unwrap_err()
                .to_string()
                .contains("3 incomplete byte"),
            "the stream must not quietly accept a partial Float32 sample"
        );
    }

    #[test]
    fn prompt_modes_have_stable_distinct_prompts_for_evaluation() {
        assert_eq!(PromptMode::Current.initial_prompt(), CURRENT_INITIAL_PROMPT);
        assert_eq!(PromptMode::Short.initial_prompt(), SHORT_INITIAL_PROMPT);
        assert_eq!(PromptMode::None.initial_prompt(), "");
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
            "If the speaker lists multiple items, separate them with commas or the word and line breaks, separate them with commas or the word.",
        ];
        for phrase in &phrases {
            assert!(
                filter_transcript_chunk(phrase).is_none(),
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
                filter_transcript_chunk(s).is_none(),
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
            "Separate the names with commas when you write it down.",
        ];
        for phrase in &phrases {
            assert!(
                filter_transcript_chunk(phrase).is_some(),
                "Incorrectly flagged as hallucination: {:?}",
                phrase
            );
        }
    }

    #[test]
    fn prompt_echo_suffix_is_stripped_without_discarding_real_speech() {
        let mixed_chunk = "The deployment is ready for review this afternoon. Transcribe clearly written English with full punctuation, proper capitalization, and line breaks. If the speaker lists multiple items, separate them with commas or the word 'and'.";

        assert_eq!(
            filter_transcript_chunk(mixed_chunk),
            Some("The deployment is ready for review this afternoon".to_string())
        );
    }

    #[test]
    fn natural_speech_ending_in_a_prompt_phrase_is_not_stripped() {
        let speech = "Please remember that if the speaker lists multiple items, separate them with commas or the word and line breaks, separate them with commas or the word.";

        assert_eq!(filter_transcript_chunk(speech), Some(speech.to_string()));
    }

    #[test]
    fn pure_prompt_echo_is_dropped() {
        assert_eq!(filter_transcript_chunk(CURRENT_INITIAL_PROMPT), None);
    }

    #[test]
    fn generic_hallucination_phrase_inside_real_speech_is_preserved() {
        let speech = "I want to say thank you to everyone on the team before we close.";
        assert_eq!(filter_transcript_chunk(speech), Some(speech.to_string()));
    }
}
