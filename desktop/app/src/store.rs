//! Everything Mimir keeps on disk: settings, history, the count-only log, and
//! the API keys (in the OS credential store, never in settings.json).

use mimir_core::prompts::CleanupStyle;
use serde::{Deserialize, Serialize};
use std::fs;
use std::io::Write;
use std::path::PathBuf;

/// "Mimir Desktop" on macOS, where the native Mac app already owns "Mimir"
/// (this build runs there only for development).
pub const APP_NAME: &str = if cfg!(target_os = "macos") { "Mimir Desktop" } else { "Mimir" };

pub fn data_dir() -> PathBuf {
    let dir = dirs::data_dir().unwrap_or_else(std::env::temp_dir).join(APP_NAME);
    let _ = fs::create_dir_all(&dir);
    dir
}

pub fn models_dir() -> PathBuf {
    let dir = data_dir().join("models");
    let _ = fs::create_dir_all(&dir);
    dir
}

/// Writes through a temp file and a rename, so a crash never leaves half a file.
fn write_atomic(path: &PathBuf, bytes: &[u8]) -> std::io::Result<()> {
    let temp = path.with_extension("tmp");
    fs::write(&temp, bytes)?;
    fs::rename(&temp, path)
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum HotkeyMode {
    Tap,
    Hold,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Engine {
    Local,
    Groq,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SpeedResult {
    pub model: String,
    /// Wall time to transcribe 30 s of speech.
    pub seconds: f64,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Settings {
    /// Never Ctrl+Alt+…: AltGr on Brazilian keyboards sends that.
    pub shortcut: String,
    pub mode: HotkeyMode,
    pub engine: Engine,
    pub local_model: String,
    /// "auto", or a language code such as "pt" or "en".
    pub language: String,
    pub cleanup: bool,
    pub style: CleanupStyle,
    pub vocabulary: String,
    pub speed: Option<SpeedResult>,
    /// Input device name; None follows the system default.
    pub microphone: Option<String>,
    /// Off: the text only goes to history and the clipboard.
    pub paste: bool,
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            shortcut: "Ctrl+Shift+Space".into(),
            mode: HotkeyMode::Tap,
            engine: Engine::Local,
            local_model: "small".into(),
            language: "auto".into(),
            cleanup: true,
            style: CleanupStyle::CleanDictation,
            vocabulary: String::new(),
            speed: None,
            microphone: None,
            paste: true,
        }
    }
}

impl Settings {
    fn path() -> PathBuf {
        data_dir().join("settings.json")
    }

    pub fn load() -> Self {
        fs::read(Self::path()).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default()
    }

    pub fn save(&self) -> std::io::Result<()> {
        write_atomic(&Self::path(), &serde_json::to_vec_pretty(self).unwrap())
    }
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct HistoryEntry {
    pub id: u64,
    /// RFC 3339, local offset.
    pub at: String,
    pub text: String,
    pub audio_ms: u64,
    pub stt_ms: u64,
    pub polish_ms: u64,
}

pub struct History;

impl History {
    const KEEP: usize = 500;

    fn path() -> PathBuf {
        data_dir().join("history.json")
    }

    pub fn load() -> Vec<HistoryEntry> {
        fs::read(Self::path()).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default()
    }

    pub fn save(entries: &[HistoryEntry]) {
        let _ = write_atomic(&Self::path(), &serde_json::to_vec(entries).unwrap());
    }

    /// Newest first.
    pub fn push(entries: &mut Vec<HistoryEntry>, mut entry: HistoryEntry) {
        entry.id = entries.iter().map(|e| e.id).max().unwrap_or(0) + 1;
        entry.at = chrono::Local::now().to_rfc3339();
        entries.insert(0, entry);
        entries.truncate(Self::KEEP);
        Self::save(entries);
    }
}

/// One line per event, numbers and names only. Never the user's text.
pub fn log(event: &str, fields: &[(&str, serde_json::Value)]) {
    let mut line = serde_json::Map::new();
    line.insert("at".into(), chrono::Local::now().format("%Y-%m-%dT%H:%M:%S").to_string().into());
    line.insert("event".into(), event.into());
    for (key, value) in fields {
        line.insert((*key).into(), value.clone());
    }
    let path = data_dir().join("mimir.log");
    if fs::metadata(&path).map(|m| m.len() > 2_000_000).unwrap_or(false) {
        let _ = fs::rename(&path, data_dir().join("mimir.old.log"));
    }
    if let Ok(mut file) = fs::OpenOptions::new().create(true).append(true).open(path) {
        let _ = writeln!(file, "{}", serde_json::Value::Object(line));
    }
}

#[derive(Clone, Copy, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Secret {
    Anthropic,
    Groq,
}

impl Secret {
    fn entry(self) -> Option<keyring::Entry> {
        let user = match self {
            Secret::Anthropic => "anthropic-api-key",
            Secret::Groq => "groq-api-key",
        };
        keyring::Entry::new(APP_NAME, user).ok()
    }

    /// The stored key; `ANTHROPIC_API_KEY` / `GROQ_API_KEY` as a dev fallback.
    pub fn get(self) -> Option<String> {
        if let Some(value) = self.entry().and_then(|e| e.get_password().ok()).filter(|v| !v.trim().is_empty()) {
            return Some(value);
        }
        let var = match self {
            Secret::Anthropic => "ANTHROPIC_API_KEY",
            Secret::Groq => "GROQ_API_KEY",
        };
        std::env::var(var).ok().filter(|v| !v.trim().is_empty())
    }

    pub fn set(self, value: &str) -> Result<(), String> {
        let entry = self.entry().ok_or("The system key store is unavailable.")?;
        let value = value.trim();
        if value.is_empty() {
            let _ = entry.delete_credential();
            return Ok(());
        }
        entry.set_password(value).map_err(|e| format!("Could not save the key: {e}"))
    }
}
