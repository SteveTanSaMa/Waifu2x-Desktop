#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:---unit}"
case "$MODE" in
  --unit) TEST_MODE=unit ;;
  --integration) TEST_MODE=integration ;;
  *) echo "usage: $0 [--unit|--integration]" >&2; exit 2 ;;
esac
if [[ $# -gt 1 ]]; then
  echo "usage: $0 [--unit|--integration]" >&2
  exit 2
fi
bash "$ROOT_DIR/script/bootstrap.sh"
if [[ "$TEST_MODE" == integration ]]; then
  python3 "$ROOT_DIR/script/fetch_test_models.py"
fi
mkdir -p "$ROOT_DIR/build"
LOG_PATH="$ROOT_DIR/build/test-$TEST_MODE.log"
echo "Running $TEST_MODE tests; log: $LOG_PATH"
if ! xcodebuild -project "$ROOT_DIR/Waifu2x.xcodeproj" -scheme Waifu2x -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath "$ROOT_DIR/build" \
  "WAIFU2X_TEST_MODE=$TEST_MODE" test > "$LOG_PATH" 2>&1; then
  tail -n 100 "$LOG_PATH"
  exit 1
fi
tail -n 20 "$LOG_PATH"
