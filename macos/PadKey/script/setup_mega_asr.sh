#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUPPORT_DIR="$ROOT_DIR/Support/MegaASR"
SRC_DIR="$SUPPORT_DIR/src"
BIN_DIR="$SUPPORT_DIR/bin"
LIB_DIR="$SUPPORT_DIR/lib"
MODELS_DIR="$SUPPORT_DIR/models"
TOOLS_DIR="$ROOT_DIR/.tools"
PYTHON_TARGET="$TOOLS_DIR/python"
MODEL_NAME="${MEGA_ASR_MODEL_NAME:-mega-asr-1.7b-q4_k.gguf}"
MODEL_REPO="${MEGA_ASR_MODEL_REPO:-cstr/mega-asr-GGUF}"

mkdir -p "$BIN_DIR" "$LIB_DIR" "$MODELS_DIR" "$TOOLS_DIR"

find_cmake() {
  if command -v cmake >/dev/null 2>&1; then
    command -v cmake
    return
  fi

  if [ -d "$PYTHON_TARGET" ]; then
    PYTHONPATH="$PYTHON_TARGET" python3 - <<'PY' 2>/dev/null || true
import cmake
import os
print(os.path.join(cmake.CMAKE_BIN_DIR, "cmake"))
PY
  fi
}

CMAKE_BIN="$(find_cmake | tail -1)"

if [ -z "$CMAKE_BIN" ] || [ ! -x "$CMAKE_BIN" ]; then
  echo "cmake was not found; installing a project-local cmake wheel..."
  python3 -m pip install --upgrade --target "$PYTHON_TARGET" cmake
  CMAKE_BIN="$(find_cmake | tail -1)"
fi

if [ -z "$CMAKE_BIN" ] || [ ! -x "$CMAKE_BIN" ]; then
  echo "Unable to locate cmake after installation." >&2
  exit 1
fi

if [ ! -d "$SRC_DIR/.git" ]; then
  git clone --depth 1 https://github.com/CrispStrobe/CrispASR.git "$SRC_DIR"
else
  git -C "$SRC_DIR" pull --ff-only
fi

"$CMAKE_BIN" -S "$SRC_DIR" -B "$SRC_DIR/build" -DCMAKE_BUILD_TYPE=Release
"$CMAKE_BIN" --build "$SRC_DIR/build" --config Release --target crispasr-cli -j "$(sysctl -n hw.ncpu)"

CRISP_BINARY="$(find "$SRC_DIR/build" -type f -name crispasr | head -1)"

if [ -z "$CRISP_BINARY" ]; then
  echo "Unable to locate built crispasr binary." >&2
  exit 1
fi

cp "$CRISP_BINARY" "$BIN_DIR/crispasr"
chmod +x "$BIN_DIR/crispasr"

find "$SRC_DIR/build" -name '*.dylib' -exec cp -P {} "$LIB_DIR/" \; 2>/dev/null || true
/usr/bin/install_name_tool -add_rpath "@executable_path/../lib" "$BIN_DIR/crispasr" 2>/dev/null || true

if command -v huggingface-cli >/dev/null 2>&1; then
  huggingface-cli download "$MODEL_REPO" "$MODEL_NAME" --local-dir "$MODELS_DIR"
else
  MODEL_URL="https://huggingface.co/$MODEL_REPO/resolve/main/$MODEL_NAME"
  echo "huggingface-cli was not found; downloading directly:"
  echo "  $MODEL_URL"
  curl -fL "$MODEL_URL" -o "$MODELS_DIR/$MODEL_NAME"
fi

echo "Mega-ASR robust transcription is ready:"
echo "  binary: $BIN_DIR/crispasr"
echo "  libs:   $LIB_DIR"
echo "  model:  $MODELS_DIR/$MODEL_NAME"
