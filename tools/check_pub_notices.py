#!/usr/bin/env python3
"""Verify pub license evidence and bundled MPL source after flutter pub get.

The declared main dependency closure includes platform alternatives and some
build/test helpers. It is deliberately broader than tree-shaken runtime code.
Flutter's generated NOTICES remains the source of the shipped Dart notices.
--write refreshes the evidence for review; it does not approve new licenses.
"""
import argparse
import difflib
import hashlib
import json
from pathlib import Path
import re
import subprocess
import shutil
import sys
import tarfile
import urllib.parse

ROOT = Path(__file__).resolve().parents[1]


def Hash(data):
    return hashlib.sha256(data).hexdigest()


def Main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--write", action="store_true")
    args = parser.parse_args()
    config_path = ROOT / "app/.dart_tool/package_config.json"
    roots = {item["name"]: Path(urllib.parse.unquote(urllib.parse.urlparse(
        urllib.parse.urljoin(config_path.as_uri(), item["rootUri"])).path))
        for item in json.loads(config_path.read_text())["packages"]}
    # file:///C:/... is represented as /C:/... by urlparse on Windows.
    import os
    if os.name == "nt":
        roots = {name: Path(str(path).lstrip("\\/")) for name, path in roots.items()}
    sdk = roots["flutter"].parents[1]
    version = json.loads((sdk / "bin/cache/flutter.version.json").read_text())
    deps = json.loads(subprocess.check_output(
        [shutil.which("dart") or "dart", "pub", "deps", "--json"], cwd=ROOT / "app", text=True))
    packages = {item["name"]: item for item in deps["packages"]}
    pending = list(packages[deps["root"]]["directDependencies"])
    closure = set()
    while pending:
        name = pending.pop()
        if name not in closure:
            closure.add(name)
            pending.extend(packages[name]["dependencies"])
    lock = (ROOT / "app/pubspec.lock").read_text()
    entries = []
    for name in sorted(closure):
        package = packages[name]
        license_file = roots[name] / "LICENSE"
        if not license_file.exists() and package["source"] == "sdk":
            license_file = sdk / "LICENSE"
        assert license_file.is_file(), f"missing license for {name}"
        hosted = package["source"] == "hosted"
        source_url = (f"https://pub.dev/packages/{name}/versions/{package['version']}" if hosted
                      else f"https://github.com/flutter/flutter/tree/{version['frameworkRevision']}")
        license_bytes = license_file.read_bytes()
        license_text = license_bytes.decode("utf-8")
        if name == "sky_engine":
            license_id = "Composite Flutter engine notices; see exact bundled text and docs/LICENSE_AUDIT.md"
        elif "Mozilla Public License Version 2.0" in license_text:
            license_id = "MPL-2.0"
        elif "Apache License" in license_text and "Version 2.0" in license_text:
            license_id = "Apache-2.0"
        elif "Permission is hereby granted, free of charge" in license_text:
            license_id = "MIT"
        elif "Redistribution and use in source and binary forms" in license_text and "Neither the name" in license_text:
            license_id = "BSD-3-Clause"
        elif name == "timezone" and "Redistribution and use in source and binary forms" in license_text:
            license_id = "BSD-2-Clause"
        else:
            raise AssertionError(f"unreviewed license form: {name}")
        entry = dict(name=name, version=package["version"], source=package["source"], license=license_id,
                     license_sha256=Hash(license_bytes), source_url=source_url,
                     delivery="Flutter generated NOTICES / LicenseRegistry")
        if package["source"] == "sdk" and license_id == "BSD-3-Clause":
            # Official Windows Flutter SDK archives use CRLF for these BSD
            # notices. Record both exact reviewed forms, without changing the
            # source files or normalizing other dependencies' license evidence.
            lf = license_bytes.replace(b"\r\n", b"\n")
            crlf = lf.replace(b"\n", b"\r\n")
            assert license_bytes in (lf, crlf), f"mixed license line endings: {name}"
            entry["license_sha256"] = Hash(lf)
            entry["license_sha256_windows_crlf"] = Hash(crlf)
        if hosted:
            block = re.search(r"^  " + re.escape(name) + r":\n(.*?)(?=^  \w+:|\Z)", lock, re.M | re.S).group(1)
            entry["archive_sha256"] = re.search(r"sha256: [\"]?([a-f0-9]{64})", block).group(1)
        if name in ("dbus", "gtk"):
            archive_name = f"{name}-{package['version']}.tar.gz"
            archive = ROOT / "app/assets/legal" / archive_name
            assert Hash(archive.read_bytes()) == entry["archive_sha256"], f"incorrect MPL source: {archive_name}"
            with tarfile.open(archive) as source:
                assert source.extractfile("LICENSE").read() == license_file.read_bytes()
                # Verify the code actually resolved by pub is this exact source.
                for member in source.getmembers():
                    if member.isfile() and (member.name.startswith("lib/") or member.name == "pubspec.yaml"):
                        assert source.extractfile(member).read() == (roots[name] / member.name).read_bytes(), member.name
            entry["source_archive"] = archive_name
        entries.append(entry)
    result = dict(schema_version=1, flutter=version["frameworkVersion"],
                  framework_revision=version["frameworkRevision"], engine_revision=version["engineRevision"],
                  scope="Declared main dependency closure; includes platform alternatives and build/test helpers, not a list of executed code.",
                  declared_main_dependency_closure=entries)
    path = ROOT / "docs/licenses/pub_manifest.json"
    data = (json.dumps(result, indent=2) + "\n").encode()
    if args.write:
        path.write_bytes(data)
    else:
        expected = path.read_bytes()
        if expected != data:
            sys.stderr.writelines(difflib.unified_diff(
                expected.decode("utf-8").splitlines(keepends=True),
                data.decode("utf-8").splitlines(keepends=True),
                fromfile="reviewed pub manifest", tofile="resolved pub manifest"))
            raise AssertionError("pub/SDK license evidence changed; review before --write")
    print(f"PASS: {len(entries)} pub/SDK license entries and exact dbus/gtk MPL sources")


if __name__ == "__main__":
    Main()
