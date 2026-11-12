<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="Assets/MimirWordmark-dark.svg">
    <img src="Assets/MimirWordmark.svg" alt="Mimir" width="260">
  </picture>
</p>

<p align="center">
  <b>Talk instead of typing, in any Mac app. Transcribed on your Mac, never in the cloud.</b>
</p>

<p align="center">
  <a href="https://github.com/Marcos-An/mimir/releases/latest"><img alt="Download for macOS" src="https://img.shields.io/badge/Download-macOS%20(Apple%20Silicon)-1748FF?style=for-the-badge&logo=apple&logoColor=white"></a>
</p>

<p align="center">
  <img alt="macOS 15+" src="https://img.shields.io/badge/macOS-15%2B-152449">
  <img alt="Apple Silicon" src="https://img.shields.io/badge/Apple%20Silicon-M1%2B-152449">
  <img alt="License: MIT" src="https://img.shields.io/badge/license-MIT-152449">
</p>

---

Mimir lives in your menu bar. Tap a shortcut, speak, tap again, and clean text
appears wherever your cursor is: Slack, Mail, your editor, a terminal. Speech
is turned into text by Whisper running on your Mac's Neural Engine, then
tidied by a small local language model. Your voice never leaves the machine.

- **Private by design.** Audio is transcribed on-device. With the default
  settings nothing is sent anywhere. Optional cloud polishing (Claude Haiku)
  sends only the transcribed text, never audio.
- **Fast.** Whisper Large v3 Turbo on the Neural Engine, streaming while you
  speak, so the text is ready a moment after you stop.
- **Clean, not rewritten.** Punctuation, capitalization and filler words are
  fixed; your sentences stay yours.
- **Two shortcuts.** One for plain dictation, one that turns rambling speech
  into a clear prompt for an AI assistant.
- **Works in many languages.** Portuguese, English, Spanish, French, German,
  Italian, Dutch and other European languages, detected automatically.

## Install

1. Download **Mimir-&lt;version&gt;.dmg** from the [latest release](https://github.com/Marcos-An/mimir/releases/latest).
2. Open it and drag **Mimir** to **Applications**.
3. Open Mimir. A setup window asks for three permissions and downloads the
   models (about 2.5 GB, once).

> [!NOTE]
> Releases are not notarized by Apple yet, so the first launch is blocked with
> "Apple could not verify Mimir". Open **System Settings → Privacy & Security**,
> scroll down and click **Open Anyway**. Alternatively run
> `xattr -dr com.apple.quarantine /Applications/Mimir.app` once.
> Because of this, macOS may ask for Accessibility and Input Monitoring again
> after an update.

**Requirements:** macOS 15 Sequoia or newer, a Mac with Apple Silicon (M1 or
later), and about 3 GB of free disk space.

### Permissions

| Permission | Why |
|---|---|
| Microphone | To hear you while you dictate. |
| Accessibility | To paste the text where your cursor is. |
| Input Monitoring | To notice the shortcut while you're in other apps. |

You can reopen the setup window any time from **Settings → Permissions → Setup guide**.

## How to use it

| Shortcut (default) | What it does |
|---|---|
| Tap **Right ⌘**, speak, tap again | Dictate. The cleaned-up text is pasted into the app in front. |
| Tap **⌥ Space**, speak, tap again | Prompt. Turns what you said into a clear, structured prompt. |

- Prefer push-to-talk? Switch **Activation** to *Hold* in Settings.
- Change a shortcut by clicking its keys in **Settings → General** and pressing
  the new ones. Esc cancels.
- Every dictation is kept in the history window (last 200), searchable, with a
  copy button and a timing breakdown in the **…** menu.

## Models

Downloaded from Hugging Face on first run and stored on your Mac.

| Role | Default model | Size |
|---|---|---|
| Speech to text | Whisper Large v3 Turbo ([WhisperKit](https://github.com/argmaxinc/WhisperKit), Core ML) | ~630 MB |
| Cleanup | Qwen2.5 3B Instruct, 4-bit ([MLX](https://github.com/ml-explore/mlx-swift-lm)) | ~1.8 GB |

In **Settings → Pipeline** you can pick a smaller or larger Whisper model,
switch cleanup to Claude Haiku (cloud, text only, your own API key stored in
the Keychain) or turn cleanup off.

## Settings at a glance

| Section | Options |
|---|---|
| General | Dictate and Prompt shortcuts, Tap or Hold activation, spoken language |
| Audio | Microphone (automatic follows the system default) |
| Pipeline | Whisper model and strategy, cleanup provider and style (Light, Clean Dictation, Structured), custom vocabulary, auto-paste |
| Permissions | Live status of each permission, setup guide |

## Privacy

- Audio is recorded to a temporary file, transcribed on-device and deleted.
  Leftovers from a crash are purged on the next launch. The only exception is
  **Keep recent recordings** (off by default), which keeps the last 40 on your
  Mac for diagnosing transcription errors.
- History and settings stay in your user account (`UserDefaults`). The Claude
  API key, if you add one, lives in the Keychain.
- Network access is used only to download models and, if you choose cloud
  cleanup, to send the transcribed text to Anthropic.

## Build from source

Requires Xcode 26 or newer (Swift 6.3 toolchain).

```bash
git clone https://github.com/Marcos-An/mimir.git
cd mimir
bash scripts/build_app.sh
open dist/Mimir.app
```

`build_app.sh` signs the app with a self-signed certificate kept in a local
keychain (`mimir-codesign`), so macOS keeps your permissions across rebuilds.

| Variable | Effect |
|---|---|
| `MIMIR_BUNDLE_ID` | Overrides the bundle identifier (default `dev.mimir.app`). |
| `MIMIR_OUTPUT_DIR` | Where the `.app` is written (default `dist/`). |
| `MIMIR_VERSION`, `MIMIR_BUILD` | Version and build number shown by macOS. |
| `MIMIR_SKIP_CODESIGN=1` | Skips signing. |

Run the tests with `swift test`.

### Making a release

```bash
MIMIR_VERSION=0.3.0 bash scripts/package_release.sh
gh release create v0.3.0 release/Mimir-0.3.0.dmg --title "Mimir 0.3.0" --notes-file notes.md
```

`package_release.sh` builds into `release/` and produces a DMG with the app and
an Applications shortcut. With an Apple Developer ID it also signs with the
hardened runtime and notarizes, which removes the Gatekeeper warning:

```bash
xcrun notarytool store-credentials mimir-notary --apple-id <email> --team-id <TEAMID>   # once

MIMIR_VERSION=0.3.0 \
MIMIR_DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" \
MIMIR_NOTARY_PROFILE=mimir-notary \
bash scripts/package_release.sh
```

## How it works

```
 shortcut ──▶ AVAudioEngine ──▶ WhisperKit (streaming, Neural Engine) ──▶ deterministic cleanup
                                                                              │
                         focused app ◀── clipboard + ⌘V ◀── Qwen 2.5 via MLX ◀┘
```

- `Sources/MimirCore`: recording, transcription, cleanup pipeline, settings, history.
- `Sources/MimirApp`: SwiftUI app, menu bar, recording island, setup, settings.
- `Tests/`: Swift Testing suite.

## Contributing

Issues and pull requests are welcome. Before opening a PR, make sure
`swift test` passes and `swift build -c release` adds no new warnings. UI
strings are in English. For bugs, include your macOS version, chip and, if
relevant, the timing breakdown from the history's **…** menu.

## Credits and license

Mimir is MIT licensed, see [`LICENSE`](LICENSE). It stands on
[WhisperKit](https://github.com/argmaxinc/WhisperKit) by Argmax and
[mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm) by Apple's ML
Explore team. Models downloaded at runtime keep their own licenses, listed with
every dependency in [`NOTICE.md`](NOTICE.md).
