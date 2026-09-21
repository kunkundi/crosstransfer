#!/usr/bin/env python3
"""Reproduce/verify the bundled MPL source from pinned upstream + local patch.

Use --upstream /path/to/libjuice-v1.7.2.tar.gz to work offline, or download the
fixed public source archive. --write updates the bundle after a reviewed patch.
The default only checks it. Requires git (also available on Windows CI).
"""
import argparse
import gzip
import hashlib
import io
from pathlib import Path
import subprocess
import tarfile
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
UPSTREAM_URL = "https://github.com/paullouisageneau/libjuice/archive/refs/tags/v1.7.2.tar.gz"
UPSTREAM_SHA256 = "75159867c4a5a689a6559e11aa0d30c9eba12ce73a4ae3d898b521467e1f635d"
PREFIX = "libjuice-1.7.2"
BUNDLE = ROOT / "app/assets/legal/libjuice-1.7.2-ct1.tar.gz"
PATCH = ROOT / "minirtc/thirdparty/libjuice/relay-only.patch"
CHANGES = """CrossTransfer libjuice 1.7.2 + ct1 (2026-09-22)
Copyright (c) 2026 DI JUNKUN

The modifications in include/juice/juice.h and src/agent.c add and retain an
optional relay_only configuration flag. When enabled, candidate pairing rejects
all non-relayed local candidates, including implicit peer-reflexive direct paths.
Default behavior is unchanged. The exact patch is CROSSTRANSFER-RELAY-ONLY.patch.

This complete corresponding source, including these modifications, is provided
under the Mozilla Public License 2.0; see LICENSE. CrossTransfer's proprietary
license places no additional restriction on your rights to this covered source.

Upstream: https://github.com/paullouisageneau/libjuice/tree/v1.7.2
Build: CMake >=3.21 <4; -DNO_TESTS=ON -DUSE_NETTLE=OFF
       -DBUILD_SHARED_LIBS=OFF -DCMAKE_BUILD_TYPE=Release
Then cmake --build and cmake --install. Cross-platform toolchains are selected
by xmake 3.1.0; no additional libjuice source transformations are performed.
"""


def Main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--upstream", type=Path)
    parser.add_argument("--write", action="store_true")
    args = parser.parse_args()
    if args.upstream:
        upstream = args.upstream.read_bytes()
    else:
        with urllib.request.urlopen(UPSTREAM_URL, timeout=60) as response:
            upstream = response.read()
    assert hashlib.sha256(upstream).hexdigest() == UPSTREAM_SHA256, "upstream hash mismatch"
    recipe = (PATCH.parent / "xmake.lua").read_text()
    patch_hash = hashlib.sha256(PATCH.read_bytes()).hexdigest()
    assert UPSTREAM_SHA256 in recipe and patch_hash in recipe, "recipe hashes are stale"
    with tempfile.TemporaryDirectory(prefix="ct-mpl-source-") as directory:
        work = Path(directory)
        # Only materialize regular files from the exact pinned archive; reject
        # links and unsafe member names even if an upstream release changes.
        modes = {}
        with tarfile.open(fileobj=io.BytesIO(upstream), mode="r:gz") as archive:
            for member in archive.getmembers():
                path = Path(member.name)
                assert path.parts[0] == PREFIX and ".." not in path.parts and not path.is_absolute()
                if member.isdir():
                    continue
                assert member.isfile(), f"unexpected member type: {member.name}"
                target = work / path
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(archive.extractfile(member).read())
                modes[member.name] = member.mode
        source = work / PREFIX
        subprocess.run(["git", "apply", "--check", str(PATCH)], cwd=source, check=True)
        subprocess.run(["git", "apply", str(PATCH)], cwd=source, check=True)
        (source / "CROSSTRANSFER-CHANGES.txt").write_bytes(CHANGES.encode("utf-8"))
        (source / "CROSSTRANSFER-RELAY-ONLY.patch").write_bytes(PATCH.read_bytes())
        buffer = io.BytesIO()
        with gzip.GzipFile(fileobj=buffer, mode="wb", mtime=0, filename="") as compressed:
            with tarfile.open(fileobj=compressed, mode="w", format=tarfile.GNU_FORMAT) as archive:
                for path in sorted(source.rglob("*")):
                    if not path.is_file():
                        continue
                    name = path.relative_to(work).as_posix()
                    data = path.read_bytes()
                    member = tarfile.TarInfo(name)
                    member.mode = modes.get(name, 0o644)
                    member.size = len(data)
                    archive.addfile(member, io.BytesIO(data))
        result = buffer.getvalue()
        if args.write:
            BUNDLE.write_bytes(result)
        # Compare every member rather than gzip bytes: zlib versions may differ
        # across build hosts without changing the corresponding covered source.
        def Contents(data):
            with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as archive:
                return {m.name: (m.mode, archive.extractfile(m).read())
                        for m in archive.getmembers() if m.isfile()}
        bundled, expected = Contents(BUNDLE.read_bytes()), Contents(result)
        changed = sorted(name for name in bundled.keys() | expected.keys()
                         if bundled.get(name) != expected.get(name))
        assert not changed, f"bundled source differs from recipe: {changed}"
        license_text = (source / "LICENSE").read_bytes()
        for path in [ROOT / "docs/licenses/libjuice.txt", ROOT / "app/assets/legal/libjuice.txt"]:
            assert path.read_bytes() == license_text, f"license mismatch: {path}"
        bundle_hash = hashlib.sha256(BUNDLE.read_bytes()).hexdigest()
        if not args.write:
            assert bundle_hash in (ROOT / "THIRD_PARTY_NOTICES.md").read_text(), "notice hash is stale"
        print(f"PASS: exact upstream + patch = complete bundled MPL source; SHA-256 {bundle_hash}")


if __name__ == "__main__":
    Main()
