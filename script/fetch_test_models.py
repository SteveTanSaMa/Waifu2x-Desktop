#!/usr/bin/env python3
"""Fetch pinned integration-test models without changing the committed catalog."""

import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys
from urllib.parse import urlsplit
import uuid


PROJECT = Path(__file__).resolve().parents[1]
CATALOG = PROJECT / "Waifu2x/Resources/ModelCatalog.json"


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(4 * 1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_catalog():
    catalog = json.loads(CATALOG.read_text(encoding="utf-8"))
    version = catalog.get("catalogVersion", "")
    files = catalog.get("files", [])
    if catalog.get("schemaVersion") != 2 or not re.fullmatch(r"models-v[0-9]+", version) or not files or len(files) > 512:
        raise ValueError("The committed model catalog is invalid")
    seen = set()
    for item in files:
        path = item["path"]
        parts = PurePosixPath(path).parts
        url = urlsplit(item["sourceURL"])
        if (not path or path.startswith("/") or "\\" in path or ":" in path
                or "\x00" in path or "\n" in path or "\r" in path
                or any(part in ("", ".", "..") for part in path.split("/"))
                or not parts or path in seen
                or not isinstance(item["bytes"], int) or not 0 < item["bytes"] <= 2_000_000_000
                or not re.fullmatch(r"[a-f0-9]{64}", item["sha256"])
                or url.scheme != "https" or not url.hostname or url.username or url.password or url.fragment):
            raise ValueError("Invalid model catalog entry: " + path)
        seen.add(path)
    return version, files


def safe_destination(root, relative):
    destination = root / relative
    current = destination
    while current != root.parent:
        if current.is_symlink():
            raise ValueError("Test model cache must not contain symbolic links: " + str(current))
        current = current.parent
    return destination


def matches(path, item):
    return (path.is_file() and not path.is_symlink() and path.stat().st_size == item["bytes"]
            and sha256(path) == item["sha256"])


def prepare(root, item, check_only):
    destination = safe_destination(root, item["path"])
    if matches(destination, item):
        return "Verified cache", item["path"]
    if check_only:
        raise ValueError("Missing or invalid test model: " + item["path"])
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_name("." + destination.name + "." + uuid.uuid4().hex + ".download")
    try:
        subprocess.run([
            "/usr/bin/curl", "--fail", "--location", "--proto", "=https", "--proto-redir", "=https",
            "--retry", "3", "--connect-timeout", "20", "--max-time", "1200", "--silent", "--show-error",
            "--output", str(temporary), item["sourceURL"],
        ], check=True)
        if not matches(temporary, item):
            raise ValueError("Downloaded bytes differ from the committed SHA-256: " + item["path"])
        os.replace(temporary, destination)
        return "Downloaded and verified", item["path"]
    finally:
        temporary.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Verify cached models without downloading")
    parser.add_argument("--jobs", type=int, default=4, help="Concurrent file downloads (default: 4)")
    args = parser.parse_args()
    if not 1 <= args.jobs <= 16:
        parser.error("--jobs must be between 1 and 16")
    version, files = load_catalog()
    root = PROJECT / "build/TestModels" / version
    total = sum(item["bytes"] for item in files)
    print(f"Test models: {len(files)} files, {total:,} bytes\nCache: {root}", flush=True)
    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        pending = [pool.submit(prepare, root, item, args.check) for item in files]
        for count, future in enumerate(as_completed(pending), 1):
            action, path = future.result()
            print(f"[{count}/{len(files)}] {action}: {path}", flush=True)
    print("All test models match the committed catalog", flush=True)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        print("Model preparation failed: " + str(error), file=sys.stderr)
        sys.exit(1)
