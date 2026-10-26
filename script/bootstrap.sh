#!/usr/bin/env bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WAIFU2X_BUILD_PYTHON="$(bash "$PROJECT_DIR/script/build_onnxruntime_macos13.sh" --print-python)"
export WAIFU2X_BUILD_PYTHON
"$WAIFU2X_BUILD_PYTHON" "$PROJECT_DIR/script/bootstrap.py" "$@"
bash "$PROJECT_DIR/script/build_onnxruntime_macos13.sh"
bash "$PROJECT_DIR/script/prepare_runtime.sh"
