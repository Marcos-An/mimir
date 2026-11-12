//! The Claude cleanup request for one dictation, and the checks on its reply.
//! Port of `MLXPostProcessor.userPrompt/cleanOutput/looksLikeForeignScript`
//! and the token ceiling in `AnthropicPostProcessor.requestCompletion`.

use crate::prompts::CleanupStyle;

pub fn user_prompt(style: CleanupStyle, transcript: &str) -> String {
    let task = match style {
        CleanupStyle::Light => "Do only a conservative review of the transcription below, following the system rules.",
        CleanupStyle::CleanDictation => "Clean up the dictation below into natural readable text, following the system rules.",
        CleanupStyle::Structured => "Format the dictation transcription below following the system rules.",
    };
    format!("{task}\nReply only with the final text.\n\nTranscription:\n{transcript}")
}

/// About 0.35 tokens per character in pt-BR, with 1.5x headroom.
pub fn max_tokens(transcript: &str) -> u32 {
    let approx_input = (transcript.chars().count() as f64 * 0.35).max(100.0);
    (approx_input * 1.5).clamp(300.0, 8192.0) as u32
}

pub fn clean_output(text: &str) -> String {
    let mut cleaned = text.trim().to_string();
    if cleaned.starts_with("```") {
        cleaned = cleaned.replace("```", "").trim().to_string();
    }
    if cleaned.chars().count() >= 2 && cleaned.starts_with('"') && cleaned.ends_with('"') {
        cleaned = cleaned[1..cleaned.len() - 1].to_string();
    }
    cleaned.trim().to_string()
}

/// CJK, Hangul, Cyrillic or Arabic letters.
pub fn looks_like_foreign_script(text: &str) -> bool {
    text.chars().any(|c| {
        matches!(c as u32, 0x4E00..=0x9FFF | 0x3040..=0x309F | 0x30A0..=0x30FF | 0xAC00..=0xD7AF | 0x0400..=0x04FF | 0x0600..=0x06FF)
    })
}

/// What to paste given Claude's reply: the reply, unless it is empty or
/// switched script (the model answered in another language).
pub fn accept_reply(transcript: &str, reply: &str) -> Option<String> {
    let cleaned = clean_output(reply);
    if cleaned.is_empty() {
        return None;
    }
    if looks_like_foreign_script(&cleaned) && !looks_like_foreign_script(transcript) {
        return None;
    }
    Some(cleaned)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn prompt_and_reply_rules() {
        assert!(user_prompt(CleanupStyle::CleanDictation, "oi").ends_with("Transcription:\noi"));
        assert_eq!(max_tokens("short"), 300);
        assert_eq!(max_tokens(&"a".repeat(100_000)), 8192);
        assert_eq!(clean_output("```\nHello.\n```"), "Hello.");
        assert_eq!(clean_output("\"Hello.\""), "Hello.");
        assert_eq!(accept_reply("oi tudo bem", "Привет"), None);
        assert_eq!(accept_reply("oi", "  "), None);
        assert_eq!(accept_reply("oi", "Oi."), Some("Oi.".into()));
    }
}
