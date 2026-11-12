//! Claude's reply → findings that can be trusted. Port of `WritingChecker.swift`.

use super::model::{Finding, IssueKind};
use crate::anthropic::Message;
use crate::prompts;
use crate::utf16;
use serde::Deserialize;
use unicode_segmentation::UnicodeSegmentation;

pub const MODEL_ID: &str = "claude-haiku-5-5";
pub const MAX_TOKENS: u32 = 600;

/// The user's custom vocabulary, one term per line, at most 150.
pub fn vocabulary_terms(text: &str) -> Vec<String> {
    text.lines()
        .map(|l| l.trim_matches([' ', '\t']))
        .filter(|l| !l.is_empty())
        .take(150)
        .map(str::to_string)
        .collect()
}

/// A fix that changes one of the user's own terms is never shown.
pub fn touches_vocabulary(finding: &Finding, vocabulary: &[String]) -> bool {
    let original = finding.original.to_lowercase();
    let replacement = finding.replacement.to_lowercase();
    vocabulary.iter().any(|term| {
        let term = term.to_lowercase();
        original.contains(&term) && !replacement.contains(&term)
    })
}

pub fn user_message(sentences: &[String], context: &str, vocabulary: &[String]) -> String {
    let terms = if vocabulary.is_empty() { String::new() } else { format!("<terms>{}</terms>\n", vocabulary.join(", ")) };
    format!("{terms}<context>{context}</context>\n<check>\n{}\n</check>", sentences.join("\n"))
}

/// Few-shot turns plus the user turn, ready for the Messages API.
pub fn messages(sentences: &[String], context: &str, vocabulary: &[String]) -> Vec<Message> {
    let mut out: Vec<Message> = prompts::writing_check_examples()
        .into_iter()
        .map(|m| Message { role: m.role, content: m.content })
        .collect();
    out.push(Message { role: "user".into(), content: user_message(sentences, context, vocabulary) });
    out
}

#[derive(Deserialize)]
struct RawFinding {
    sentence: Option<String>,
    original: Option<String>,
    replacement: Option<String>,
    why: Option<String>,
    kind: Option<String>,
}

/// Parses the model's JSON and drops anything that can't be trusted. Invalid
/// JSON yields no findings (never a retry).
pub fn parse(reply: &str, checked: &[String]) -> Vec<Finding> {
    let (Some(start), Some(end)) = (reply.find('['), reply.rfind(']')) else { return vec![] };
    if start >= end {
        return vec![];
    }
    let Ok(raw) = serde_json::from_str::<Vec<RawFinding>>(&reply[start..=end]) else { return vec![] };
    raw.into_iter()
        .take(5)
        .filter_map(|item| {
            let sentence = item.sentence.filter(|s| checked.contains(s))?;
            let kind = match item.kind?.as_str() {
                "spelling" => IssueKind::Spelling,
                "grammar" => IssueKind::Grammar,
                "word" => IssueKind::Word,
                "phrasing" => IssueKind::Phrasing,
                _ => return None,
            };
            let finding = Finding {
                sentence,
                original: item.original?,
                replacement: item.replacement?,
                why: item.why.unwrap_or_default().trim().to_string(),
                kind,
            };
            is_acceptable(&finding).then_some(finding)
        })
        .collect()
}

fn graphemes(text: &str) -> Vec<&str> {
    text.graphemes(true).collect()
}

/// Keeps a fix only when placeable and small: `original` once in its sentence,
/// a different replacement at most 20 characters longer, at most 4 words
/// changed, and a spelling fix close to the typed word.
pub fn is_acceptable(finding: &Finding) -> bool {
    let original = &finding.original;
    let replacement = &finding.replacement;
    if original.trim_matches([' ', '\t']).is_empty()
        || original == replacement
        || utf16::unique_range(original, &utf16::units(&finding.sentence)).is_none()
        || graphemes(replacement).len() > graphemes(original).len() + 20
    {
        return false;
    }
    let original_words: Vec<&str> = original.split_whitespace().collect();
    let replacement_words: Vec<&str> = replacement.split_whitespace().collect();
    if edit_distance(&original_words, &replacement_words) > 4 {
        return false;
    }
    if finding.kind == IssueKind::Spelling {
        let a = original.to_lowercase();
        let b = replacement.to_lowercase();
        let limit = 3usize.max((graphemes(original).len() as f64 * 0.6).floor() as usize);
        if edit_distance(&graphemes(&a), &graphemes(&b)) > limit {
            return false;
        }
    }
    true
}

pub fn edit_distance<T: PartialEq>(a: &[T], b: &[T]) -> usize {
    if a.is_empty() {
        return b.len();
    }
    if b.is_empty() {
        return a.len();
    }
    let mut previous: Vec<usize> = (0..=b.len()).collect();
    for (i, x) in a.iter().enumerate() {
        let mut current = vec![i + 1; b.len() + 1];
        for (j, y) in b.iter().enumerate() {
            current[j + 1] = (previous[j + 1] + 1).min(current[j] + 1).min(previous[j] + usize::from(x != y));
        }
        previous = current;
    }
    previous[b.len()]
}

/// Up to 300 UTF-16 units before the checked text, to resolve references.
pub fn context_before(sentence: &str, text: &str) -> String {
    let units = utf16::units(text);
    let needle = utf16::units(sentence);
    if needle.is_empty() || needle.len() > units.len() {
        return String::new();
    }
    let Some(location) = (0..=units.len() - needle.len()).rev().find(|&i| units[i..i + needle.len()] == needle[..]) else {
        return String::new();
    };
    if location == 0 {
        return String::new();
    }
    let start = location.saturating_sub(300);
    utf16::string(&units[start..location]).trim().to_string()
}
