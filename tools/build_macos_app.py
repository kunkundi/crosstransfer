#!/usr/bin/env python3
"""Build macOS release with an isolated, version-checked Flutter 3.47.5 fix.

Upstream issue: https://github.com/flutter/flutter/issues/191575
Retain the six internal macOS FFI classes so the AOT snapshot writer cannot
reference a class whose ID has been discarded. No windowing feature is enabled.
The installed SDK is never modified. APFS copy-on-write keeps the clone small.
Remove this workaround and its CI entry once an upstream fixed SDK is validated.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
REVISION = "6a19cca56475dbfba1478ee68d7bd0c2ef891da1"
SOURCE = "packages/flutter/lib/src/widgets/_window_macos.dart"
SOURCE_SHA = "ca2a09633a4c7c0af25ddbabcf148f4c6096e813e29cda3cd306f9c7f484b2e2"


def Main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--flutter-sdk", type=Path)
    args = parser.parse_args()
    sdk = (args.flutter_sdk or Path(shutil.which("flutter")).resolve().parents[1]).resolve()
    version = json.loads((sdk / "bin/cache/flutter.version.json").read_text())
    assert version["frameworkVersion"] == "3.47.5" and version["frameworkRevision"] == REVISION, \
        "SDK changed; validate upstream fix before updating this workaround"
    original = (sdk / SOURCE).read_bytes()
    assert hashlib.sha256(original).hexdigest() == SOURCE_SHA, "installed Flutter source differs from reviewed version"
    patched, count = re.subn(r"(?m)^(final class _\w+ extends (?:Struct|Opaque) \{)",
                             "@pragma('vm:entry-point')\n\\1", original.decode())
    assert count == 6
    clone = ROOT / "build/flutter-sdk-macos-3.47.5"
    assert sdk != clone, "Pass the original installed Flutter SDK"
    if not clone.exists():
        clone.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(["cp", "-cR", str(sdk), str(clone)], check=True)
    assert json.loads((clone / "bin/cache/flutter.version.json").read_text()) == version, "stale SDK clone"
    current = (clone / SOURCE).read_bytes()
    assert current in (original, patched.encode()), "unexpected modifications in owned SDK clone"
    (clone / SOURCE).write_text(patched)
    flutter = str(clone / "bin/flutter")
    app = ROOT / "app"
    try:
        # build alone can reuse a package_config pointing to the original SDK.
        subprocess.run([flutter, "pub", "get", "--enforce-lockfile"], cwd=app, check=True)
        config = json.loads((app / ".dart_tool/package_config.json").read_text())
        resolved = next(item for item in config["packages"] if item["name"] == "flutter")
        assert resolved["rootUri"] == (clone / "packages/flutter").as_uri(), resolved
        subprocess.run([flutter, "build", "macos", "--release"], cwd=app, check=True)
    finally:
        # Subsequent Android/iOS/Dart commands use the original SDK again.
        subprocess.run([str(sdk / "bin/flutter"), "pub", "get", "--enforce-lockfile"], cwd=app, check=True)
        assert (sdk / SOURCE).read_bytes() == original, "installed SDK was unexpectedly modified"


if __name__ == "__main__":
    Main()
