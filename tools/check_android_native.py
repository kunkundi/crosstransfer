#!/usr/bin/env python3
"""Check Android FFI exports, page alignment and runtime dependencies."""
import argparse
import os
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def Main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('library', type=Path)
    parser.add_argument('--ndk', type=Path, default=os.environ.get('ANDROID_NDK_HOME'))
    args = parser.parse_args()
    if not args.ndk:
        parser.error('--ndk or ANDROID_NDK_HOME is required')
    bins = list((args.ndk / 'toolchains/llvm/prebuilt').glob('*/bin'))
    if len(bins) != 1:
        parser.error('Cannot identify NDK host tools')
    suffix = '.exe' if os.name == 'nt' else ''
    def Run(name, *flags):
        return subprocess.check_output([str(bins[0] / (name + suffix)), *flags, str(args.library)], text=True)
    symbols = Run('llvm-nm', '--dynamic', '--defined-only', '--extern-only')
    expected = set(re.findall(r'\b(Ct\w+)\s*\(', (ROOT / 'core/include/crosstransfer/ct_api.h').read_text()))
    exported = set(re.findall(r'\b(Ct\w+)\s*$', symbols, re.M))
    assert expected <= exported, f'Missing FFI symbols: {expected - exported}'
    headers = Run('llvm-readelf', '--program-headers', '--wide')
    alignments = [int(line.split()[-1], 16) for line in headers.splitlines() if line.strip().startswith('LOAD ')]
    assert alignments and all(v >= 16384 for v in alignments), f'Not 16 KB aligned: {alignments}'
    needed = re.findall(r'Shared library: \[(.*?)\]', Run('llvm-readelf', '--dynamic'))
    allowed = {'libc.so', 'libm.so', 'libdl.so', 'liblog.so', 'libandroid.so', 'libz.so'}
    assert set(needed) <= allowed, f'Unexpected dynamic dependency: {set(needed) - allowed}'
    print(f'PASS {args.library.parent.name}: {len(expected)} FFI exports, 16 KB alignment, system libraries only')


if __name__ == '__main__':
    Main()
