//! The Claude prompts, embedded from `shared/prompts` (the same files the Mac
//! app is generated from). `.gitattributes` keeps them LF on Windows checkouts.

pub const CLEANUP_LIGHT: &str = include_str!("../../../shared/prompts/cleanup-light.txt");
pub const CLEANUP_CLEAN_DICTATION: &str = include_str!("../../../shared/prompts/cleanup-clean-dictation.txt");
pub const CLEANUP_STRUCTURED: &str = include_str!("../../../shared/prompts/cleanup-structured.txt");
pub const CLEANUP_PROMPT_ENGINEER: &str = include_str!("../../../shared/prompts/cleanup-prompt-engineer.txt");
const CLEANUP_VOCABULARY_SECTION: &str = include_str!("../../../shared/prompts/cleanup-vocabulary-section.txt");
pub const WRITING_CHECK_SYSTEM: &str = include_str!("../../../shared/prompts/writing-check-system.txt");
const WRITING_CHECK_EXAMPLES: &str = include_str!("../../../shared/prompts/writing-check-examples.json");

#[derive(Clone, Copy, Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum CleanupStyle {
    Light,
    CleanDictation,
    Structured,
}

/// System prompt for a dictation cleanup, with the user's vocabulary appended
/// exactly as the Mac app does (`MLXPostProcessor.systemPrompt`).
pub fn cleanup_system_prompt(style: CleanupStyle, vocabulary: &str) -> String {
    let base = match style {
        CleanupStyle::Light => CLEANUP_LIGHT,
        CleanupStyle::CleanDictation => CLEANUP_CLEAN_DICTATION,
        CleanupStyle::Structured => CLEANUP_STRUCTURED,
    };
    format!("{base}{}", vocabulary_section(vocabulary))
}

pub fn vocabulary_terms(vocabulary: &str) -> Vec<String> {
    vocabulary
        .lines()
        .map(|line| line.trim_matches([' ', '\t']).to_string())
        .filter(|line| !line.is_empty())
        .collect()
}

fn vocabulary_section(vocabulary: &str) -> String {
    let terms = vocabulary_terms(vocabulary);
    if terms.is_empty() {
        return String::new();
    }
    CLEANUP_VOCABULARY_SECTION.replace("{{terms}}", &terms.join(", "))
}

#[derive(Clone, Debug, PartialEq, Eq, serde::Deserialize)]
pub struct ExampleMessage {
    pub role: String,
    pub content: String,
}

/// Few-shot turns sent before every writing check.
pub fn writing_check_examples() -> Vec<ExampleMessage> {
    serde_json::from_str(WRITING_CHECK_EXAMPLES).expect("shared/prompts/writing-check-examples.json is valid")
}
