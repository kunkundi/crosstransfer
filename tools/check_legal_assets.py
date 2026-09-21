#!/usr/bin/env python3
"""Offline release gate for reviewed dependency inputs and bundled notices."""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def Hash(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def Main():
    licenses = ROOT / "docs/licenses"
    assets = ROOT / "app/assets/legal"
    manifest_path = licenses / "native_manifest.json"
    assert manifest_path.read_bytes() == (assets / manifest_path.name).read_bytes(), "license manifest not bundled"
    manifest = json.loads(manifest_path.read_text())
    for component in manifest["components"]:
        name = component["asset"]
        assert Path(name).name == name, "license asset must be a basename"
        assert Hash(licenses / name) == component["license_sha256"], f"notice hash changed: {name}"
        assert (assets / name).read_bytes() == (licenses / name).read_bytes(), f"notice not bundled: {name}"
        if "source_archive" in component:
            assert Hash(assets / component["source_archive"]) == component["source_sha256"], "MPL source changed"
    inputs = json.loads((licenses / "dependency_inputs.json").read_text())
    for name, checksum in inputs["sha256"].items():
        assert Hash(ROOT / name) == checksum, f"dependency input changed: {name}; review and refresh license evidence"
    print(f"PASS: {len(manifest['components'])} supplemental notice entries and {len(inputs['sha256'])} dependency inputs match")


if __name__ == "__main__":
    Main()
