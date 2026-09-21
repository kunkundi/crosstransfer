#!/usr/bin/env python3
"""Check the final iOS app exposes every Ct* symbol required by Dart FFI."""
import argparse
from pathlib import Path
import plistlib
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def Main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    args = parser.parse_args()
    subprocess.run([sys.executable, str(ROOT / 'tools/check_flutter_legal_bundle.py'),
                    str(args.app / 'Frameworks/App.framework/flutter_assets')], check=True)
    info = plistlib.loads((args.app / 'Info.plist').read_bytes())
    binary = args.app / info['CFBundleExecutable']
    names = set(re.findall(r'\b(Ct\w+)\s*\(', (ROOT / 'core/include/crosstransfer/ct_api.h').read_text()))
    # Debug runners may move native code into Runner.debug.dylib.
    binaries = [binary, *args.app.glob('*.debug.dylib')]
    symbols = '\n'.join(subprocess.check_output(['xcrun', 'nm', '-gU', str(file)], text=True) for file in binaries)
    exported = set(re.findall(r'\b_(Ct\w+)\s*$', symbols, re.M))
    missing = names - exported
    if missing:
        raise SystemExit('Missing iOS FFI symbols: ' + ', '.join(sorted(missing)))
    extension = args.app / 'PlugIns/ShareExtension.appex'
    assert extension.is_dir(), 'ShareExtension missing from app'
    extension_info = plistlib.loads((extension / 'Info.plist').read_bytes())
    assert extension_info['CFBundleIdentifier'] == info['CFBundleIdentifier'] + '.ShareExtension'
    assert extension_info['CTAppGroup'] == info['CTAppGroup']
    print(f'PASS {len(names)} public FFI symbols, embedded extension, matching App Group')


if __name__ == '__main__':
    Main()
