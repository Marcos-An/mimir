const { invoke } = window.__TAURI__.core;
const { listen } = window.__TAURI__.event;
const $ = (id) => document.getElementById(id);



const STATUS = { idle: "Ready", recording: "Recording", transcribing: "Transcribing", polishing: "Thinking", pasting: "Inserting" };
let latestText = null;
let copyTimer = null;

function setCopyButton(copied) {
  const button = $("copy-latest");
  button.classList.toggle("copied", copied);
  button.querySelector(".icon").innerHTML = MIMIR_ICONS[copied ? "check" : "copy"];
  button.querySelector(".copy-label").textContent = copied ? "Copied" : "Copy";
  button.setAttribute("aria-label", copied ? "Copied" : "Copy latest text");
}

function recentItem(entry) {
  const item = document.createElement("button");
  item.className = "recent-item";
  item.title = "Click to copy";
  item.innerHTML = `<span class="recent-date"></span><span class="recent-text"></span><span class="recent-icon">${MIMIR_ICONS.copy}</span>`;
  item.querySelector(".recent-date").textContent = humanizedDate(entry.at);
  item.querySelector(".recent-text").textContent = entry.text;
  item.addEventListener("click", async () => {
    await invoke("copy_text", { text: entry.text });
    item.classList.add("copied");
    item.querySelector(".recent-icon").innerHTML = MIMIR_ICONS.check;
    setTimeout(() => {
      item.classList.remove("copied");
      item.querySelector(".recent-icon").innerHTML = MIMIR_ICONS.copy;
    }, 1200);
  });
  return item;
}

function render(state) {
  const error = state.error;
  $("status").textContent = error ? `Error — ${error}` : STATUS[state.phase];
  $("dot").className = "status-dot " + (error ? "error" : state.phase === "idle" ? "idle" : state.phase === "recording" ? "recording" : "busy");
  const hold = state.mode === "hold";
  $("verb").textContent = hold ? "Hold" : "Tap";
  $("trail").textContent = hold ? "and speak." : "to start/stop.";
  $("shortcut").textContent = state.shortcut;

  const credits = state.outOfCredits;
  $("credits").classList.toggle("hidden", !credits);
  $("credits-divider").classList.toggle("hidden", !credits);

  const download = state.download;
  $("download").classList.toggle("hidden", !download);
  $("download-divider").classList.toggle("hidden", !download);
  if (download) {
    const fraction = download.done / download.total;
    $("download-pct").textContent = `${Math.floor(fraction * 100)}%`;
    $("download-bar").style.width = `${fraction * 100}%`;
  }

  const [latest, ...rest] = state.history;
  latestText = latest ? latest.text : null;
  $("copy-latest").classList.toggle("hidden", !latest);
  const text = $("latest-text");
  text.classList.toggle("placeholder", !latest);
  text.textContent = latest ? latest.text : state.phase !== "idle" ? "Processing…" : "Say something to get started.";
  $("earlier").classList.toggle("hidden", rest.length === 0);
  $("recent").replaceChildren(...rest.slice(0, 3).map(recentItem));
}

$("copy-latest").addEventListener("click", async () => {
  if (latestText == null) return;
  await invoke("copy_text", { text: latestText });
  setCopyButton(true);
  clearTimeout(copyTimer);
  copyTimer = setTimeout(() => setCopyButton(false), 1500);
});
$("open").addEventListener("click", () => invoke("open_main"));
$("billing").addEventListener("click", (e) => {
  e.preventDefault();
  invoke("open_billing");
});
$("more").addEventListener("click", (e) => {
  e.stopPropagation();
  $("more-menu").classList.toggle("hidden");
});
document.addEventListener("click", () => $("more-menu").classList.add("hidden"));
$("quit").addEventListener("click", () => invoke("quit"));
document.addEventListener("keydown", (e) => {
  if (e.key === "Escape") invoke("hide_panel");
});

// The window fits the panel's height, like the Mac's anchored panel.
new ResizeObserver(() => invoke("fit_panel", { height: document.querySelector(".panel").offsetHeight })).observe(
  document.querySelector(".panel"),
);

listen("state", (event) => render(event.payload));
invoke("get_state").then(render);
