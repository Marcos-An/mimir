//! Pastes text into the app the user is typing in: put it on the clipboard,
//! press Ctrl+V (Cmd+V on macOS), then give the clipboard back. Mirrors
//! `ClipboardPasteInserter.swift`. On Windows the dictated text is kept out
//! of clipboard history (Win+V), cloud clipboard and clipboard monitors, and
//! the user's clipboard is saved in every format (files from Explorer, Excel
//! cells, formatted Word text), not only as text.

use arboard::Clipboard;
use enigo::{Direction, Enigo, Key, Keyboard, Settings};
use std::sync::Mutex;
use std::time::{Duration, Instant};

/// The user's clipboard waiting to be given back after a paste. A second
/// dictation that lands before the restore reuses it, so the first
/// dictation is never mistaken for the user's own copy.
struct Pending {
    generation: u64,
    saved: clip::Saved,
    marker: clip::Marker,
}

static PENDING: Mutex<Option<Pending>> = Mutex::new(None);
static GENERATION: Mutex<u64> = Mutex::new(0);

#[cfg(windows)]
mod clip {
    //! Raw Win32 clipboard: every memory-backed format, byte for byte.
    use std::ptr::null_mut;
    use windows_sys::Win32::Foundation::{GlobalFree, HANDLE, HWND};
    use windows_sys::Win32::System::DataExchange::{
        CloseClipboard, EmptyClipboard, EnumClipboardFormats, GetClipboardData, GetClipboardSequenceNumber, OpenClipboard,
        SetClipboardData,
    };
    use windows_sys::Win32::System::Memory::{GlobalAlloc, GlobalLock, GlobalSize, GlobalUnlock, GMEM_MOVEABLE};
    use windows_sys::Win32::UI::WindowsAndMessaging::{CreateWindowExW, HWND_MESSAGE};

    pub struct Saved(Vec<(u32, Vec<u8>)>);
    pub type Marker = u32;

    // GDI and owner-drawn formats are handles, not memory; Windows
    // synthesises the bitmap ones from CF_DIB, which is saved.
    const NOT_MEMORY: [u32; 8] = [2, 3, 9, 14, 0x80, 0x82, 0x83, 0x8E];

    /// A message-only window to own the clipboard: SetClipboardData fails
    /// when the clipboard was opened without an owner.
    fn owner() -> HWND {
        thread_local! {
            static OWNER: HWND = unsafe {
                let class: Vec<u16> = "STATIC\0".encode_utf16().collect();
                CreateWindowExW(0, class.as_ptr(), null_mut(), 0, 0, 0, 0, 0, HWND_MESSAGE, null_mut(), null_mut(), null_mut())
            };
        }
        OWNER.with(|h| *h)
    }

    fn open() -> bool {
        for _ in 0..10 {
            if unsafe { OpenClipboard(owner()) } != 0 {
                return true;
            }
            std::thread::sleep(std::time::Duration::from_millis(20));
        }
        false
    }

    pub fn snapshot() -> Saved {
        let mut formats = Vec::new();
        if !open() {
            return Saved(formats);
        }
        unsafe {
            let mut format = EnumClipboardFormats(0);
            while format != 0 {
                if !NOT_MEMORY.contains(&format) {
                    let handle = GetClipboardData(format);
                    if !handle.is_null() {
                        let size = GlobalSize(handle as _);
                        let data = GlobalLock(handle as _);
                        if !data.is_null() {
                            formats.push((format, std::slice::from_raw_parts(data as *const u8, size).to_vec()));
                            GlobalUnlock(handle as _);
                        }
                    }
                }
                format = EnumClipboardFormats(format);
            }
            CloseClipboard();
        }
        Saved(formats)
    }

    pub fn restore(saved: Saved) {
        if !open() {
            return;
        }
        unsafe {
            EmptyClipboard();
            for (format, bytes) in saved.0 {
                let memory = GlobalAlloc(GMEM_MOVEABLE, bytes.len().max(1));
                if memory.is_null() {
                    continue;
                }
                let target = GlobalLock(memory);
                if target.is_null() {
                    GlobalFree(memory);
                    continue;
                }
                std::ptr::copy_nonoverlapping(bytes.as_ptr(), target as *mut u8, bytes.len());
                GlobalUnlock(memory);
                if SetClipboardData(format, memory as HANDLE).is_null() {
                    GlobalFree(memory);
                }
            }
            CloseClipboard();
        }
    }

    /// Changes whenever anyone writes to the clipboard.
    pub fn marker(_text: &str) -> Marker {
        unsafe { GetClipboardSequenceNumber() }
    }

    pub fn unchanged(marker: Marker) -> bool {
        unsafe { GetClipboardSequenceNumber() == marker }
    }
}

#[cfg(not(windows))]
mod clip {
    //! Text and images only (development builds on macOS; Linux comes later).
    use arboard::{Clipboard, ImageData};

    pub enum Saved {
        Text(String),
        Image(ImageData<'static>),
        Unknown,
    }
    pub type Marker = String;

    pub fn snapshot() -> Saved {
        let Ok(mut clipboard) = Clipboard::new() else { return Saved::Unknown };
        if let Ok(text) = clipboard.get_text() {
            return Saved::Text(text);
        }
        if let Ok(image) = clipboard.get_image() {
            return Saved::Image(image.to_owned_img());
        }
        Saved::Unknown
    }

    /// An unknown format is left alone rather than wiped.
    pub fn restore(saved: Saved) {
        let Ok(mut clipboard) = Clipboard::new() else { return };
        let _ = match saved {
            Saved::Text(text) => clipboard.set_text(text),
            Saved::Image(image) => clipboard.set_image(image),
            Saved::Unknown => Ok(()),
        };
    }

    pub fn marker(text: &str) -> Marker {
        text.to_string()
    }

    pub fn unchanged(marker: Marker) -> bool {
        Clipboard::new().ok().and_then(|mut c| c.get_text().ok()).as_deref() == Some(marker.as_str())
    }
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
    let generation = {
        let mut g = GENERATION.lock().unwrap();
        *g += 1;
        *g
    };
    // The user's clipboard: still pending from a paste a moment ago, or now.
    let saved = PENDING.lock().unwrap().take().map(|p| p.saved).unwrap_or_else(clip::snapshot);
    let mut clipboard = Clipboard::new().map_err(|e| format!("Clipboard unavailable: {e}"))?;
    if let Err(e) = set_private_text(&mut clipboard, text) {
        clip::restore(saved);
        return Err(format!("Clipboard unavailable: {e}"));
    }
    drop(clipboard);
    let marker = clip::marker(text);
    wait_for_modifiers_up();
    if let Err(error) = press_paste() {
        clip::restore(saved);
        return Err(error);
    }
    *PENDING.lock().unwrap() = Some(Pending { generation, saved, marker });
    // Give the clipboard back once the target app has read it, unless the
    // user copied something new meanwhile or a newer paste took over.
    std::thread::spawn(move || {
        std::thread::sleep(Duration::from_secs(1));
        let mut pending = PENDING.lock().unwrap();
        if pending.as_ref().is_some_and(|p| p.generation == generation) {
            let Pending { saved, marker, .. } = pending.take().unwrap();
            if clip::unchanged(marker) {
                clip::restore(saved);
            }
        }
    });
    Ok(())
}

pub fn copy(text: &str) -> Result<(), String> {
    Clipboard::new().and_then(|mut c| c.set_text(text)).map_err(|e| format!("Clipboard unavailable: {e}"))
}
