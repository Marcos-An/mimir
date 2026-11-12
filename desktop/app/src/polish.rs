//! Claude cleanup over HTTP. Request shape, reply checks and prompts come from
//! mimir-core. A failure never blocks the paste: the caller pastes the
//! rule-cleaned transcript instead.

use mimir_core::anthropic::{self, Failure, Message};
use mimir_core::dictation;
use mimir_core::prompts::{cleanup_system_prompt, CleanupStyle};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::LazyLock;
use std::time::Duration;

/// Shared so the connection opened by `warm_up` is reused by the request.
static CLIENT: LazyLock<reqwest::blocking::Client> = LazyLock::new(|| {
    reqwest::blocking::Client::builder()
        .connect_timeout(Duration::from_secs(10))
        .timeout(Duration::from_secs(25))
        .build()
        .expect("HTTP client")
});

pub static OUT_OF_CREDITS: AtomicBool = AtomicBool::new(false);

/// Opens the TLS connection while the user is still talking. A pooled socket
/// left idle for hours can stall the first request for seconds.
pub fn warm_up() {
    std::thread::spawn(|| {
        let _ = CLIENT.head(anthropic::ENDPOINT).timeout(Duration::from_secs(5)).send();
    });
}

pub enum Outcome {
    Polished(String),
    /// Paste the transcript as it is; the reason is for the log.
    Skipped(&'static str),
}

pub fn polish(transcript: &str, style: CleanupStyle, vocabulary: &str, key: &str) -> Outcome {
    let body = anthropic::request_body(
        anthropic::CLEANUP_MODEL,
        &cleanup_system_prompt(style, vocabulary),
        &[Message { role: "user".into(), content: dictation::user_prompt(style, transcript) }],
        dictation::max_tokens(transcript),
    );
    let send = || {
        CLIENT
            .post(anthropic::ENDPOINT)
            .header("x-api-key", key)
            .header("anthropic-version", anthropic::API_VERSION)
            .json(&body)
            .send()
    };
    // Retry only a dead connection; an HTTP error may already be billed.
    let response = match send() {
        Err(e) if e.is_connect() => send(),
        other => other,
    };
    let Ok(response) = response else { return Outcome::Skipped("network") };
    let status = response.status().as_u16();
    let bytes = response.bytes().map(|b| b.to_vec()).unwrap_or_default();
    match anthropic::reply_text(status, &bytes) {
        Ok(text) => {
            OUT_OF_CREDITS.store(false, Ordering::Relaxed);
            match dictation::accept_reply(transcript, &text) {
                Some(cleaned) => Outcome::Polished(cleaned),
                None => Outcome::Skipped("rejected-reply"),
            }
        }
        Err(Failure::OutOfCredits) => {
            OUT_OF_CREDITS.store(true, Ordering::Relaxed);
            Outcome::Skipped("out-of-credits")
        }
        Err(Failure::Http { .. }) => Outcome::Skipped("http-error"),
        Err(_) => Outcome::Skipped("bad-reply"),
    }
}
