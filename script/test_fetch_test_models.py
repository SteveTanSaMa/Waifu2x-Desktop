"""Exercise real tar.xz model installation, hostile entries, and cache rollback."""

import hashlib
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest import mock

import fetch_test_models as models


class ModelArchiveTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="waifu2x-model-tests-")
        self.addCleanup(self.temporary.cleanup)
        self.project = Path(self.temporary.name).resolve()
        self.root = self.project / "build/TestModels/models-v1"
        self.payloads = {
            "ONNXModels/art/model.onnx": b"onnx fixture",
            "Engine/models-cunet/model.bin": b"ncnn fixture",
        }
        self.files = [dict(path=name, bytes=len(data), sha256=hashlib.sha256(data).hexdigest(),
                           sourceURL="https://example.invalid/" + name)
                      for name, data in self.payloads.items()]

    def entries(self):
        return [(name, tarfile.REGTYPE, data, "") for name, data in self.payloads.items()]

    def make_archive(self, entries=None):
        path = self.project / "Waifu2x-models-v1.tar.xz"
        with tarfile.open(path, "w:xz", format=tarfile.USTAR_FORMAT) as archive:
            for name, kind, data, link in self.entries() if entries is None else entries:
                item = tarfile.TarInfo(name)
                item.type = kind
                item.linkname = link
                item.size = len(data) if kind == tarfile.REGTYPE else 0
                archive.addfile(item, io.BytesIO(data) if kind == tarfile.REGTYPE else None)
        metadata = dict(path=path.name, bytes=path.stat().st_size, sha256=models.sha256(path),
                        sourceURL="https://example.invalid/" + path.name)
        return path, metadata

    def old_cache(self):
        path = self.root / self.files[0]["path"]
        path.parent.mkdir(parents=True)
        path.write_bytes(b"existing incomplete cache")

    def snapshot(self):
        return {p.relative_to(self.root).as_posix(): p.read_bytes()
                for p in self.root.rglob("*") if p.is_file()}

    def write_catalog(self, archive):
        catalog = self.project / "Waifu2x/Resources/ModelCatalog.json"
        catalog.parent.mkdir(parents=True, exist_ok=True)
        catalog.write_text(json.dumps(dict(schemaVersion=3, catalogVersion="models-v1",
                                          archive=archive, files=self.files)))
        return catalog

    def test_local_archive_installs_all_verified_files(self):
        self.old_cache()
        path, archive = self.make_archive()
        models.prepare_archive(self.root, self.files, archive, path)
        self.assertEqual(self.snapshot(), self.payloads)
        self.assertEqual(models.invalid_cache_files(self.root, self.files, 2), [])
        self.assertTrue(path.exists())
        self.assertEqual(list(self.root.parent.glob(".*.backup-*")), [])

    def test_bad_archive_checksum_or_size_keeps_old_cache(self):
        self.old_cache()
        before = self.snapshot()
        path, archive = self.make_archive()
        for override in ({"sha256": "0" * 64}, {"bytes": archive["bytes"] + 1}):
            with self.subTest(override=override), self.assertRaises(ValueError):
                models.prepare_archive(self.root, self.files, archive | override, path)
            self.assertEqual(self.snapshot(), before)

    def test_hostile_archives_are_rejected_without_changing_cache(self):
        self.old_cache()
        before = self.snapshot()
        first, second = self.entries()
        cases = {
            "absolute": [("/outside", tarfile.REGTYPE, b"escape", ""), second],
            "parent traversal": [("../outside", tarfile.REGTYPE, b"escape", ""), second],
            "symlink": [(first[0], tarfile.SYMTYPE, b"", "../../../outside"), second],
            "hardlink": [(first[0], tarfile.LNKTYPE, b"", second[0]), second],
            "directory": [(first[0], tarfile.DIRTYPE, b"", ""), second],
            "extra file": [first, second, ("extra", tarfile.REGTYPE, b"extra", "")],
            "duplicate": [first, second, first],
            "missing": [first],
            "wrong size": [(first[0], tarfile.REGTYPE, first[2] + b"!", ""), second],
            "wrong file hash": [(first[0], tarfile.REGTYPE, b"X" + first[2][1:], ""), second],
        }
        for name, entries in cases.items():
            with self.subTest(name=name):
                path, archive = self.make_archive(entries)
                with self.assertRaises(ValueError):
                    models.prepare_archive(self.root, self.files, archive, path)
                self.assertEqual(self.snapshot(), before)
                self.assertFalse((self.project / "outside").exists())

    def test_install_failure_restores_previous_cache(self):
        self.old_cache()
        before = self.snapshot()
        path, archive = self.make_archive()
        replace = models.os.replace

        def fail_install(source, destination):
            if Path(source).name == "models":
                raise OSError("simulated final rename failure")
            return replace(source, destination)

        with mock.patch.object(models.os, "replace", side_effect=fail_install), self.assertRaises(OSError):
            models.prepare_archive(self.root, self.files, archive, path)
        self.assertEqual(self.snapshot(), before)
        self.assertEqual(list(self.root.parent.glob(".*.backup-*")), [])

    def test_complete_cache_is_reused_without_network(self):
        path, archive = self.make_archive()
        models.prepare_archive(self.root, self.files, archive, path)
        catalog = self.write_catalog(archive)
        with mock.patch.object(models, "PROJECT", self.project), mock.patch.object(models, "CATALOG", catalog), \
                mock.patch.object(models.sys, "argv", ["fetch_test_models.py"]), \
                mock.patch.object(models.subprocess, "run", side_effect=AssertionError("unexpected download")):
            models.main()
        self.assertEqual(self.snapshot(), self.payloads)

    def test_check_is_read_only_for_an_incomplete_cache(self):
        self.old_cache()
        before = self.snapshot()
        _, archive = self.make_archive()
        catalog = self.write_catalog(archive)
        with mock.patch.object(models, "PROJECT", self.project), mock.patch.object(models, "CATALOG", catalog), \
                mock.patch.object(models.sys, "argv", ["fetch_test_models.py", "--check"]), \
                mock.patch.object(models.subprocess, "run", side_effect=AssertionError("unexpected download")), \
                self.assertRaises(ValueError):
            models.main()
        self.assertEqual(self.snapshot(), before)

    def test_archive_and_root_cli_install_a_fresh_cache_without_network(self):
        path, archive = self.make_archive()
        catalog = self.write_catalog(archive)
        with mock.patch.object(models, "CATALOG", catalog), \
                mock.patch.object(models.sys, "argv", ["fetch_test_models.py", "--archive", str(path), "--root", str(self.root)]), \
                mock.patch.object(models.subprocess, "run", side_effect=AssertionError("unexpected download")):
            models.main()
        self.assertEqual(self.snapshot(), self.payloads)

    def test_single_download_uses_archive_url(self):
        path, archive = self.make_archive()

        def download(arguments, check):
            self.assertTrue(check)
            self.assertEqual(arguments[-1], archive["sourceURL"])
            Path(arguments[arguments.index("--output") + 1]).write_bytes(path.read_bytes())

        with mock.patch.object(models.subprocess, "run", side_effect=download) as request:
            models.prepare_archive(self.root, self.files, archive, None)
        request.assert_called_once()
        self.assertEqual(self.snapshot(), self.payloads)

    def test_unrelated_directory_is_preserved(self):
        self.root.mkdir(parents=True)
        document = self.root / "personal-document.txt"
        document.write_bytes(b"keep this")
        path, archive = self.make_archive()
        with self.assertRaises(ValueError):
            models.prepare_archive(self.root, self.files, archive, path)
        self.assertEqual(document.read_bytes(), b"keep this")


if __name__ == "__main__":
    unittest.main()
