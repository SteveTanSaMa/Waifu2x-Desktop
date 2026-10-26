# ONNX Runtime on macOS 13.0

The upstream ONNX Runtime 1.23.2 macOS archive declares macOS 13.4 as its
minimum system version. Waifu2x recompiles the same release for 13.0 so that
Ventura 13.0–13.3 do not load a library built for a newer operating system.
Neither the minimum-version load command nor the upstream archive is rewritten.

## Pinned inputs

- Runtime: ONNX Runtime 1.23.2
- Official source commit: `a83fc4d58cb48eb68890dd689f94f28288cf2278`
- Deployment target: macOS 13.0
- Architecture: the build host's arm64 or x86_64 architecture
- Providers: CPU, CoreML and WebGPU, including Dawn's Metal backend
- Third-party sources: the URL/revision/hash entries in that commit's
  `cmake/deps.txt` and Dawn dependency manifests
- C API headers and notices: the original, checksum-verified 1.23.2 archive

`FETCHCONTENT_TRY_FIND_PACKAGE_MODE=NEVER` prevents CMake from silently using
an unrelated Homebrew or Conda dependency. Upstream runtime tests are disabled;
Waifu2x's own runtime tests remain available. Unused Emscripten and fuzzer Git
submodules are not downloaded. Required ONNX sources are fetched by CMake using
the pinned dependency manifest.

## Build and reuse

The first build requires Xcode command-line tools, Python 3.10 or later, CMake,
Ninja, Node.js, npm and Git. The script reuses installed tools and does not
install packages globally. Run the normal project bootstrap to restore the
official headers before invoking this script directly.

```sh
bash script/build_onnxruntime_macos13.sh
bash script/build_onnxruntime_macos13.sh --check
```

All generated files stay under `build/onnxruntime-macos13/`. The final runtime
appears atomically in `Runtime/include/` and
`Runtime/lib/libonnxruntime.1.23.2.dylib` after successful compilation and checks.
`--jobs N` controls native compiler parallelism; the default is at most six.

The build driver and CMake's Python code generators use the same interpreter;
the driver explicitly supplies `Python3_EXECUTABLE` so Dawn does not select an
unrelated Python installation. CI selects a supported Python version before
building. Interpreter paths are machine-local and are not stored in provenance.

`WAIFU2X_BUILD_PYTHON` can select an explicit executable. Otherwise the wrapper
reuses the workspace's validated `build/onnxruntime-macos13/.python-path`, or
finds a Python 3.10+ interpreter on `PATH` and remembers it atomically. This keeps
Xcode's bundled Python 3.9 from overriding the selected build interpreter.
`bash script/build_onnxruntime_macos13.sh --print-python` prints only that absolute
path without downloading or compiling. The choice file is generated state and
is excluded from source control and runtime provenance.

The cache records the source commit, architecture, deployment target, providers,
build configuration, build-script checksum, full Python version, compiler and SDK. Every generated
header, notice and library is hashed. A missing or changed output causes the
runtime to be rebuilt; an advisory lock serializes simultaneous Xcode builds.

Before installing the generated runtime, the script checks its Mach-O deployment
target, rejects non-system dynamic-library dependencies, then compiles and runs a
small C API program to confirm the version and all three execution providers.
It never downloads the app's model weights.

## Distribution checks

```sh
python3 script/check_macos_compatibility.py \
  --app /path/to/Waifu2x.app --minimum-os 13.0 --architecture arm64
python3 -m unittest discover -s script -p 'test_macos_compatibility.py'
```

The bundle check inspects `LSMinimumSystemVersion` and every slice of each
bundled Mach-O file, including the inference helper and dylib. It supports both
modern and legacy deployment load commands and refuses malformed metadata,
external bundle links and non-macOS slices. This is a deployment-metadata gate;
testing on macOS 13 remains necessary to verify behavior on that OS.

Upstream references:

- [Pinned runtime source](https://github.com/microsoft/onnxruntime/tree/a83fc4d58cb48eb68890dd689f94f28288cf2278)
- [Upstream 1.23.2 Apple deployment configuration](https://github.com/microsoft/onnxruntime/blob/v1.23.2/tools/ci_build/github/apple/default_full_apple_framework_build_settings.json)
- [CoreML provider build instructions](https://onnxruntime.ai/docs/execution-providers/CoreML-ExecutionProvider.html)
