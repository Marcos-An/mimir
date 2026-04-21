# Third-party notices

Mimir is MIT-licensed (see `LICENSE`) and depends on the following open-source
components. Each retains its own license; see the upstream project for the
authoritative terms.

## Swift packages

| Package | License | Upstream |
|---------|---------|----------|
| [WhisperKit](https://github.com/argmaxinc/WhisperKit) | MIT | argmaxinc/WhisperKit |
| [mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm) | MIT | ml-explore/mlx-swift-lm |
| [swift-huggingface](https://github.com/huggingface/swift-huggingface) | Apache-2.0 | huggingface/swift-huggingface |
| [swift-transformers](https://github.com/huggingface/swift-transformers) | Apache-2.0 | huggingface/swift-transformers |
| [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) | MIT | migueldeicaza/SwiftTerm |

## Pretrained models (downloaded on first run)

The app downloads the following models on first use, each under their own terms.
By using Mimir you accept the upstream licenses of the models you choose.

- **WhisperKit models** (Whisper by OpenAI, quantized for Core ML). See
  [argmaxinc/whisperkit-coreml](https://huggingface.co/argmaxinc/whisperkit-coreml).
- **Qwen2.5-3B-Instruct (4-bit, MLX)** — used for optional post-processing. See
  [mlx-community/Qwen2.5-3B-Instruct-4bit](https://huggingface.co/mlx-community/Qwen2.5-3B-Instruct-4bit)
  and the Qwen research license.

## Native frameworks

Apple platform frameworks (`AppKit`, `AVFoundation`, `Speech`, `SwiftUI`) are
used under Apple's standard macOS developer agreements.
