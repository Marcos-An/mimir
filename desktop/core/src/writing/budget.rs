//! Keeps the writing check cheap when something goes wrong: a pause on a bad
//! key, growing backoff on any other failure, and a daily cap. Port of
//! `WritingRequestBudget` (WritingCheckScheduler.swift).

use chrono::{DateTime, Local, TimeZone};
use serde::{Deserialize, Serialize};

pub const DEFAULT_DAILY_CAP: u32 = 1000;

/// Seconds since the Unix epoch; injected so tests control the clock.
pub type Seconds = i64;

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Budget {
    pub daily_cap: u32,
    day: String,
    sent_today: u32,
    blocked_until: Option<Seconds>,
    pub key_rejected: bool,
    backoff: i64,
}

pub enum Outcome {
    Success,
    HttpStatus(u16),
    OtherFailure,
}

fn day_key(now: Seconds) -> String {
    let local: DateTime<Local> = Local.timestamp_opt(now, 0).single().unwrap_or_else(Local::now);
    local.format("%Y-%m-%d").to_string()
}

impl Budget {
    pub fn new(daily_cap: u32, now: Seconds) -> Self {
        Self { daily_cap, day: day_key(now), sent_today: 0, blocked_until: None, key_rejected: false, backoff: 0 }
    }

    pub fn can_send(&self, now: Seconds) -> bool {
        if self.key_rejected || self.blocked_until.is_some_and(|until| now < until) {
            return false;
        }
        self.sent_on(now) < self.daily_cap
    }

    pub fn sent_on(&self, now: Seconds) -> u32 {
        if day_key(now) == self.day { self.sent_today } else { 0 }
    }

    pub fn record_sent(&mut self, now: Seconds) {
        let today = day_key(now);
        if today != self.day {
            self.day = today;
            self.sent_today = 0;
        }
        self.sent_today += 1;
    }

    pub fn record(&mut self, outcome: Outcome, now: Seconds) {
        match outcome {
            Outcome::Success => {
                self.backoff = 0;
                self.blocked_until = None;
            }
            Outcome::HttpStatus(401 | 403) => self.key_rejected = true,
            Outcome::HttpStatus(_) | Outcome::OtherFailure => {
                self.backoff = if self.backoff == 0 { 30 } else { (self.backoff * 2).min(600) };
                self.blocked_until = Some(now + self.backoff);
            }
        }
    }

    /// The key changed in Settings: try again.
    pub fn key_changed(&mut self) {
        self.key_rejected = false;
        self.backoff = 0;
        self.blocked_until = None;
    }
}
