#!/usr/bin/env python3
"""Build the pinned ONNX Runtime with CPU, CoreML and WebGPU for macOS 13.0.

Official 1.23.2 macOS binaries target 13.4. Recompiling the same source, rather
than editing its Mach-O deployment metadata, covers Ventura 13.0 through 13.3.
Generated sources, downloads, object files and the runtime stay under build/.
"""

import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tempfile

from check_macos_compatibility import macho_slices, version


PROJECT = Path(__file__).resolve().parents[1]
BUILD_ROOT = PROJECT / "build/onnxruntime-macos13"
SOURCE = BUILD_ROOT / "Source"
OUTPUT = BUILD_ROOT / "Runtime"
ORT_VERSION = "1.23.2"
ORT_COMMIT = "a83fc4d58cb48eb68890dd689f94f28288cf2278"
ORT_REPOSITORY = "https://github.com/microsoft/onnxruntime.git"
MINIMUM_OS = "13.0"
PROVIDERS = ["CPUExecutionProvider", "CoreMLExecutionProvider", "WebGpuExecutionProvider"]
DEFINES = ["CMAKE_OSX_DEPLOYMENT_TARGET=13.0", "onnxruntime_BUILD_UNIT_TESTS=OFF",
           "FETCHCONTENT_TRY_FIND_PACKAGE_MODE=NEVER", "CMAKE_POLICY_VERSION_MINIMUM=3.5"]


def run(arguments, **kwargs):
    print("+ " + " ".join(map(str, arguments)), flush=True)
    return subprocess.run(list(map(str, arguments)), check=True, **kwargs)


def capture(arguments):
    return subprocess.check_output(list(map(str, arguments)), text=True).strip()


def digest(path):
    with Path(path).open("rb") as stream:
        result = hashlib.sha256()
        for chunk in iter(lambda: stream.read(4 * 1024 * 1024), b""):
            result.update(chunk)
        return result.hexdigest()


def configuration(architecture):
    return dict(schemaVersion=1, runtimeVersion=ORT_VERSION, sourceCommit=ORT_COMMIT,
                minimumOS=MINIMUM_OS, architecture=architecture, providers=PROVIDERS,
                cmakeDefines=DEFINES, scriptSHA256=digest(__file__),
                buildPythonVersion=platform.python_version(),
                compiler=capture(["xcrun", "clang", "--version"]).splitlines()[0],
                sdkBuild=capture(["xcrun", "--show-sdk-build-version"]))


def inventory(directory):
    result = {}
    for path in sorted(directory.rglob("*")):
        if path.is_file() and not path.is_symlink() and path.name != "provenance.json":
            result[path.relative_to(directory).as_posix()] = digest(path)
    return result


def valid_cached_runtime(expected):
    try:
        manifest = json.loads((OUTPUT / "provenance.json").read_text())
        if manifest["configuration"] != expected or manifest["files"] != inventory(OUTPUT):
            return False
        library = OUTPUT / f"lib/libonnxruntime.{ORT_VERSION}.dylib"
        images = macho_slices(library)
        return images is not None and len(images) == 1 and images[0].architecture == expected["architecture"] \
            and images[0].minimum_os <= version(MINIMUM_OS)
    except (OSError, ValueError, KeyError):
        return False


def ensure_source():
    if not (SOURCE / ".git").is_dir():
        if SOURCE.exists():
            raise RuntimeError(f"Unexpected non-Git build source directory: {SOURCE}")
        run(["git", "clone", "--depth", "1", "--branch", f"v{ORT_VERSION}", "--filter=blob:none",
             ORT_REPOSITORY, SOURCE])
    if capture(["git", "-C", SOURCE, "remote", "get-url", "origin"]) != ORT_REPOSITORY:
        raise RuntimeError("Runtime build source must use the pinned official repository")
    if capture(["git", "-C", SOURCE, "rev-parse", "HEAD"]) != ORT_COMMIT:
        raise RuntimeError("Runtime source commit differs from the pinned v1.23.2 commit")
    # This is a generated checkout owned by this build script, never app source.
    run(["git", "-C", SOURCE, "reset", "--hard", ORT_COMMIT])


def verify_library(path, architecture):
    images = macho_slices(path)
    if images is None or len(images) != 1 or images[0].architecture != architecture:
        raise RuntimeError("The rebuilt runtime has an unexpected architecture")
    if images[0].minimum_os > version(MINIMUM_OS):
        raise RuntimeError("The rebuilt runtime still requires a newer macOS version")
    # Distributable binaries cannot depend on Homebrew/Conda libraries.
    lines = capture(["otool", "-L", path]).splitlines()[1:]
    for line in lines:
        dependency = line.strip().split(" (", 1)[0]
        if dependency == f"@rpath/libonnxruntime.{ORT_VERSION}.dylib":
            continue
        if not dependency.startswith(("/System/Library/", "/usr/lib/")):
            raise RuntimeError("Unbundled runtime dependency: " + dependency)


def verify_providers(runtime, architecture):
    source = r'''#include "onnxruntime_c_api.h"
#include <stdio.h>
int main(void) {
    const OrtApiBase *base = OrtGetApiBase();
    const OrtApi *api = base->GetApi(ORT_API_VERSION);
    if (!api) return 1;
    printf("%s\n", base->GetVersionString());
    char **providers = NULL;
    int count = 0;
    OrtStatus *status = api->GetAvailableProviders(&providers, &count);
    if (status) { api->ReleaseStatus(status); return 2; }
    for (int index = 0; index < count; ++index) printf("%s\n", providers[index]);
    status = api->ReleaseAvailableProviders(providers, count);
    if (status) { api->ReleaseStatus(status); return 3; }
    return 0;
}
'''
    with tempfile.TemporaryDirectory(prefix="provider-check-", dir=BUILD_ROOT) as temporary:
        temporary = Path(temporary)
        (temporary / "providers.c").write_text(source)
        run(["xcrun", "clang", "-target", f"{architecture}-apple-macos{MINIMUM_OS}",
             "-I", runtime / "include", temporary / "providers.c", "-L", runtime / "lib",
             f"-lonnxruntime.{ORT_VERSION}", "-Wl,-rpath," + str(runtime / "lib"),
             "-o", temporary / "providers"])
        facts = capture([temporary / "providers"]).splitlines()
        if not facts or facts[0] != ORT_VERSION or sorted(facts[1:]) != sorted(PROVIDERS):
            raise RuntimeError("Rebuilt runtime version or execution providers differ: " + repr(facts))
        print("Verified runtime " + facts[0] + ": " + ", ".join(facts[1:]), flush=True)


def build(expected, jobs):
    ensure_source()
    environment = os.environ.copy()
    environment["MACOSX_DEPLOYMENT_TARGET"] = MINIMUM_OS
    environment.setdefault("SSL_CERT_FILE", "/etc/ssl/cert.pem")
    # CMake FetchContent downloads dependencies at the revisions and hashes in
    # this pinned source's cmake/deps.txt. No unrelated Emscripten submodules,
    # inference models, installed host packages or build-time unit tests are used.
    run([sys.executable, SOURCE / "tools/ci_build/build.py", "--build_dir", BUILD_ROOT / "Build",
         "--config", "Release", "--update", "--build", "--build_shared_lib", "--use_coreml", "--use_webgpu",
         "--skip_tests", "--skip_submodule_sync", "--parallel", str(jobs), "--cmake_generator", "Ninja",
         "--osx_arch", expected["architecture"], "--cmake_extra_defines", *DEFINES,
         "Python3_EXECUTABLE=" + sys.executable],
        cwd=PROJECT, env=environment)
    library = BUILD_ROOT / f"Build/Release/libonnxruntime.{ORT_VERSION}.dylib"
    verify_library(library, expected["architecture"])
    original = PROJECT / "Vendor/onnxruntime"
    if (original / "GIT_COMMIT_ID").read_text().strip() != ORT_COMMIT:
        raise RuntimeError("Official runtime headers are missing or belong to another version; run bootstrap first")
    staging = BUILD_ROOT / "Runtime.staging"
    if staging.exists():
        shutil.rmtree(staging)
    (staging / "lib").mkdir(parents=True)
    shutil.copy2(library, staging / "lib" / library.name)
    (staging / "lib/libonnxruntime.dylib").symlink_to(library.name)
    shutil.copytree(original / "include", staging / "include")
    for name in ["LICENSE", "ThirdPartyNotices.txt", "Privacy.md", "VERSION_NUMBER", "GIT_COMMIT_ID"]:
        shutil.copy2(original / name, staging / name)
    verify_providers(staging, expected["architecture"])
    manifest = dict(configuration=expected, files=inventory(staging))
    (staging / "provenance.json").write_text(json.dumps(manifest, indent=2) + "\n")
    if OUTPUT.exists():
        shutil.rmtree(OUTPUT)
    staging.rename(OUTPUT)
    print(f"macOS {MINIMUM_OS} runtime ready: {OUTPUT}", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Check the cache without downloading or compiling")
    parser.add_argument("--jobs", type=int, default=min(6, os.cpu_count() or 2))
    arguments = parser.parse_args()
    if platform.system() != "Darwin" or platform.machine() not in ("arm64", "x86_64"):
        parser.error("Building the runtime requires macOS on arm64 or x86_64")
    if not 1 <= arguments.jobs <= 64:
        parser.error("--jobs must be between 1 and 64")
    for command in ["git", "cmake", "ninja", "node", "npm", "xcrun"]:
        if shutil.which(command) is None:
            parser.error(f"Missing build tool: {command}")
    BUILD_ROOT.mkdir(parents=True, exist_ok=True)
    expected = configuration(platform.machine())
    with (BUILD_ROOT / ".build.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if valid_cached_runtime(expected):
            print(f"ONNX Runtime {ORT_VERSION} for macOS {MINIMUM_OS} verified; reusing compiled runtime")
            return 0
        if arguments.check:
            print("macOS 13 runtime is missing or its provenance/checksums differ", file=sys.stderr)
            return 1
        print(f"Building ONNX Runtime {ORT_VERSION} for macOS {MINIMUM_OS}; the first build can take several minutes", flush=True)
        build(expected, arguments.jobs)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"macOS 13 runtime build failed: {error}", file=sys.stderr)
        raise SystemExit(1)
