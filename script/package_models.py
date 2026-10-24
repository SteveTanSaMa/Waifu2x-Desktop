#!/usr/bin/env python3
"""Build the reproducible model archive from an already verified model cache."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import tarfile

PROJECT = Path(__file__).resolve().parents[1]
CATALOG = PROJECT / "Waifu2x/Resources/ModelCatalog.json"


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(4 * 1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, help="Verified model cache root")
    parser.add_argument("--release", default="v1.0.1", help="GitHub Release tag hosting the archive")
    parser.add_argument("--update-catalog", action="store_true", help="Record archive metadata in the catalog")
    args = parser.parse_args()
    if not re.fullmatch(r"v\d+\.\d+\.\d+", args.release):
        parser.error("--release must be a stable version tag")
    catalog = json.loads(CATALOG.read_text())
    version = catalog["catalogVersion"]
    if not re.fullmatch(r"models-v\d+", version):
        raise ValueError("Invalid model cache version")
    root = args.root or PROJECT / "build/TestModels" / version
    files = catalog["files"]
    for item in files:
        relative = item["path"]
        if (relative.startswith("/") or "\\" in relative or ":" in relative
                or any(p in ("", ".", "..") for p in relative.split("/"))):
            raise ValueError("Invalid model path: " + relative)
        path = root / relative
        if not path.is_file() or path.is_symlink() or path.stat().st_size != item["bytes"] or sha256(path) != item["sha256"]:
            raise ValueError("Missing or invalid source model: " + str(path))
        if not path.resolve().is_relative_to(root.resolve()):
            raise ValueError("Source model escapes the cache: " + str(path))
    destination = PROJECT / "dist" / ("Waifu2x-" + version + ".tar.xz")
    destination.parent.mkdir(exist_ok=True)
    temporary = destination.with_suffix(destination.suffix + ".partial")
    print(f"Packing {len(files)} verified files ({sum(i['bytes'] for i in files):,} bytes)", flush=True)
    try:
        with tarfile.open(temporary, mode="w:xz", format=tarfile.USTAR_FORMAT, preset=6) as archive:
            for item in sorted(files, key=lambda i: i["path"]):
                info = tarfile.TarInfo(item["path"])
                info.size = item["bytes"]
                info.mode = 0o644
                info.mtime = info.uid = info.gid = 0
                with (root / item["path"]).open("rb") as stream:
                    archive.addfile(info, stream)
        os.replace(temporary, destination)
    finally:
        temporary.unlink(missing_ok=True)
    metadata = {
        "path": destination.name,
        "bytes": destination.stat().st_size,
        "sha256": sha256(destination),
        "sourceURL": f"https://github.com/SteveTanSaMa/Waifu2x-Desktop/releases/download/{args.release}/{destination.name}",
    }
    if args.update_catalog:
        catalog["schemaVersion"] = 3
        catalog = {"schemaVersion": 3, "catalogVersion": version, "archive": metadata, "files": files}
        CATALOG.write_text(json.dumps(catalog, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(metadata, indent=2), flush=True)


if __name__ == "__main__":
    main()
