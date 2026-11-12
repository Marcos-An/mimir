const { invoke } = window.__TAURI__.core;
const { listen } = window.__TAURI__.event;
const $ = (id) => document.getElementById(id);
const el = (tag, cls, text) => {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (text != null) e.textContent = text;
  return e;
};
const icon = (name) => {
  const span = el("span");
  span.innerHTML = MIMIR_ICONS[name];
  return span.firstChild;
};

let history = [];
let view = null; // settings view from Rust
let query = "";

// ---------- Shortcut labels ----------
const caps = (shortcut) => shortcut.split("+");
function capsText(shortcut) {
  return caps(shortcut).join(" + ");
}

// ---------- Journal ----------
function durationLabel(ms) {
  if (!ms) return null;
  const s = ms / 1000;
  return s < 60 ? `${Math.round(s)}s` : `${Math.floor(s / 60)}m ${Math.round(s % 60)}s`;
}

function timeOf(iso) {
  return new Date(iso).toLocaleTimeString("en-GB", { hour: "2-digit", minute: "2-digit" });
}

function dayTitle(iso) {
  const date = new Date(iso);
  const now = new Date();
  const day = (d) => new Date(d.getFullYear(), d.getMonth(), d.getDate());
  const days = Math.round((day(now) - day(date)) / 86400000);
  if (days === 0) return "Earlier today";
  if (days === 1) return "Yesterday";
  if (days < 7) return date.toLocaleDateString("en-US", { weekday: "long" });
  return date.toLocaleDateString("en-US", { month: "long", day: "numeric" });
}

function card(entry, { featured = false, relative = false } = {}) {
  const box = el("article", "card" + (featured ? " featured" : ""));
  const head = el("div", "card-head");
  if (featured) head.append(el("span", "latest-badge", "Latest"));
  const when = relative ? humanizedDate(entry.at) : timeOf(entry.at);
  const duration = durationLabel(entry.audioMs);
  head.append(el("span", "meta", duration ? `${when} · ${duration}` : when));

  const more = el("button", "card-more");
  more.setAttribute("aria-label", "More");
  more.append(icon("dots"));
  more.addEventListener("click", (e) => {
    e.stopPropagation();
    openMenu(more, [{ label: "Delete transcription", destructive: true, action: () => confirmDelete(entry) }]);
  });
  head.append(more);

  let copy;
  if (featured) {
    copy = el("button", "copy-pill", "Copy");
  } else {
    copy = el("button", "card-copy");
    copy.title = "Copy";
    copy.append(icon("copy"));
  }
  copy.addEventListener("click", async () => {
    await invoke("copy_text", { text: entry.text });
    if (featured) {
      copy.textContent = "Copied";
    } else {
      copy.classList.add("copied");
      copy.replaceChildren(icon("check"));
      copy.title = "Copied";
    }
    setTimeout(() => {
      if (featured) copy.textContent = "Copy";
      else {
        copy.classList.remove("copied");
        copy.replaceChildren(icon("copy"));
        copy.title = "Copy";
      }
    }, 1200);
  });
  head.append(copy);

  const text = el("div", "card-text", entry.text);
  const toggle = el("button", "show-more hidden", "Show more");
  toggle.addEventListener("click", () => {
    const expanded = text.classList.toggle("expanded");
    toggle.textContent = expanded ? "Show less" : "Show more";
  });
  box.append(head, text, toggle);
  requestAnimationFrame(() => {
    if (text.scrollHeight > text.clientHeight + 1) toggle.classList.remove("hidden");
  });
  return box;
}

function groupHeading(title, count) {
  const h = el("div", "group-heading");
  h.append(el("h2", null, title), el("span", null, String(count)));
  return h;
}

function hero() {
  const box = el("section", "hero");
  const mark = el("img", "mark");
  mark.src = "mark.svg";
  mark.alt = "Mimir";
  const copy = el("div");
  copy.append(
    el("h1", null, "Speak, we're listening."),
    el("p", null, "Use your shortcut in any app to turn speech into text. Audio stays on your computer unless you choose cloud transcription. Optional cloud polishing sends only the transcribed text."),
  );
  const steps = el("div", "steps");
  const shortcut = view ? capsText(view.settings.shortcut) : "";
  [["1", "Open any app where you type."], ["2", `Press ${shortcut} and speak normally.`], ["3", "Finish dictation to insert the text in your app."]].forEach(([n, t]) => {
    const row = el("div", "step");
    row.append(el("b", null, n), el("span", null, t));
    steps.append(row);
  });
  box.append(mark, copy, steps);
  return box;
}

function renderJournal() {
  const root = $("journal");
  root.replaceChildren();
  const q = query.trim().toLowerCase();
  if (history.length === 0) {
    root.append(hero());
    return;
  }
  if (q) {
    const results = history.filter((e) => e.text.toLowerCase().includes(q));
    if (results.length === 0) {
      const empty = el("div", "no-results");
      empty.append(el("b", null, `Nothing matches “${query.trim()}”.`), el("span", null, "Try fewer or different words."));
      root.append(empty);
      return;
    }
    const group = el("section", "group");
    const grid = el("div", "grid");
    results.forEach((e) => grid.append(card(e, { relative: true })));
    group.append(groupHeading("Results", results.length), grid);
    root.append(group);
    return;
  }
  const [latest, ...rest] = history;
  root.append(card(latest, { featured: true }));
  const groups = [];
  for (const entry of rest) {
    const title = dayTitle(entry.at);
    if (!groups.length || groups[groups.length - 1].title !== title) groups.push({ title, entries: [] });
    groups[groups.length - 1].entries.push(entry);
  }
  for (const g of groups) {
    const section = el("section", "group");
    const grid = el("div", "grid");
    g.entries.forEach((e) => grid.append(card(e)));
    section.append(groupHeading(g.title, g.entries.length), grid);
    root.append(section);
  }
  const clear = el("button", "clear-history", "Clear history…");
  clear.addEventListener("click", () =>
    alertBox("Delete everything?", `You'll lose ${history.length} transcriptions. This action cannot be undone.`, "Delete", true, async () => {
      history = await invoke("clear_history");
      renderJournal();
    }),
  );
  root.append(clear);
}

function confirmDelete(entry) {
  alertBox("Delete this transcription?", "This action cannot be undone.", "Delete", true, async () => {
    history = await invoke("delete_entry", { id: entry.id });
    renderJournal();
  });
}

// ---------- Menus and alerts ----------
function openMenu(anchor, items, { checked } = {}) {
  const menu = $("menu");
  menu.replaceChildren();
  for (const item of items) {
    const b = el("button", item.destructive ? "destructive" : "");
    const check = el("span", "check", checked !== undefined && item.value === checked ? "✓" : "");
    b.append(check, el("span", null, item.label));
    if (item.disabled) b.disabled = true;
    b.addEventListener("click", () => {
      closeMenu();
      item.action();
    });
    menu.append(b);
  }
  menu.classList.remove("hidden");
  const r = anchor.getBoundingClientRect();
  const width = Math.max(menu.offsetWidth, r.width);
  menu.style.minWidth = `${r.width}px`;
  menu.style.left = `${Math.min(r.left, innerWidth - width - 8)}px`;
  const below = r.bottom + 4;
  menu.style.top = `${below + menu.offsetHeight > innerHeight - 8 ? r.top - menu.offsetHeight - 4 : below}px`;
}
function closeMenu() {
  $("menu").classList.add("hidden");
}
document.addEventListener("click", closeMenu);

function alertBox(title, message, okLabel, destructive, onOk) {
  $("alert-title").textContent = title;
  $("alert-message").textContent = message;
  $("alert-ok").textContent = okLabel;
  $("alert-ok").className = "alert-button " + (destructive ? "destructive" : "primary");
  $("alert-backdrop").classList.remove("hidden");
  $("alert-ok").onclick = () => {
    $("alert-backdrop").classList.add("hidden");
    onOk();
  };
  $("alert-cancel").onclick = () => $("alert-backdrop").classList.add("hidden");
}

// ---------- Settings sheet ----------
const SECTIONS = [
  ["general", "General", "sliders"],
  ["audio", "Audio", "micline"],
  ["pipeline", "Pipeline", "waveform"],
  ["writing", "Writing", "textcheck"],
  ["about", "About", "info"],
];
let section = "general";
let editing = {}; // which inline editors are open

const LANGUAGES = [
  ["auto", "Automatic (system)"], ["pt", "Portuguese"], ["en", "English"], ["es", "Spanish"],
  ["fr", "French"], ["de", "German"], ["it", "Italian"], ["ja", "Japanese"],
];
const STYLES = [["light", "Light cleanup"], ["cleanDictation", "Clean Dictation"], ["structured", "Structured"]];

async function save(patch) {
  const next = { ...view.settings, ...patch };
  await invoke("save_settings", { settings: next });
  view.settings = next;
}

function row(title, subtitle, control, subtitleClass = "") {
  const r = el("div", "row");
  const text = el("div", "row-text");
  text.append(el("div", "row-title", title));
  if (subtitle) text.append(el("div", "row-subtitle " + subtitleClass, subtitle));
  r.append(text);
  if (control) {
    const c = el("div", "row-control");
    [].concat(control).forEach((x) => c.append(x));
    r.append(c);
  }
  return r;
}
const groupLabel = (text) => el("div", "group-label", text);

function segmented(options, value, onChange) {
  const box = el("div", "segmented");
  options.forEach(([v, label]) => {
    const b = el("button", v === value ? "selected" : "", label);
    b.addEventListener("click", () => onChange(v));
    box.append(b);
  });
  return box;
}

function toggle(on, onChange, disabled = false) {
  const b = el("button", "switch" + (on ? " on" : ""));
  b.setAttribute("role", "switch");
  b.setAttribute("aria-checked", String(on));
  b.disabled = disabled;
  b.addEventListener("click", () => onChange(!on));
  return b;
}

function dropdown(options, value, onChange) {
  const b = el("button", "dropdown");
  const current = options.find((o) => o[0] === value);
  b.append(el("span", "label", current ? current[1] : String(value)), icon("chevron"));
  b.addEventListener("click", (e) => {
    e.stopPropagation();
    openMenu(b, options.map(([v, label, disabled]) => ({ value: v, label, disabled, action: () => onChange(v) })), { checked: value });
  });
  return b;
}

function button(label, onClick, cls = "button") {
  const b = el("button", cls, label);
  b.addEventListener("click", onClick);
  return b;
}

function keycaps(shortcut) {
  const box = el("button", "keycaps");
  box.title = "Click to record a new shortcut";
  caps(shortcut).forEach((cap, i) => {
    if (i) box.append(el("span", "plus", "+"));
    box.append(el("span", "keycap", cap));
  });
  return box;
}

function shortcutRow() {
  const s = view.settings;
  if (!editing.shortcut) {
    const capsButton = keycaps(s.shortcut);
    const check = el("span", "saved-check" + (editing.savedFlash ? " on" : ""));
    check.append(icon("check"));
    capsButton.addEventListener("click", () => {
      editing.shortcut = { conflict: null };
      renderSection();
    });
    return row("Dictate", null, [check, capsButton]);
  }
  const recorder = el("div", "recorder" + (editing.shortcut.conflict ? " conflict" : ""));
  recorder.append(el("span", "pulse"), el("span", null, editing.shortcut.live || "Press new shortcut"));
  const subtitle = editing.shortcut.conflict || "Press the new keys. Esc cancels.";
  return row("Dictate", subtitle, recorder, editing.shortcut.conflict ? "red" : "");
}

const KEY_NAMES = { Space: "Space", Enter: "Enter", Tab: "Tab", Backquote: "`", Minus: "-", Equal: "=", Comma: ",", Period: ".", Slash: "/", Backslash: "\\", Semicolon: ";", Quote: "'", BracketLeft: "[", BracketRight: "]" };
function keyName(code) {
  if (code.startsWith("Key")) return code.slice(3);
  if (code.startsWith("Digit")) return code.slice(5);
  if (/^F\d+$/.test(code)) return code;
  return KEY_NAMES[code];
}
document.addEventListener("keydown", async (e) => {
  if (editing.shortcut) {
    e.preventDefault();
    if (e.key === "Escape") {
      editing.shortcut = null;
      renderSection();
      return;
    }
    const mods = [];
    if (e.ctrlKey) mods.push("Ctrl");
    if (e.altKey) mods.push("Alt");
    if (e.shiftKey) mods.push("Shift");
    if (e.metaKey) mods.push("Super");
    const key = keyName(e.code);
    editing.shortcut.live = [...mods, key || ""].filter(Boolean).join(" + ");
    if (!key) {
      renderSection();
      return;
    }
    const next = [...mods, key].join("+");
    if (e.ctrlKey && e.altKey) {
      editing.shortcut.conflict = `${capsText(next)} is what AltGr sends on many keyboards. Try another.`;
    } else if (!mods.length && !/^F\d+$/.test(key)) {
      editing.shortcut.conflict = `${capsText(next)} needs Ctrl, Alt, Shift or Win. Try another.`;
    } else {
      try {
        await save({ shortcut: next });
        editing.shortcut = null;
        editing.savedFlash = true;
        setTimeout(() => {
          editing.savedFlash = false;
          if (section === "general") renderSection();
        }, 1200);
        $("hint-caps").textContent = capsText(next);
      } catch (err) {
        editing.shortcut.conflict = `${capsText(next)} is already used by another app. Try another.`;
      }
    }
    renderSection();
    return;
  }
  if (e.key === "Escape" && !$("sheet-backdrop").classList.contains("hidden")) closeSheet();
});

function keyRow(name, title, subtitle, placeholder) {
  const has = name === "anthropic" ? view.hasAnthropicKey : view.hasGroqKey;
  const state = editing[name] || {};
  if (!state.open) {
    const b = el("button", "value-button");
    b.append(el("span", "value" + (has ? "" : " unset"), has ? "Saved" : "Not set"), icon("pencil"));
    b.addEventListener("click", () => {
      editing[name] = { open: true };
      renderSection();
    });
    return row(title, state.feedback || subtitle, b);
  }
  const input = el("input", "secure");
  input.type = "password";
  input.placeholder = has ? "Paste a new key" : placeholder;
  const commit = async (value) => {
    try {
      await invoke("set_secret", { name, value });
      const fresh = await invoke("get_settings");
      view.hasAnthropicKey = fresh.hasAnthropicKey;
      view.hasGroqKey = fresh.hasGroqKey;
      editing[name] = { feedback: value ? "Key saved." : "Key removed." };
    } catch {
      editing[name] = { open: true, feedback: "Could not save the key." };
    }
    renderSection();
  };
  const controls = [input, button("Save", () => commit(input.value))];
  if (has) controls.push(button("Remove", () => commit("")));
  const x = el("button", "x-button");
  x.append(icon("xmark"));
  x.addEventListener("click", () => {
    editing[name] = null;
    renderSection();
  });
  controls.push(x);
  setTimeout(() => input.focus(), 0);
  input.addEventListener("keydown", (e) => {
    if (e.key === "Enter") commit(input.value);
  });
  return row(title, state.feedback || subtitle, controls);
}

function modelRows() {
  const s = view.settings;
  const model = view.models.find((m) => m.id === s.localModel) || view.models[0];
  const rows = [
    row("Model", null, dropdown(view.models.map((m) => [m.id, m.label]), model.id, (v) => save({ localModel: v }).then(renderSection))),
  ];
  const dl = view.download && view.download.id === model.id ? view.download : null;
  if (!model.downloaded) {
    if (dl) {
      const bar = el("div", "progress");
      const fill = el("div", "progress-fill");
      fill.style.width = `${(dl.done / dl.total) * 100}%`;
      bar.append(fill);
      rows.push(row("Download", "One time only. Everything runs on this computer afterwards.", [bar, el("span", "pct", `${Math.floor((dl.done / dl.total) * 100)}%`)]));
    } else {
      rows.push(row("Download", model.error ? null : "The model downloads once and then works offline.",
        button(model.error ? "Retry" : "Download", () => startDownload(model.id)), ""));
      if (model.error) rows[rows.length - 1].querySelector(".row-text").append(el("div", "row-subtitle red", model.error));
    }
  } else {
    const speed = s.speed && s.speed.model === model.id ? s.speed : null;
    let subtitle = "How long this computer takes to transcribe 30 s of speech.";
    let cls = "";
    let value = null;
    if (view.testing) {
      subtitle = "Testing: transcribing 30 seconds of speech…";
    } else if (speed) {
      value = el("span", "value", `${speed.seconds.toFixed(1)} s`);
      if (speed.seconds > view.slowSeconds) {
        subtitle = `This computer takes about ${speed.seconds.toFixed(1)} s for 30 s of speech. That is slow: Groq (cloud) or a smaller model is recommended.`;
        cls = "orange";
      } else {
        subtitle = "Fast enough to use on this computer.";
        cls = "green";
      }
    }
    const test = button(speed ? "Test again" : "Test speed", runSpeedTest);
    test.disabled = !!view.testing;
    rows.push(row("Speed on this computer", subtitle, value ? [value, test] : test, cls));
  }
  return rows;
}

async function startDownload(id) {
  view.download = { id, done: 0, total: 1 };
  renderSection();
  try {
    await invoke("download_model", { id });
    view = { ...view, ...(await invoke("get_settings")), download: null };
    renderSection();
    runSpeedTest();
  } catch (err) {
    view.download = null;
    const m = view.models.find((x) => x.id === id);
    if (m) m.error = String(err);
    renderSection();
  }
}

async function runSpeedTest() {
  view.testing = true;
  renderSection();
  try {
    view.settings.speed = await invoke("run_speed_test");
  } catch (err) {
    alertBox("Speed test failed", String(err), "OK", false, () => {});
  }
  view.testing = false;
  renderSection();
}

function vocabularyRows() {
  const s = view.settings;
  const terms = s.vocabulary.split("\n").map((t) => t.trim()).filter(Boolean).length;
  if (!editing.vocabulary) {
    const b = el("button", "value-button");
    b.append(el("span", "value", terms === 0 ? "None" : terms === 1 ? "1 term" : `${terms} terms`), icon("pencil"));
    b.addEventListener("click", () => {
      editing.vocabulary = true;
      renderSection();
    });
    return [row("Custom vocabulary", null, b)];
  }
  const area = el("textarea", "editor");
  area.value = s.vocabulary;
  area.spellcheck = false;
  const wrap = el("div", "editor-wrap");
  wrap.append(area);
  setTimeout(() => area.focus(), 0);
  return [
    row("Custom vocabulary", "One term per line: people, projects, product names.", button("Done", async () => {
      await save({ vocabulary: area.value });
      editing.vocabulary = false;
      renderSection();
    })),
    wrap,
  ];
}

const BUILDERS = {
  general() {
    const s = view.settings;
    return [
      shortcutRow(),
      row("Activation", null, segmented([["tap", "Tap"], ["hold", "Hold"]], s.mode, (v) => save({ mode: v }).then(renderSection))),
      row("Appearance", null, segmented([["system", "System"], ["light", "Light"], ["dark", "Dark"]], s.appearance, (v) => save({ appearance: v }).then(renderSection))),
      row("Spoken language", null, dropdown(LANGUAGES, s.language, (v) => save({ language: v }).then(renderSection))),
    ];
  },
  audio() {
    const s = view.settings;
    const mics = view.microphones || [];
    const options = [[null, "Automatic (system)"], ...mics.map((m) => [m, m])];
    if (s.microphone && !mics.includes(s.microphone)) options.push([s.microphone, `Unavailable device (${s.microphone})`]);
    const refresh = el("button", "icon-button");
    refresh.title = "Refresh microphones";
    refresh.append(icon("refresh"));
    refresh.addEventListener("click", async () => {
      view.microphones = await invoke("list_microphones");
      renderSection();
    });
    return [row("Microphone", "Automatic uses the system default.", [dropdown(options, s.microphone ?? null, (v) => save({ microphone: v }).then(renderSection)), refresh])];
  },
  pipeline() {
    const s = view.settings;
    const out = [groupLabel("Transcription")];
    out.push(row("Provider", s.engine === "groq" ? "Audio is sent to Groq to be transcribed." : null,
      dropdown([["local", "Whisper (on this computer)"], ["groq", "Groq (cloud)"]], s.engine, (v) => save({ engine: v }).then(renderSection))));
    if (s.engine === "local") out.push(...modelRows());
    else {
      out.push(keyRow("groq", "Groq API key", "Get a free key at console.groq.com.", "gsk_..."));
    }
    out.push(groupLabel("Cleanup"));
    out.push(row("Dictation", null, dropdown([["off", "Off (basic cleanup only)"], ["claude", "Claude (cloud)"]], s.cleanup ? "claude" : "off",
      (v) => save({ cleanup: v === "claude" }).then(renderSection))));
    if (s.cleanup) {
      out.push(row("Dictation style", null, dropdown(STYLES, s.style, (v) => save({ style: v }).then(renderSection))));
      out.push(row("Leaves your computer", s.engine === "groq"
        ? "The audio goes to Groq and the text of every dictation to Anthropic."
        : "The text of every dictation is sent to Anthropic. Audio stays here."));
      out.push(keyRow("anthropic", "Anthropic API key", "Only text is sent. Audio stays on this computer.", "sk-ant-..."));
      if (view.outOfCredits) {
        out.push(row("Out of credits", "Your Anthropic account is out of credits. Dictations are pasted without cleanup and the writing check is paused until you add credits.",
          button("Add credits", () => invoke("open_billing")), "red"));
      }
    }
    out.push(...vocabularyRows());
    out.push(groupLabel("Insertion"));
    out.push(row("Paste automatically", null, toggle(s.paste, (v) => save({ paste: v }).then(renderSection))));
    return out;
  },
  writing() {
    return [row("Check my writing", "Underlines mistakes while you type. Coming to Windows in the next version.", toggle(false, () => {}, true))];
  },
  about() {
    return [row("Mimir", `Version ${view.version}. Local dictation. Audio stays on this computer unless you pick cloud transcription; optional cloud polishing sends only the transcribed text.`),
      row("Logs", "Counts and timings only, never what you say.", button("Open folder", () => invoke("open_data_folder")))];
  },
};

function renderSidebar() {
  const list = $("sections");
  list.replaceChildren();
  for (const [id, title, ic] of SECTIONS) {
    const b = el("button", "section-link" + (id === section ? " selected" : ""));
    const box = el("span", "box");
    box.append(icon(ic));
    b.append(box, el("span", null, title));
    b.addEventListener("click", () => {
      section = id;
      editing = {};
      renderSidebar();
      renderSection();
    });
    list.append(b);
  }
}

function renderSection() {
  if (!view) return;
  $("section-title").textContent = SECTIONS.find((s) => s[0] === section)[1];
  const body = $("section-body");
  const scroll = body.scrollTop;
  body.replaceChildren(...BUILDERS[section]());
  body.scrollTop = scroll;
}

async function openSheet(which) {
  if (which) section = which;
  view = { ...view, ...(await invoke("get_settings")) };
  view.microphones = await invoke("list_microphones");
  editing = {};
  renderSidebar();
  renderSection();
  $("sheet-backdrop").classList.remove("hidden");
}
function closeSheet() {
  editing = {};
  $("sheet-backdrop").classList.add("hidden");
}

$("gear").addEventListener("click", () => openSheet());
$("close-sheet").addEventListener("click", closeSheet);
$("sheet-backdrop").addEventListener("click", (e) => {
  if (e.target === $("sheet-backdrop")) closeSheet();
});
$("restore").addEventListener("click", () =>
  alertBox("Restore default settings?", "Shortcuts, models, and preferences go back to their defaults. Your history is kept.", "Restore", false, async () => {
    view = { ...view, ...(await invoke("restore_defaults")) };
    $("hint-caps").textContent = capsText(view.settings.shortcut);
    renderSection();
  }),
);

$("search").addEventListener("input", (e) => {
  query = e.target.value;
  $("clear-search").classList.toggle("hidden", !query);
  renderJournal();
});
$("clear-search").addEventListener("click", (e) => {
  e.preventDefault();
  query = "";
  $("search").value = "";
  $("search").blur();
  $("clear-search").classList.add("hidden");
  renderJournal();
});

listen("history", (event) => {
  history = event.payload;
  renderJournal();
});
listen("download", (event) => {
  if (!view) return;
  view.download = event.payload;
  if (section === "pipeline" && !$("sheet-backdrop").classList.contains("hidden")) renderSection();
});
listen("state", (event) => {
  if (view) view.outOfCredits = event.payload.outOfCredits;
});
listen("open-settings", (event) => openSheet(event.payload || undefined));

(async () => {
  view = await invoke("get_settings");
  if (location.hash.startsWith("#settings")) openSheet(location.hash.split(":")[1]);
  $("hint-caps").textContent = capsText(view.settings.shortcut);
  history = await invoke("get_history");
  renderJournal();
})();
