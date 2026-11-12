const { invoke } = window.__TAURI__.core;
const { listen } = window.__TAURI__.event;
const $ = (id) => document.getElementById(id);

let view = null;
let shortcut = "";

function radio(name) {
  return document.querySelector(`input[name=${name}]:checked`)?.value;
}

function setRadio(name, value) {
  const input = document.querySelector(`input[name=${name}][value=${value}]`);
  if (input) input.checked = true;
}

function showStatus(id, text, kind = "muted") {
  const el = $(id);
  el.className = "status small " + kind;
  el.textContent = text;
}

function selectedModel() {
  return view.models.find((m) => m.id === $("model").value);
}

function speedLine() {
  const speed = view.settings.speed;
  const model = selectedModel();
  if (!model.downloaded) {
    showStatus("local-status", "Download the model to use it. The download happens once.");
    return;
  }
  if (!speed || speed.model !== model.id) {
    showStatus("local-status", "Downloaded. Test the speed to see how this computer handles it.");
    return;
  }
  const seconds = speed.seconds.toFixed(1);
  if (speed.seconds > view.slowSeconds) {
    showStatus("local-status",
      `This computer takes about ${seconds} s to transcribe 30 s of speech. That is slow: Groq (cloud) or a smaller model is recommended.`, "warn");
  } else {
    showStatus("local-status", `This computer takes about ${seconds} s to transcribe 30 s of speech. Good for local use.`, "ok");
  }
}

function refreshEngine() {
  const local = radio("engine") === "local";
  $("local-options").classList.toggle("hidden", !local);
  $("groq-options").classList.toggle("hidden", local);
  $("groq-status").classList.toggle("hidden", local);
  const model = selectedModel();
  $("download").classList.toggle("hidden", model.downloaded);
  $("speed").classList.toggle("hidden", !model.downloaded);
  speedLine();
}

function keyStatus() {
  showStatus("groq-status", view.hasGroqKey ? "Groq key saved." : "No Groq key yet.", view.hasGroqKey ? "ok" : "muted");
  showStatus("anthropic-status", view.hasAnthropicKey ? "Anthropic key saved." : "No Anthropic key yet: basic cleanup only.",
    view.hasAnthropicKey ? "ok" : "muted");
}

async function load() {
  view = await invoke("get_settings");
  const s = view.settings;
  shortcut = s.shortcut;
  $("shortcut").textContent = shortcut;
  setRadio("mode", s.mode);
  setRadio("engine", s.engine);
  $("model").replaceChildren(...view.models.map((m) => {
    const option = document.createElement("option");
    option.value = m.id;
    option.textContent = m.label + (m.downloaded ? "" : " (not downloaded)");
    return option;
  }));
  $("model").value = s.localModel;
  $("language").value = s.language;
  $("cleanup").checked = s.cleanup;
  $("style").value = s.style;
  $("vocabulary").value = s.vocabulary;
  keyStatus();
  refreshEngine();
}

function collect() {
  return {
    ...view.settings,
    shortcut,
    mode: radio("mode"),
    engine: radio("engine"),
    localModel: $("model").value,
    language: $("language").value,
    cleanup: $("cleanup").checked,
    style: $("style").value,
    vocabulary: $("vocabulary").value,
  };
}

async function save() {
  try {
    await invoke("save_settings", { settings: collect() });
    view.settings = collect();
    $("save-status").className = "small ok";
    $("save-status").textContent = "Saved.";
    showStatus("shortcut-status", "");
    setTimeout(() => ($("save-status").textContent = ""), 2000);
  } catch (e) {
    $("save-status").className = "small error";
    $("save-status").textContent = String(e);
  }
}

// Shortcut capture.
const KEY_NAMES = { Space: "Space", Enter: "Enter", Tab: "Tab", Backquote: "`", Minus: "-", Equal: "=", Comma: ",", Period: ".", Slash: "/" };
function keyName(code) {
  if (code.startsWith("Key")) return code.slice(3);
  if (code.startsWith("Digit")) return code.slice(5);
  if (/^F\d+$/.test(code)) return code;
  return KEY_NAMES[code];
}
let listening = false;
$("shortcut").addEventListener("click", () => {
  listening = true;
  $("shortcut").classList.add("listening");
  $("shortcut").textContent = "Press the keys…";
});
$("shortcut").addEventListener("blur", () => {
  if (listening) {
    listening = false;
    $("shortcut").classList.remove("listening");
    $("shortcut").textContent = shortcut;
  }
});
document.addEventListener("keydown", (e) => {
  if (!listening) return;
  e.preventDefault();
  if (e.key === "Escape") {
    $("shortcut").blur();
    return;
  }
  const key = keyName(e.code);
  if (!key) return; // a modifier on its own: keep waiting
  const mods = [];
  if (e.ctrlKey) mods.push("Ctrl");
  if (e.altKey) mods.push("Alt");
  if (e.shiftKey) mods.push("Shift");
  if (e.metaKey) mods.push("Super");
  if (e.ctrlKey && e.altKey) {
    showStatus("shortcut-status", "Ctrl+Alt is what AltGr sends on many keyboards. Pick another combination.", "error");
    return;
  }
  if (mods.length === 0 && !/^F\d+$/.test(key)) {
    showStatus("shortcut-status", "Use at least one of Ctrl, Alt, Shift or Win with that key.", "error");
    return;
  }
  shortcut = [...mods, key].join("+");
  listening = false;
  $("shortcut").classList.remove("listening");
  $("shortcut").textContent = shortcut;
  showStatus("shortcut-status", "Click Save to use it.", "muted");
});

document.querySelectorAll("input[name=engine]").forEach((r) => r.addEventListener("change", refreshEngine));
$("model").addEventListener("change", refreshEngine);

$("download").addEventListener("click", async () => {
  const model = selectedModel();
  $("download").disabled = true;
  $("progress").classList.remove("hidden");
  showStatus("local-status", "Downloading…");
  try {
    await invoke("download_model", { id: model.id });
    await save();
    await load();
    $("speed").click();
  } catch (e) {
    showStatus("local-status", String(e), "error");
  } finally {
    $("download").disabled = false;
    $("progress").classList.add("hidden");
  }
});

listen("download", (event) => {
  const { done, total } = event.payload;
  $("progress").value = done / total;
  showStatus("local-status", `Downloading… ${Math.round(done / 1e6)} of ${Math.round(total / 1e6)} MB`);
});

$("speed").addEventListener("click", async () => {
  $("speed").disabled = true;
  showStatus("local-status", "Testing: transcribing 30 seconds of speech…");
  try {
    await invoke("save_settings", { settings: collect() });
    view.settings.speed = await invoke("run_speed_test");
    speedLine();
  } catch (e) {
    showStatus("local-status", String(e), "error");
  } finally {
    $("speed").disabled = false;
  }
});

async function saveKey(name, input, statusId) {
  try {
    await invoke("set_secret", { name, value: $(input).value });
    $(input).value = "";
    const fresh = await invoke("get_settings");
    view.hasGroqKey = fresh.hasGroqKey;
    view.hasAnthropicKey = fresh.hasAnthropicKey;
    keyStatus();
    refreshEngine();
  } catch (e) {
    showStatus(statusId, String(e), "error");
  }
}
$("groq-save").addEventListener("click", () => saveKey("groq", "groq-key", "groq-status"));
$("anthropic-save").addEventListener("click", () => saveKey("anthropic", "anthropic-key", "anthropic-status"));
$("groq-get").addEventListener("click", () => invoke("open_url", { url: "https://console.groq.com/keys" }));
$("anthropic-get").addEventListener("click", () => invoke("open_url", { url: "https://console.anthropic.com/settings/keys" }));
$("save").addEventListener("click", save);
$("folder").addEventListener("click", () => invoke("open_data_folder"));

load();
