#!/usr/bin/env python3
"""Check an app's declared minimum macOS version against every bundled Mach-O slice.

This checks deployment metadata, not runtime behavior on an older Mac. It never
rewrites binaries or masks an incompatible dependency by changing load commands.
"""

import argparse
from dataclasses import dataclass
from pathlib import Path
import plistlib
import re
import struct
import sys


class CompatibilityError(ValueError):
    pass


def version(value):
    if not isinstance(value, str) or not re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,2}", value):
        raise CompatibilityError(f"Invalid macOS version: {value!r}")
    parts = tuple(map(int, value.split(".")))
    return parts + (0,) * (3 - len(parts))


def version_text(value):
    return ".".join(map(str, value[:2] if value[2] == 0 else value))


def unpack_version(value):
    return value >> 16, (value >> 8) & 255, value & 255


@dataclass(frozen=True)
class Slice:
    architecture: str
    minimum_os: tuple


CPU_NAMES = {7: "i386", 12: "arm", 0x01000007: "x86_64", 0x0100000C: "arm64"}
THIN_MAGICS = {
    b"\xce\xfa\xed\xfe": ("<", 28), b"\xcf\xfa\xed\xfe": ("<", 32),
    b"\xfe\xed\xfa\xce": (">", 28), b"\xfe\xed\xfa\xcf": (">", 32),
}
FAT_MAGICS = {
    b"\xca\xfe\xba\xbe": (">", False), b"\xbe\xba\xfe\xca": ("<", False),
    b"\xca\xfe\xba\xbf": (">", True), b"\xbf\xba\xfe\xca": ("<", True),
}


def _read(stream, offset, count, end):
    if offset < 0 or count < 0 or offset + count > end:
        raise CompatibilityError("Truncated Mach-O metadata")
    stream.seek(offset)
    result = stream.read(count)
    if len(result) != count:
        raise CompatibilityError("Truncated Mach-O metadata")
    return result


def _thin(stream, offset, size):
    end = offset + size
    magic = _read(stream, offset, 4, end)
    if magic not in THIN_MAGICS:
        raise CompatibilityError("A universal binary contains an invalid Mach-O slice")
    endian, header_size = THIN_MAGICS[magic]
    header = _read(stream, offset, header_size, end)
    cpu, _, _, command_count, command_bytes, _ = struct.unpack_from(endian + "6I", header, 4)
    architecture = CPU_NAMES.get(cpu, f"cpu-{cpu:#x}")
    if command_count > 65536 or command_bytes > 16 * 1024 * 1024:
        raise CompatibilityError("Unreasonable Mach-O load-command table")
    commands_end = offset + header_size + command_bytes
    if commands_end > end:
        raise CompatibilityError("Truncated Mach-O load-command table")
    cursor = offset + header_size
    minimums = []
    for _ in range(command_count):
        command, command_size = struct.unpack(endian + "2I", _read(stream, cursor, 8, commands_end))
        if command_size < 8 or command_size % 4:
            raise CompatibilityError("Invalid Mach-O load-command size")
        data = _read(stream, cursor, command_size, commands_end)
        if command == 0x32:  # LC_BUILD_VERSION
            if command_size < 24:
                raise CompatibilityError("Truncated LC_BUILD_VERSION")
            platform, minimum = struct.unpack_from(endian + "2I", data, 8)
            if platform != 1:  # PLATFORM_MACOS
                raise CompatibilityError(f"{architecture} targets Apple platform {platform}, not macOS")
            minimums.append(unpack_version(minimum))
        elif command == 0x24:  # LC_VERSION_MIN_MACOSX
            if command_size < 16:
                raise CompatibilityError("Truncated LC_VERSION_MIN_MACOSX")
            minimums.append(unpack_version(struct.unpack_from(endian + "I", data, 8)[0]))
        cursor += command_size
    if cursor != commands_end:
        raise CompatibilityError("Inconsistent Mach-O load-command table")
    if len(minimums) != 1 or minimums[0][0] == 0:
        raise CompatibilityError(f"{architecture} must declare exactly one macOS deployment target")
    return Slice(architecture, minimums[0])


def macho_slices(path):
    """Return all slices, or None for an ordinary resource file."""
    path = Path(path)
    size = path.stat().st_size
    if size < 4:
        return None
    with path.open("rb") as stream:
        magic = _read(stream, 0, 4, size)
        if magic in THIN_MAGICS:
            return [_thin(stream, 0, size)]
        if magic not in FAT_MAGICS:
            return None
        endian, wide = FAT_MAGICS[magic]
        count = struct.unpack(endian + "I", _read(stream, 4, 4, size))[0]
        if count == 0 or count > 64:
            raise CompatibilityError("Invalid universal-binary slice count")
        entry_size = 32 if wide else 20
        table_end = 8 + count * entry_size
        _read(stream, 8, count * entry_size, size)
        result, intervals = [], []
        for index in range(count):
            entry = _read(stream, 8 + index * entry_size, entry_size, size)
            if wide:
                cpu, _, offset, length, _, _ = struct.unpack(endian + "2I2Q2I", entry)
            else:
                cpu, _, offset, length, _ = struct.unpack(endian + "5I", entry)
            if offset < table_end or not length or offset + length > size:
                raise CompatibilityError("Invalid universal-binary slice bounds")
            if any(offset < old_end and old_start < offset + length for old_start, old_end in intervals):
                raise CompatibilityError("Overlapping universal-binary slices")
            intervals.append((offset, offset + length))
            item = _thin(stream, offset, length)
            if item.architecture != CPU_NAMES.get(cpu, f"cpu-{cpu:#x}"):
                raise CompatibilityError("Universal-binary architecture disagrees with its slice")
            result.append(item)
        if len({item.architecture for item in result}) != len(result):
            raise CompatibilityError("Duplicate universal-binary architecture")
        return result


def check_bundle(app, minimum_os=None, architecture=None):
    app = Path(app)
    info_path = app / "Contents/Info.plist"
    if not app.is_dir() or not info_path.is_file():
        raise CompatibilityError(f"Not an app bundle: {app}")
    with info_path.open("rb") as source:
        info = plistlib.load(source)
    declared = version(info.get("LSMinimumSystemVersion"))
    requested = version(minimum_os) if minimum_os is not None else declared
    if declared > requested:
        raise CompatibilityError(f"App declares macOS {version_text(declared)}, above requested {version_text(requested)}")
    reports, checked = [], set()
    for path in sorted(app.rglob("*")):
        if not path.is_file():
            continue
        resolved = path.resolve()
        if not resolved.is_relative_to(app.resolve()):
            raise CompatibilityError(f"Bundle file points outside the app: {path.relative_to(app)}")
        if resolved in checked:
            continue
        checked.add(resolved)
        try:
            slices = macho_slices(path)
        except CompatibilityError as error:
            raise CompatibilityError(f"{path.relative_to(app)}: {error}") from error
        if slices is None:
            continue
        if architecture and not any(item.architecture == architecture for item in slices):
            raise CompatibilityError(f"{path.relative_to(app)} is missing {architecture}")
        for item in slices:
            if item.minimum_os > declared:
                raise CompatibilityError(f"{path.relative_to(app)} ({item.architecture}) requires macOS "
                                         f"{version_text(item.minimum_os)}, above app minimum {version_text(declared)}")
        reports.append((path.relative_to(app), slices))
    executable = info.get("CFBundleExecutable")
    if not isinstance(executable, str) or "/" in executable or not executable:
        raise CompatibilityError("App is missing a valid CFBundleExecutable")
    executable_path = Path("Contents/MacOS") / executable
    if not any(path == executable_path for path, _ in reports):
        raise CompatibilityError("App executable is missing or is not Mach-O")
    return declared, reports


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--minimum-os", help="Oldest macOS version this release must support")
    parser.add_argument("--architecture", choices=sorted(set(CPU_NAMES.values())))
    arguments = parser.parse_args()
    try:
        minimum, reports = check_bundle(arguments.app, arguments.minimum_os, arguments.architecture)
        for path, slices in reports:
            print(f"{path}: " + ", ".join(f"{item.architecture} macOS {version_text(item.minimum_os)}" for item in slices))
        print(f"Verified {len(reports)} Mach-O files against macOS {version_text(minimum)}")
    except (CompatibilityError, OSError, plistlib.InvalidFileException) as error:
        print(f"macOS compatibility check failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
