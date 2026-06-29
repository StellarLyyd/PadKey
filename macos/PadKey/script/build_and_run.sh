#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
PRODUCT_NAME="padkey"
APP_NAME="PadKey"
BUNDLE_ID="com.stellarlyyd.padkey"
MIN_SYSTEM_VERSION="13.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
BUILD_DIST_DIR="${TMPDIR:-/tmp}/padkey-build"
APP_BUNDLE="$BUILD_DIST_DIR/$APP_NAME.app"
INSTALL_DIR="${PADKEY_INSTALL_DIR:-$HOME/Applications}"
PUBLISHED_APP_BUNDLE="$INSTALL_DIR/$APP_NAME.app"
DIST_APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$PRODUCT_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
WHISPER_SUPPORT="$ROOT_DIR/Support/Whisper"
SHERPA_SUPPORT="$ROOT_DIR/Support/Sherpa"
MEGA_ASR_SUPPORT="$ROOT_DIR/Support/MegaASR"
APP_ICON="$ROOT_DIR/Assets/AppIcon.icns"
PADKEY_LOGO="$ROOT_DIR/Assets/PadKeyLogo.svg"
STUDIO_ROOT="$ROOT_DIR/../../padkey-studio"
STUDIO_DIST="$STUDIO_ROOT/dist"
SIGN_IDENTITY="${PADKEY_CODESIGN_IDENTITY:-}"

cd "$ROOT_DIR"

find_development_identity() {
  /usr/bin/security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' \
    | head -1
}

if [ -z "$SIGN_IDENTITY" ]; then
  SIGN_IDENTITY="$(find_development_identity)"
fi

if [ -z "$SIGN_IDENTITY" ]; then
  SIGN_IDENTITY="-"
fi

pkill -x "$PRODUCT_NAME" >/dev/null 2>&1 || true

if [ ! -d "$STUDIO_ROOT/node_modules" ]; then
  npm --prefix "$STUDIO_ROOT" ci
fi
npm --prefix "$STUDIO_ROOT" run build -- --base=/studio/

swift build --product "$PRODUCT_NAME"
BUILD_BINARY="$(swift build --show-bin-path)/$PRODUCT_NAME"

rm -rf "$APP_BUNDLE" "$PUBLISHED_APP_BUNDLE" "$DIST_APP_BUNDLE"
mkdir -p "$BUILD_DIST_DIR" "$DIST_DIR" "$INSTALL_DIR"
mkdir -p "$APP_MACOS" "$APP_RESOURCES"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"

if [ -x "$WHISPER_SUPPORT/bin/whisper-cli" ]; then
  mkdir -p "$APP_RESOURCES/Whisper/bin"
  cp "$WHISPER_SUPPORT/bin/whisper-cli" "$APP_RESOURCES/Whisper/bin/whisper-cli"
  chmod +x "$APP_RESOURCES/Whisper/bin/whisper-cli"
fi

if compgen -G "$WHISPER_SUPPORT/lib/*.dylib" >/dev/null; then
  mkdir -p "$APP_RESOURCES/Whisper/lib"
  cp -P "$WHISPER_SUPPORT"/lib/*.dylib "$APP_RESOURCES/Whisper/lib/"
fi

if compgen -G "$WHISPER_SUPPORT/models/ggml-*.bin" >/dev/null; then
  mkdir -p "$APP_RESOURCES/Whisper/models"
  cp "$WHISPER_SUPPORT"/models/ggml-*.bin "$APP_RESOURCES/Whisper/models/"
fi

if [ -x "$SHERPA_SUPPORT/bin/sherpa-onnx-microphone" ]; then
  mkdir -p "$APP_RESOURCES/Sherpa/bin"
  cp "$SHERPA_SUPPORT/bin/sherpa-onnx-microphone" "$APP_RESOURCES/Sherpa/bin/sherpa-onnx-microphone"
  chmod +x "$APP_RESOURCES/Sherpa/bin/sherpa-onnx-microphone"
fi

if [ -x "$SHERPA_SUPPORT/bin/sherpa-onnx" ]; then
  mkdir -p "$APP_RESOURCES/Sherpa/bin"
  cp "$SHERPA_SUPPORT/bin/sherpa-onnx" "$APP_RESOURCES/Sherpa/bin/sherpa-onnx"
  chmod +x "$APP_RESOURCES/Sherpa/bin/sherpa-onnx"
fi

if compgen -G "$SHERPA_SUPPORT/lib/*.dylib" >/dev/null; then
  mkdir -p "$APP_RESOURCES/Sherpa/lib"
  cp -P "$SHERPA_SUPPORT"/lib/*.dylib "$APP_RESOURCES/Sherpa/lib/"
fi

if [ -d "$SHERPA_SUPPORT/models" ]; then
  mkdir -p "$APP_RESOURCES/Sherpa/models"
  cp -R "$SHERPA_SUPPORT/models/." "$APP_RESOURCES/Sherpa/models/"
fi

if [ -x "$MEGA_ASR_SUPPORT/bin/crispasr" ]; then
  mkdir -p "$APP_RESOURCES/MegaASR/bin"
  cp "$MEGA_ASR_SUPPORT/bin/crispasr" "$APP_RESOURCES/MegaASR/bin/crispasr"
  chmod +x "$APP_RESOURCES/MegaASR/bin/crispasr"
fi

if compgen -G "$MEGA_ASR_SUPPORT/lib/*.dylib" >/dev/null; then
  mkdir -p "$APP_RESOURCES/MegaASR/lib"
  cp -P "$MEGA_ASR_SUPPORT"/lib/*.dylib "$APP_RESOURCES/MegaASR/lib/"
fi

if compgen -G "$MEGA_ASR_SUPPORT/models/*.gguf" >/dev/null; then
  mkdir -p "$APP_RESOURCES/MegaASR/models"
  cp "$MEGA_ASR_SUPPORT"/models/*.gguf "$APP_RESOURCES/MegaASR/models/"
fi

if [ -f "$APP_ICON" ]; then
  cp "$APP_ICON" "$APP_RESOURCES/AppIcon.icns"
fi

if [ -f "$PADKEY_LOGO" ]; then
  cp "$PADKEY_LOGO" "$APP_RESOURCES/PadKeyLogo.svg"
fi

if [ -f "$STUDIO_DIST/index.html" ]; then
  mkdir -p "$APP_RESOURCES/Studio"
  cp -R "$STUDIO_DIST/." "$APP_RESOURCES/Studio/"
else
  echo "PadKey Studio build is missing at $STUDIO_DIST" >&2
  exit 1
fi

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$PRODUCT_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSAppleEventsUsageDescription</key>
  <string>PadKey Mac Control uses app automation only when you ask it to create notes, prepare calls, or control another Mac app.</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>PadKey records your voice so it can transcribe dictation.</string>
  <key>NSBluetoothAlwaysUsageDescription</key>
  <string>PadKey connects to the PadKey sensor device for wireless signal and audio capture.</string>
  <key>NSLocalNetworkUsageDescription</key>
  <string>PadKey connects directly to your PadKey sensor device over your local Wi-Fi network.</string>
  <key>NSBonjourServices</key>
  <array><string>_ws._tcp</string></array>
  <key>NSSpeechRecognitionUsageDescription</key>
  <string>PadKey uses speech recognition to turn your voice into text.</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

/usr/bin/xattr -cr "$APP_BUNDLE" 2>/dev/null || true
/usr/bin/find "$APP_BUNDLE" -exec /usr/bin/xattr -d com.apple.FinderInfo {} \; 2>/dev/null || true
/usr/bin/find "$APP_BUNDLE" -exec /usr/bin/xattr -d 'com.apple.fileprovider.fpfs#P' {} \; 2>/dev/null || true
/usr/bin/xattr -d com.apple.FinderInfo "$APP_BUNDLE" 2>/dev/null || true
/usr/bin/xattr -d 'com.apple.fileprovider.fpfs#P' "$APP_BUNDLE" 2>/dev/null || true
/usr/bin/xattr -d com.apple.FinderInfo "$APP_CONTENTS" 2>/dev/null || true
/usr/bin/xattr -d 'com.apple.fileprovider.fpfs#P' "$APP_CONTENTS" 2>/dev/null || true
/usr/bin/xattr -c "$APP_BUNDLE" 2>/dev/null || true
/usr/bin/xattr -c "$APP_CONTENTS" 2>/dev/null || true
echo "Signing $APP_NAME with: $SIGN_IDENTITY"
if ! /usr/bin/codesign --force --deep --sign "$SIGN_IDENTITY" "$APP_BUNDLE" >/dev/null; then
  /usr/bin/xattr -d com.apple.FinderInfo "$APP_BUNDLE" 2>/dev/null || true
  /usr/bin/xattr -d 'com.apple.fileprovider.fpfs#P' "$APP_BUNDLE" 2>/dev/null || true
  /usr/bin/xattr -d com.apple.FinderInfo "$APP_CONTENTS" 2>/dev/null || true
  /usr/bin/xattr -d 'com.apple.fileprovider.fpfs#P' "$APP_CONTENTS" 2>/dev/null || true
  /usr/bin/xattr -c "$APP_BUNDLE" 2>/dev/null || true
  /usr/bin/xattr -c "$APP_CONTENTS" 2>/dev/null || true
  /usr/bin/codesign --force --deep --sign "$SIGN_IDENTITY" "$APP_BUNDLE" >/dev/null
fi
/usr/bin/codesign --verify --deep --strict "$APP_BUNDLE"

/usr/bin/ditto --norsrc --noextattr "$APP_BUNDLE" "$PUBLISHED_APP_BUNDLE" 2>/dev/null || true
/usr/bin/ditto --norsrc --noextattr "$APP_BUNDLE" "$DIST_APP_BUNDLE" 2>/dev/null || true
if [ -d "$PUBLISHED_APP_BUNDLE" ]; then
  /usr/bin/xattr -cr "$PUBLISHED_APP_BUNDLE" 2>/dev/null || true
  /usr/bin/find "$PUBLISHED_APP_BUNDLE" -exec /usr/bin/xattr -d com.apple.FinderInfo {} \; 2>/dev/null || true
  /usr/bin/find "$PUBLISHED_APP_BUNDLE" -exec /usr/bin/xattr -d 'com.apple.fileprovider.fpfs#P' {} \; 2>/dev/null || true
  /usr/bin/codesign --verify --deep "$PUBLISHED_APP_BUNDLE"
fi
if [ -d "$DIST_APP_BUNDLE" ]; then
  /usr/bin/xattr -cr "$DIST_APP_BUNDLE" 2>/dev/null || true
  /usr/bin/find "$DIST_APP_BUNDLE" -exec /usr/bin/xattr -d com.apple.FinderInfo {} \; 2>/dev/null || true
  /usr/bin/find "$DIST_APP_BUNDLE" -exec /usr/bin/xattr -d 'com.apple.fileprovider.fpfs#P' {} \; 2>/dev/null || true
  /usr/bin/codesign --verify --deep "$DIST_APP_BUNDLE"
fi

open_app() {
  /usr/bin/open -n "$PUBLISHED_APP_BUNDLE"
}

open_app_with_args() {
  /usr/bin/open -n "$PUBLISHED_APP_BUNDLE" --args "$@"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$PRODUCT_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$PRODUCT_NAME" >/dev/null
    ;;
  --hub|hub)
    open_app_with_args --show-hub
    ;;
  --settings|settings)
    open_app_with_args --show-settings
    ;;
  --agent|agent)
    open_app_with_args --show-agent
    ;;
  --scratchpad|scratchpad)
    open_app_with_args --show-scratchpad
    ;;
  --insertion-self-test|insertion-self-test)
    open_app_with_args --insertion-self-test
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify|--hub|--settings|--agent|--scratchpad|--insertion-self-test]" >&2
    exit 2
    ;;
esac
