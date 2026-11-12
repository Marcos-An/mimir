//! uia-probe: for each text field you click into, prints one line saying what
//! Windows UI Automation exposes there: the app, the control type, whether
//! it is a password field, whether text, word positions and selection work.
//! It never prints or stores what you type. Run it, then click into a text
//! box in each app and type a few words. Ctrl+C to stop.

#[cfg(not(windows))]
fn main() {
    eprintln!("uia-probe runs on Windows only.");
}

#[cfg(windows)]
fn main() {
    if let Err(error) = probe::run() {
        eprintln!("uia-probe failed: {error}");
        std::process::exit(1);
    }
}

#[cfg(windows)]
mod probe {
    use std::time::{Duration, Instant};
    use windows::core::{Interface, Result, BSTR, PWSTR};
    use windows::Win32::Foundation::{CloseHandle, RECT};
    use windows::Win32::System::Com::{CoCreateInstance, CoInitializeEx, CLSCTX_INPROC_SERVER, COINIT_MULTITHREADED};
    use windows::Win32::System::Ole::{SafeArrayGetElement, SafeArrayGetLBound, SafeArrayGetUBound};
    use windows::Win32::System::Threading::{OpenProcess, QueryFullProcessImageNameW, PROCESS_NAME_WIN32, PROCESS_QUERY_LIMITED_INFORMATION};
    use windows::Win32::UI::Accessibility::*;

    #[derive(PartialEq)]
    struct Row {
        app: String,
        control: String,
        password: bool,
        text_pattern: bool,
        value_pattern: bool,
        length: Option<usize>,
        find_text: Option<bool>,
        rects: Option<usize>,
        rects_inside: Option<bool>,
        select: Option<bool>,
        text_changes_seen: bool,
    }

    fn yes(value: Option<bool>) -> &'static str {
        match value {
            Some(true) => "yes",
            Some(false) => "no",
            None => "-",
        }
    }

    pub fn run() -> Result<()> {
        unsafe { CoInitializeEx(None, COINIT_MULTITHREADED).ok()? };
        let automation: IUIAutomation = unsafe { CoCreateInstance(&CUIAutomation, None, CLSCTX_INPROC_SERVER)? };
        println!("uia-probe {}: click into text fields and type a few words. Nothing you type is printed.", env!("CARGO_PKG_VERSION"));
        println!("app | control | password | TextPattern | ValuePattern | length | FindText ok | rects | rects inside field | Select ok | text change seen");
        let mut last: Option<Row> = None;
        let mut last_length: Option<usize> = None;
        let mut changes_seen = false;
        let mut last_print = Instant::now() - Duration::from_secs(60);
        loop {
            std::thread::sleep(Duration::from_millis(700));
            let Ok(element) = (unsafe { automation.GetFocusedElement() }) else { continue };
            let row = match inspect(&element, &mut last_length, &mut changes_seen) {
                Ok(Some(row)) => row,
                _ => continue,
            };
            if last.as_ref() != Some(&row) || last_print.elapsed() > Duration::from_secs(30) {
                println!(
                    "{} | {} | {} | {} | {} | {} | {} | {} | {} | {} | {}",
                    row.app,
                    row.control,
                    row.password,
                    row.text_pattern,
                    row.value_pattern,
                    row.length.map_or("-".into(), |l| l.to_string()),
                    yes(row.find_text),
                    row.rects.map_or("-".into(), |r| r.to_string()),
                    yes(row.rects_inside),
                    yes(row.select),
                    row.text_changes_seen
                );
                last_print = Instant::now();
                last = Some(row);
            }
        }
    }

    fn exe_name(pid: i32) -> String {
        unsafe {
            let Ok(handle) = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid as u32) else { return "?".into() };
            let mut buffer = [0u16; 512];
            let mut size = buffer.len() as u32;
            let ok = QueryFullProcessImageNameW(handle, PROCESS_NAME_WIN32, PWSTR(buffer.as_mut_ptr()), &mut size).is_ok();
            let _ = CloseHandle(handle);
            if !ok {
                return "?".into();
            }
            let path = String::from_utf16_lossy(&buffer[..size as usize]);
            path.rsplit('\\').next().unwrap_or("?").to_lowercase()
        }
    }

    #[allow(non_upper_case_globals)]
    fn control_name(id: UIA_CONTROLTYPE_ID) -> String {
        match id {
            UIA_EditControlTypeId => "Edit".into(),
            UIA_DocumentControlTypeId => "Document".into(),
            UIA_TextControlTypeId => "Text".into(),
            UIA_PaneControlTypeId => "Pane".into(),
            UIA_GroupControlTypeId => "Group".into(),
            UIA_CustomControlTypeId => "Custom".into(),
            other => format!("type{}", other.0),
        }
    }

    fn inspect(element: &IUIAutomationElement, last_length: &mut Option<usize>, changes_seen: &mut bool) -> Result<Option<Row>> {
        unsafe {
            let pid = element.CurrentProcessId()?;
            if pid as u32 == std::process::id() {
                return Ok(None);
            }
            let control_type = element.CurrentControlType()?;
            let password = element.CurrentIsPassword()?.as_bool();
            let app = exe_name(pid);
            let value_pattern = element.GetCurrentPattern(UIA_ValuePatternId).is_ok_and(|p| p.as_raw() as usize != 0);
            let text = element
                .GetCurrentPattern(UIA_TextPatternId)
                .ok()
                .and_then(|p| p.cast::<IUIAutomationTextPattern>().ok());
            let mut row = Row {
                app,
                control: control_name(control_type),
                password,
                text_pattern: text.is_some(),
                value_pattern,
                length: None,
                find_text: None,
                rects: None,
                rects_inside: None,
                select: None,
                text_changes_seen: false,
            };
            // A password field is reported, never read.
            if password {
                return Ok(Some(row));
            }
            let Some(text) = text else { return Ok(Some(row)) };
            let document = text.DocumentRange()?;
            let content = document.GetText(8001)?.to_string();
            let length = content.encode_utf16().count();
            if last_length.is_some_and(|previous| previous != length) {
                *changes_seen = true;
            }
            *last_length = Some(length);
            row.length = Some(length);
            row.text_changes_seen = *changes_seen;

            // The last word of 3+ letters: is it findable, where is it, and can
            // it be selected? The word itself is never printed.
            let Some(word) = content
                .split(|c: char| !c.is_alphanumeric())
                .filter(|w| w.chars().count() >= 3)
                .last()
            else {
                return Ok(Some(row));
            };
            let found = document.FindText(&BSTR::from(word), true, false);
            let Ok(range) = found else {
                row.find_text = Some(false);
                return Ok(Some(row));
            };
            row.find_text = Some(range.GetText(-1).map(|t| t.to_string() == word).unwrap_or(false));
            let field: RECT = element.CurrentBoundingRectangle()?;
            if let Ok(array) = range.GetBoundingRectangles() {
                let lower = SafeArrayGetLBound(array, 1).unwrap_or(0);
                let upper = SafeArrayGetUBound(array, 1).unwrap_or(-1);
                let mut values = Vec::new();
                for index in lower..=upper {
                    let mut value = 0f64;
                    if SafeArrayGetElement(array, &index, &mut value as *mut f64 as *mut _).is_ok() {
                        values.push(value);
                    }
                }
                let rects: Vec<[f64; 4]> = values.chunks_exact(4).map(|c| [c[0], c[1], c[2], c[3]]).collect();
                row.rects = Some(rects.len());
                row.rects_inside = Some(
                    !rects.is_empty()
                        && rects.iter().all(|r| {
                            r[2] > 0.0
                                && r[3] > 0.0
                                && r[0] >= field.left as f64 - 1.0
                                && r[1] >= field.top as f64 - 1.0
                                && r[0] + r[2] <= field.right as f64 + 1.0
                                && r[1] + r[3] <= field.bottom as f64 + 1.0
                        }),
                );
            } else {
                row.rects = Some(0);
            }
            row.select = Some(range.Select().is_ok());
            Ok(Some(row))
        }
    }
}
