#!/usr/bin/env python3
"""Package a verified app inventory and optional file-level incremental update."""

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import stat
import tarfile
import tempfile
import zipfile


BUNDLE_NAME = "Waifu2x.app"
BUNDLE_IDENTIFIER = "studio.stevetan.Waifu2x"
CATALOG_NAME = "Waifu2x-update.json"
MAX_APP_BYTES = 2 * 1024 * 1024 * 1024


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as source:
        for chunk in iter(lambda: source.read(4 * 1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def safe_path(name):
    if (not isinstance(name, str) or not name or "\\" in name or ":" in name
            or any(ord(c) < 32 or ord(c) == 127 for c in name)
            or name.startswith("/") or any(part in ("", ".", "..") for part in name.split("/"))):
        raise ValueError("Unsafe app path: " + repr(name))
    return PurePosixPath(name)


def inventory(app):
    app = Path(app)
    if not app.is_dir() or app.is_symlink():
        raise ValueError("App bundle must be a real directory")
    files = []
    folded = set()
    total = 0
    for path in sorted(app.rglob("*")):
        relative = path.relative_to(app).as_posix()
        safe_path(relative)
        if path.is_symlink():
            raise ValueError("App update bundles cannot contain symlinks: " + relative)
        if path.is_dir():
            continue
        details = path.stat()
        if not stat.S_ISREG(details.st_mode) or details.st_mode & 0o7000:
            raise ValueError("Unsupported app file: " + relative)
        if relative.casefold() in folded:
            raise ValueError("Case-colliding app files: " + relative)
        folded.add(relative.casefold())
        total += details.st_size
        if total > MAX_APP_BYTES:
            raise ValueError("App update bundle exceeds the size limit")
        files.append(dict(path=relative, bytes=details.st_size, sha256=sha256(path),
                          mode=stat.S_IMODE(details.st_mode)))
    if not files:
        raise ValueError("App update bundle is empty")
    return files


def app_version(app):
    info = plistlib.loads((Path(app) / "Contents/Info.plist").read_bytes())
    version = info.get("CFBundleShortVersionString")
    build = info.get("CFBundleVersion")
    if (info.get("CFBundleIdentifier") != BUNDLE_IDENTIFIER
            or not isinstance(version, str) or not re.fullmatch(r"\d+\.\d+\.\d+", version)
            or not isinstance(build, str) or not build or len(build) > 128
            or any(ord(c) < 32 for c in build)):
        raise ValueError("Unexpected app identifier, version or build")
    return version, build


def extract_app_zip(archive_path, destination):
    """Read only regular bundle files, never ZIP-controlled links or destinations."""
    destination = Path(destination)
    root = destination / BUNDLE_NAME
    seen = set()
    declared_bytes = 0
    with zipfile.ZipFile(archive_path) as archive:
        for member in archive.infolist():
            name = member.filename.rstrip("/")
            safe_path(name)
            parts = PurePosixPath(name).parts
            mode = member.external_attr >> 16
            if stat.S_ISLNK(mode) or stat.S_IFMT(mode) not in (0, stat.S_IFREG, stat.S_IFDIR):
                raise ValueError("Unsupported ZIP member: " + name)
            if parts[0] == "__MACOSX":
                continue
            if parts[0] != BUNDLE_NAME:
                raise ValueError("Unexpected ZIP bundle root: " + name)
            if member.is_dir():
                continue
            if len(parts) < 2 or name.casefold() in seen:
                raise ValueError("Duplicate or invalid ZIP member: " + name)
            seen.add(name.casefold())
            declared_bytes += member.file_size
            if declared_bytes > MAX_APP_BYTES:
                raise ValueError("App ZIP exceeds the size limit")
            output = destination.joinpath(*parts)
            output.parent.mkdir(parents=True, exist_ok=True)
            with archive.open(member) as incoming, output.open("xb") as outgoing:
                copied = 0
                while chunk := incoming.read(4 * 1024 * 1024):
                    copied += len(chunk)
                    if copied > member.file_size:
                        raise ValueError("ZIP member exceeds its declared size")
                    outgoing.write(chunk)
            if copied != member.file_size:
                raise ValueError("Incomplete ZIP member: " + name)
            output.chmod(stat.S_IMODE(mode) or 0o644)
    return root


def metadata(path):
    path = Path(path)
    return dict(path=path.name, bytes=path.stat().st_size, sha256=sha256(path))


def version_tuple(version):
    return tuple(int(part) for part in version.split("."))


def package(app, full_archive, release, output_dir, previous_archive=None):
    app, full_archive, output_dir = Path(app), Path(full_archive), Path(output_dir)
    version, build = app_version(app)
    if release != "v" + version:
        raise ValueError("Release tag must match the app version")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*\.zip", full_archive.name):
        raise ValueError("Unsafe full app archive name")
    target_files = inventory(app)
    # Ensure that fallback downloads recreate exactly the app used for deltas.
    with tempfile.TemporaryDirectory(prefix="waifu2x-full-update-") as temporary:
        expanded = extract_app_zip(full_archive, temporary)
        if inventory(expanded) != target_files:
            raise ValueError("The full ZIP differs from the signed app inventory")
    output_dir.mkdir(parents=True, exist_ok=True)
    result = dict(schemaVersion=1, version=version, build=build, appBundleName=BUNDLE_NAME,
                  full=metadata(full_archive), files=target_files, deltas=[])
    if previous_archive:
        with tempfile.TemporaryDirectory(prefix="waifu2x-base-update-") as temporary:
            previous = extract_app_zip(previous_archive, temporary)
            from_version, from_build = app_version(previous)
            base_files = inventory(previous)
            if version_tuple(from_version) < version_tuple(version):
                base = {item["path"]: item for item in base_files}
                target = {item["path"]: item for item in target_files}
                changed = sorted(name for name in target if target[name] != base.get(name))
                removed = sorted(set(base).difference(target))
                if changed or removed:
                    # Build identifiers are only metadata; asset names use versions.
                    archive_path = output_dir / f"Waifu2x-{from_version}-to-{version}-macos-arm64.delta.tar.xz"
                    partial = archive_path.with_suffix(archive_path.suffix + ".partial")
                    try:
                        with tarfile.open(partial, "w:xz", format=tarfile.USTAR_FORMAT, preset=6) as archive:
                            for name in changed:
                                item = target[name]
                                member = tarfile.TarInfo(name)
                                member.size, member.mode = item["bytes"], item["mode"]
                                member.uid = member.gid = member.mtime = 0
                                with (app / name).open("rb") as source:
                                    archive.addfile(member, source)
                        if partial.stat().st_size < full_archive.stat().st_size:
                            os.replace(partial, archive_path)
                            result["deltas"].append(dict(fromVersion=from_version, fromBuild=from_build,
                                baseFiles=base_files, archive=metadata(archive_path),
                                changedFiles=changed, removedFiles=removed))
                    finally:
                        partial.unlink(missing_ok=True)
    catalog = output_dir / CATALOG_NAME
    temporary = catalog.with_suffix(".json.partial")
    try:
        temporary.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
        os.replace(temporary, catalog)
    finally:
        temporary.unlink(missing_ok=True)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True, help="Final signed arm64 app bundle")
    parser.add_argument("--full-archive", type=Path, required=True, help="Complete release ZIP for fallback")
    parser.add_argument("--previous-archive", type=Path, help="Previous official arm64 release ZIP")
    parser.add_argument("--release", required=True, help="Stable release tag matching the app version")
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()
    result = package(args.app, args.full_archive, args.release, args.output_dir, args.previous_archive)
    print(f"App update catalog: {args.output_dir / CATALOG_NAME}")
    if result["deltas"]:
        delta = result["deltas"][0]
        print(f"Incremental archive: {delta['archive']['bytes']:,} bytes; full ZIP: {result['full']['bytes']:,} bytes")
    else:
        print("No compatible smaller delta; the verified full ZIP remains available")


if __name__ == "__main__":
    main()
