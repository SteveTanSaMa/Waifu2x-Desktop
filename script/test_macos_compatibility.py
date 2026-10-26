import importlib.util
from pathlib import Path
import plistlib
import struct
import sys
import tempfile
import unittest

_spec = importlib.util.spec_from_file_location("check_macos_compatibility", Path(__file__).with_name("check_macos_compatibility.py"))
compatibility = importlib.util.module_from_spec(_spec)
sys.modules[_spec.name] = compatibility
_spec.loader.exec_module(compatibility)


def thin(minimum=(13, 0, 0), cpu=0x0100000C, platform=1, legacy=False):
    packed = minimum[0] << 16 | minimum[1] << 8 | minimum[2]
    command = struct.pack("<4I", 0x24, 16, packed, packed) if legacy else struct.pack("<6I", 0x32, 24, platform, packed, packed, 0)
    return struct.pack("<8I", 0xFEEDFACF, cpu, 0, 2, 1, len(command), 0, 0) + command


def universal(*images):
    offset = 8 + 20 * len(images)
    entries = []
    for cpu, image in images:
        entries.append(struct.pack(">5I", cpu, 0, offset, len(image), 0))
        offset += len(image)
    return struct.pack(">2I", 0xCAFEBABE, len(images)) + b"".join(entries) + b"".join(image for _, image in images)


class MacOSCompatibilityTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.app = self.root / "Fixture.app"
        (self.app / "Contents/MacOS").mkdir(parents=True)
        self.info = dict(CFBundleExecutable="Fixture", LSMinimumSystemVersion="13.0")
        self.write_info()
        (self.app / "Contents/MacOS/Fixture").write_bytes(thin())

    def write_info(self):
        (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps(self.info))

    def test_versions_are_normalized_and_invalid_values_are_rejected(self):
        self.assertEqual(compatibility.version("13"), (13, 0, 0))
        self.assertEqual(compatibility.version("13.4.1"), (13, 4, 1))
        for value in [None, "13beta", "13.0.0.0", "-1.0", "13..0"]:
            with self.assertRaises(compatibility.CompatibilityError):
                compatibility.version(value)

    def test_every_bundled_macho_is_checked_while_resources_are_ignored(self):
        (self.app / "Contents/resource.txt").write_text("ordinary resource")
        helper = self.app / "Contents/helper"
        helper.write_bytes(thin((12, 0, 0)))
        minimum, reports = compatibility.check_bundle(self.app, "13.0", "arm64")
        self.assertEqual(minimum, (13, 0, 0))
        self.assertEqual(len(reports), 2)
        helper.write_bytes(thin((13, 4, 0)))
        with self.assertRaisesRegex(compatibility.CompatibilityError, r"helper.*13\.4"):
            compatibility.check_bundle(self.app, "13.0", "arm64")

    def test_a_newer_declared_minimum_cannot_pass_an_older_product_target(self):
        self.info["LSMinimumSystemVersion"] = "14.0"
        self.write_info()
        with self.assertRaisesRegex(compatibility.CompatibilityError, "above requested"):
            compatibility.check_bundle(self.app, "13.0")

    def test_all_universal_slices_must_meet_the_declared_minimum(self):
        binary = self.app / "Contents/MacOS/Fixture"
        binary.write_bytes(universal((0x0100000C, thin()), (0x01000007, thin(cpu=0x01000007))))
        self.assertEqual(len(compatibility.check_bundle(self.app, architecture="arm64")[1][0][1]), 2)
        binary.write_bytes(universal((0x0100000C, thin()), (0x01000007, thin((13, 4, 0), cpu=0x01000007))))
        with self.assertRaisesRegex(compatibility.CompatibilityError, r"x86_64.*13\.4"):
            compatibility.check_bundle(self.app, architecture="arm64")

    def test_required_architecture_and_macos_platform_are_enforced(self):
        binary = self.app / "Contents/MacOS/Fixture"
        binary.write_bytes(thin(cpu=0x01000007))
        with self.assertRaisesRegex(compatibility.CompatibilityError, "missing arm64"):
            compatibility.check_bundle(self.app, architecture="arm64")
        binary.write_bytes(thin(platform=2))
        with self.assertRaisesRegex(compatibility.CompatibilityError, "not macOS"):
            compatibility.check_bundle(self.app)

    def test_legacy_minimum_os_load_command_is_supported(self):
        (self.app / "Contents/MacOS/Fixture").write_bytes(thin(legacy=True))
        self.assertEqual(compatibility.check_bundle(self.app)[1][0][1][0].minimum_os, (13, 0, 0))

    def test_truncated_or_missing_deployment_metadata_is_rejected(self):
        binary = self.app / "Contents/MacOS/Fixture"
        for data in [thin()[:-1], struct.pack("<8I", 0xFEEDFACF, 0x0100000C, 0, 2, 0, 0, 0, 0),
                     struct.pack(">2I", 0xCAFEBABE, 65)]:
            binary.write_bytes(data)
            with self.assertRaises(compatibility.CompatibilityError):
                compatibility.check_bundle(self.app)

    def test_a_resource_cannot_impersonate_the_main_executable(self):
        (self.app / "Contents/MacOS/Fixture").write_text("not Mach-O")
        with self.assertRaisesRegex(compatibility.CompatibilityError, "not Mach-O"):
            compatibility.check_bundle(self.app)

    def test_bundle_links_cannot_hide_an_external_dependency(self):
        external = self.root / "external.dylib"
        external.write_bytes(thin((14, 0, 0)))
        (self.app / "Contents/linked.dylib").symlink_to(external)
        with self.assertRaisesRegex(compatibility.CompatibilityError, "outside the app"):
            compatibility.check_bundle(self.app)


if __name__ == "__main__":
    unittest.main()
