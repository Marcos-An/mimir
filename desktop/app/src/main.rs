#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod audio;
mod controller;
mod paste;
mod polish;
mod shell;
mod store;
mod stt;

use controller::Controller;
use serde::Serialize;
use serde_json::json;
use store::{Engine, Secret, Settings, SpeedResult};
use tauri::{AppHandle, Emitter, Manager, RunEvent, State, WindowEvent};

type Ctl<'a> = State<'a, &'static Controller>;

#[tauri::command]
fn get_state(controller: Ctl) -> controller::Snapshot {
    controller.snapshot()
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ModelInfo {
    id: &'static str,
    label: &'static str,
    downloaded: bool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct SettingsView {
    settings: Settings,
    models: Vec<ModelInfo>,
    has_anthropic_key: bool,
    has_groq_key: bool,
    slow_seconds: f64,
    data_dir: String,
}

#[tauri::command]
fn get_settings(controller: Ctl) -> SettingsView {
    SettingsView {
        settings: controller.settings.lock().unwrap().clone(),
        models: stt::MODELS.iter().map(|m| ModelInfo { id: m.id, label: m.label, downloaded: m.is_downloaded() }).collect(),
        has_anthropic_key: Secret::Anthropic.get().is_some(),
        has_groq_key: Secret::Groq.get().is_some(),
        slow_seconds: stt::SLOW_SECONDS_PER_30S,
        data_dir: store::data_dir().display().to_string(),
    }
}

#[tauri::command]
fn save_settings(app: AppHandle, controller: Ctl, settings: Settings) -> Result<(), String> {
    let old = controller.settings.lock().unwrap().shortcut.clone();
    shell::register_shortcut(&app, Some(&old), &settings.shortcut)?;
    settings.save().map_err(|e| format!("Could not save settings: {e}"))?;
    *controller.settings.lock().unwrap() = settings;
    controller.publish(&app);
    Ok(())
}

#[tauri::command]
fn set_secret(name: Secret, value: String) -> Result<(), String> {
    name.set(&value)
}

#[tauri::command]
async fn download_model(app: AppHandle, id: String) -> Result<(), String> {
    tauri::async_runtime::spawn_blocking(move || {
        let model = stt::model(&id).ok_or("Unknown model.")?;
        let result = model.download(|done, total| {
            let _ = app.emit("download", json!({"id": model.id, "done": done, "total": total}));
        });
        store::log("model-download", &[("model", json!(model.id)), ("ok", json!(result.is_ok()))]);
        result
    })
    .await
    .map_err(|e| e.to_string())?
}

#[tauri::command]
async fn run_speed_test(controller: Ctl<'_>) -> Result<SpeedResult, String> {
    let controller: &'static Controller = *controller;
    let id = controller.settings.lock().unwrap().local_model.clone();
    let seconds = tauri::async_runtime::spawn_blocking({
        let id = id.clone();
        move || stt::speed_test(&id)
    })
    .await
    .map_err(|e| e.to_string())??;
    store::log("speed-test", &[("model", json!(id)), ("seconds", json!((seconds * 10.0).round() / 10.0))]);
    let result = SpeedResult { model: id, seconds };
    let mut settings = controller.settings.lock().unwrap();
    settings.speed = Some(result.clone());
    let _ = settings.save();
    Ok(result)
}

#[tauri::command]
fn copy_text(text: String) -> Result<(), String> {
    paste::copy(&text)
}

#[tauri::command]
fn open_settings(app: AppHandle) {
    shell::show_settings(&app);
}

#[tauri::command]
fn hide_panel(app: AppHandle) {
    if let Some(panel) = app.get_webview_window("panel") {
        let _ = panel.hide();
    }
}

#[tauri::command]
fn open_billing() {
    let _ = tauri_plugin_opener::open_url("https://console.anthropic.com/settings/billing", None::<&str>);
}

#[tauri::command]
fn open_url(url: String) {
    if url.starts_with("https://console.groq.com/") || url.starts_with("https://console.anthropic.com/") {
        let _ = tauri_plugin_opener::open_url(url, None::<&str>);
    }
}

#[tauri::command]
fn open_data_folder() {
    let _ = tauri_plugin_opener::open_path(store::data_dir(), None::<&str>);
}

#[tauri::command]
fn quit(app: AppHandle) {
    app.exit(0);
}

/// `mimir --self-test [model]`: downloads the model if needed, transcribes
/// the bundled public-domain clip and runs the text filters, with no window,
/// microphone or key. Used by CI and to check a build on a new machine.
fn self_test(model_id: &str) -> Result<(), String> {
    let model = stt::model(model_id).ok_or("unknown model")?;
    model.download(|done, total| eprint!("\rdownloading {} MB of {} MB", done / 1_000_000, total / 1_000_000))?;
    let seconds = stt::speed_test(model.id)?;
    let text = stt::transcribe_local(model.id, &stt::speed_clip(), "en", "")?;
    let cleaned = mimir_core::cleaner::clean(&mimir_core::transcript::clean_special_tokens(&text));
    println!("model {} | 30 s of speech in {seconds:.1} s | {cleaned}", model.id);
    if !cleaned.to_lowercase().contains("your country") {
        return Err("the transcript does not match the clip".into());
    }
    Ok(())
}

fn main() {
    // whisper.cpp prints its internals to stderr; route them to the void.
    whisper_rs::install_logging_hooks();
    let args: Vec<String> = std::env::args().collect();
    if args.get(1).map(String::as_str) == Some("--self-test") {
        let result = self_test(args.get(2).map(String::as_str).unwrap_or("base"));
        if let Err(error) = &result {
            eprintln!("self-test failed: {error}");
        }
        std::process::exit(if result.is_ok() { 0 } else { 1 });
    }
    let controller: &'static Controller = Box::leak(Box::new(Controller::new()));
    let app = tauri::Builder::default()
        .plugin(tauri_plugin_single_instance::init(|app, args, _cwd| {
            // Starting Mimir again opens it; `mimir --settings` opens Settings.
            if args.iter().any(|a| a == "--settings") {
                shell::show_settings(app);
            } else {
                shell::show_panel(app, None);
            }
        }))
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_global_shortcut::Builder::new().with_handler(shell::on_shortcut).build())
        .manage(controller)
        .setup(move |app| {
            #[cfg(target_os = "macos")]
            app.set_activation_policy(tauri::ActivationPolicy::Accessory);
            shell::build_tray(app.handle())?;
            let settings = controller.settings.lock().unwrap().clone();
            let shortcut_ok = shell::register_shortcut(app.handle(), None, &settings.shortcut).is_ok();
            store::log(
                "launch",
                &[
                    ("version", json!(env!("CARGO_PKG_VERSION"))),
                    ("os", json!(std::env::consts::OS)),
                    ("engine", json!(format!("{:?}", settings.engine).to_lowercase())),
                    ("shortcutOk", json!(shortcut_ok)),
                ],
            );
            // First run, or a local model that is missing: start in Settings.
            let local_missing = settings.engine == Engine::Local
                && !stt::model(&settings.local_model).map(|m| m.is_downloaded()).unwrap_or(false);
            if !shortcut_ok || local_missing {
                shell::show_settings(app.handle());
            }
            Ok(())
        })
        .on_window_event(|window, event| match event {
            WindowEvent::CloseRequested { api, .. } => {
                api.prevent_close();
                let _ = window.hide();
            }
            WindowEvent::Focused(false) if window.label() == "panel" => {
                let _ = window.hide();
            }
            _ => {}
        })
        .invoke_handler(tauri::generate_handler![
            get_state,
            get_settings,
            save_settings,
            set_secret,
            download_model,
            run_speed_test,
            copy_text,
            open_settings,
            hide_panel,
            open_billing,
            open_url,
            open_data_folder,
            quit
        ])
        .build(tauri::generate_context!())
        .expect("Mimir failed to start");
    app.run(|_, event| {
        // Closing the last window keeps Mimir in the tray.
        if let RunEvent::ExitRequested { api, code: None, .. } = event {
            api.prevent_exit();
        }
    });
}
