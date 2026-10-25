"""Offline checks for exact app deltas and content-addressed model repairs."""

import hashlib
import io
import json
import os
from pathlib import Path
import plistlib
import shutil
import tarfile
import tempfile
import unittest
import zipfile

import package_app_updates as apps
import package_models as models


class AppUpdatePackagingTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="waifu2x-update-tool-tests-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.dist = self.root / "dist"
        self.base = self.make_app("base", "1.0.1", "2")
        self.target = self.make_app("target", "1.0.2", "3")
        for app in (self.base, self.target):
            (app / "Contents/Frameworks").mkdir()
            # An unchanged incompressible runtime makes file reuse measurable.
        payload = os.urandom(80_000)
        for app in (self.base, self.target):
            (app / "Contents/Frameworks/runtime.dylib").write_bytes(payload)
        (self.base / "Contents/Resources/removed.txt").write_bytes(b"old resource")
        (self.target / "Contents/Resources/new.txt").write_bytes(b"new resource")

    def make_app(self, directory, version, build):
        app = self.root / directory / apps.BUNDLE_NAME
        (app / "Contents/MacOS").mkdir(parents=True)
        (app / "Contents/Resources").mkdir()
        (app / "Contents/_CodeSignature").mkdir()
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps(dict(
            CFBundleIdentifier=apps.BUNDLE_IDENTIFIER, CFBundleShortVersionString=version,
            CFBundleVersion=build)))
        executable = app / "Contents/MacOS/Waifu2x"
        executable.write_bytes(("executable " + version).encode())
        executable.chmod(0o755)
        (app / "Contents/_CodeSignature/CodeResources").write_bytes(("signature " + version).encode())
        return app

    def zip_app(self, app, name):
        output = self.root / name
        with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            for path in sorted(app.rglob("*")):
                if path.is_file():
                    archive.write(path, apps.BUNDLE_NAME + "/" + path.relative_to(app).as_posix())
            archive.writestr("__MACOSX/._Waifu2x.app", b"resource fork metadata")
        return output

    def package(self, previous=True):
        target_zip = self.zip_app(self.target, "Waifu2x-1.0.2-macos-arm64.zip")
        base_zip = self.zip_app(self.base, "Waifu2x-1.0.1-macos-arm64.zip") if previous else None
        return apps.package(self.target, target_zip, "v1.0.2", self.dist, base_zip)

    def test_delta_reconstructs_exact_target_without_unchanged_runtime(self):
        result = self.package()
        self.assertEqual(result["schemaVersion"], 1)
        self.assertEqual(result["appBundleName"], apps.BUNDLE_NAME)
        self.assertEqual((result["version"], result["build"]), ("1.0.2", "3"))
        delta, = result["deltas"]
        self.assertEqual(delta["baseFiles"], apps.inventory(self.base))
        self.assertEqual(delta["removedFiles"], ["Contents/Resources/removed.txt"])
        self.assertNotIn("Contents/Frameworks/runtime.dylib", delta["changedFiles"])
        archive_path = self.dist / delta["archive"]["path"]
        self.assertLess(delta["archive"]["bytes"], result["full"]["bytes"])
        self.assertEqual(apps.sha256(archive_path), delta["archive"]["sha256"])
        copy = self.root / "reconstructed.app"
        shutil.copytree(self.base, copy)
        for name in delta["removedFiles"]:
            (copy / name).unlink()
        with tarfile.open(archive_path, "r:xz") as archive:
            self.assertEqual(archive.getnames(), delta["changedFiles"])
            for member in archive:
                self.assertTrue(member.isfile())
                self.assertEqual(member.mtime, 0)
                path = copy / member.name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(archive.extractfile(member).read())
                path.chmod(member.mode)
        self.assertEqual(apps.inventory(copy), apps.inventory(self.target))

    def test_full_catalog_without_a_previous_release_is_usable(self):
        result = self.package(previous=False)
        self.assertEqual(result["deltas"], [])
        self.assertEqual(result["files"], apps.inventory(self.target))
        self.assertEqual(json.loads((self.dist / apps.CATALOG_NAME).read_text()), result)

    def test_same_version_does_not_publish_a_delta(self):
        self.base.joinpath("Contents/Info.plist").write_bytes(self.target.joinpath("Contents/Info.plist").read_bytes())
        self.assertEqual(self.package()["deltas"], [])

    def test_modified_full_zip_is_rejected(self):
        wrong_zip = self.zip_app(self.base, "Waifu2x-1.0.2-macos-arm64.zip")
        with self.assertRaisesRegex(ValueError, "differs"):
            apps.package(self.target, wrong_zip, "v1.0.2", self.dist)
        self.assertFalse((self.dist / apps.CATALOG_NAME).exists())

    def test_wrong_app_identity_tag_and_symlinks_are_rejected(self):
        archive = self.zip_app(self.target, "Waifu2x-1.0.2-macos-arm64.zip")
        with self.assertRaisesRegex(ValueError, "tag"):
            apps.package(self.target, archive, "v1.0.3", self.dist)
        link = self.target / "Contents/Resources/external"
        link.symlink_to(self.root)
        with self.assertRaisesRegex(ValueError, "symlink"):
            apps.inventory(self.target)
        link.unlink()
        info = self.target / "Contents/Info.plist"
        values = plistlib.loads(info.read_bytes())
        values["CFBundleIdentifier"] = "other.app"
        info.write_bytes(plistlib.dumps(values))
        with self.assertRaisesRegex(ValueError, "identifier"):
            apps.app_version(self.target)

    def test_zip_traversal_symlinks_and_duplicate_paths_are_rejected(self):
        cases = ["../escape", "/escape", "Waifu2x.app/Contents/../../escape", "Waifu2x.app\\escape"]
        for index, name in enumerate(cases):
            with self.subTest(name=name):
                archive_path = self.root / f"unsafe-{index}.zip"
                with zipfile.ZipFile(archive_path, "w") as archive:
                    archive.writestr(name, b"escape")
                with self.assertRaises(ValueError):
                    apps.extract_app_zip(archive_path, self.root / f"unsafe-{index}")
                self.assertFalse(self.root.joinpath("escape").exists())
        archive_path = self.root / "link.zip"
        with zipfile.ZipFile(archive_path, "w") as archive:
            member = zipfile.ZipInfo("Waifu2x.app/Contents/external")
            member.external_attr = 0o120777 << 16
            archive.writestr(member, b"../../../escape")
        with self.assertRaises(ValueError):
            apps.extract_app_zip(archive_path, self.root / "link")
        archive_path = self.root / "duplicate.zip"
        with zipfile.ZipFile(archive_path, "w") as archive:
            archive.writestr("Waifu2x.app/Contents/File", b"one")
            archive.writestr("Waifu2x.app/Contents/file", b"two")
        with self.assertRaisesRegex(ValueError, "Duplicate"):
            apps.extract_app_zip(archive_path, self.root / "duplicate")

    def test_incremental_archives_are_reproducible(self):
        first = self.package()
        first_bytes = (self.dist / first["deltas"][0]["archive"]["path"]).read_bytes()
        second = self.package()
        self.assertEqual(first, second)
        self.assertEqual(first_bytes, (self.dist / second["deltas"][0]["archive"]["path"]).read_bytes())


class ModelRepairPackagingTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="waifu2x-model-repair-tool-tests-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.cache, self.dist = self.root / "models", self.root / "dist"
        self.payloads = {"ONNXModels/art/a.onnx": b"shared weights" * 50,
                         "ONNXModels/art/b.onnx": b"shared weights" * 50,
                         "Engine/models-cunet/a.param": b"parameter fixture"}
        self.files = []
        for name, data in self.payloads.items():
            path = self.cache / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
            self.files.append(dict(path=name, bytes=len(data), sha256=hashlib.sha256(data).hexdigest(),
                                   sourceURL="https://source.example.invalid/" + name))

    def test_identical_models_share_one_verified_single_entry_archive(self):
        result = models.package_repairs(self.cache, self.files, "models-v1", "v1.0.2", self.dist)
        self.assertEqual(result["schemaVersion"], 1)
        self.assertEqual(len(result["files"]), 3)
        self.assertEqual(len(list(self.dist.glob("*.tar.xz"))), 2)
        by_name = {item["path"]: item for item in result["files"]}
        self.assertEqual(by_name["ONNXModels/art/a.onnx"]["archive"], by_name["ONNXModels/art/b.onnx"]["archive"])
        for item in result["files"]:
            metadata = item["archive"]
            archive_path = self.dist / metadata["path"]
            self.assertEqual(models.sha256(archive_path), metadata["sha256"])
            self.assertEqual(archive_path.stat().st_size, metadata["bytes"])
            self.assertEqual(metadata["sourceURL"], "https://github.com/SteveTanSaMa/Waifu2x-Desktop/releases/download/v1.0.2/" + metadata["path"])
            with tarfile.open(archive_path, "r:xz") as archive:
                self.assertEqual(archive.getnames(), ["model"])
                member = archive.getmember("model")
                self.assertTrue(member.isfile())
                self.assertEqual(member.mtime, 0)
                self.assertEqual(archive.extractfile(member).read(), self.payloads[item["path"]])

    def test_corrupt_or_symlink_sources_never_publish_a_manifest(self):
        path = self.cache / self.files[0]["path"]
        path.write_bytes(b"corrupt")
        with self.assertRaises(ValueError):
            models.package_repairs(self.cache, self.files, "models-v1", "v1.0.2", self.dist)
        self.assertFalse(self.dist.exists())
        path.unlink()
        path.symlink_to(self.cache / self.files[1]["path"])
        with self.assertRaises(ValueError):
            models.package_repairs(self.cache, self.files, "models-v1", "v1.0.2", self.dist)

    def test_repair_assets_are_reproducible(self):
        first = models.package_repairs(self.cache, self.files, "models-v1", "v1.0.2", self.dist)
        contents = {path.name: path.read_bytes() for path in self.dist.iterdir()}
        second = models.package_repairs(self.cache, self.files, "models-v1", "v1.0.2", self.dist)
        self.assertEqual(first, second)
        self.assertEqual(contents, {path.name: path.read_bytes() for path in self.dist.iterdir()})


if __name__ == "__main__":
    unittest.main()
