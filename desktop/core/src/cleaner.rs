//! Rule-based cleanup of known dictation defects. Port of
//! `Sources/MimirCore/DictationTextCleaner.swift`; `shared/fixtures/cleaner.json`
//! keeps both in step. Order of rules matters and matches the Swift file.

use fancy_regex::Regex as FancyRegex;
use regex::Regex;
use std::sync::LazyLock;

pub fn clean(input: &str) -> String {
    let trimmed = input.trim();
    if trimmed.is_empty() {
        return input.to_string();
    }
    let mut text = collapse_ellipses(trimmed);
    text = remove_hesitations(&text);
    text = collapse_repeated_words(&text);
    text = strip_trailing_farewells(&text);
    text = normalize_whitespace(&text);
    text = capitalize_sentence_starts(&text);
    ensure_terminal_punctuation(&text)
}

static PUNCT_THEN_DOTS: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"([,;:!?])\s*\.{2,}").unwrap());
static DOTS_BEFORE_LOWER: LazyLock<FancyRegex> = LazyLock::new(|| FancyRegex::new(r"\s*\.{2,}\s*(?=\p{Ll})").unwrap());
static DOTS_BEFORE_UPPER: LazyLock<FancyRegex> = LazyLock::new(|| FancyRegex::new(r"\s*\.{2,}\s*(?=\p{Lu})").unwrap());
static DOTS: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\s*\.{2,}").unwrap());

/// "..." or "…": before a lowercase letter → a space (pause mid-sentence);
/// before an uppercase letter → ". "; elsewhere → one period.
fn collapse_ellipses(input: &str) -> String {
    let text = input.replace('…', "...");
    let text = PUNCT_THEN_DOTS.replace_all(&text, "$1").into_owned();
    let text = DOTS_BEFORE_LOWER.replace_all(&text, " ").into_owned();
    let text = DOTS_BEFORE_UPPER.replace_all(&text, ". ").into_owned();
    DOTS.replace_all(&text, ".").into_owned()
}

static HESITATIONS: LazyLock<FancyRegex> = LazyLock::new(|| {
    FancyRegex::new(r"(?i)(?<![\p{L}\p{N}])(?:ahn+|hum+|hmm+|uh+|éh+|ehh+)(?![\p{L}\p{N}]),?\s*").unwrap()
});

/// Hesitation sounds with their trailing comma. "ah" stays (a real interjection).
fn remove_hesitations(input: &str) -> String {
    HESITATIONS.replace_all(input, "").into_owned()
}

static REPEATED_WORD: LazyLock<FancyRegex> = LazyLock::new(|| {
    FancyRegex::new(r"(?i)(?<![\p{L}\p{N}])(\p{L}{2,})(?:[ \t]+\1)+(?![\p{L}\p{N}])").unwrap()
});

const INTENTIONAL_REPEATS: [&str; 6] = ["que", "tchau", "tic", "tac", "bye", "very"];

/// "os os" → "os" (a stutter); "não, não" and "o que que" stay.
fn collapse_repeated_words(input: &str) -> String {
    let mut out = String::with_capacity(input.len());
    let mut last = 0;
    for found in REPEATED_WORD.captures_iter(input).flatten() {
        let whole = found.get(0).unwrap();
        let word = found.get(1).unwrap().as_str();
        if INTENTIONAL_REPEATS.contains(&word.to_lowercase().as_str()) {
            continue;
        }
        out.push_str(&input[last..whole.start()]);
        out.push_str(word);
        last = whole.end();
    }
    out.push_str(&input[last..]);
    out
}

const FAREWELLS: [&str; 18] = [
    "obrigado", "obrigada", "muito obrigado", "muito obrigada", "brigado",
    "tchau", "tchau tchau", "valeu", "até mais", "até logo", "até a próxima",
    "obrigado tchau", "obrigado até mais",
    "thanks", "thank you", "bye", "goodbye", "see you",
];

const MID_TEXT_FAREWELLS: [&str; 9] = [
    "tchau", "tchau tchau", "e tchau", "obrigado", "obrigada", "obrigado tchau",
    "thanks", "thank you", "bye",
];

static PUNCT_OR_SYMBOL: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"[\p{P}\p{S}]").unwrap());

fn normalized_words(text: &str) -> String {
    PUNCT_OR_SYMBOL.replace_all(text, "").trim().to_lowercase()
}

/// A final short farewell ("Obrigado.") is a Whisper hallucination at the end
/// of silence; dropped when there is real speech before it. Two passes.
fn strip_trailing_farewells(input: &str) -> String {
    let mut text = input.to_string();
    for _ in 0..2 {
        let stripped = remove_last_sentence_if_farewell(&text);
        if stripped == text {
            break;
        }
        text = stripped;
    }
    text
}

fn remove_last_sentence_if_farewell(input: &str) -> String {
    let trimmed = input.trim();
    let body = trimmed.trim_end_matches(|c: char| c.is_whitespace() || ".!?".contains(c));
    if body.is_empty() {
        return input.to_string();
    }
    let tail_start = body.rfind(['.', '!', '?']).map(|i| i + 1).unwrap_or(0);
    let normalized = normalized_words(&body[tail_start..]);
    if normalized.is_empty() {
        return input.to_string();
    }
    if normalized.split_whitespace().count() > 3 || !FAREWELLS.contains(&normalized.as_str()) {
        return input.to_string();
    }
    let prefix = body[..tail_start].trim();
    if prefix.is_empty() {
        return input.to_string();
    }
    prefix.to_string()
}

static SENTENCE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"[^.!?]+(?:[.!?]+|$)").unwrap());

/// A sentence made only of a farewell, with speech on both sides, is dropped.
pub fn strip_mid_text_farewells(input: &str) -> String {
    let sentences: Vec<&str> = SENTENCE.find_iter(input).map(|m| m.as_str()).collect();
    if sentences.len() < 3 {
        return input.to_string();
    }
    let last = sentences.len() - 1;
    let kept: Vec<&str> = sentences
        .iter()
        .enumerate()
        .filter(|(i, s)| !(*i > 0 && *i < last && MID_TEXT_FAREWELLS.contains(&normalized_words(s).as_str())))
        .map(|(_, s)| *s)
        .collect();
    if kept.len() == sentences.len() {
        return input.to_string();
    }
    normalize_whitespace(&kept.concat())
}

static SPACES: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"[ \t]+").unwrap());
static SPACE_BEFORE_PUNCT: LazyLock<Regex> = LazyLock::new(|| Regex::new(r" +([.,;:!?])").unwrap());
static DOUBLE_DOTS: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\.{2,}").unwrap());

fn normalize_whitespace(input: &str) -> String {
    let text = SPACES.replace_all(input, " ");
    let text = SPACE_BEFORE_PUNCT.replace_all(&text, "$1");
    let text = DOUBLE_DOTS.replace_all(&text, ".");
    text.trim().to_string()
}

/// Uppercases the first letter of the text and after ". ", "! ", "? " or a
/// line break. Requiring the space leaves "site.com" and "v1.2" alone.
fn capitalize_sentence_starts(input: &str) -> String {
    let chars: Vec<char> = input.chars().collect();
    let mut out = String::with_capacity(input.len());
    let mut at_start = true;
    for (i, &c) in chars.iter().enumerate() {
        if at_start && c.is_alphabetic() {
            out.extend(c.to_uppercase());
            at_start = false;
            continue;
        }
        if ".!?".contains(c) {
            if chars.get(i + 1).is_none_or(|n| n.is_whitespace()) {
                at_start = true;
            }
        } else if c == '\n' || c == '\r' {
            at_start = true;
        } else if !c.is_whitespace() && at_start && !c.is_alphabetic() {
            at_start = false;
        }
        out.push(c);
    }
    out
}

fn ensure_terminal_punctuation(input: &str) -> String {
    match input.chars().last() {
        Some(c) if c.is_alphanumeric() => format!("{input}."),
        _ => input.to_string(),
    }
}
