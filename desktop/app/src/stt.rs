//! Speech to text: local whisper.cpp or Groq's hosted Whisper, chosen by the
//! user. Local models download once into the data folder, checked against a
//! pinned SHA-256.

use crate::store::{models_dir, Engine, Settings};
use sha2::{Digest, Sha256};
use std::io::{Read, Write};
use std::path::PathBuf;
use std::sync::Mutex;
use std::time::{Duration, Instant};
use whisper_rs::{FullParams, SamplingStrategy, WhisperContext, WhisperContextParameters};

pub struct Model {
    pub id: &'static str,
    pub label: &'static str,
    file: &'static str,
    pub bytes: u64,
    sha256: &'static str,
}

/// Sizes and hashes from huggingface.co/ggerganov/whisper.cpp (LFS metadata).
pub const MODELS: [Model; 3] = [
    Model {
        id: "base",
        label: "Base (74M, fast, ok quality)",
        file: "ggml-base-q5_1.bin",
        bytes: 59_707_625,
        sha256: "422f1ae452ade6f30a004d7e5c6a43195e4433bc370bf23fac9cc591f01a8898",
    },
    Model {
        id: "small",
        label: "Small (244M, balanced)",
        file: "ggml-small-q5_1.bin",
        bytes: 190_085_487,
        sha256: "ae85e4a935d7a567bd102fe55afc16bb595bdb618e11b2fc7591bc08120411bb",
    },
    Model {
        id: "turbo",
        label: "Large v3 Turbo (~570MB, fast on a good PC, best quality)",
        file: "ggml-large-v3-turbo-q5_0.bin",
        bytes: 574_041_195,
        sha256: "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2",
    },
];

const MODEL_BASE: &str = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/";
const GROQ_URL: &str = "https://api.groq.com/openai/v1/audio/transcriptions";
pub const GROQ_MODEL: &str = "whisper-large-v3-turbo";
/// Above this, local transcription counts as slow and Mimir recommends cloud.
pub const SLOW_SECONDS_PER_30S: f64 = 10.0;

pub fn model(id: &str) -> Option<&'static Model> {
    MODELS.iter().find(|m| m.id == id)
}

impl Model {
    pub fn path(&self) -> PathBuf {
        models_dir().join(self.file)
    }

    pub fn is_downloaded(&self) -> bool {
        std::fs::metadata(self.path()).map(|m| m.len() == self.bytes).unwrap_or(false)
    }

    /// Downloads to a `.part` file, checks the hash, then renames.
    pub fn download(&self, progress: impl Fn(u64, u64)) -> Result<(), String> {
        if self.is_downloaded() {
            return Ok(());
        }
        let response = reqwest::blocking::Client::builder()
            .timeout(None)
            .connect_timeout(Duration::from_secs(15))
            .build()
            .map_err(|e| e.to_string())?
            .get(format!("{MODEL_BASE}{}", self.file))
            .send()
            .and_then(|r| r.error_for_status())
            .map_err(|e| format!("Download failed: {e}"))?;
        let partial = self.path().with_extension("part");
        let mut file = std::fs::File::create(&partial).map_err(|e| e.to_string())?;
        let mut reader = response;
        let mut hasher = Sha256::new();
        let mut buffer = vec![0u8; 1 << 16];
        let mut done = 0u64;
        let mut last_report = Instant::now();
        loop {
            let n = reader.read(&mut buffer).map_err(|e| format!("Download failed: {e}"))?;
            if n == 0 {
                break;
            }
            hasher.update(&buffer[..n]);
            file.write_all(&buffer[..n]).map_err(|e| e.to_string())?;
            done += n as u64;
            if last_report.elapsed() > Duration::from_millis(200) {
                progress(done, self.bytes);
                last_report = Instant::now();
            }
        }
        drop(file);
        let digest: String = hasher.finalize().iter().map(|b| format!("{b:02x}")).collect();
        if digest != self.sha256 {
            let _ = std::fs::remove_file(&partial);
            return Err("The downloaded model is damaged. Try again.".into());
        }
        progress(self.bytes, self.bytes);
        std::fs::rename(&partial, self.path()).map_err(|e| e.to_string())
    }
}

/// The loaded whisper.cpp model, kept between dictations.
static LOADED: Mutex<Option<(&'static str, WhisperContext)>> = Mutex::new(None);

pub fn preload_local(id: &str) -> Result<(), String> {
    let model = model(id).ok_or("Unknown model.")?;
    let mut loaded = LOADED.lock().unwrap();
    if loaded.as_ref().is_some_and(|(loaded_id, _)| *loaded_id == model.id) {
        return Ok(());
    }
    if !model.is_downloaded() {
        return Err("The speech model is not downloaded yet. Open Settings to download it.".into());
    }
    let context = WhisperContext::new_with_params(model.path().to_str().unwrap(), WhisperContextParameters::default())
        .map_err(|e| format!("Could not load the speech model: {e}"))?;
    *loaded = Some((model.id, context));
    Ok(())
}

pub fn transcribe_local(id: &str, audio: &[f32], language: &str, prompt: &str) -> Result<String, String> {
    preload_local(id)?;
    let loaded = LOADED.lock().unwrap();
    let (_, context) = loaded.as_ref().unwrap();
    let mut state = context.create_state().map_err(|e| e.to_string())?;
    let mut params = FullParams::new(SamplingStrategy::Greedy { best_of: 1 });
    params.set_language(Some(language));
    params.set_n_threads(std::thread::available_parallelism().map(|n| n.get()).unwrap_or(4).min(8) as i32);
    params.set_print_progress(false);
    params.set_print_realtime(false);
    params.set_print_timestamps(false);
    params.set_print_special(false);
    params.set_suppress_blank(true);
    if !prompt.is_empty() {
        params.set_initial_prompt(prompt);
    }
    state.full(params, audio).map_err(|e| format!("Transcription failed: {e}"))?;
    let text: String = (0..state.full_n_segments().unwrap_or(0))
        .filter_map(|i| state.full_get_segment_text_lossy(i).ok())
        .collect();
    Ok(text.trim().to_string())
}

pub fn transcribe_groq(wav: Vec<u8>, language: &str, prompt: &str, key: &str) -> Result<String, String> {
    use reqwest::blocking::multipart::{Form, Part};
    let mut form = Form::new()
        .text("model", GROQ_MODEL)
        .text("response_format", "json")
        .part("file", Part::bytes(wav).file_name("audio.wav").mime_str("audio/wav").unwrap());
    if language != "auto" {
        form = form.text("language", language.to_string());
    }
    if !prompt.is_empty() {
        form = form.text("prompt", prompt.to_string());
    }
    let response = reqwest::blocking::Client::builder()
        .timeout(Duration::from_secs(60))
        .build()
        .map_err(|e| e.to_string())?
        .post(GROQ_URL)
        .bearer_auth(key)
        .multipart(form)
        .send()
        .map_err(|e| format!("Groq is unreachable: {e}"))?;
    let status = response.status();
    let body: serde_json::Value = response.json().unwrap_or_default();
    if !status.is_success() {
        return Err(match status.as_u16() {
            401 => "Groq rejected the API key. Check it in Settings.".into(),
            429 => "Groq's free limit was reached. Try again in a minute.".into(),
            code => format!("Groq error {code}."),
        });
    }
    Ok(body.get("text").and_then(|t| t.as_str()).unwrap_or_default().trim().to_string())
}

/// The vocabulary, as Whisper's initial prompt (spelling hints).
pub fn vocabulary_prompt(settings: &Settings) -> String {
    mimir_core::prompts::vocabulary_terms(&settings.vocabulary).join(", ")
}

pub fn transcribe(settings: &Settings, audio: &[f32]) -> Result<String, String> {
    let prompt = vocabulary_prompt(settings);
    match settings.engine {
        Engine::Local => transcribe_local(&settings.local_model, audio, &settings.language, &prompt),
        Engine::Groq => {
            let key = crate::store::Secret::Groq.get().ok_or("Add your Groq API key in Settings, or switch to local transcription.")?;
            transcribe_groq(crate::audio::wav_bytes(audio), &settings.language, &prompt, &key)
        }
    }
}

const SPEED_CLIP: &[u8] = include_bytes!("../../../shared/audio/jfk.wav");

/// The clip (JFK, public domain, 16 kHz mono) at its own length.
pub fn speed_clip() -> Vec<f32> {
    let mut reader = hound::WavReader::new(std::io::Cursor::new(SPEED_CLIP)).expect("bundled clip");
    reader.samples::<i16>().filter_map(Result::ok).map(|s| s as f32 / 32768.0).collect()
}

/// Seconds the local model takes for 30 s of speech (model already loaded).
pub fn speed_test(id: &str) -> Result<f64, String> {
    let audio: Vec<f32> = speed_clip().into_iter().cycle().take(crate::audio::RATE as usize * 30).collect();
    preload_local(id)?;
    let start = Instant::now();
    transcribe_local(id, &audio, "en", "")?;
    Ok(start.elapsed().as_secs_f64())
}
