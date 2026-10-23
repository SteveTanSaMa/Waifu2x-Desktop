#!/usr/bin/env bash
set -euo pipefail
MODE="${1:-run}"
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
case "$MODE" in
    run|--build|--sample|--onboarding|--debug|--verify) CONFIGURATION=Debug ;;
    --release) CONFIGURATION=Release ;;
    *) echo 'usage: build_and_run.sh [run|--build|--sample|--onboarding|--debug|--verify|--release]' >&2; exit 2 ;;
esac

bash "$PROJECT_DIR/script/bootstrap.sh"
mkdir -p "$PROJECT_DIR/build"
BUILD_LOG="$PROJECT_DIR/build/build-$CONFIGURATION.log"
BUILD_ARGUMENTS=(-project "$PROJECT_DIR/Waifu2x.xcodeproj" -scheme Waifu2x
    -configuration "$CONFIGURATION" -derivedDataPath "$PROJECT_DIR/build")
if [[ "$CONFIGURATION" == Release ]]; then
    BUILD_ARGUMENTS+=(-arch arm64 -arch x86_64 ONLY_ACTIVE_ARCH=NO)
fi
xcodebuild "${BUILD_ARGUMENTS[@]}" build > "$BUILD_LOG" 2>&1 || { tail -80 "$BUILD_LOG" >&2; exit 1; }
APP_BUNDLE="$PROJECT_DIR/build/Build/Products/$CONFIGURATION/Waifu2x.app"
case "$MODE" in
    --build) echo "$APP_BUNDLE" ;;
    --release)
        mkdir -p "$PROJECT_DIR/dist"
        VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP_BUNDLE/Contents/Info.plist")"
        DESTINATION="$PROJECT_DIR/dist/Waifu2x-$VERSION.app"
        ditto "$APP_BUNDLE" "$DESTINATION"
        codesign --verify --strict --deep "$DESTINATION"
        echo "$DESTINATION"
        ;;
    --verify) codesign --verify --strict --deep "$APP_BUNDLE"; echo 'Build and signature verified' ;;
    --sample) /usr/bin/open -n "$APP_BUNDLE" --args --sample ;;
    --onboarding) /usr/bin/open -n "$APP_BUNDLE" --args --isolated-session --show-onboarding ;;
    --debug) lldb -- "$APP_BUNDLE/Contents/MacOS/Waifu2x" ;;
    run) /usr/bin/open -n "$APP_BUNDLE" ;;
esac
