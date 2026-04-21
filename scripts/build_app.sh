#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# Build script — empacota o Mimir como um .app executável assinado localmente.
#
# Variáveis de ambiente úteis:
#   MIMIR_BUNDLE_ID   — override do CFBundleIdentifier (default: "dev.mimir.app")
#   MIMIR_OUTPUT_DIR  — diretório de saída do .app (default: "<repo>/dist")
#   MIMIR_SKIP_CODESIGN=1 — pula a assinatura (útil para CI/desenvolvimento)
#
# Saída: "<MIMIR_OUTPUT_DIR>/Mimir.app"
# -----------------------------------------------------------------------------

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Mimir"
BUILD_DIR="$ROOT/.build/arm64-apple-macosx/release"
OUTPUT_DIR="${MIMIR_OUTPUT_DIR:-$ROOT/dist}"
APP_DIR="$OUTPUT_DIR/${APP_NAME}.app"
EXECUTABLE="$BUILD_DIR/MimirApp"
BUNDLE_ID="${MIMIR_BUNDLE_ID:-dev.mimir.app}"
CODESIGN_IDENTITY="Mimir Local Codesign"

if [ "${MIMIR_SKIP_CODESIGN:-0}" != "1" ]; then
    bash "$ROOT/scripts/setup_codesign.sh"
fi

swift build -c release --product MimirApp --package-path "$ROOT" >/tmp/mimir-swift-build.log

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$EXECUTABLE" "$APP_DIR/Contents/MacOS/$APP_NAME"
cp "$ROOT/Assets/Mimir.icns" "$APP_DIR/Contents/Resources/Mimir.icns"
chmod +x "$APP_DIR/Contents/MacOS/$APP_NAME"

RESOURCE_BUNDLE="$BUILD_DIR/Mimir_MimirApp.bundle"
if [ -d "$RESOURCE_BUNDLE" ]; then
    cp -R "$RESOURCE_BUNDLE" "$APP_DIR/Contents/Resources/Mimir_MimirApp.bundle"
fi

# MLX metallib: pure SPM builds don't compile the Metal shaders, so we pull the
# prebuilt metallib from the mlx-swift release xcframework and drop it next to
# the executable where MLX will find it via load_colocated_library("mlx").
MLX_SWIFT_VERSION="0.31.3"
MLX_CACHE="$HOME/Library/Caches/mimir-build"
MLX_ZIP="$MLX_CACHE/Cmlx-$MLX_SWIFT_VERSION.zip"
MLX_DIR="$MLX_CACHE/Cmlx-$MLX_SWIFT_VERSION"
MLX_METALLIB="$MLX_DIR/Cmlx.xcframework/macos-arm64_x86_64/Cmlx.framework/Versions/A/Resources/default.metallib"

if [ ! -f "$MLX_METALLIB" ]; then
    mkdir -p "$MLX_CACHE"
    curl -fsSL -o "$MLX_ZIP" "https://github.com/ml-explore/mlx-swift/releases/download/${MLX_SWIFT_VERSION}/Cmlx.xcframework.zip"
    rm -rf "$MLX_DIR"
    mkdir -p "$MLX_DIR"
    unzip -qq -o "$MLX_ZIP" -d "$MLX_DIR"
fi

cp "$MLX_METALLIB" "$APP_DIR/Contents/MacOS/mlx.metallib"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>Mimir</string>
  <key>CFBundleExecutable</key>
  <string>Mimir</string>
  <key>CFBundleIconFile</key>
  <string>Mimir</string>
  <key>CFBundleIdentifier</key>
  <string>${BUNDLE_ID}</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>Mimir</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.productivity</string>
  <key>LSMinimumSystemVersion</key>
  <string>15.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>Mimir needs microphone access to record your speech locally.</string>
  <key>NSSpeechRecognitionUsageDescription</key>
  <string>Mimir needs speech recognition access to transcribe your voice on-device.</string>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key>
      <string>${BUNDLE_ID}.url</string>
      <key>CFBundleURLSchemes</key>
      <array>
        <string>mimir</string>
      </array>
    </dict>
  </array>
</dict>
</plist>
PLIST

if [ "${MIMIR_SKIP_CODESIGN:-0}" != "1" ]; then
    KEYCHAIN_PATH="$HOME/Library/Keychains/mimir-codesign.keychain-db"
    if codesign --force --deep --keychain "$KEYCHAIN_PATH" -s "$CODESIGN_IDENTITY" "$APP_DIR" >/tmp/mimir-codesign.log 2>&1; then
        :
    else
        # Fallback: ad-hoc signing (identity "-"). Tipo: "codesign para conseguir rodar".
        codesign --force --deep -s - "$APP_DIR" >/tmp/mimir-codesign.log 2>&1 || true
    fi
fi

echo "$APP_DIR"
