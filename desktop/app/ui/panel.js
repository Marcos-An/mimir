const { invoke } = window.__TAURI__.core;
const { listen } = window.__TAURI__.event;
const $ = (id) => document.getElementById(id);

function entry(item, latest) {
  const box = document.createElement("div");
  box.className = "entry " + (latest ? "latest" : "recent");
  const text = document.createElement("p");
  text.textContent = item.text;
  const meta = document.createElement("div");
  meta.className = "meta";
  const when = document.createElement("span");
  when.className = "muted small";
  when.textContent = item.at;
  const copy = document.createElement("button");
  copy.textContent = "Copy";
  copy.addEventListener("click", async () => {
    try {
      await invoke("copy_text", { text: item.text });
      copy.textContent = "Copied";
      setTimeout(() => (copy.textContent = "Copy"), 1500);
    } catch (e) {
      copy.textContent = "Failed";
    }
  });
  meta.append(when, copy);
  box.append(text, meta);
  return box;
}

function render(state) {
  $("title").textContent = state.title;
  const dot = $("dot");
  dot.className = "dot" + (state.phase === "recording" ? " recording" : state.phase === "idle" ? "" : " busy");
  $("hint").innerHTML = "";
  if (state.phase === "recording") {
    $("hint").innerHTML = "<kbd>Esc</kbd> cancels";
  }
  $("credits").classList.toggle("hidden", !state.outOfCredits);
  $("error").classList.toggle("hidden", !state.error);
  $("error").textContent = state.error || "";
  const list = $("entries");
  list.replaceChildren();
  if (state.history.length === 0) {
    const empty = document.createElement("div");
    empty.className = "empty muted";
    const keys = state.shortcut.split("+").map((k) => `<kbd>${k}</kbd>`).join(" + ");
    empty.innerHTML = `Press ${keys} anywhere, speak, and press it again.<br>The text is pasted where you are typing.`;
    list.append(empty);
  } else {
    state.history.forEach((item, i) => list.append(entry(item, i === 0)));
  }
}

$("settings").addEventListener("click", () => invoke("open_settings"));
$("quit").addEventListener("click", () => invoke("quit"));
$("billing").addEventListener("click", () => invoke("open_billing"));
document.addEventListener("keydown", (e) => {
  if (e.key === "Escape") invoke("hide_panel");
});

listen("state", (event) => render(event.payload));
invoke("get_state").then(render);
