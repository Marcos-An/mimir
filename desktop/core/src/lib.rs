//! Platform-neutral logic shared by the Windows and Linux app. Ported from the
//! Swift sources in `Sources/MimirCore`; `shared/fixtures` pins both to the
//! same behaviour. No OS APIs here, so every test runs on any machine.

pub mod anthropic;
pub mod cleaner;
pub mod prompts;
pub mod utf16;
pub mod writing;
