# Mimir

100% local dictation for macOS. Records your voice, transcribes it on-device
(WhisperKit), runs an optional cleanup pass through a local LLM (MLX), and
pastes the text into whatever app is in front. Nothing ever leaves your
machine.

> ⚠️ **Early stage.** Stable for personal use, but expect occasional
> performance regressions. PRs welcome.

## Highlights

- **Fully offline** — audio and text never leave the device.
- **Configurable global trigger** (default: Right ⌘, tap-to-toggle).
- **Streaming preview** — the LLM output appears token-by-token on the island while it generates.
- **Visual telemetry** — popover with fast/normal/slow verdict, proportional
  bar showing where the time went, comparison against the median of recent sessions.
- **Local history** in `UserDefaults` (last 200 dictations with metrics).
- **Automatic language detection** — works with Portuguese, English, Spanish,
  French, German, Italian, Japanese, and more out of the box.

## Requirements

- macOS 15 (Sequoia) or newer
- Apple Silicon (M1+) — MLX and the quantized Whisper models are tuned for ANE/GPU
- Xcode 26+ with Swift 6.3+ toolchain
- ~3 GB of free disk for the models (Whisper Large V3 Turbo Quantized + Qwen2.5-3B 4-bit)

## Install (from source)

```bash
git clone https://github.com/<your-user>/mimir.git
cd mimir
swift build -c release
bash scripts/build_app.sh
open dist/Mimir.app
```

`build_app.sh` creates a local keychain (`mimir-codesign`) with a self-signed
certificate so the binary gets a stable code signature — required for macOS to
grant permissions (Input Monitoring, Accessibility) without revoking them on
every rebuild. Useful environment variables:

- `MIMIR_BUNDLE_ID=dev.yourname.mimir` — overrides `CFBundleIdentifier`.
- `MIMIR_OUTPUT_DIR=/custom/path` — output directory for the `.app`.
- `MIMIR_SKIP_CODESIGN=1` — skips signing (useful in CI).

## First run

1. Open the freshly built `Mimir.app`.
2. macOS will ask for three permissions:
   - **Microphone** — to capture audio.
   - **Input Monitoring** — to detect the global shortcut.
   - **Accessibility** — to send the final `⌘V` into the focused app.
3. On the first dictation the models are downloaded from Hugging Face:
   - Whisper Large V3 Turbo Quantized (~950 MB) via WhisperKit
   - Qwen2.5-3B Instruct 4-bit (~1.8 GB) via mlx-community
   - Takes a few minutes and only happens once per model.
4. Hold the trigger (default: **tap Right ⌘**), speak, tap again, and the text shows up.

## Main settings (UI → Settings)

| Category | Options |
|-----------|--------|
| Dictation trigger | Plain modifier (Right ⌘/⌥/⇧), modifier + key, hold-to-talk or tap-to-toggle. Default: tap Right ⌘ → Clean Dictation |
| Prompt / Rewrite trigger | Separate hotkey that forces the prompt-engineering polish intent. Default: ⌥ Space |
| Transcription | WhisperKit (Core ML) — other providers are placeholders |
| Whisper strategy | Chunked (streaming + warmup) or Batch (whole file) |
| Whisper model | tiny / base / small / medium / large-v3 / large-v3-turbo / **large-v3-turbo quantized (default)** |
| Post-processing | MLX (Qwen2.5-3B) or disabled |
| Post-processing style | Light cleanup (spelling/diacritics), **Clean Dictation (default — punctuation, removes filler/pauses, no restructuring)**, or Structured (punctuation, paragraphs, lists when obvious) |
| Insertion | Clipboard + synthetic paste |
| Preferred language | Forces Whisper to decode in a specific variant; Automatic by default |

## Hermes integration (optional)

Mimir has a built-in panel for a separate CLI called **Hermes**. If you don't
use Hermes, the panel sits idle and shows instructions — the rest of the app
works normally.

To enable:
- Install the `hermes` binary anywhere on your `PATH` (Mimir looks in
  `~/.local/bin/hermes` by default), or
- Set `HERMES_PATH=/path/to/hermes` before launching Mimir.

## Architecture at a glance

```
┌─────────────┐   audio    ┌───────────────────┐  transcript   ┌─────────────┐
│ AVAudio     │──────────▶│ WhisperKitProvider │──────────────▶│ MLX Post    │
│ Engine tap  │  chunks +  │   (Chunked/Batch)  │    SpeechTR   │ Processor   │
└─────────────┘  full WAV  └───────────────────┘                └──────┬──────┘
                                                                       │ final text
                                                                       ▼
                                                              ┌─────────────┐
                                                              │ Clipboard + │
                                                              │ synthetic ⌘V│
                                                              └─────────────┘
```

Sources live in `Sources/MimirCore` (logic, pipeline, models) and
`Sources/MimirApp` (SwiftUI, controllers, UI). Tests in `Tests/`.

## Contributing

PRs are welcome. Before sending one:

1. `swift test` passes.
2. `swift build -c release` with no new warnings.
3. Keep UI strings in English.

Detailed bug reports (macOS version, chip, `/tmp/mimir-swift-build.log`)
help a lot.

## Credits

See `NOTICE.md` for the full list of dependencies and licenses. In
particular, special thanks to the folks behind **argmaxinc/WhisperKit** and
**ml-explore/mlx-swift-lm**, without whom this project would not exist.

## License

MIT — see `LICENSE`. The models downloaded at runtime have their own
licenses; see `NOTICE.md`.
