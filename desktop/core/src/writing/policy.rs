//! Which apps the writing check may read. Password fields are blocked
//! separately, in every app. Port of `WritingAppPolicy.swift`, with the
//! Windows and Linux lists compiled in (a privacy list must not depend on a
//! file loading).

use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Scope {
    #[default]
    AllApps,
    ListedApps,
}

/// Never checked, even in "All apps": terminals and code editors, password
/// managers. Windows: lowercased exe name without ".exe"; Linux: process name.
pub const ALWAYS_SKIPPED: &[&str] = &[
    // Windows terminals
    "windowsterminal", "cmd", "powershell", "pwsh", "conhost", "openconsole", "wezterm-gui", "alacritty",
    "mintty", "putty", "tabby",
    // Windows editors
    "code", "code - insiders", "cursor", "windsurf", "devenv", "zed", "sublime_text", "notepad++", "idea64",
    "pycharm64", "webstorm64", "rider64", "studio64",
    // Windows secrets
    "1password", "bitwarden", "keepassxc", "keepass", "lastpass", "dashlane", "nordpass", "protonpass",
    "credentialuibroker",
    // Linux terminals
    "gnome-terminal-server", "kgx", "ptyxis", "konsole", "kitty", "foot", "xterm", "tilix", "xfce4-terminal",
    "ghostty", "terminator",
    // Linux editors
    "code-insiders", "idea", "pycharm", "gnome-builder", "emacs", "gvim",
    // Linux secrets
    "seahorse", "kwalletmanager5", "secrets", "enpass",
];

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Policy {
    pub scope: Scope,
    pub listed: Vec<String>,
    pub skipped: Vec<String>,
}

pub fn normalize_app_id(app: &str) -> String {
    let lower = app.trim().to_lowercase();
    lower.strip_suffix(".exe").map(str::to_string).unwrap_or(lower)
}

impl Policy {
    pub fn allows(&self, app: &str) -> bool {
        let app = normalize_app_id(app);
        let contains = |list: &[String]| list.iter().any(|item| normalize_app_id(item) == app);
        match self.scope {
            Scope::ListedApps => contains(&self.listed),
            Scope::AllApps => !ALWAYS_SKIPPED.contains(&app.as_str()) && !contains(&self.skipped),
        }
    }
}
