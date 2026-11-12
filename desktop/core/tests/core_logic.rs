//! Mirrors of the Swift unit tests that are scripted (state over time), so
//! they don't fit a plain input → output fixture.

use mimir_core::anthropic::{self, Failure, Message};
use mimir_core::prompts::{self, CleanupStyle};
use mimir_core::writing::budget::{Budget, Outcome};
use mimir_core::writing::model::{Finding, IssueKind};
use mimir_core::writing::policy::{Policy, Scope};
use mimir_core::writing::scheduler::{Decision, Scheduler};

fn fix(sentence: &str, original: &str, replacement: &str) -> Finding {
    Finding { sentence: sentence.into(), original: original.into(), replacement: replacement.into(), why: "x".into(), kind: IssueKind::Grammar }
}

const S: &str = "I has went there yesterday.";

#[test]
fn finished_sentences_are_checked_once() {
    let mut scheduler = Scheduler::new();
    assert_eq!(scheduler.text_changed("I has went"), Decision::Nothing);
    assert_eq!(scheduler.text_changed(S), Decision::CheckNow(vec![S.into()]));
    scheduler.mark_in_flight(&[S.into()]);
    assert_eq!(scheduler.text_changed(&format!("{S} And")), Decision::Nothing);
    scheduler.record(&[fix(S, "has went", "went")], &[S.into()]);
    assert_eq!(scheduler.text_changed(&format!("{S} And then")), Decision::Nothing);
    assert_eq!(scheduler.findings(&format!("Hi. {S} And then")).len(), 1);
}

#[test]
fn sentence_being_typed_is_checked_after_a_pause_once_per_version() {
    let mut scheduler = Scheduler::new();
    assert_eq!(scheduler.text_changed("we was going"), Decision::Nothing);
    assert_eq!(scheduler.text_changed("we was going there"), Decision::CheckWhenIdle);
    assert_eq!(scheduler.idle_fired("we was going there"), vec!["we was going there".to_string()]);
    assert_eq!(scheduler.text_changed("we was going there"), Decision::Nothing);
    assert!(scheduler.idle_fired("we was going there").is_empty());
    assert_eq!(scheduler.text_changed("we was going there now"), Decision::CheckWhenIdle);
}

#[test]
fn a_dropped_idle_request_can_be_retried() {
    let mut scheduler = Scheduler::new();
    let sent = scheduler.idle_fired("we was going there");
    scheduler.request_failed(&sent);
    assert_eq!(scheduler.text_changed("we was going there"), Decision::CheckWhenIdle);
}

#[test]
fn stale_answers_never_show() {
    let mut scheduler = Scheduler::new();
    scheduler.text_changed(S);
    scheduler.mark_in_flight(&[S.into()]);
    scheduler.record(&[fix(S, "has went", "went")], &[S.into()]);
    assert!(scheduler.findings("I went there yesterday.").is_empty());
}

#[test]
fn seeded_text_is_never_sent() {
    let mut scheduler = Scheduler::new();
    scheduler.seed_as_checked("Dictated text one. Dictated text two");
    assert_eq!(scheduler.text_changed("Dictated text one. Dictated text two"), Decision::Nothing);
    assert_eq!(
        scheduler.text_changed("Dictated text one. Dictated text two. New typed words here."),
        Decision::CheckNow(vec!["New typed words here.".into()])
    );
}

#[test]
fn budget_stops_backs_off_and_caps() {
    let start = 1_000_000;
    let mut budget = Budget::new(2, start);
    assert!(budget.can_send(start));
    budget.record_sent(start);
    budget.record(Outcome::HttpStatus(429), start);
    assert!(!budget.can_send(start + 10));
    assert!(budget.can_send(start + 31));
    budget.record_sent(start + 31);
    assert!(!budget.can_send(start + 32));
    assert!(budget.can_send(start + 86_400 * 2));

    let mut keyed = Budget::new(1000, start);
    keyed.record(Outcome::HttpStatus(401), start);
    assert!(!keyed.can_send(start + 3600));
    keyed.key_changed();
    assert!(keyed.can_send(start));
}

#[test]
fn app_policy() {
    let all = Policy { scope: Scope::AllApps, listed: vec![], skipped: vec!["Private.exe".into()] };
    assert!(all.allows("chrome.exe"));
    assert!(all.allows("slack"));
    assert!(!all.allows("WindowsTerminal.exe"));
    assert!(!all.allows("1Password.exe"));
    assert!(!all.allows("gnome-terminal-server"));
    assert!(!all.allows("private"));
    let listed = Policy { scope: Scope::ListedApps, listed: vec!["notepad.exe".into()], skipped: vec![] };
    assert!(listed.allows("Notepad.exe"));
    assert!(!listed.allows("chrome.exe"));
}

#[test]
fn cleanup_request_matches_the_mac_shape() {
    let messages = [Message { role: "user".into(), content: "texto ditado".into() }];
    let body = anthropic::request_body(anthropic::CLEANUP_MODEL, prompts::CLEANUP_CLEAN_DICTATION, &messages, 300);
    assert_eq!(body["model"], "claude-haiku-5-5");
    assert_eq!(body["thinking"]["type"], "disabled");
    assert!(body.get("temperature").is_none());
    assert_eq!(body["max_tokens"], 300);
    assert_eq!(body["messages"][0]["role"], "user");
}

#[test]
fn replies_are_read_defensively() {
    let ok = br#"{"content":[{"type":"text","text":"Texto limpo."}],"stop_reason":"end_turn"}"#;
    assert_eq!(anthropic::reply_text(200, ok), Ok("Texto limpo.".into()));
    assert_eq!(anthropic::reply_text(200, br#"{"content":[],"stop_reason":"refusal"}"#), Err(Failure::Refusal));
    assert_eq!(
        anthropic::reply_text(401, br#"{"type":"error","error":{"type":"authentication_error","message":"x"}}"#),
        Err(Failure::Http { status: 401, kind: Some("authentication_error".into()) })
    );
    assert_eq!(anthropic::reply_text(402, b""), Err(Failure::OutOfCredits));
}

#[test]
fn prompts_match_the_shared_files_and_vocabulary_is_appended() {
    assert!(prompts::CLEANUP_CLEAN_DICTATION.starts_with("Dictation transcript editor."));
    assert!(!prompts::CLEANUP_LIGHT.ends_with('\n'));
    let with = prompts::cleanup_system_prompt(CleanupStyle::Light, "Trecho\n\n Mimir \n");
    assert!(with.starts_with(prompts::CLEANUP_LIGHT));
    assert!(with.contains("Trecho, Mimir\n"));
    assert_eq!(prompts::cleanup_system_prompt(CleanupStyle::Light, ""), prompts::CLEANUP_LIGHT);
    assert_eq!(prompts::writing_check_examples().len(), 6);
}
