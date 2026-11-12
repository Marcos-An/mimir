//! Tray icon, panel placement and the global shortcut.

use crate::controller::{Controller, Phase};
use crate::store::HotkeyMode;
use tauri::image::Image;
use tauri::menu::{Menu, MenuItem};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::{AppHandle, Emitter, Manager, PhysicalPosition, Rect};
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
    watch_escape(app, phase == Phase::Recording);
}

/// Esc cancels, but only while recording: outside that it belongs to other
/// apps. On Windows the key is read directly, because a hotkey for Esc does
/// not fire while the dictation shortcut's Ctrl/Shift are still held (hold
/// mode), and Ctrl+Shift+Esc would open Task Manager instead.
#[cfg(windows)]
fn watch_escape(app: &AppHandle, recording: bool) {
    use std::sync::atomic::{AtomicBool, Ordering};
    use windows_sys::Win32::UI::Input::KeyboardAndMouse::{GetAsyncKeyState, VK_ESCAPE};
    static WATCHING: AtomicBool = AtomicBool::new(false);
    if !recording || WATCHING.swap(true, Ordering::SeqCst) {
        return;
    }
    let app = app.clone();
    std::thread::spawn(move || {
        let controller = *app.state::<&'static Controller>();
        // Ignore an Esc that was already down when recording started.
        let mut was_down = true;
        while controller.phase() == Phase::Recording {
            let down = unsafe { GetAsyncKeyState(VK_ESCAPE as i32) } as u16 & 0x8000 != 0;
            if down && !was_down {
                controller.cancel(&app);
                break;
            }
            was_down = down;
            std::thread::sleep(std::time::Duration::from_millis(25));
        }
        WATCHING.store(false, Ordering::SeqCst);
    });
}

#[cfg(not(windows))]
fn watch_escape(app: &AppHandle, recording: bool) {
    let esc: Shortcut = "Escape".parse().unwrap();
    let shortcuts = app.global_shortcut();
    if recording {
        let _ = shortcuts.register(esc);
    } else if shortcuts.is_registered(esc) {
        let _ = shortcuts.unregister(esc);
    }
}

pub fn build_tray(app: &AppHandle) -> tauri::Result<()> {
    let open = MenuItem::with_id(app, "open", "Open Mimir", true, None::<&str>)?;
    let settings = MenuItem::with_id(app, "settings", "Settings…", true, None::<&str>)?;
    let quit = MenuItem::with_id(app, "quit", "Quit Mimir", true, None::<&str>)?;
    // Linux tray icons only open their menu on click, so the panel gets an item.
    #[cfg(target_os = "linux")]
    let menu = {
        let recent = MenuItem::with_id(app, "panel", "Latest text", true, None::<&str>)?;
        Menu::with_items(app, &[&recent, &open, &settings, &quit])?
    };
    #[cfg(not(target_os = "linux"))]
    let menu = Menu::with_items(app, &[&open, &settings, &quit])?;
    TrayIconBuilder::with_id("main")
        .icon(icon(false))
        .tooltip("Mimir: Ready")
        .menu(&menu)
        .show_menu_on_left_click(false)
        .on_menu_event(|app, event| match event.id.as_ref() {
            "panel" => show_panel(app, None),
            "open" => show_main(app, None),
            "settings" => show_main(app, Some("general")),
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

/// The "Open Mimir" window (journal); with a section, its Settings sheet opens.
pub fn show_main(app: &AppHandle, section: Option<&str>) {
    if let Some(panel) = app.get_webview_window("panel") {
        let _ = panel.hide();
    }
    if let Some(window) = app.get_webview_window("main") {
        // Same as the Mac's dashboard: opens at 960x640 (smaller on a small
        // screen), never below 720x460.
        if !window.is_visible().unwrap_or(false) {
            let (mut width, mut height) = (960.0, 640.0);
            if let Ok(Some(monitor)) = window.current_monitor().or_else(|_| window.primary_monitor()) {
                let area = monitor.work_area().size.to_logical::<f64>(monitor.scale_factor());
                width = f64::min(width, area.width - 40.0).max(720.0);
                height = f64::min(height, area.height - 40.0).max(460.0);
            }
            let _ = window.set_min_size(Some(tauri::LogicalSize::new(720.0, 460.0)));
            let _ = window.set_size(tauri::LogicalSize::new(width, height));
            let _ = window.center();
        }
        let _ = window.show();
        let _ = window.unminimize();
        let _ = window.set_focus();
        if let Some(section) = section {
            let _ = window.emit_to("main", "open-settings", section);
        }
    }
}

/// The recording island: a borderless, transparent window that never takes
/// focus, so the dictation is pasted in the app the user is typing in.
pub fn build_island(app: &AppHandle) -> tauri::Result<()> {
    tauri::WebviewWindowBuilder::new(app, "island", tauri::WebviewUrl::App("island.html".into()))
        .title("Mimir Island")
        .inner_size(440.0, 76.0)
        .decorations(false)
        .transparent(true)
        .shadow(false)
        .resizable(false)
        .always_on_top(true)
        .skip_taskbar(true)
        .visible_on_all_workspaces(true)
        .focused(false)
        .focusable(false)
        .visible(false)
        .build()?;
    Ok(())
}

/// Bottom centre of the work area, the pill 24 px above the taskbar/Dock.
pub fn show_island(app: &AppHandle, visible: bool) {
    let Some(island) = app.get_webview_window("island") else { return };
    if !visible {
        let _ = island.hide();
        return;
    }
    if !island.is_visible().unwrap_or(false) {
        if let Ok(Some(monitor)) = island.current_monitor().or_else(|_| island.primary_monitor()) {
            let scale = monitor.scale_factor();
            let area = monitor.work_area();
            let width = (440.0 * scale) as i32;
            let height = (76.0 * scale) as i32;
            let x = area.position.x + (area.size.width as i32 - width) / 2;
            let y = area.position.y + area.size.height as i32 - height - ((24.0 - 20.0) * scale) as i32;
            let _ = island.set_position(PhysicalPosition::new(x, y));
        }
        let _ = island.show();
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
