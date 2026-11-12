use crate::utf16::{self, Range16};
use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum IssueKind {
    Spelling,
    Grammar,
    /// Right spelling, wrong word ("their" for "there").
    Word,
    /// Correct but unnatural.
    Phrasing,
}

impl IssueKind {
    pub fn title(self) -> &'static str {
        match self {
            IssueKind::Spelling => "Spelling",
            IssueKind::Grammar => "Grammar",
            IssueKind::Word => "Wrong word",
            IssueKind::Phrasing => "More natural",
        }
    }
}

/// One fix, tied to the sentence it was found in.
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct Finding {
    pub sentence: String,
    pub original: String,
    pub replacement: String,
    pub why: String,
    pub kind: IssueKind,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AnchoredFinding {
    pub finding: Finding,
    pub range: Range16,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Sentence {
    pub text: String,
    pub range: Range16,
    /// Ends with . ! ? or a line break; the last one may still be typed.
    pub is_complete: bool,
}

fn is_space(unit: u16) -> bool {
    matches!(unit, 32 | 9 | 10 | 13 | 160)
}

fn is_terminator(unit: u16) -> bool {
    matches!(unit, 46 | 33 | 63)
}

/// Trimmed sentences. A sentence ends at . ! ? followed by whitespace or the
/// end, or at a line break.
pub fn sentences(text: &str) -> Vec<Sentence> {
    let units = utf16::units(text);
    let len = units.len();
    let mut out = Vec::new();
    let mut start = 0;
    let mut i = 0;
    let emit = |start: usize, end: usize, complete: bool, out: &mut Vec<Sentence>| {
        let (mut lo, mut hi) = (start, end.max(start));
        while lo < hi && is_space(units[lo]) {
            lo += 1;
        }
        while hi > lo && is_space(units[hi - 1]) {
            hi -= 1;
        }
        if hi > lo {
            out.push(Sentence {
                text: utf16::string(&units[lo..hi]),
                range: Range16 { location: lo, length: hi - lo },
                is_complete: complete,
            });
        }
    };
    while i < len {
        let unit = units[i];
        if unit == 10 || unit == 13 {
            emit(start, i, true, &mut out);
            start = i + 1;
        } else if is_terminator(unit) {
            let mut end = i + 1;
            while end < len && is_terminator(units[end]) {
                end += 1;
            }
            if end == len || is_space(units[end]) {
                emit(start, end, true, &mut out);
                start = end;
                i = end;
                continue;
            }
        }
        i += 1;
    }
    if start < len {
        emit(start, len, false, &mut out);
    }
    out
}

pub fn word_count(text: &str) -> usize {
    text.split_whitespace().count()
}

/// Where `finding` sits in `text` now, or None when it can't be placed without
/// guessing (sentence gone or twice, or the words not exactly once in it).
pub fn anchor(finding: &Finding, text: &str) -> Option<Range16> {
    let units = utf16::units(text);
    let sentence = utf16::unique_range(&finding.sentence, &units)?;
    let local = utf16::unique_range(&finding.original, &units[sentence.location..sentence.end()])?;
    Some(Range16 { location: sentence.location + local.location, length: local.length })
}

pub fn anchor_all(findings: &[Finding], text: &str) -> Vec<AnchoredFinding> {
    let mut seen = std::collections::HashSet::new();
    findings
        .iter()
        .filter_map(|finding| {
            let range = anchor(finding, text)?;
            seen.insert(range).then(|| AnchoredFinding { finding: finding.clone(), range })
        })
        .collect()
}

/// The text after applying `finding`, re-located against `text`.
pub fn applying(finding: &Finding, text: &str) -> Option<(String, Range16)> {
    let range = anchor(finding, text)?;
    let units = utf16::units(text);
    let mut out = units[..range.location].to_vec();
    out.extend(utf16::units(&finding.replacement));
    out.extend_from_slice(&units[range.end()..]);
    Some((utf16::string(&out), range))
}
