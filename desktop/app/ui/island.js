const { invoke } = window.__TAURI__.core;
const { listen } = window.__TAURI__.event;
const $ = (id) => document.getElementById(id);

Object.assign(MIMIR_ICONS, {
  warn: '<svg viewBox="0 0 16 16"><path d="M8 1.8L15 14H1z" fill="currentColor"/><path d="M8 6v4M8 11.8v.1" stroke="#141416" stroke-width="1.6" stroke-linecap="round"/></svg>',
  micSlash: '<svg viewBox="0 0 16 16"><rect x="5.5" y="1.5" width="5" height="8.5" rx="2.5" fill="currentColor"/><path d="M3.5 7.5a4.5 4.5 0 009 0M8 12v2.5M2.5 2l11 12" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/></svg>',
  mic: '<svg viewBox="0 0 16 16"><rect x="5.5" y="1.5" width="5" height="8.5" rx="2.5" fill="currentColor"/><path d="M3.5 7.5a4.5 4.5 0 009 0M8 12v2.5" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/></svg>',
  lines: '<svg viewBox="0 0 16 16"><path d="M2 4h12M2 8h9M2 12h11" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/></svg>',
  sparkle: '<svg viewBox="0 0 16 16"><path d="M8 1l1.6 5.4L15 8l-5.4 1.6L8 15l-1.6-5.4L1 8l5.4-1.6z" fill="currentColor"/></svg>',
});
window.mountIcons();

// Wave: 13 bars, newest level in the centre, older ones mirrored outward.
const BARS = 13;
const wave = $("wave");
for (let i = 0; i < BARS; i++) wave.append(document.createElement("span"));
let levels = new Array(7).fill(0);
function drawWave() {
  const bars = wave.children;
  for (let i = 0; i < BARS; i++) {
    const d = Math.abs(i - 6);
    const v = levels[d] * (1 - d / 8);
    bars[i].style.height = `${3 + v * 15}px`;
  }
}

let phase = "idle";
let startedAt = 0;
let timerTick = null;
let hovering = false;
let noticeTimer = null;

function show(row) {
  for (const id of ["recording", "processing", "notice", "metrics"]) $(id).classList.toggle("hidden", id !== row);
  $("pill").classList.toggle("buttons", row === "recording" && hovering);
  $("pill").classList.add("shown");
  invoke("island_visible", { visible: true });
}

function hide() {
  $("pill").classList.remove("shown");
  setTimeout(() => {
    if (!$("pill").classList.contains("shown")) invoke("island_visible", { visible: false });
  }, 220);
}

function formatTimer(seconds) {
  return `${Math.floor(seconds / 60)}:${String(Math.floor(seconds % 60)).padStart(2, "0")}`;
}

// Progress: base + span * (1 - e^(-t/tau)), never backwards, capped at .99.
const SEGMENTS = { transcribing: [0, 0.45, 2.5], polishing: [0.45, 0.47, 3.5], pasting: [0.92, 0.08, 0.3] };
const LABELS = { transcribing: "Transcribing", polishing: "Polishing", pasting: "Pasting" };
let progress = 0;
let segmentStart = 0;
let progressTick = null;
function startProgress() {
  clearInterval(progressTick);
  progressTick = setInterval(() => {
    const segment = SEGMENTS[phase];
    if (!segment) return;
    const [base, span, tau] = segment;
    const t = (performance.now() - segmentStart) / 1000;
    progress = Math.min(0.99, Math.max(progress, base + span * (1 - Math.exp(-t / tau))));
    $("bar-fill").style.width = `${progress * 100}%`;
  }, 50);
}

function onPhase(next) {
  if (next === phase) return;
  const previous = phase;
  phase = next;
  if (next === "recording") {
    clearTimeout(noticeTimer);
    levels.fill(0);
    drawWave();
    startedAt = performance.now();
    $("timer").textContent = "0:00";
    clearInterval(timerTick);
    timerTick = setInterval(() => ($("timer").textContent = formatTimer((performance.now() - startedAt) / 1000)), 1000);
    show("recording");
  } else if (LABELS[next]) {
    clearInterval(timerTick);
    if (previous === "recording" || previous === "idle") progress = 0;
    segmentStart = performance.now();
    $("phase-label").textContent = LABELS[next];
    show("processing");
    startProgress();
  } else {
    clearInterval(timerTick);
    clearInterval(progressTick);
    if ($("notice").classList.contains("hidden") && $("metrics").classList.contains("hidden")) hide();
  }
}

function flash(row) {
  show(row);
  clearTimeout(noticeTimer);
  noticeTimer = setTimeout(() => {
    $(row).classList.add("hidden");
    if (phase === "idle") hide();
  }, 4000);
}

function short(ms) {
  const s = ms / 1000;
  if (s < 10) return `${s.toFixed(1)}s`;
  if (s < 60) return `${Math.round(s)}s`;
  const m = Math.floor(s / 60);
  const rest = Math.round(s % 60);
  return rest ? `${m}m${rest}s` : `${m}m`;
}

listen("state", (event) => onPhase(event.payload.phase));
listen("level", (event) => {
  levels = [event.payload, ...levels.slice(0, 6)];
  drawWave();
});
listen("notice", (event) => {
  const { kind, text } = event.payload;
  $("notice-icon").className = "notice-icon " + (kind === "error" ? "error" : "info");
  $("notice-icon").innerHTML = MIMIR_ICONS[kind === "error" ? "warn" : "micSlash"];
  $("notice-text").textContent = text;
  flash("notice");
});
listen("metrics", (event) => {
  const { audioMs, sttMs, polishMs } = event.payload;
  const items = [["mic", audioMs, "Recorded"], ["lines", sttMs, "Transcribed in"]];
  if (polishMs) items.push(["sparkle", polishMs, "Polished in"]);
  $("metrics").innerHTML = items
    .map(([icon, ms, tip]) => `<span class="metric" title="${tip} ${short(ms)}">${MIMIR_ICONS[icon]}<b>${short(ms)}</b></span>`)
    .join("");
  flash("metrics");
});

document.addEventListener("mouseenter", () => {
  hovering = true;
  if (phase === "recording") $("pill").classList.add("buttons");
});
document.addEventListener("mouseleave", () => {
  hovering = false;
  $("pill").classList.remove("buttons");
});
$("cancel").addEventListener("click", () => invoke("cancel_dictation"));
$("finish").addEventListener("click", () => invoke("finish_dictation"));
