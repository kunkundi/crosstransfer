#!/usr/bin/env python3
"""Verify ctserver's embedded notices against its declared Go modules.

All direct/indirect go.mod requirements are included (including platform-specific
ones); modules present only for dependency tests in go.sum are not shipped.
--write regenerates the files for review, never approves a license policy change.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
SERVER = ROOT / "server"


def Go(*args):
    return subprocess.check_output(["go", *args], cwd=SERVER, text=True)


def Main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--write", action="store_true")
    args = parser.parse_args()
    requirements = json.loads(Go("mod", "edit", "-json"))["Require"]
    sections, components = [], []
    for item in sorted(requirements, key=lambda value: value["Path"]):
        name, version = item["Path"], item["Version"]
        download = json.loads(Go("mod", "download", "-json", f"{name}@{version}"))
        directory = Path(download["Dir"])
        files = sorted(path for path in directory.iterdir() if path.is_file() and
                       path.name.upper().startswith(("LICENSE", "COPYING", "NOTICE", "PATENTS")))
        assert any(path.name.upper().startswith(("LICENSE", "COPYING")) for path in files), name
        sections.append(f"{name} {version}\nSource: https://pkg.go.dev/{name}@{version}\n")
        license_files = []
        for path in files:
            data = path.read_bytes()
            sections.append(path.name + "\n\n" + data.decode("utf-8").strip() + "\n")
            license_files.append(dict(path=path.name, sha256=hashlib.sha256(data).hexdigest()))
        components.append(dict(name=name, version=version, sum=download["Sum"],
                               source=f"https://pkg.go.dev/{name}@{version}", license_files=license_files))
    goroot = Path(Go("env", "GOROOT").strip())
    # Homebrew keeps LICENSE one level above libexec/GOROOT.
    runtime_license = next(path for path in [goroot / "LICENSE", goroot.parent / "LICENSE"] if path.is_file()).read_bytes()
    sections.append("Go standard library and runtime\nSource: https://go.dev/\n\n" + runtime_license.decode().strip() + "\n")
    contents = ("ctserver third-party copyright and license notices\n"
                "CrossTransfer is proprietary; the following terms apply to the respective components.\n\n" +
                ("\n" + "=" * 72 + "\n\n").join(sections)).encode()
    manifest = dict(schema_version=1, components=components,
                    go_runtime_license_sha256=hashlib.sha256(runtime_license).hexdigest(),
                    notices_sha256=hashlib.sha256(contents).hexdigest())
    manifest_bytes = (json.dumps(manifest, indent=2) + "\n").encode()
    for path, data in [(SERVER / "internal/legal/NOTICE.txt", contents),
                       (ROOT / "docs/licenses/go_manifest.json", manifest_bytes)]:
        if args.write:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        else:
            assert path.read_bytes() == data, f"stale notices: {path}; regenerate and review"
    print(f"PASS: {len(components)} locked Go modules and runtime license match embedded notices")


if __name__ == "__main__":
    Main()
