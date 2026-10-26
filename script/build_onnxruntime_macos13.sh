#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIRECTORY="$(cd "$SCRIPT_DIRECTORY/.." && pwd)"
PYTHON_SELECTION_DIRECTORY="$PROJECT_DIRECTORY/build/onnxruntime-macos13"
PYTHON_SELECTION_FILE="$PYTHON_SELECTION_DIRECTORY/.python-path"
PYTHON_SELECTION_LOCK="$PYTHON_SELECTION_DIRECTORY/.python-selection.lock"

validate_python() {
    local candidate="$1"
    [[ "$candidate" = /* && -x "$candidate" && "$candidate" != *$'\n'* && "$candidate" != *$'\r'* ]] || return 1
    "$candidate" -I -c 'import os, sys; sys.exit(1) if sys.version_info < (3, 10) else print(os.path.abspath(sys.executable))' 2>/dev/null
}

mkdir -p "$PYTHON_SELECTION_DIRECTORY"
# Selection is short-lived and separate from the native-build lock. Concurrent
# Xcode/CLI invocations must agree before either starts a long compilation.
selection_attempts=0
until mkdir "$PYTHON_SELECTION_LOCK" 2>/dev/null; do
    if [[ -f "$PYTHON_SELECTION_LOCK/pid" ]]; then
        IFS= read -r selection_owner < "$PYTHON_SELECTION_LOCK/pid" || true
        if [[ "${selection_owner:-}" =~ ^[0-9]+$ ]] && ! kill -0 "$selection_owner" 2>/dev/null; then
            rm -f "$PYTHON_SELECTION_LOCK/pid"
            rmdir "$PYTHON_SELECTION_LOCK" 2>/dev/null || true
            continue
        fi
    fi
    selection_attempts=$((selection_attempts + 1))
    if [[ "$selection_attempts" -ge 300 ]]; then
        echo 'Timed out waiting for the runtime Python selection lock' >&2
        exit 1
    fi
    sleep 0.05
done
printf '%s\n' "$$" > "$PYTHON_SELECTION_LOCK/pid"
release_selection_lock() {
    rm -f "$PYTHON_SELECTION_LOCK/pid"
    rmdir "$PYTHON_SELECTION_LOCK" 2>/dev/null || true
}
trap release_selection_lock EXIT

selected_python=''
if [[ -n "${WAIFU2X_BUILD_PYTHON:-}" ]]; then
    if ! selected_python="$(validate_python "$WAIFU2X_BUILD_PYTHON")"; then
        echo 'WAIFU2X_BUILD_PYTHON must be an executable absolute path to Python 3.10 or later' >&2
        exit 1
    fi
elif [[ -f "$PYTHON_SELECTION_FILE" ]]; then
    IFS= read -r cached_python < "$PYTHON_SELECTION_FILE" || true
    selected_python="$(validate_python "${cached_python:-}")" || selected_python=''
fi

if [[ -z "$selected_python" ]]; then
    for python_name in python3 python3.12 python3.11 python3.10 python3.13 python3.14 python3.15; do
        candidate_python="$(command -v "$python_name" || true)"
        if selected_python="$(validate_python "$candidate_python")"; then break; fi
        selected_python=''
    done
fi
if [[ -z "$selected_python" ]]; then
    echo 'Python 3.10 or later is required; set WAIFU2X_BUILD_PYTHON to its absolute executable path' >&2
    exit 1
fi

selection_temporary="$(mktemp "$PYTHON_SELECTION_DIRECTORY/.python-path.XXXXXX")"
printf '%s\n' "$selected_python" > "$selection_temporary"
mv -f "$selection_temporary" "$PYTHON_SELECTION_FILE"
release_selection_lock
trap - EXIT

if [[ "${1:-}" == --print-python ]]; then
    if [[ "$#" -ne 1 ]]; then
        echo '--print-python must be used without other arguments' >&2
        exit 2
    fi
    printf '%s\n' "$selected_python"
    exit 0
fi
exec "$selected_python" "$SCRIPT_DIRECTORY/build_onnxruntime_macos13.py" "$@"
