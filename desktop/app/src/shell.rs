//! Tray icon, panel placement and the global shortcut.

use crate::controller::{Controller, Phase, TrayState};
use crate::store::{Appearance, HotkeyMode};
use tauri::image::Image;
use tauri::menu::{Menu, MenuItem};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::{AppHandle, Emitter, Manager, PhysicalPosition, Rect};
use tauri_plugin_global_shortcut::{GlobalShortcutExt, Shortcut, ShortcutEvent, ShortcutState};

/// The Mac menu bar glyph (Sources/MimirApp/Resources/MenuBarIcon.png):
/// a black "m" on transparent, 128x80.
const ICON: &[u8] = include_bytes!("../icons/tray.png");

/// What the tray draws: the Mimir "m", or the SF Symbols the Mac app swaps
/// in per state (mic.fill, ellipsis.circle.fill, exclamationmark.circle.fill,
/// arrow.down.circle), redrawn here as shapes.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Glyph {
    Mark,
    Mic,
    Busy,
    Error,
    Download,
}

/// Side of the square the symbols are drawn on, the size of the "m" glyph.
const SYMBOL: u32 = 128;

/// The glyph's coverage (0-255) and size. macOS keeps the "m" at 128x80 (the
/// bar draws it 18 pt tall, like the Mac app); Windows and Linux need a
/// square icon, so it is centred on a transparent square there.
fn mask(glyph: Glyph) -> (Vec<u8>, u32, u32) {
    if glyph != Glyph::Mark {
        return (symbol(glyph), SYMBOL, SYMBOL);
    }
    let base = Image::from_bytes(ICON).expect("tray icon");
    let (width, height) = (base.width(), base.height());
    let src = base.rgba();
    let (out_w, out_h) = if cfg!(target_os = "macos") { (width, height) } else { (width.max(height), width.max(height)) };
    let (dx, dy) = ((out_w - width) / 2, (out_h - height) / 2);
    let mut alpha = vec![0u8; (out_w * out_h) as usize];
    for y in 0..height {
        for x in 0..width {
            alpha[((y + dy) * out_w + x + dx) as usize] = src[((y * width + x) * 4 + 3) as usize];
        }
    }
    (alpha, out_w, out_h)
}

/// The state symbols, from signed distances (negative inside) in a 0-1 box,
/// anti-aliased over one pixel.
fn symbol(glyph: Glyph) -> Vec<u8> {
    type P = (f32, f32);
    let len = |(x, y): P| (x * x + y * y).sqrt();
    let circle = |p: P, c: P, r: f32| len((p.0 - c.0, p.1 - c.1)) - r;
    // A stroke from a to b with round ends, `r` thick on each side.
    let line = |p: P, a: P, b: P, r: f32| {
        let (ba, pa) = ((b.0 - a.0, b.1 - a.1), (p.0 - a.0, p.1 - a.1));
        let t = ((pa.0 * ba.0 + pa.1 * ba.1) / (ba.0 * ba.0 + ba.1 * ba.1)).clamp(0.0, 1.0);
        len((pa.0 - ba.0 * t, pa.1 - ba.1 * t)) - r
    };
    let cut = |d: f32, hole: f32| d.max(-hole);
    let disc = |p: P| circle(p, (0.5, 0.5), 0.42);
    let distance = |p: P| match glyph {
        Glyph::Mic => {
            let body = line(p, (0.5, 0.25), (0.5, 0.45), 0.14);
            // The cradle: the lower half of a ring under the capsule.
            let (c, r, w) = ((0.5, 0.45), 0.25, 0.04);
            let cradle = if p.1 >= c.1 {
                (circle(p, c, r)).abs() - w
            } else {
                circle(p, (c.0 - r, c.1), w).min(circle(p, (c.0 + r, c.1), w))
            };
            let stem = line(p, (0.5, 0.7), (0.5, 0.86), w);
            let foot = line(p, (0.36, 0.86), (0.64, 0.86), w);
            body.min(cradle).min(stem).min(foot)
        }
        Glyph::Busy => {
            let dots = [0.3, 0.5, 0.7].iter().map(|&x| circle(p, (x, 0.5), 0.065)).fold(f32::MAX, f32::min);
            cut(disc(p), dots)
        }
        Glyph::Error => {
            let mark = line(p, (0.5, 0.27), (0.5, 0.55), 0.055).min(circle(p, (0.5, 0.71), 0.065));
            cut(disc(p), mark)
        }
        Glyph::Download => {
            let w = 0.04;
            let ring = circle(p, (0.5, 0.5), 0.38).abs() - w;
            let shaft = line(p, (0.5, 0.29), (0.5, 0.69), w);
            let head = line(p, (0.5, 0.7), (0.35, 0.55), w).min(line(p, (0.5, 0.7), (0.65, 0.55), w));
            ring.min(shaft).min(head)
        }
        Glyph::Mark => unreachable!(),
    };
    let side = SYMBOL as f32;
    (0..SYMBOL * SYMBOL)
        .map(|i| {
            let p = (((i % SYMBOL) as f32 + 0.5) / side, ((i / SYMBOL) as f32 + 0.5) / side);
            ((0.5 - distance(p) * side).clamp(0.0, 1.0) * 255.0).round() as u8
        })
        .collect()
}

/// The glyph in `rgb`, with the Linux rim.
fn icon(glyph: Glyph, rgb: [u8; 3]) -> Image<'static> {
    let (alpha, width, height) = mask(glyph);
    let mut rgba: Vec<u8> = alpha.iter().flat_map(|&a| [rgb[0], rgb[1], rgb[2], a]).collect();
    if cfg!(target_os = "linux") {
        outline(&mut rgba, width, height);
    }
    Image::new_owned(rgba, width, height)
}

/// Linux panels can be light or dark and say neither, so the glyph gets a
/// dark rim that keeps it visible on both.
fn outline(rgba: &mut [u8], width: u32, height: u32) {
    const R: i32 = 6;
    let alpha = |x: i32, y: i32| rgba[((y as u32 * width + x as u32) * 4 + 3) as usize];
    let mut rim = vec![0u8; (width * height) as usize];
    for y in 0..height as i32 {
        for x in 0..width as i32 {
            if alpha(x, y) == 255 {
                continue;
            }
            let mut best = 0u8;
            for oy in -R..=R {
                for ox in -R..=R {
                    let (nx, ny) = (x + ox, y + oy);
                    if ox * ox + oy * oy <= R * R && nx >= 0 && ny >= 0 && nx < width as i32 && ny < height as i32 {
                        best = best.max(alpha(nx, ny));
                    }
                }
            }
            rim[(y as u32 * width + x as u32) as usize] = best;
        }
    }
    for (i, &a) in rim.iter().enumerate() {
        let glyph = rgba[i * 4 + 3];
        if a > glyph {
            // Glyph colour over a 70% black rim.
            let rim_alpha = (a as f32 * 0.7) as u8;
            let g = glyph as f32 / 255.0;
            for c in 0..3 {
                rgba[i * 4 + c] = (rgba[i * 4 + c] as f32 * g) as u8;
            }
            rgba[i * 4 + 3] = glyph.max(rim_alpha);
        }
    }
}

/// Redraws the tray glyph for the dictation state and the taskbar colour
/// (the user may have switched Windows between light and dark). Skipped when
/// neither changed: download progress calls this many times a second.
pub fn refresh_tray(app: &AppHandle) {
    static SHOWN: std::sync::Mutex<Option<(TrayState, bool)>> = std::sync::Mutex::new(None);
    let state = app.try_state::<&'static Controller>().map(|c| c.tray_state()).unwrap_or(TrayState::Idle);
    let light = bar_is_light();
    let Some(tray) = app.tray_by_id("main") else { return };
    {
        // Released before set_icon: off the main thread that call waits for
        // the main thread, which may itself be waiting here (tray click).
        let mut shown = SHOWN.lock().unwrap();
        if *shown == Some((state, light)) {
            return;
        }
        *shown = Some((state, light));
    }
    set_tray_icon(&tray, state, light);
}

/// Same states and colours as MenuBarController.updateIcon: red mic while
/// recording, orange "!" after an error, and otherwise a glyph that follows
/// the bar (a template on macOS).
fn set_tray_icon(tray: &tauri::tray::TrayIcon, state: TrayState, light: bool) {
    let bar = if light { [0, 0, 0] } else { [255, 255, 255] };
    let (glyph, rgb, template) = match state {
        TrayState::Idle => (Glyph::Mark, bar, true),
        TrayState::Recording => (Glyph::Mic, [255, 59, 48], false),
        TrayState::Busy => (Glyph::Busy, bar, true),
        TrayState::Error => (Glyph::Error, [255, 149, 0], false),
        TrayState::Downloading => (Glyph::Download, bar, true),
    };
    let _ = tray.set_icon(Some(icon(glyph, rgb)));
    let _ = tray.set_icon_as_template(template);
}

/// Whether the taskbar is light, so the glyph is drawn dark on it. Windows
/// reads its taskbar setting; Linux panels are dark on the common desktops.
#[cfg(windows)]
fn bar_is_light() -> bool {
    use windows_sys::Win32::System::Registry::{RegGetValueW, HKEY_CURRENT_USER, RRF_RT_REG_DWORD};
    let wide = |s: &str| s.encode_utf16().chain(Some(0)).collect::<Vec<u16>>();
    let key = wide(r"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
    let value = wide("SystemUsesLightTheme");
    let mut data: u32 = 0;
    let mut size = std::mem::size_of::<u32>() as u32;
    let status = unsafe {
        RegGetValueW(
            HKEY_CURRENT_USER,
            key.as_ptr(),
            value.as_ptr(),
            RRF_RT_REG_DWORD,
            std::ptr::null_mut(),
            &mut data as *mut u32 as *mut _,
            &mut size,
        )
    };
    status == 0 && data == 1
}

#[cfg(not(windows))]
fn bar_is_light() -> bool {
    // macOS ignores the colour (the icon is a template); Linux: dark panel.
    false
}

/// Light/dark for every window: native title bars, and the webviews'
/// prefers-color-scheme, which mac.css follows.
pub fn apply_appearance(app: &AppHandle, appearance: Appearance) {
    app.set_theme(match appearance {
        // GTK reads None as "light", so Linux asks the desktop itself.
        Appearance::System if cfg!(target_os = "linux") && linux_prefers_dark() => Some(tauri::Theme::Dark),
        Appearance::System => None,
        Appearance::Light => Some(tauri::Theme::Light),
        Appearance::Dark => Some(tauri::Theme::Dark),
    });
}

/// GNOME 42+ and most GTK desktops: `color-scheme`, else a "-dark" GTK theme.
fn linux_prefers_dark() -> bool {
    let read = |key: &str| {
        std::process::Command::new("gsettings")
            .args(["get", "org.gnome.desktop.interface", key])
            .output()
            .ok()
            .map(|o| String::from_utf8_lossy(&o.stdout).to_lowercase())
            .unwrap_or_default()
    };
    read("color-scheme").contains("dark") || read("gtk-theme").contains("dark")
}

pub fn phase_changed(app: &AppHandle, phase: Phase) {
    if let Some(tray) = app.tray_by_id("main") {
        let _ = tray.set_tooltip(Some(format!("Mimir: {}", phase.title())));
    }
    refresh_tray(app);
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
    let tray = TrayIconBuilder::with_id("main")
        .icon(icon(Glyph::Mark, [0, 0, 0]))
        .icon_as_template(true)
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
    // On a Mac this build sits next to the real Mimir; the label tells them apart.
    #[cfg(target_os = "macos")]
    let _ = tray.set_title(Some("dev"));
    let _ = tray;
    refresh_tray(app);
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
    refresh_tray(app);
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

#[cfg(test)]
mod tray_tests {
    use super::*;

    fn at(mask: &[u8], x: f32, y: f32) -> u8 {
        mask[((y * SYMBOL as f32) as u32 * SYMBOL + (x * SYMBOL as f32) as u32) as usize]
    }

    #[test]
    fn symbols_draw_their_shapes() {
        let mic = symbol(Glyph::Mic);
        assert_eq!(at(&mic, 0.5, 0.35), 255, "capsule");
        assert_eq!(at(&mic, 0.1, 0.1), 0, "corner stays clear");
        let busy = symbol(Glyph::Busy);
        assert_eq!(at(&busy, 0.5, 0.3), 255, "disc");
        assert_eq!(at(&busy, 0.3, 0.5), 0, "dot is cut out");
        let error = symbol(Glyph::Error);
        assert_eq!(at(&error, 0.5, 0.4), 0, "bar is cut out");
        assert_eq!(at(&error, 0.3, 0.5), 255, "disc");
        let download = symbol(Glyph::Download);
        assert_eq!(at(&download, 0.5, 0.45), 255, "shaft");
        assert_eq!(at(&download, 0.3, 0.3), 0, "inside the ring is clear");
    }

    #[test]
    fn the_mark_is_square_off_macos() {
        let (alpha, w, h) = mask(Glyph::Mark);
        assert_eq!(alpha.len(), (w * h) as usize);
        assert_eq!(w == h, !cfg!(target_os = "macos"));
    }
}
