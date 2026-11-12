//! Claude Messages API, as pure functions: the request body, the reply's
//! text, and what an error means. Port of `AnthropicClient.swift`; the HTTP
//! call itself lives in the app (retry only on a dead connection, never on
//! an HTTP error, which the server may already have billed).

use serde::Serialize;
use serde_json::{json, Value};

pub const ENDPOINT: &str = "https://api.anthropic.com/v1/messages";
pub const API_VERSION: &str = "2023-06-01";
pub const CLEANUP_MODEL: &str = "claude-haiku-5-5";

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Message {
    pub role: String,
    pub content: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Failure {
    /// HTTP error; `kind` is the API's error type, never its message (logs
    /// must not carry text that could echo the user's).
    Http { status: u16, kind: Option<String> },
    Refusal,
    BadPayload,
    EmptyText,
    /// No credit left on the account: every call fails until credits are added.
    OutOfCredits,
}

pub fn request_body(model: &str, system: &str, messages: &[Message], max_tokens: u32) -> Value {
    let mut body = json!({
        "model": model,
        "max_tokens": max_tokens,
        "system": system,
        "messages": messages,
    });
    if model.starts_with("claude-haiku-4") {
        body["temperature"] = json!(0);
    } else {
        // Haiku 5.5 thinks by default; these tasks need no reasoning and
        // thinking only adds latency before the first word.
        body["thinking"] = json!({"type": "disabled"});
    }
    body
}

/// Billing errors: HTTP 402, an error of type `billing_error`, or the
/// "credit balance is too low" 400.
pub fn is_out_of_credits(status: u16, body: &[u8]) -> bool {
    if status == 402 {
        return true;
    }
    if status != 400 && status != 403 {
        return false;
    }
    let Ok(json) = serde_json::from_slice::<Value>(body) else { return false };
    let Some(error) = json.get("error") else { return false };
    if error.get("type").and_then(Value::as_str) == Some("billing_error") {
        return true;
    }
    error.get("message").and_then(Value::as_str).unwrap_or_default().to_lowercase().contains("credit balance")
}

/// The text of a reply, or why there is none.
pub fn reply_text(status: u16, body: &[u8]) -> Result<String, Failure> {
    if status != 200 {
        if is_out_of_credits(status, body) {
            return Err(Failure::OutOfCredits);
        }
        let kind = serde_json::from_slice::<Value>(body)
            .ok()
            .and_then(|v| v.pointer("/error/type").and_then(Value::as_str).map(str::to_string));
        return Err(Failure::Http { status, kind });
    }
    let json: Value = serde_json::from_slice(body).map_err(|_| Failure::BadPayload)?;
    let content = json.get("content").and_then(Value::as_array).ok_or(Failure::BadPayload)?;
    // A declined request comes back as HTTP 200.
    if json.get("stop_reason").and_then(Value::as_str) == Some("refusal") {
        return Err(Failure::Refusal);
    }
    let text: String = content
        .iter()
        .filter(|block| block.get("type").and_then(Value::as_str) == Some("text"))
        .filter_map(|block| block.get("text").and_then(Value::as_str))
        .collect();
    if text.is_empty() { Err(Failure::EmptyText) } else { Ok(text) }
}
