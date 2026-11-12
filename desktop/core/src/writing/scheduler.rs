//! Which sentences to send and when. Port of `WritingCheckScheduler.swift`.
//! Pure logic: the controller calls it on every text change and on idle.

use super::model::{self, AnchoredFinding, Finding};
use std::collections::{HashMap, HashSet, VecDeque};

pub const IDLE_DELAY_MS: u64 = 800;
const MINIMUM_IDLE_WORDS: usize = 4;
const MAX_SENTENCES_PER_REQUEST: usize = 6;
const CACHE_LIMIT: usize = 400;

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Decision {
    Nothing,
    CheckNow(Vec<String>),
    CheckWhenIdle,
}

#[derive(Default)]
pub struct Scheduler {
    results: HashMap<String, Vec<Finding>>,
    order: VecDeque<String>,
    in_flight: HashSet<String>,
    last_idle_sent: Option<String>,
    /// Sentences Mimir pasted or that were already in the field, without
    /// their final punctuation, so typing a period after them doesn't send them.
    seeded: HashSet<String>,
}

fn without_terminator(sentence: &str) -> &str {
    sentence.trim_end_matches(['.', '!', '?'])
}

impl Scheduler {
    pub fn new() -> Self {
        Self::default()
    }

    /// Findings for every sentence of `text` already checked, placed in `text`.
    pub fn findings(&self, text: &str) -> Vec<AnchoredFinding> {
        let cached: Vec<Finding> = model::sentences(text)
            .iter()
            .flat_map(|s| self.results.get(&s.text).cloned().unwrap_or_default())
            .collect();
        model::anchor_all(&cached, text)
    }

    pub fn text_changed(&mut self, text: &str) -> Decision {
        let sentences = model::sentences(text);
        let pending: Vec<String> = sentences
            .iter()
            .filter(|s| s.is_complete && !self.results.contains_key(&s.text) && !self.in_flight.contains(&s.text) && !self.is_seeded(&s.text))
            .map(|s| s.text.clone())
            .collect();
        if !pending.is_empty() {
            let skip = pending.len().saturating_sub(MAX_SENTENCES_PER_REQUEST);
            return Decision::CheckNow(pending[skip..].to_vec());
        }
        match sentences.last() {
            Some(last) if !last.is_complete && self.is_idle_eligible(&last.text) => Decision::CheckWhenIdle,
            _ => Decision::Nothing,
        }
    }

    /// The idle timer fired: the unfinished sentence to send, if any.
    pub fn idle_fired(&mut self, text: &str) -> Vec<String> {
        match model::sentences(text).last() {
            Some(last) if !last.is_complete && self.is_idle_eligible(&last.text) => {
                self.last_idle_sent = Some(last.text.clone());
                vec![last.text.clone()]
            }
            _ => vec![],
        }
    }

    pub fn mark_in_flight(&mut self, sentences: &[String]) {
        self.in_flight.extend(sentences.iter().cloned());
    }

    /// A request answered: store what it found (empty counts as checked).
    pub fn record(&mut self, findings: &[Finding], sentences: &[String]) {
        for sentence in sentences {
            self.in_flight.remove(sentence);
            let own: Vec<Finding> = findings.iter().filter(|f| &f.sentence == sentence).cloned().collect();
            self.store(own, sentence);
        }
    }

    /// A request failed or was not sent: its sentences can go again later.
    pub fn request_failed(&mut self, sentences: &[String]) {
        for sentence in sentences {
            self.in_flight.remove(sentence);
        }
        if self.last_idle_sent.as_ref().is_some_and(|s| sentences.contains(s)) {
            self.last_idle_sent = None;
        }
    }

    /// Text that must never be sent (a dictation, or what was already in a
    /// field when it got focus): every sentence counts as checked.
    pub fn seed_as_checked(&mut self, text: &str) {
        let sentences = model::sentences(text);
        for sentence in &sentences {
            self.seeded.insert(without_terminator(&sentence.text).to_string());
            if self.seeded.len() > CACHE_LIMIT {
                self.seeded.clear();
            }
            if !self.results.contains_key(&sentence.text) {
                self.store(vec![], &sentence.text);
            }
        }
        if let Some(last) = sentences.last() {
            self.last_idle_sent = Some(last.text.clone());
        }
    }

    /// Drops a finding the user chose to ignore.
    pub fn ignore(&mut self, finding: &Finding) {
        if let Some(list) = self.results.get_mut(&finding.sentence) {
            list.retain(|f| f != finding);
        }
    }

    fn is_seeded(&self, sentence: &str) -> bool {
        self.seeded.contains(without_terminator(sentence))
    }

    fn is_idle_eligible(&self, sentence: &str) -> bool {
        !self.results.contains_key(sentence)
            && !self.is_seeded(sentence)
            && !self.in_flight.contains(sentence)
            && self.last_idle_sent.as_deref() != Some(sentence)
            && model::word_count(sentence) >= MINIMUM_IDLE_WORDS
    }

    fn store(&mut self, findings: Vec<Finding>, sentence: &str) {
        if !self.results.contains_key(sentence) {
            self.order.push_back(sentence.to_string());
        }
        self.results.insert(sentence.to_string(), findings);
        if self.order.len() > CACHE_LIMIT {
            if let Some(dropped) = self.order.pop_front() {
                self.results.remove(&dropped);
            }
        }
    }
}
