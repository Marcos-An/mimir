//! Pastes text into the app the user is typing in: put it on the clipboard,
//! press Ctrl+V (Cmd+V on macOS), then give the clipboard back. Mirrors
//! `ClipboardPasteInserter.swift`. On Windows the dictated text is kept out
//! of clipboard history (Win+V), cloud clipboard and clipboard monitors.

use arboard::{Clipboard, ImageData};
use enigo::{Direction, Enigo, Key, Keyboard, Settings};
use std::time::{Duration, Instant};

enum Saved {
    Text(String),
    Image(ImageData<'static>),
    Empty,
}

fn snapshot(clipboard: &mut Clipboard) -> Saved {
    if let Ok(text) = clipboard.get_text() {
        return Saved::Text(text);
    }
    if let Ok(image) = clipboard.get_image() {
        return Saved::Image(image.to_owned_img());
    }
    Saved::Empty
}

fn restore(clipboard: &mut Clipboard, saved: Saved) {
    let _ = match saved {
        Saved::Text(text) => clipboard.set_text(text),
        Saved::Image(image) => clipboard.set_image(image),
        Saved::Empty => clipboard.clear(),
    };
}

#[cfg(windows)]
fn set_private_text(clipboard: &mut Clipboard, text: &str) -> Result<(), arboard::Error> {
    use arboard::SetExtWindows;
    clipboard.set().exclude_from_history().exclude_from_cloud().exclude_from_monitoring().text(text)
}

#[cfg(not(windows))]
fn set_private_text(clipboard: &mut Clipboard, text: &str) -> Result<(), arboard::Error> {
    clipboard.set_text(text)
}

/// Waits (500 ms at most) until Ctrl, Shift, Alt and Win are up, so the
/// shortcut's own keys do not turn Ctrl+V into Ctrl+Shift+V.
#[cfg(windows)]
fn wait_for_modifiers_up() {
    use windows_sys::Win32::UI::Input::KeyboardAndMouse::{GetAsyncKeyState, VK_CONTROL, VK_LWIN, VK_MENU, VK_RWIN, VK_SHIFT};
    let deadline = Instant::now() + Duration::from_millis(500);
    while Instant::now() < deadline {
        let down = [VK_CONTROL, VK_SHIFT, VK_MENU, VK_LWIN, VK_RWIN]
            .iter()
            .any(|&vk| unsafe { GetAsyncKeyState(vk as i32) } as u16 & 0x8000 != 0);
        if !down {
            return;
        }
        std::thread::sleep(Duration::from_millis(15));
    }
}

#[cfg(not(windows))]
fn wait_for_modifiers_up() {
    let _ = Instant::now();
    std::thread::sleep(Duration::from_millis(60));
}

fn press_paste() -> Result<(), String> {
    let mut enigo = Enigo::new(&Settings::default()).map_err(|e| format!("Cannot send keys: {e}"))?;
    let modifier = if cfg!(target_os = "macos") { Key::Meta } else { Key::Control };
    let v = if cfg!(windows) { Key::Other(0x56) } else { Key::Unicode('v') };
    enigo.key(modifier, Direction::Press).map_err(|e| e.to_string())?;
    let result = enigo.key(v, Direction::Click).map_err(|e| e.to_string());
    let _ = enigo.key(modifier, Direction::Release);
    result
}

pub fn paste(text: &str) -> Result<(), String> {
    let mut clipboard = Clipboard::new().map_err(|e| format!("Clipboard unavailable: {e}"))?;
    let saved = snapshot(&mut clipboard);
    set_private_text(&mut clipboard, text).map_err(|e| format!("Clipboard unavailable: {e}"))?;
    wait_for_modifiers_up();
    if let Err(error) = press_paste() {
        restore(&mut clipboard, saved);
        return Err(error);
    }
    // Give the clipboard back after the target app has read it, unless the
    // user copied something new in the meantime.
    let ours = text.to_string();
    std::thread::spawn(move || {
        std::thread::sleep(Duration::from_secs(1));
        if let Ok(mut clipboard) = Clipboard::new() {
            if clipboard.get_text().ok().as_deref() == Some(ours.as_str()) {
                restore(&mut clipboard, saved);
            }
        }
    });
    Ok(())
}

pub fn copy(text: &str) -> Result<(), String> {
    Clipboard::new().and_then(|mut c| c.set_text(text)).map_err(|e| format!("Clipboard unavailable: {e}"))
}
