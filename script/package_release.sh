#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
    echo 'Release packaging requires an Apple Silicon Mac with Xcode 27 or later.' >&2
    exit 1
fi
if [[ $# -ne 0 ]]; then
    echo 'usage: bash script/package_release.sh' >&2
    exit 2
fi

WAIFU2X_BUILD_PYTHON="$(bash "$PROJECT_DIR/script/build_onnxruntime_macos13.sh" --print-python)"
export WAIFU2X_BUILD_PYTHON
bash "$PROJECT_DIR/script/bootstrap.sh"
mkdir -p "$PROJECT_DIR/build" "$PROJECT_DIR/dist"
xcodebuild -project "$PROJECT_DIR/Waifu2x.xcodeproj" -scheme Waifu2x \
    -configuration Release -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$PROJECT_DIR/build/release" \
    "WAIFU2X_BUILD_PYTHON=$WAIFU2X_BUILD_PYTHON" ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
    CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
    ENABLE_HARDENED_RUNTIME=NO build 2>&1 | tee "$PROJECT_DIR/build/release.log"

BUILT_APP="$PROJECT_DIR/build/release/Build/Products/Release/Waifu2x.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$BUILT_APP/Contents/Info.plist")"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Expected a stable semantic app version, got: $VERSION" >&2
    exit 1
fi
STAGING_DIR="$(mktemp -d "$PROJECT_DIR/build/release-stage.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
APP="$STAGING_DIR/Waifu2x.app"
ditto "$BUILT_APP" "$APP"

# Bootstrap dependencies stay universal and hash-verifiable in Vendor/. Only
# copies inside the distributable are thinned, then signed without a certificate.
BINARY_COUNT=0
while IFS= read -r -d '' binary; do
    if [[ "$(/usr/bin/file -b "$binary")" != *Mach-O* ]]; then
        continue
    fi
    architectures="$(/usr/bin/lipo -archs "$binary")"
    if [[ " $architectures " != *' arm64 '* ]]; then
        echo "Bundled binary is missing arm64: $binary ($architectures)" >&2
        exit 1
    fi
    if [[ "$architectures" != arm64 ]]; then
        /usr/bin/lipo "$binary" -thin arm64 -output "$binary.arm64"
        chmod 755 "$binary.arm64"
        mv "$binary.arm64" "$binary"
    fi
    test "$(/usr/bin/lipo -archs "$binary")" = arm64
    /usr/bin/codesign --force --sign - --timestamp=none "$binary"
    BINARY_COUNT=$((BINARY_COUNT + 1))
done < <(/usr/bin/find "$APP" -type f -print0)
test "$BINARY_COUNT" -ge 3
test -x "$APP/Contents/MacOS/Waifu2x"
test -x "$APP/Contents/Resources/Engine/waifu2x-ncnn-vulkan"
test -f "$APP/Contents/Frameworks/libonnxruntime.1.23.2.dylib"
test -f "$APP/Contents/Resources/ModelCatalog.json"
test -f "$APP/Contents/Resources/Engine/ThirdPartyNotices.md"
if /usr/bin/find "$APP" -type f \( -name '*.onnx' -o -name '*.bin' -o -name '*.param' \) | /usr/bin/grep -q .; then
    echo 'Model weights must be downloaded on demand, not bundled in the release.' >&2
    exit 1
fi

"$WAIFU2X_BUILD_PYTHON" "$PROJECT_DIR/script/check_macos_compatibility.py" --app "$APP" --minimum-os 13.0 --architecture arm64

/usr/bin/codesign --force --sign - --timestamp=none "$APP"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"

NAME="Waifu2x-$VERSION-macos-arm64"
ZIP_PATH="$PROJECT_DIR/dist/$NAME.zip"
DMG_PATH="$PROJECT_DIR/dist/$NAME.dmg"
rm -f "$ZIP_PATH" "$DMG_PATH"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP_PATH"
/usr/bin/unzip -tq "$ZIP_PATH"
ln -s /Applications "$STAGING_DIR/Applications"
/usr/bin/hdiutil create -volname Waifu2x -srcfolder "$STAGING_DIR" \
    -format UDZO -ov "$DMG_PATH"
/usr/bin/hdiutil verify "$DMG_PATH"
UPDATE_ARGUMENTS=(--app "$APP" --full-archive "$ZIP_PATH" --release "v$VERSION" --output-dir "$PROJECT_DIR/dist")
if [[ -n "${APP_UPDATE_BASE_ZIP:-}" ]]; then
    UPDATE_ARGUMENTS+=(--previous-archive "$APP_UPDATE_BASE_ZIP")
fi
"$WAIFU2X_BUILD_PYTHON" "$PROJECT_DIR/script/package_app_updates.py" "${UPDATE_ARGUMENTS[@]}"
"$WAIFU2X_BUILD_PYTHON" - "$PROJECT_DIR/dist" "$NAME" <<'PY'
import hashlib
import json
from pathlib import Path
import sys

root, name = Path(sys.argv[1]), sys.argv[2]
catalog = json.loads((root / 'Waifu2x-update.json').read_text())
names = [name + '.dmg', name + '.zip', 'Waifu2x-update.json']
names += [item['archive']['path'] for item in catalog['deltas']]
with (root / 'SHA256SUMS').open('w') as output:
    for name in names:
        digest = hashlib.sha256()
        with (root / name).open('rb') as source:
            for chunk in iter(lambda: source.read(4 * 1024 * 1024), b''):
                digest.update(chunk)
        output.write(digest.hexdigest() + '  ' + name + '\n')
PY
(
    cd "$PROJECT_DIR/dist"
    /usr/bin/shasum -a 256 --check SHA256SUMS
)

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf 'version=%s\ntag=v%s\n' "$VERSION" "$VERSION" >> "$GITHUB_OUTPUT"
fi
echo "Apple Silicon release packages: $DMG_PATH and $ZIP_PATH"
