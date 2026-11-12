//! One dictation, start to paste: record → transcribe → filter → Claude →
//! rule cleanup → paste → history. The phase is shown in the panel and tray.

use crate::audio::{self, Recorder};
use crate::store::{self, Engine, History, HistoryEntry, Secret, Settings};
use crate::{paste, polish, stt};
use mimir_core::{cleaner, transcript};
use serde::Serialize;
use serde_json::json;
use std::sync::atomic::Ordering;
use std::sync::Mutex;
use std::time::Instant;
use tauri::{AppHandle, Emitter, Manager};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Phase {
    Idle,
    Recording,
    Transcribing,
    Polishing,
    Pasting,
}

impl Phase {
    pub fn title(self) -> &'static str {
        match self {
            Phase::Idle => "Ready",
            Phase::Recording => "Recording…",
            Phase::Transcribing => "Transcribing…",
            Phase::Polishing => "Polishing…",
            Phase::Pasting => "Pasting…",
        }
    }
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Snapshot {
    pub phase: Phase,
    pub title: &'static str,
    pub error: Option<String>,
    pub history: Vec<HistoryEntry>,
    pub out_of_credits: bool,
    pub shortcut: String,
    pub mode: crate::store::HotkeyMode,
    pub download: Option<Download>,
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Download {
    pub id: String,
    pub done: u64,
    pub total: u64,
}

pub struct Controller {
    pub settings: Mutex<Settings>,
    inner: Mutex<Inner>,
}

struct Inner {
    phase: Phase,
    recorder: Option<Recorder>,
    started: Option<Instant>,
    error: Option<String>,
    history: Vec<HistoryEntry>,
    download: Option<Download>,
}

impl Controller {
    pub fn new() -> Self {
        Self {
            settings: Mutex::new(Settings::load()),
            inner: Mutex::new(Inner { phase: Phase::Idle, recorder: None, started: None, error: None, history: History::load(), download: None }),
        }
    }

    pub fn snapshot(&self) -> Snapshot {
        let inner = self.inner.lock().unwrap();
        let settings = self.settings.lock().unwrap();
        Snapshot {
            mode: settings.mode,
            download: inner.download.clone(),
            phase: inner.phase,
            title: inner.phase.title(),
            error: inner.error.clone(),
            history: inner.history.iter().take(4).cloned().collect(),
            out_of_credits: polish::OUT_OF_CREDITS.load(Ordering::Relaxed),
            shortcut: settings.shortcut.clone(),
        }
    }

    pub fn history(&self) -> Vec<HistoryEntry> {
        self.inner.lock().unwrap().history.clone()
    }

    pub fn edit_history(&self, app: &AppHandle, edit: impl FnOnce(&mut Vec<HistoryEntry>)) -> Vec<HistoryEntry> {
        let entries = {
            let mut inner = self.inner.lock().unwrap();
            edit(&mut inner.history);
            History::save(&inner.history);
            inner.history.clone()
        };
        let _ = app.emit("history", &entries);
        self.publish(app);
        entries
    }

    pub fn set_download(&self, app: &AppHandle, download: Option<Download>) {
        self.inner.lock().unwrap().download = download.clone();
        let _ = app.emit("download", &download);
        self.publish(app);
    }

    pub fn phase(&self) -> Phase {
        self.inner.lock().unwrap().phase
    }

    fn set_phase(&self, app: &AppHandle, phase: Phase) {
        self.inner.lock().unwrap().phase = phase;
        crate::shell::phase_changed(app, phase);
        self.publish(app);
    }

    pub fn publish(&self, app: &AppHandle) {
        let _ = app.emit("state", self.snapshot());
    }

    fn fail(&self, app: &AppHandle, message: String) {
        {
            let mut inner = self.inner.lock().unwrap();
            inner.error = Some(message.clone());
            inner.phase = Phase::Idle;
        }
        crate::shell::phase_changed(app, Phase::Idle);
        self.publish(app);
        notice(app, "error", &message);
    }

    pub fn start(&self, app: &AppHandle) {
        if self.phase() != Phase::Idle {
            return;
        }
        let settings = self.settings.lock().unwrap().clone();
        // Hide the panel so the paste lands in the app the user was in.
        if let Some(panel) = app.get_webview_window("panel") {
            let _ = panel.hide();
        }
        let level_app = app.clone();
        match Recorder::start(settings.microphone.clone(), move |level| {
            let _ = level_app.emit_to("island", "level", level);
        }) {
            Ok(recorder) => {
                let mut inner = self.inner.lock().unwrap();
                inner.recorder = Some(recorder);
                inner.started = Some(Instant::now());
                inner.error = None;
            }
            Err(message) => return self.fail(app, message),
        }
        self.set_phase(app, Phase::Recording);
        if settings.cleanup && Secret::Anthropic.get().is_some() {
            polish::warm_up();
        }
        if settings.engine == Engine::Local {
            let id = settings.local_model.clone();
            std::thread::spawn(move || stt::preload_local(&id));
        }
    }

    pub fn cancel(&self, app: &AppHandle) {
        let recorder = {
            let mut inner = self.inner.lock().unwrap();
            if inner.phase != Phase::Recording || inner.recorder.is_none() {
                return;
            }
            inner.phase = Phase::Idle;
            inner.recorder.take()
        };
        if let Some(recorder) = recorder {
            std::thread::spawn(move || drop(recorder.finish()));
        }
        store::log("cancelled", &[]);
        self.set_phase(app, Phase::Idle);
    }

    pub fn stop(&'static self, app: &AppHandle) {
        let (recorder, started) = {
            let mut inner = self.inner.lock().unwrap();
            if inner.phase != Phase::Recording || inner.recorder.is_none() {
                return;
            }
            // Leave Recording under the same lock, so an Esc arriving now
            // finds nothing to cancel instead of cancelling a paste.
            inner.phase = Phase::Transcribing;
            (inner.recorder.take(), inner.started.take())
        };
        let Some(recorder) = recorder else { return };
        crate::shell::phase_changed(app, Phase::Transcribing);
        self.publish(app);
        let app = app.clone();
        std::thread::spawn(move || {
            let result = self.finish(&app, recorder, started);
            match result {
                Ok(()) => self.set_phase(&app, Phase::Idle),
                Err(message) => self.fail(&app, message),
            }
        });
    }

    fn finish(&self, app: &AppHandle, recorder: Recorder, started: Option<Instant>) -> Result<(), String> {
        let settings = self.settings.lock().unwrap().clone();
        let samples = recorder.finish()?;
        let audio_ms = samples.len() as u64 * 1000 / audio::RATE as u64;
        let held_ms = started.map(|s| s.elapsed().as_millis() as u64).unwrap_or(0);
        if !audio::has_speech(&samples) {
            store::log("no-speech", &[("audioMs", json!(audio_ms))]);
            notice(app, "info", if audio_ms < 400 { "No speech detected" } else { "Audio too quiet — check your microphone" });
            return Ok(());
        }

        let stt_start = Instant::now();
        let raw = stt::transcribe(&settings, &samples)?;
        let stt_ms = stt_start.elapsed().as_millis() as u64;
        let heard = cleaner::strip_mid_text_farewells(&transcript::clean_special_tokens(&raw));
        if heard.is_empty() {
            store::log("no-speech", &[("audioMs", json!(audio_ms)), ("sttMs", json!(stt_ms))]);
            notice(app, "info", "No speech detected");
            return Ok(());
        }

        let mut text = heard.clone();
        let mut polish_ms = 0;
        let mut polish_result = "off";
        if settings.cleanup {
            if let Some(key) = Secret::Anthropic.get() {
                self.set_phase(app, Phase::Polishing);
                let start = Instant::now();
                match polish::polish(&heard, settings.style, &settings.vocabulary, &key) {
                    polish::Outcome::Polished(cleaned) => {
                        text = cleaned;
                        polish_result = "ok";
                    }
                    polish::Outcome::Skipped(reason) => polish_result = reason,
                }
                polish_ms = start.elapsed().as_millis() as u64;
            } else {
                polish_result = "no-key";
            }
        }
        let text = cleaner::clean(&text);

        self.set_phase(app, Phase::Pasting);
        let paste_result = if settings.paste { paste::paste(&text) } else { paste::copy(&text) };
        self.edit_history(app, |entries| {
            History::push(
                entries,
                HistoryEntry { text: text.clone(), audio_ms, stt_ms, polish_ms, ..Default::default() },
            )
        });
        store::log(
            "dictation",
            &[
                ("engine", json!(format!("{:?}", settings.engine).to_lowercase())),
                ("heldMs", json!(held_ms)),
                ("audioMs", json!(audio_ms)),
                ("sttMs", json!(stt_ms)),
                ("polish", json!(polish_result)),
                ("polishMs", json!(polish_ms)),
                ("chars", json!(text.chars().count())),
                ("pasted", json!(paste_result.is_ok())),
            ],
        );
        if paste_result.is_ok() {
            let _ = app.emit_to("island", "metrics", json!({"audioMs": audio_ms, "sttMs": stt_ms, "polishMs": polish_ms}));
        }
        paste_result.map_err(|e| format!("{e} The text is in the history; use Copy."))
    }
}

/// A 4-second message in the island ("No speech detected", errors).
fn notice(app: &AppHandle, kind: &str, text: &str) {
    let _ = app.emit_to("island", "notice", json!({"kind": kind, "text": text}));
}
