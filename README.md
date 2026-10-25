# Waifu2x Desktop

**English** | [简体中文](README.zh-CN.md)

A native macOS app for image upscaling and denoising, with on-device processing and a quiet, turquoise workspace.

**Version 1.0.2 · macOS 26 or later**

## Download and install

Download the **Apple Silicon (arm64)** DMG or ZIP from [Releases](https://github.com/SteveTanSaMa/Waifu2x-Desktop/releases/latest). Open the DMG and drag **Waifu2x** into **Applications**, or extract the ZIP and move the app there. These packages require macOS 26 or later and do not support Intel Macs. Verify downloads with the included `SHA256SUMS` file if needed.

The app uses a certificate-free ad-hoc signature and is **not Developer ID signed or notarized by Apple**. If macOS blocks the first launch and you trust the download, try opening the app, then choose **System Settings → Privacy & Security → Open Anyway**. See [Apple's instructions](https://support.apple.com/102445).

## Features

- Upscale images to 2× or 4×, or reduce noise at the original size
- Choose models for illustrations, scanned artwork, and photos, with adjustable noise reduction, transparency handling, and optional TTA
- Queue multiple images, enhance a selection or the whole batch, and export lossless PNG files
- Inspect results with a draggable before-and-after divider, zoom, pan, and actual-pixel preview
- Follow an animated first-run tutorial and try the included sample artwork
- Use the app in English, Simplified Chinese, Traditional Chinese, Japanese, French, Korean, or Russian; follow the system language or choose one in Settings, with changes applied immediately
- Open a compact Settings window to choose an appearance, revisit the tutorial, and view the app version or GitHub project
- Enable background batch completion notifications and keep your Mac awake only while enhancement is running
- Check for stable app updates manually or once a day at launch
- Download app updates incrementally when a compatible package is available, with a verified full download as fallback
- Verify the app signature and model files with an animated, read-only integrity check
- View model storage usage and repair missing or damaged models directly in Settings
- Copy app, system, runtime, and model status for support, without personal paths or image names

## First launch and model downloads

The first-run sequence is **splash → model preparation → tutorial → workspace**.

After verification, the completed landscape gently fades into the tutorial. Users who have already completed it continue to the workspace. The transition respects Reduce Motion.

On later launches, installed models are verified behind the splash before entering the workspace. The model preparation page appears only when files need downloading or extraction, or preparation needs attention.

Model weights are downloaded on demand rather than included in the app. Version 1.0.2 downloads one compressed [`Waifu2x-models-v1.tar.xz` archive](https://github.com/SteveTanSaMa/Waifu2x-Desktop/releases/download/v1.0.2/Waifu2x-models-v1.tar.xz) from this project's GitHub Release. The download is **839,373,332 bytes (about 839 MB)**, about **23.4% smaller** than the unpacked model data. It expands to **99 model and helper files**, totaling **1,095,327,613 bytes (about 1.1 GB)**. The download page shows real progress, supports pause/resume and retry, and reveals its landscape illustration as the download advances. The archive and its extracted files are checked against their expected sizes and SHA-256 hashes before use.

The archive preserves the upstream model files from:

- ONNX models and helper graphs: [unlimited.waifu2x.net/models](https://unlimited.waifu2x.net/models/), from [nagadomi/nunif](https://github.com/nagadomi/nunif/tree/master/waifu2x/unlimited_waifu2x)
- CUNet and Upconv ncnn models: [waifu2x-ncnn-vulkan, release 20250915](https://github.com/nihui/waifu2x-ncnn-vulkan/releases/tag/20250915), pinned to commit [`a86cfb0`](https://github.com/nihui/waifu2x-ncnn-vulkan/tree/a86cfb043e6482b5f08778a114df9b5faf6e73b7/models)

The archive's download size, URL, and checksum, along with the original file URLs, sizes, and hashes, are recorded in [ModelCatalog.json](Waifu2x/Resources/ModelCatalog.json). Network access is needed to obtain missing models. Image enhancement runs on your Mac; your images are not uploaded.

If only part of the model cache is missing or damaged, launch verifies the remaining files and downloads just the needed compressed repair payloads. Identical model contents share a download. Each repaired file is verified before atomic replacement, then the complete model set is checked again. If repair assets are unavailable or a complete archive is more efficient, the app uses the verified full archive instead. Initial installation still uses one archive.

In **Settings → Models & Files**, check the installation and choose **Repair Models** if a problem is found. Repair continues if Settings closes; enhancement resumes once the repaired model set passes verification.

## App updates

Open **Settings → Software Update** to check and download an update. Releases with `Waifu2x-update.json` can offer a smaller file-level update: unchanged application files are reused, and only changed files are downloaded. A different or modified installed build, an unavailable patch, or a failed patch check falls back to the complete ZIP. All final files and the app signature are verified in a separate staging folder.

After downloading, choose **Show Update in Finder**, quit Waifu2x, and replace the copy in Applications with the verified app. The running app is never overwritten during download. Older releases without update metadata keep the GitHub download link. Model repair and app delta assets must be published with a release before they can be used online.

## Build and run

Requirements:

- macOS 26 or later
- Xcode 27 or later, with its developer tools selected
- Python 3
- Network access for the initial runtime bootstrap and model download

```sh
git clone https://github.com/SteveTanSaMa/Waifu2x-Desktop.git
cd Waifu2x-Desktop
open Waifu2x.xcodeproj
```

In Xcode, choose the **Waifu2x** scheme and **My Mac**, then run the app. The build automatically restores missing runtime dependencies and verifies their checksums, including after local build files have been removed. To build and launch from the terminal instead:

```sh
./script/build_and_run.sh
```

The build calls `bootstrap.sh` to download the pinned ONNX Runtime **1.23.2** universal macOS library and headers, plus the **20250915** ncnn inference helper. It verifies the archives and prepares the ignored `Vendor/` and runtime directories, reusing verified local dependencies on subsequent builds. You can also run `./script/bootstrap.sh` separately. It does not install the app’s model weights. Dependency versions and checksums are in [runtime-dependencies.json](script/runtime-dependencies.json).

The Xcode project is committed. [XcodeGen](https://github.com/yonaskolb/XcodeGen) is optional and is only needed when regenerating it after editing `project.yml`:

```sh
xcodegen generate
```

### Apple Silicon release packages

```sh
bash script/package_release.sh
```

On an Apple Silicon Mac, this builds a Release app, trims all bundled Mach-O binaries to arm64, applies certificate-free ad-hoc signatures, verifies the bundle, and creates a DMG, ZIP, and `SHA256SUMS` in `dist/`. Model weights are not bundled.

The script also creates `Waifu2x-update.json`. To generate a delta against an earlier official ZIP, run `APP_UPDATE_BASE_ZIP=/path/to/previous.zip bash script/package_release.sh`. GitHub Actions obtains the previous release automatically; if no compatible base is available, the catalog supplies the complete update.

Prepare the separate model archive from a verified model cache:

```sh
python3 script/fetch_test_models.py
python3 script/package_models.py --release v1.0.2 --update-catalog
```

This creates `dist/Waifu2x-models-v1.tar.xz` and records its metadata in the catalog. The archive contains the catalog's relative `ONNXModels/` and `Engine/` paths directly, without an outer directory.

It also creates the repair index and content-addressed repair archives. To build only those assets from a verified cache, use `python3 script/package_models.py --release vX.Y.Z --repair-only`. Publishing CI builds them from the verified full archive and uploads them together with the app update catalog and any app delta.

[GitHub Actions](.github/workflows/release.yml) runs unit tests and packages the app with Xcode 27.0 on Apple Silicon for pushes to `main`, pull requests, and manual runs. Before publishing, update the app version and catalog archive metadata, then prepare a draft `vX.Y.Z` release targeting the final commit SHA and upload the model archive named in the catalog. Its catalog URL must point to that release, and its size and SHA-256 must match the uploaded archive.

To publish the prepared version, either push a matching `vX.Y.Z` tag, push a commit to `main` whose first line is exactly `release: vX.Y.Z`, or run the workflow on `main` with **publish** enabled. The workflow checks the draft's commit, downloads and verifies its existing model archive, and adds it to `SHA256SUMS` alongside the DMG and ZIP. It publishes as **Waifu2x Desktop X.Y.Z** only after tests, packaging, and checksum verification pass. Published releases are never overwritten by this workflow.

## Tests

Run tests that do not require model weights:

```sh
./script/test.sh --unit
```

`./script/test.sh` uses the same mode by default. Tests that require actual inference are explicitly skipped in unit mode.

Run the full suite, including real inference:

```sh
./script/test.sh --integration
```

Integration mode reuses a complete, SHA-256-verified cache offline. Otherwise it downloads the single model archive, verifies it, and safely extracts and checks every file before replacing the ignored `build/TestModels/models-v1/` cache. To prepare or check that cache separately:

```sh
python3 script/fetch_test_models.py
python3 script/fetch_test_models.py --check
```

`--check` only checks local file sizes and hashes; it does not download files. In Xcode, **⌘U** skips inference tests when models are unavailable and runs them when a valid cache is present.

Verify and install a local archive into a fresh cache before publishing:

```sh
python3 script/fetch_test_models.py --archive dist/Waifu2x-models-v1.tar.xz --root build/FreshTestModels/models-v1
python3 script/fetch_test_models.py --check --root build/FreshTestModels/models-v1
```

Run the model archive and incremental packaging tests without Xcode or network access:

```sh
python3 -m unittest discover -s script -p 'test_*.py'
```

## Artwork and third-party components

The current icon source and regeneration instructions are in [Design](Design/README.md).

The app uses ONNX Runtime and waifu2x-ncnn-vulkan. Model and dependency attributions, including their license texts, are retained in [Third-party notices](Waifu2x/Resources/Engine/ThirdPartyNotices.md).

Copyright © 2026 Steve Tan. Third-party components remain subject to their respective licenses.
