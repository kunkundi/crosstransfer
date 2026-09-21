#!/usr/bin/env python3
"""Enforce the Linux system-only, dynamic GTK/GLib license exception."""
import argparse
from pathlib import Path
import re
import subprocess


def Main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bundle", type=Path)
    args = parser.parse_args()
    # gobject/gio/gmodule/gthread are part of GLib; GDK is part of GTK.
    system_library = re.compile(r"lib(?:gtk|gdk|glib|gobject|gio|gmodule|gthread)[-.].*\.(?:so(?:\..*)?|a)$")
    for path in args.bundle.rglob("*"):
        assert not system_library.fullmatch(path.name), f"system GTK/GLib must not be bundled: {path}"
    executable = args.bundle / "crosstransfer"
    dynamic = subprocess.check_output(["readelf", "-d", str(executable)], text=True)
    assert re.search(r"\(NEEDED\).*\[libgtk-3\.so\.0\]", dynamic), "runner must dynamically link system GTK"
    resolved = subprocess.check_output(["ldd", str(executable.resolve())], text=True)
    for line in resolved.splitlines():
        fields = line.split()
        if fields and system_library.fullmatch(fields[0]):
            assert len(fields) >= 3 and fields[1] == "=>" and fields[2].startswith("/"), line
            location = Path(fields[2]).resolve()
            assert location.is_file() and not location.is_relative_to(args.bundle.resolve()), line
    print("PASS: GTK/GLib are dynamic system dependencies and absent from the bundle")


if __name__ == "__main__":
    Main()
