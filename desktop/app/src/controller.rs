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
}

impl Controller {
    pub fn new() -> Self {
        Self {
            settings: Mutex::new(Settings::load()),
            inner: Mutex::new(Inner { phase: Phase::Idle, recorder: None, started: None, error: None, history: History::load() }),
        }
    }

    pub fn snapshot(&self) -> Snapshot {
        let inner = self.inner.lock().unwrap();
        Snapshot {
            phase: inner.phase,
            title: inner.phase.title(),
            error: inner.error.clone(),
            history: inner.history.iter().take(4).cloned().collect(),
            out_of_credits: polish::OUT_OF_CREDITS.load(Ordering::Relaxed),
            shortcut: self.settings.lock().unwrap().shortcut.clone(),
        }
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
            inner.error = Some(message);
            inner.phase = Phase::Idle;
        }
        crate::shell::phase_changed(app, Phase::Idle);
        self.publish(app);
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
        match Recorder::start() {
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
            if inner.phase != Phase::Recording {
                return;
            }
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
            if inner.phase != Phase::Recording {
                return;
            }
            (inner.recorder.take(), inner.started.take())
        };
        let Some(recorder) = recorder else { return };
        self.set_phase(app, Phase::Transcribing);
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
            return Ok(());
        }

        let stt_start = Instant::now();
        let raw = stt::transcribe(&settings, &samples)?;
        let stt_ms = stt_start.elapsed().as_millis() as u64;
        let heard = cleaner::strip_mid_text_farewells(&transcript::clean_special_tokens(&raw));
        if heard.is_empty() {
            store::log("no-speech", &[("audioMs", json!(audio_ms)), ("sttMs", json!(stt_ms))]);
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
        let paste_result = paste::paste(&text);
        {
            let mut inner = self.inner.lock().unwrap();
            History::push(&mut inner.history, &text);
        }
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
        paste_result.map_err(|e| format!("{e} The text is in the history; use Copy."))
    }
}
