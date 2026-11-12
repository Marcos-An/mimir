//! stt-bench: how long local Whisper (whisper.cpp) takes on this computer to
//! transcribe 30 seconds of speech, for two model sizes. The answer decides
//! whether Mimir recommends cloud transcription on machines like this one.
//!
//! It downloads a public-domain speech sample (JFK, from the whisper.cpp
//! repository) and the models into a `mimir-bench` folder next to the program.
//! Nothing is recorded and nothing is uploaded.

use std::fs;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::time::Instant;
use whisper_rs::{FullParams, SamplingStrategy, WhisperContext, WhisperContextParameters};

const SAMPLE_URL: &str = "https://raw.githubusercontent.com/ggerganov/whisper.cpp/master/samples/jfk.wav";
const MODELS: [(&str, &str); 2] = [
    ("small (q5_1)", "ggml-small-q5_1.bin"),
    ("large-v3-turbo (q5_0)", "ggml-large-v3-turbo-q5_0.bin"),
];
const MODEL_BASE: &str = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/";
/// whisper.cpp uses the GPU by default when built with a GPU feature.
const BACKEND: &str = if cfg!(feature = "gpu") { "GPU (Vulkan)" } else { "CPU" };
/// Above this, local transcription is "slow": Mimir recommends cloud.
const SLOW_SECONDS_PER_30S: f64 = 10.0;

fn main() {
    if let Err(error) = run() {
        eprintln!("\nstt-bench failed: {error}");
        wait_for_enter();
        std::process::exit(1);
    }
    wait_for_enter();
}

fn wait_for_enter() {
    println!("\nPress Enter to close.");
    let _ = std::io::stdin().read_line(&mut String::new());
}

fn run() -> Result<(), String> {
    let dir = std::env::current_exe()
        .ok()
        .and_then(|p| p.parent().map(Path::to_path_buf))
        .unwrap_or_else(|| PathBuf::from("."))
        .join("mimir-bench");
    fs::create_dir_all(&dir).map_err(|e| e.to_string())?;

    println!("stt-bench {}", env!("CARGO_PKG_VERSION"));
    println!("Backend: {BACKEND}");
    println!("CPU: {}", cpu_name());
    let threads = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(4).min(8);
    println!("Threads used: {threads}\n");

    let sample = download(SAMPLE_URL, &dir.join("jfk.wav"))?;
    let audio = thirty_seconds_of_speech(&sample)?;

    for (label, file) in MODELS {
        let model = download(&format!("{MODEL_BASE}{file}"), &dir.join(file))?;
        let load = Instant::now();
        let context = WhisperContext::new_with_params(model.to_str().unwrap(), WhisperContextParameters::default())
            .map_err(|e| format!("loading {label}: {e}"))?;
        let load_seconds = load.elapsed().as_secs_f64();
        let mut state = context.create_state().map_err(|e| e.to_string())?;
        let mut params = FullParams::new(SamplingStrategy::Greedy { best_of: 1 });
        params.set_language(Some("en"));
        params.set_n_threads(threads as i32);
        params.set_print_progress(false);
        params.set_print_realtime(false);
        params.set_print_timestamps(false);
        let start = Instant::now();
        state.full(params, &audio).map_err(|e| e.to_string())?;
        let seconds = start.elapsed().as_secs_f64();
        let words: usize = (0..state.full_n_segments().unwrap_or(0))
            .filter_map(|i| state.full_get_segment_text_lossy(i).ok())
            .map(|t| t.split_whitespace().count())
            .sum();
        let verdict = if seconds > SLOW_SECONDS_PER_30S { "SLOW: cloud recommended" } else { "OK for local use" };
        println!("RESULT | {BACKEND} | {label} | load {load_seconds:.1} s | 30 s of speech in {seconds:.1} s | {words} words | {verdict}");
    }
    if cfg!(feature = "gpu") {
        println!("\nPlease send the lines that start with RESULT, the CPU line, and any line that starts with ggml_vulkan (it names the video card).");
    } else {
        println!("\nPlease send the lines that start with RESULT, and the CPU line.");
    }
    Ok(())
}

fn cpu_name() -> String {
    if let Ok(name) = std::env::var("PROCESSOR_IDENTIFIER") {
        return name;
    }
    if let Ok(info) = fs::read_to_string("/proc/cpuinfo") {
        if let Some(line) = info.lines().find(|l| l.starts_with("model name")) {
            return line.split(':').nth(1).unwrap_or("").trim().to_string();
        }
    }
    std::env::consts::ARCH.to_string()
}

/// The sample repeated and cut to exactly 30 s at 16 kHz mono: one Whisper
/// window of continuous speech.
fn thirty_seconds_of_speech(path: &Path) -> Result<Vec<f32>, String> {
    let mut reader = hound::WavReader::open(path).map_err(|e| e.to_string())?;
    let spec = reader.spec();
    if spec.sample_rate != 16_000 || spec.channels != 1 {
        return Err("sample is not 16 kHz mono".into());
    }
    let samples: Vec<f32> = reader.samples::<i16>().filter_map(Result::ok).map(|s| s as f32 / 32768.0).collect();
    if samples.is_empty() {
        return Err("sample is empty".into());
    }
    let target = 16_000 * 30;
    Ok(samples.iter().copied().cycle().take(target).collect())
}

fn download(url: &str, path: &Path) -> Result<PathBuf, String> {
    if path.exists() {
        return Ok(path.to_path_buf());
    }
    let name = path.file_name().unwrap().to_string_lossy();
    print!("Downloading {name}…");
    let _ = std::io::stdout().flush();
    let response = ureq::get(url).call().map_err(|e| format!("download {name}: {e}"))?;
    let total: Option<u64> = response.header("content-length").and_then(|v| v.parse().ok());
    let partial = path.with_extension("part");
    let mut file = fs::File::create(&partial).map_err(|e| e.to_string())?;
    let mut reader = response.into_reader();
    let mut buffer = vec![0u8; 1 << 16];
    let (mut done, mut shown) = (0u64, 0u64);
    loop {
        let n = reader.read(&mut buffer).map_err(|e| e.to_string())?;
        if n == 0 {
            break;
        }
        file.write_all(&buffer[..n]).map_err(|e| e.to_string())?;
        done += n as u64;
        if let Some(total) = total {
            let percent = done * 100 / total.max(1);
            if percent >= shown + 10 {
                shown = percent;
                print!(" {percent}%");
                let _ = std::io::stdout().flush();
            }
        }
    }
    println!(" done");
    fs::rename(&partial, path).map_err(|e| e.to_string())?;
    Ok(path.to_path_buf())
}
