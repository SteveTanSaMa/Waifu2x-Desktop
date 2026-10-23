#!/usr/bin/env bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 "$PROJECT_DIR/script/bootstrap.py" "$@"
bash "$PROJECT_DIR/script/prepare_runtime.sh"
