#!/usr/bin/env python3
"""Verify all packaged Android ELF libraries and ZIP entries support 16 KB pages."""
import argparse
import os
from pathlib import Path
import re
import subprocess
import tempfile
import zipfile


def Main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('apk', type=Path)
    parser.add_argument('--abis', default='arm64-v8a,armeabi-v7a,x86_64')
    args = parser.parse_args()
    sdk = Path(os.environ.get('ANDROID_HOME', Path.home() / 'Library/Android/sdk'))
    ndk = Path(os.environ.get('ANDROID_NDK_HOME', sdk / 'ndk/28.2.13676358'))
    readelf = next((ndk / 'toolchains/llvm/prebuilt').glob('*/bin/llvm-readelf'))
    subprocess.run([str(sdk / 'build-tools/36.0.0/zipalign'), '-c', '-P', '16', '4', str(args.apk)], check=True)
    subprocess.run([str(sdk / 'build-tools/36.0.0/apksigner'), 'verify', str(args.apk)], check=True)
    expected = set(args.abis.split(','))
    found = set()
    count = 0
    with tempfile.TemporaryDirectory(prefix='ct-apk-check-') as tmp, zipfile.ZipFile(args.apk) as archive:
        for member in archive.infolist():
            if not re.fullmatch(r'lib/[^/]+/[^/]+\.so', member.filename):
                continue
            parts = member.filename.split('/')
            if parts[-1] == 'libcrosstransfer_native.so':
                found.add(parts[1])
            assert member.compress_type == zipfile.ZIP_STORED, f'Compressed native library: {member.filename}'
            file = Path(tmp) / 'library.so'
            file.write_bytes(archive.read(member))
            headers = subprocess.check_output([str(readelf), '--program-headers', '--wide', str(file)], text=True)
            alignments = [int(line.split()[-1], 16) for line in headers.splitlines() if line.strip().startswith('LOAD ')]
            # Android's 16 KB devices use 64-bit ABIs. Third-party ARMv7
            # binaries may retain 4 KB ELF segments; ZIP alignment still applies.
            page = 16384 if parts[1] in {'arm64-v8a', 'x86_64'} else 4096
            assert alignments and all(value >= page for value in alignments), f'{member.filename}: {alignments}'
            for line in headers.splitlines():
                if line.strip().startswith('GNU_RELRO '):
                    fields = line.split()
                    end = int(fields[2], 16) + int(fields[5], 16)
                    rounded = (end + page - 1) // page * page
                    # Some linkers leave unmapped padding after RELRO rather
                    # than include it in p_memsz (including Flutter's engine).
                    # Rounding protection must not cover live writable data.
                    for segment in headers.splitlines():
                        fields = segment.split()
                        if fields and fields[0] == 'LOAD' and 'W' in ''.join(fields[6:-1]):
                            start = int(fields[2], 16)
                            stop = start + int(fields[5], 16)
                            assert min(rounded, stop) <= max(end, start), f'RELRO overlaps writable data: {member.filename}'
            count += 1
    assert found == expected, f'Engine ABIs {found}, expected {expected}'
    print(f'PASS APK: {count} native libraries, {len(found)} engine ABIs, 16 KB 64-bit ELF/ZIP alignment, valid signature')


if __name__ == '__main__':
    Main()
