//! Writing check: which sentences to send, what to keep from Claude's reply,
//! and where each fix sits in the field. Port of `Sources/MimirCore/Writing`.

pub mod budget;
pub mod checker;
pub mod model;
pub mod policy;
pub mod scheduler;
