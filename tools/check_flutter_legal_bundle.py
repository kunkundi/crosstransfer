#!/usr/bin/env python3
"""Check an unpacked Flutter asset directory carries all reviewed legal assets."""
import argparse
import gzip
from pathlib import Path


def Main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("flutter_assets", type=Path)
    args = parser.parse_args()
    source = Path(__file__).resolve().parents[1] / "app/assets/legal"
    files = [path for path in source.iterdir() if path.is_file()]
    for path in files:
        assert (args.flutter_assets / "assets/legal" / path.name).read_bytes() == path.read_bytes(), \
            f"missing/stale bundled legal asset: {path.name}"
    notices = args.flutter_assets / "NOTICES.Z"
    text = gzip.decompress(notices.read_bytes()) if notices.exists() else (args.flutter_assets / "NOTICES").read_bytes()
    assert b"Flutter" in text and b"Redistribution and use" in text, "Flutter/engine notices missing"
    print(f"PASS: Flutter notices and {len(files)} exact supplemental legal/source assets")


if __name__ == "__main__":
    Main()
