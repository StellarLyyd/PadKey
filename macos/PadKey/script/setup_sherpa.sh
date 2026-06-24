#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUPPORT_DIR="$ROOT_DIR/Support/Sherpa"
BIN_DIR="$SUPPORT_DIR/bin"
LIB_DIR="$SUPPORT_DIR/lib"
MODELS_DIR="$SUPPORT_DIR/models"
TOOLS_DIR="$ROOT_DIR/.tools"

MODEL_NAME="${SHERPA_MODEL_NAME:-sherpa-onnx-streaming-zipformer-en-20M-2023-02-17}"
MODEL_URL="${SHERPA_MODEL_URL:-https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/$MODEL_NAME.tar.bz2}"

mkdir -p "$BIN_DIR" "$LIB_DIR" "$MODELS_DIR" "$TOOLS_DIR"

latest_sherpa_tag() {
  curl -fsSL "https://api.github.com/repos/k2-fsa/sherpa-onnx/releases/latest" \
    | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' \
    | head -1
}

SHERPA_VERSION="${SHERPA_VERSION:-$(latest_sherpa_tag)}"
if [ -z "$SHERPA_VERSION" ]; then
  echo "Unable to resolve the latest sherpa-onnx release tag." >&2
  exit 1
fi

case "$(uname -m)" in
  arm64)
    PACKAGE_ARCH="osx-arm64"
    ;;
  x86_64)
    PACKAGE_ARCH="osx-x64"
    ;;
  *)
    PACKAGE_ARCH="osx-universal2"
    ;;
esac

PACKAGE_NAME="sherpa-onnx-$SHERPA_VERSION-$PACKAGE_ARCH-shared-no-tts.tar.bz2"
PACKAGE_URL="${SHERPA_PACKAGE_URL:-https://github.com/k2-fsa/sherpa-onnx/releases/download/$SHERPA_VERSION/$PACKAGE_NAME}"
PACKAGE_ARCHIVE="$TOOLS_DIR/$PACKAGE_NAME"
EXTRACT_DIR="$TOOLS_DIR/sherpa-extract-$SHERPA_VERSION-$PACKAGE_ARCH"
MODEL_ARCHIVE="$TOOLS_DIR/$MODEL_NAME.tar.bz2"

echo "Downloading sherpa-onnx runtime:"
echo "  $PACKAGE_URL"
curl -fL "$PACKAGE_URL" -o "$PACKAGE_ARCHIVE"

rm -rf "$EXTRACT_DIR"
mkdir -p "$EXTRACT_DIR"
tar -xjf "$PACKAGE_ARCHIVE" -C "$EXTRACT_DIR"

PACKAGE_DIR="$(find "$EXTRACT_DIR" -mindepth 1 -maxdepth 1 -type d | head -1)"
if [ -z "$PACKAGE_DIR" ]; then
  echo "Unable to find extracted sherpa-onnx package." >&2
  exit 1
fi

if [ -d "$PACKAGE_DIR/bin" ]; then
  cp -R "$PACKAGE_DIR/bin/." "$BIN_DIR/"
fi

if [ -d "$PACKAGE_DIR/lib" ]; then
  cp -R "$PACKAGE_DIR/lib/." "$LIB_DIR/"
fi

chmod +x "$BIN_DIR"/sherpa-onnx* 2>/dev/null || true
/usr/bin/install_name_tool -add_rpath "@executable_path/../lib" "$BIN_DIR/sherpa-onnx-microphone" 2>/dev/null || true

echo "Downloading streaming ASR model:"
echo "  $MODEL_URL"
curl -fL "$MODEL_URL" -o "$MODEL_ARCHIVE"
tar -xjf "$MODEL_ARCHIVE" -C "$MODELS_DIR"

echo "Sherpa live transcription is ready:"
echo "  binary: $BIN_DIR/sherpa-onnx-microphone"
echo "  libs:   $LIB_DIR"
echo "  model:  $MODELS_DIR/$MODEL_NAME"
