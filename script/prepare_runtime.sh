#!/usr/bin/env bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNTIME_DIR="$PROJECT_DIR/Waifu2x/Resources/Runtime/Engine"
HELPER="$PROJECT_DIR/Vendor/waifu2x-ncnn-vulkan/waifu2x-ncnn-vulkan"
if [[ ! -x "$HELPER" ]]; then
    echo 'Inference helper is missing; run bash script/bootstrap.sh first' >&2
    exit 1
fi
mkdir -p "$RUNTIME_DIR"
# Source-controlled Engine contains notices only; dependencies remain in ignored Vendor.
/usr/bin/rsync -a --delete --delete-excluded --exclude='models-*' --exclude='waifu2x-ncnn-vulkan' "$PROJECT_DIR/Waifu2x/Resources/Engine/" "$RUNTIME_DIR/"
cp -p "$HELPER" "$RUNTIME_DIR/waifu2x-ncnn-vulkan"
if /usr/bin/find "$RUNTIME_DIR" -type f \( -name '*.onnx' -o -name '*.bin' -o -name '*.param' \) | /usr/bin/grep -q .; then
    echo 'Model weights must not be included in the runtime bundle' >&2
    exit 1
fi
