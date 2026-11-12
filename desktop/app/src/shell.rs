//! Tray icon, panel placement and the global shortcut.

use crate::controller::{Controller, Phase};
use crate::store::HotkeyMode;
use tauri::image::Image;
use tauri::menu::{Menu, MenuItem};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::{AppHandle, Manager, PhysicalPosition, Rect};
use tauri_plugin_global_shortcut::{GlobalShortcutExt, Shortcut, ShortcutEvent, ShortcutState};

const ICON: &[u8] = include_bytes!("../icons/32x32.png");

fn icon(recording: bool) -> Image<'static> {
    let base = Image::from_bytes(ICON).expect("tray icon");
    if !recording {
        return base.to_owned();
    }
    // Red dot in the lower-right corner while recording.
    let (width, height) = (base.width(), base.height());
    let mut rgba = base.rgba().to_vec();
    let radius = width as f32 * 0.28;
    let (cx, cy) = (width as f32 - radius - 0.5, height as f32 - radius - 0.5);
    for y in 0..height {
        for x in 0..width {
            let d = ((x as f32 - cx).powi(2) + (y as f32 - cy).powi(2)).sqrt();
            if d <= radius {
                let i = ((y * width + x) * 4) as usize;
                rgba[i..i + 4].copy_from_slice(&[230, 40, 40, 255]);
            }
        }
    }
    Image::new_owned(rgba, width, height)
}

pub fn phase_changed(app: &AppHandle, phase: Phase) {
    if let Some(tray) = app.tray_by_id("main") {
        let _ = tray.set_icon(Some(icon(phase == Phase::Recording)));
        let _ = tray.set_tooltip(Some(format!("Mimir: {}", phase.title())));
    }
    // Esc cancels, but only while recording: outside that it belongs to other apps.
    let esc: Shortcut = "Escape".parse().unwrap();
    let shortcuts = app.global_shortcut();
    if phase == Phase::Recording {
        let _ = shortcuts.register(esc);
    } else if shortcuts.is_registered(esc) {
        let _ = shortcuts.unregister(esc);
    }
}

pub fn build_tray(app: &AppHandle) -> tauri::Result<()> {
    let open = MenuItem::with_id(app, "open", "Open Mimir", true, None::<&str>)?;
    let settings = MenuItem::with_id(app, "settings", "Settings…", true, None::<&str>)?;
    let quit = MenuItem::with_id(app, "quit", "Quit Mimir", true, None::<&str>)?;
    let menu = Menu::with_items(app, &[&open, &settings, &quit])?;
    TrayIconBuilder::with_id("main")
        .icon(icon(false))
        .tooltip("Mimir: Ready")
        .menu(&menu)
        .show_menu_on_left_click(false)
        .on_menu_event(|app, event| match event.id.as_ref() {
            "open" => show_panel(app, None),
            "settings" => show_settings(app),
            "quit" => app.exit(0),
            _ => {}
        })
        .on_tray_icon_event(|tray, event| {
            if let TrayIconEvent::Click { button: MouseButton::Left, button_state: MouseButtonState::Up, rect, .. } = event {
                let app = tray.app_handle();
                let visible = app.get_webview_window("panel").and_then(|w| w.is_visible().ok()).unwrap_or(false);
                if visible {
                    if let Some(panel) = app.get_webview_window("panel") {
                        let _ = panel.hide();
                    }
                } else {
                    show_panel(app, Some(rect));
                }
            }
        })
        .build(app)?;
    Ok(())
}

/// Opens the panel next to the tray icon: above it when the taskbar is at
/// the bottom (Windows), below it when the bar is at the top.
pub fn show_panel(app: &AppHandle, near: Option<Rect>) {
    let Some(panel) = app.get_webview_window("panel") else { return };
    if let (Some(rect), Ok(size)) = (near, panel.outer_size()) {
        let scale = panel.scale_factor().unwrap_or(1.0);
        let position = rect.position.to_physical::<i32>(scale);
        let icon = rect.size.to_physical::<i32>(scale);
        let monitor = panel.current_monitor().ok().flatten().or_else(|| panel.primary_monitor().ok().flatten());
        let (screen_x, screen_y, screen_w, screen_h) = monitor
            .map(|m| (m.position().x, m.position().y, m.size().width as i32, m.size().height as i32))
            .unwrap_or((0, 0, 1920, 1080));
        let width = size.width as i32;
        let height = size.height as i32;
        let x = (position.x + icon.width / 2 - width / 2).clamp(screen_x + 8, screen_x + screen_w - width - 8);
        let y = if position.y > screen_y + screen_h / 2 { position.y - height - 8 } else { position.y + icon.height + 8 };
        let _ = panel.set_position(PhysicalPosition::new(x, y));
    } else {
        let _ = panel.center();
    }
    let _ = panel.show();
    let _ = panel.set_focus();
    if let Some(controller) = app.try_state::<&'static Controller>() {
        controller.publish(app);
    }
}

pub fn show_settings(app: &AppHandle) {
    if let Some(window) = app.get_webview_window("settings") {
        let _ = window.show();
        let _ = window.unminimize();
        let _ = window.set_focus();
    }
}

pub fn on_shortcut(app: &AppHandle, shortcut: &Shortcut, event: ShortcutEvent) {
    let controller = *app.state::<&'static Controller>();
    let esc: Shortcut = "Escape".parse().unwrap();
    if *shortcut == esc {
        if event.state() == ShortcutState::Pressed {
            controller.cancel(app);
        }
        return;
    }
    let mode = controller.settings.lock().unwrap().mode;
    match (mode, event.state()) {
        (HotkeyMode::Tap, ShortcutState::Pressed) => {
            if controller.phase() == Phase::Recording {
                controller.stop(app);
            } else {
                controller.start(app);
            }
        }
        (HotkeyMode::Hold, ShortcutState::Pressed) => controller.start(app),
        (HotkeyMode::Hold, ShortcutState::Released) => controller.stop(app),
        _ => {}
    }
}

/// Swaps the dictation shortcut; on failure the old one stays registered.
pub fn register_shortcut(app: &AppHandle, old: Option<&str>, new: &str) -> Result<(), String> {
    let parsed: Shortcut = new.parse().map_err(|_| format!("\"{new}\" is not a shortcut Mimir understands."))?;
    let shortcuts = app.global_shortcut();
    if let Some(old) = old.and_then(|o| o.parse::<Shortcut>().ok()) {
        if old == parsed && shortcuts.is_registered(parsed) {
            return Ok(());
        }
        let _ = shortcuts.unregister(old);
    }
    shortcuts.register(parsed).map_err(|_| {
        if let Some(old) = old.and_then(|o| o.parse::<Shortcut>().ok()) {
            let _ = shortcuts.register(old);
        }
        format!("{new} is already used by another app. Pick another shortcut.")
    })
}
