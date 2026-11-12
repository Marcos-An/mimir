//! Text positions in UTF-16 code units: what macOS Accessibility and Windows
//! UI Automation use, and what `shared/fixtures` records. Linux (AT-SPI) counts
//! code points and converts at its edge.

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct Range16 {
    pub location: usize,
    pub length: usize,
}

impl Range16 {
    pub fn end(&self) -> usize {
        self.location + self.length
    }
}

pub fn units(text: &str) -> Vec<u16> {
    text.encode_utf16().collect()
}

pub fn string(units: &[u16]) -> String {
    String::from_utf16_lossy(units)
}

/// First occurrence of `needle` in `haystack` at or after `from`.
pub fn find(haystack: &[u16], needle: &[u16], from: usize) -> Option<usize> {
    if needle.is_empty() || needle.len() > haystack.len() {
        return None;
    }
    (from..=haystack.len() - needle.len()).find(|&i| &haystack[i..i + needle.len()] == needle)
}

/// The range of `needle` when it occurs exactly once (overlaps count).
pub fn unique_range(needle: &str, haystack: &[u16]) -> Option<Range16> {
    let needle = units(needle);
    let first = find(haystack, &needle, 0)?;
    if find(haystack, &needle, first + 1).is_some() {
        return None;
    }
    Some(Range16 { location: first, length: needle.len() })
}
