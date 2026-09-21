#!/usr/bin/env python3
"""Cross-platform Dart FFI <-> CLI transfers against an isolated Go server."""
import argparse
import hashlib
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import time
import urllib.request

ROOT = Path(__file__).resolve().parents[1]


def WaitFor(predicate, timeout=30):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = predicate()
        if result:
            return result
        time.sleep(0.1)
    raise TimeoutError('Timed out waiting for server or share code')


def Main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cli', required=True)
    parser.add_argument('--native', required=True)
    args = parser.parse_args()
    cli, native = str(Path(args.cli).resolve()), str(Path(args.native).resolve())
    processes, logs = [], []
    with tempfile.TemporaryDirectory(prefix='ct-desktop-e2e-') as temp:
        work = Path(temp)
        dart = shutil.which('dart')
        if os.name == 'nt' and os.environ.get('FLUTTER_ROOT'):
            dart = str(Path(os.environ['FLUTTER_ROOT']) / 'bin/cache/dart-sdk/bin/dart.exe')
        env = dict(os.environ, CT_NATIVE_LIB=native)

        def Start(name, command, extra=None):
            log = work / (name + '.log')
            handle = log.open('w', encoding='utf-8')
            logs.append((log, handle))
            process = subprocess.Popen(command, cwd=ROOT / 'app', env=extra or env,
                                       stdout=handle, stderr=subprocess.STDOUT)
            processes.append(process)
            return process, log

        try:
            server = work / ('ctserver.exe' if os.name == 'nt' else 'ctserver')
            subprocess.run(['go', 'build', '-o', str(server), './cmd/ctserver'],
                           cwd=ROOT / 'server', check=True)
            with socket.socket() as sock:
                sock.bind(('127.0.0.1', 0))
                port = sock.getsockname()[1]
            endpoint = f'127.0.0.1:{port}'
            server_env = dict(env, CT_LISTEN=endpoint, CT_PUBLIC_IP='127.0.0.1',
                              CT_TURN_SECRET='local-test-only', CT_LOG_LEVEL='error')
            Start('server', [str(server)], server_env)

            def Healthy():
                try:
                    with urllib.request.urlopen(f'http://{endpoint}/healthz', timeout=1) as response:
                        return response.status == 200
                except OSError:
                    return False

            WaitFor(Healthy)
            source = work / 'tree'
            (source / 'sub' / 'empty').mkdir(parents=True)
            for name, size in [('zero.bin', 0), ('tiny.bin', 19), ('one-block.bin', 1100),
                               ('sub/中文 文件.txt', 4096), ('sub/payload.bin', 3 * 1024 * 1024 + 321)]:
                (source / name).write_bytes(os.urandom(size))
            common = ['--server', endpoint, '--timeout', '120', '--log-level', 'warn']
            ffi = [dart, 'run', 'tool/ffi_smoke.dart']
            for direction in ('ffi-to-cli', 'cli-to-ffi'):
                dest = work / direction
                dest.mkdir()
                if direction == 'ffi-to-cli':
                    sender, log = Start(direction + '-send', ffi + ['share', str(source), '--server', endpoint])
                else:
                    sender, log = Start(direction + '-send', [cli, 'share', str(source),
                        '--data-dir', str(work / 'cli-send')] + common)

                def Code():
                    if sender.poll() is not None:
                        raise RuntimeError(f'Sender exited {sender.returncode}: {log.read_text(errors="replace")}')
                    for line in log.read_text(errors='replace').splitlines():
                        if line.startswith('CODE '):
                            return line.split()[1]
                    return None

                code = WaitFor(Code)
                if direction == 'ffi-to-cli':
                    receiver, _ = Start(direction + '-recv', [cli, 'receive', code, '--dir', str(dest),
                        '--data-dir', str(work / 'cli-recv')] + common)
                else:
                    receiver, _ = Start(direction + '-recv', ffi + ['receive', code, str(dest), '--server', endpoint])
                for process in (receiver, sender):
                    if process.wait(timeout=150) != 0:
                        raise RuntimeError(f'{direction} process exited {process.returncode}')
                for original in source.rglob('*'):
                    received = dest / 'tree' / original.relative_to(source)
                    if original.is_dir():
                        assert received.is_dir(), received
                    else:
                        assert hashlib.sha256(original.read_bytes()).digest() == hashlib.sha256(received.read_bytes()).digest(), received
                assert not list(dest.rglob('*.ctpart'))
                print(f'PASS: {direction}: all SHA-256 hashes, Unicode paths and empty directories', flush=True)
        except Exception:
            for log, handle in logs:
                handle.flush()
                print(f'{log.name}:\n{log.read_text(errors="replace")[-16000:]}')
            raise
        finally:
            for process in reversed(processes):
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()
            for _, handle in logs:
                handle.close()


if __name__ == '__main__':
    Main()
