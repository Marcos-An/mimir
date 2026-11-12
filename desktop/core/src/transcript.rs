//! Whisper output filters, run before any cleanup. Port of
//! `WhisperKitProvider.cleanSpecialTokens` and its helpers: sound tags,
//! music symbols, special tokens, CJK hallucinations and the YouTube outros
//! Whisper adds after silence. An empty result means "no speech".

use regex::Regex;
use std::sync::LazyLock;

static BRACKET_TAG: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\s*\[[^\]]{1,80}\]\s*").unwrap());
static ASTERISK_TAG: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\s*\*[^*\n]{1,30}\*\s*").unwrap());
static SPECIAL_TOKEN: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"<\|[^|>]+\|>").unwrap());
static SPACES: LazyLock<Regex> = LazyLock::new(|| Regex::new(r" +").unwrap());
static PUNCT_OR_SYMBOL: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"[\p{P}\p{S}]").unwrap());

const MUSIC_SYMBOLS: [char; 6] = ['♫', '♪', '🎵', '🎶', '♩', '♬'];

/// Only unambiguous video-outro phrases; plain "obrigado" or "tchau" stay,
/// people end real messages with them.
const OUTROS: [&str; 13] = [
    "obrigado por assistir", "obrigada por assistir", "até o próximo vídeo",
    "legendado por", "legendas pela equipe", "inscrevase no canal", "não esqueça de se inscrever",
    "thanks for watching", "thank you for watching", "see you next time",
    "see you in the next video", "dont forget to subscribe", "like and subscribe",
];

pub fn clean_special_tokens(input: &str) -> String {
    let mut text = BRACKET_TAG.replace_all(input, " ").into_owned();
    text = ASTERISK_TAG.replace_all(&text, " ").into_owned();
    if is_non_speech_artifact(&text) {
        text.clear();
    }
    text = SPECIAL_TOKEN.replace_all(&text, "").into_owned();
    text = strip_cjk_hallucinations(&text);
    text = strip_tail_outro(&text);
    text = SPACES.replace_all(&text, " ").into_owned();
    text.trim().to_string()
}

/// True when nothing in the text is a letter or digit (music symbols do not count).
pub fn is_non_speech_artifact(text: &str) -> bool {
    !text.trim().chars().any(|c| !MUSIC_SYMBOLS.contains(&c) && c.is_alphanumeric())
}

fn is_cjk(c: char) -> bool {
    matches!(c as u32, 0x3040..=0x309F | 0x30A0..=0x30FF | 0x4E00..=0x9FFF | 0xAC00..=0xD7AF | 0x3000..=0x303F)
}

/// Latin text with CJK characters mixed in: the CJK part is a hallucination.
fn strip_cjk_hallucinations(text: &str) -> String {
    if !text.chars().any(is_cjk) {
        return text.to_string();
    }
    let has_latin = text.chars().any(|c| matches!(c as u32, 0x41..=0x5A | 0x61..=0x7A | 0xC0..=0xFF));
    if !has_latin {
        return text.to_string();
    }
    text.chars().filter(|&c| !is_cjk(c)).collect()
}

fn strip_tail_outro(input: &str) -> String {
    let trimmed = input.trim();
    let body = trimmed.trim_end_matches(|c: char| c.is_whitespace() || ".!?".contains(c));
    if body.is_empty() {
        return input.to_string();
    }
    let tail_start = body.rfind(['.', '!', '?']).map(|i| i + 1).unwrap_or(0);
    let normalized = PUNCT_OR_SYMBOL.replace_all(body[tail_start..].trim(), "").trim().to_lowercase();
    let words = normalized.split_whitespace().count();
    if words == 0 || words > 5 || !OUTROS.contains(&normalized.as_str()) {
        return input.to_string();
    }
    let prefix = body[..tail_start].trim();
    if prefix.is_empty() { input.to_string() } else { prefix.to_string() }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn drops_tags_and_outros() {
        assert_eq!(clean_special_tokens("[Music] ♪ ♪"), "");
        assert_eq!(clean_special_tokens("  "), "");
        assert_eq!(clean_special_tokens("Manda o relatório. Obrigado por assistir!"), "Manda o relatório.");
        assert_eq!(clean_special_tokens("Obrigado por assistir!"), "Obrigado por assistir!");
        assert_eq!(clean_special_tokens("Hello there ご視聴ありがとうございました"), "Hello there");
        assert_eq!(clean_special_tokens("<|pt|> Oi *risos* tudo bem"), "Oi tudo bem");
        assert_eq!(clean_special_tokens("Coloca um ♫ aqui"), "Coloca um ♫ aqui");
    }
}
