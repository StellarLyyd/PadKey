#!/usr/bin/env bash
set -euo pipefail

MODEL="${1:-large-v3-turbo}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUPPORT_DIR="$ROOT_DIR/Support/Whisper"
SRC_DIR="$SUPPORT_DIR/src"
BIN_DIR="$SUPPORT_DIR/bin"
LIB_DIR="$SUPPORT_DIR/lib"
MODELS_DIR="$SUPPORT_DIR/models"
TOOLS_DIR="$ROOT_DIR/.tools"
PYTHON_TARGET="$TOOLS_DIR/python"

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
  git clone --depth 1 https://github.com/ggerganov/whisper.cpp.git "$SRC_DIR"
else
  git -C "$SRC_DIR" pull --ff-only
fi

"$CMAKE_BIN" -S "$SRC_DIR" -B "$SRC_DIR/build" -DCMAKE_BUILD_TYPE=Release
"$CMAKE_BIN" --build "$SRC_DIR/build" --config Release --target whisper-cli -j "$(sysctl -n hw.ncpu)"

cp "$SRC_DIR/build/bin/whisper-cli" "$BIN_DIR/whisper-cli"
chmod +x "$BIN_DIR/whisper-cli"

find "$SRC_DIR/build" -name '*.dylib' -exec cp -P {} "$LIB_DIR/" \;
/usr/bin/install_name_tool -add_rpath "@executable_path/../lib" "$BIN_DIR/whisper-cli" 2>/dev/null || true

bash "$SRC_DIR/models/download-ggml-model.sh" "$MODEL" "$MODELS_DIR"

echo "Local Whisper is ready:"
echo "  binary: $BIN_DIR/whisper-cli"
echo "  libs:   $LIB_DIR"
echo "  model:  $MODELS_DIR/ggml-$MODEL.bin"
