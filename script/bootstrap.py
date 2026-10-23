#!/usr/bin/env python3
"""Install SHA-pinned universal macOS inference dependencies into ignored Vendor/."""

import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import subprocess
import sys
import tarfile
import tempfile
from urllib.parse import urlparse
import zipfile


PROJECT = Path(__file__).resolve().parents[1]
CACHE = PROJECT / "build/dependency-cache"
MANIFEST = Path(__file__).with_name("runtime-dependencies.json")


def sha256(path):
    result = hashlib.sha256()
    with path.open("rb") as source:
        while True:
            chunk = source.read(4 * 1024 * 1024)
            if not chunk:
                break
            result.update(chunk)
    return result.hexdigest()


def matches(path, size, digest):
    return path.is_file() and not path.is_symlink() and path.stat().st_size == size and sha256(path) == digest


def valid_install(directory, dependency):
    if not directory.is_dir() or directory.is_symlink():
        return False
    for item in dependency["files"]:
        if not matches(directory / item["path"], item["bytes"], item["sha256"]):
            return False
    for item in dependency["symlinks"]:
        path = directory / item["path"]
        if not path.is_symlink() or str(path.readlink()) != item["target"]:
            return False
    for binary in dependency["universalBinaries"]:
        path = directory / binary
        if not os.access(path, os.X_OK):
            return False
        architectures = subprocess.check_output(["/usr/bin/lipo", "-archs", str(path)], text=True).split()
        if set(architectures) != {"arm64", "x86_64"}:
            return False
    return True


def download(dependency):
    CACHE.mkdir(parents=True, exist_ok=True)
    archive = CACHE / dependency["archiveName"]
    if matches(archive, dependency["archiveBytes"], dependency["archiveSHA256"]):
        return archive
    parsed = urlparse(dependency["sourceURL"])
    if parsed.scheme != "https" or parsed.netloc != "github.com":
        raise ValueError("Dependency archives must use their pinned official GitHub release")
    temporary = archive.with_name(archive.name + ".download")
    print("Downloading " + dependency["archiveName"], flush=True)
    try:
        subprocess.run([
            "/usr/bin/curl", "--fail", "--location", "--silent", "--show-error",
            "--proto", "=https", "--proto-redir", "=https", "--retry", "3",
            "--connect-timeout", "20", "--max-time", "600",
            "--output", str(temporary), dependency["sourceURL"],
        ], check=True)
        if not matches(temporary, dependency["archiveBytes"], dependency["archiveSHA256"]):
            raise ValueError("Archive SHA-256 or size mismatch: " + dependency["archiveName"])
        temporary.replace(archive)
    finally:
        temporary.unlink(missing_ok=True)
    return archive


def check_tar_member(member):
    path = PurePosixPath(member.name)
    if path.is_absolute() or ".." in path.parts or not (member.isdir() or member.isfile() or member.issym()):
        raise ValueError("Unexpected path or file type in dependency archive: " + member.name)
    if member.issym():
        target = PurePosixPath(member.linkname)
        if target.is_absolute() or ".." in target.parts:
            raise ValueError("Unexpected external symlink in dependency archive: " + member.name)


def install(dependency):
    destination = PROJECT / dependency["installDirectory"]
    if valid_install(destination, dependency):
        print(dependency["id"] + " " + dependency["version"] + " verified; using installed dependency", flush=True)
        return
    archive = download(dependency)
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".bootstrap-", dir=destination.parent) as temporary:
        temporary = Path(temporary)
        staged = temporary / "installed"
        if dependency["format"] == "tar.gz":
            with tarfile.open(archive, "r:gz") as source:
                for member in source.getmembers():
                    check_tar_member(member)
                # The complete archive has already been pinned by SHA-256 above.
                source.extractall(temporary / "extracted")
            shutil.move(str(temporary / "extracted" / dependency["archiveRoot"]), staged)
        elif dependency["format"] == "zip-selected":
            staged.mkdir()
            with zipfile.ZipFile(archive) as source:
                # Only the helper is extracted; the release's model weights stay out of Vendor.
                for item in dependency["files"]:
                    path = staged / item["path"]
                    path.parent.mkdir(parents=True, exist_ok=True)
                    member = dependency["archiveRoot"] + "/" + item["path"]
                    with source.open(member) as incoming, path.open("wb") as outgoing:
                        shutil.copyfileobj(incoming, outgoing)
        else:
            raise ValueError("Unknown dependency archive format")
        for item in dependency["symlinks"]:
            path = staged / item["path"]
            path.unlink(missing_ok=True)
            path.symlink_to(item["target"])
        for binary in dependency["universalBinaries"]:
            (staged / binary).chmod(0o755)
        if not valid_install(staged, dependency):
            raise ValueError("Extracted dependency differs from its pinned file hashes: " + dependency["id"])
        backup = temporary / "previous"
        if destination.exists() or destination.is_symlink():
            destination.rename(backup)
        try:
            staged.rename(destination)
        except BaseException:
            if backup.exists() or backup.is_symlink():
                backup.rename(destination)
            raise
    print(dependency["id"] + " " + dependency["version"] + " installed and verified", flush=True)


def main():
    if len(sys.argv) != 1:
        raise ValueError("Usage: bash script/bootstrap.sh (no arguments required)")
    if sys.platform != "darwin":
        raise ValueError("These pinned universal2 dependencies require macOS")
    manifest = json.loads(MANIFEST.read_text())
    if manifest["schemaVersion"] != 1:
        raise ValueError("Unsupported runtime dependency manifest")
    for dependency in manifest["dependencies"]:
        install(dependency)
    print("Inference dependencies ready (CPU, CoreML and WebGPU preserved)", flush=True)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, subprocess.CalledProcessError, tarfile.TarError, zipfile.BadZipFile) as error:
        print("Bootstrap failed: " + str(error), file=sys.stderr)
        sys.exit(1)
