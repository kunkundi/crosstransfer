#!/usr/bin/env python3
"""Verify Android cold/warm links, foreground service and background receive.

Requires an installed debuggable APK and ct_cli. App files are backed up and
restored; only this run's Received directory and adb reverse mapping are removed.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import socket
import subprocess
import tempfile
import time
import urllib.request

ROOT = Path(__file__).resolve().parents[1]


def WaitFor(predicate, timeout=120):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(.2)
    raise TimeoutError('Android E2E timed out')


def Main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--device', required=True)
    parser.add_argument('--package', default='com.crosstransfer.crosstransfer')
    parser.add_argument('--cli', default='build/macosx/arm64/release/ct_cli')
    args = parser.parse_args()
    sdk = Path(os.environ.get('ANDROID_HOME', Path.home() / 'Library/Android/sdk'))
    adb = [str(sdk / 'platform-tools/adb'), '-s', args.device]
    def Adb(*command, **kwargs):
        return subprocess.run([*adb, *command], check=True, capture_output=True, **kwargs)
    def App(*command, **kwargs):
        # adb shell joins arguments itself; quote each so filenames remain literal.
        return Adb('shell', shlex.join(['run-as', args.package, *command]), **kwargs)
    def Shell(*command):
        return Adb('shell', shlex.join(command)).stdout.decode().strip()
    if b'tcp:19090 ' in Adb('reverse', '--list').stdout:
        raise RuntimeError('Device port 19090 already has a reverse mapping')
    app_dir = App('pwd').stdout.decode().strip()  # Also ensures APK is debuggable.
    processes, handles = [], []
    backup = received = None
    prepared = reversed_port = False
    with tempfile.TemporaryDirectory(prefix='ct-android-e2e-') as tmp:
        work = Path(tmp)
        def Start(name, command, env=None):
            log = work / f'{name}.log'
            handle = log.open('w')
            handles.append(handle)
            process = subprocess.Popen(command, stdout=handle, stderr=subprocess.STDOUT, env=env)
            processes.append(process)
            return process, log
        try:
            server = work / 'ctserver'
            subprocess.run(['go', 'build', '-o', str(server), './cmd/ctserver'], cwd=ROOT / 'server', check=True)
            with socket.socket() as sock:
                sock.bind(('127.0.0.1', 0))
                port = sock.getsockname()[1]
            endpoint = f'127.0.0.1:{port}'
            Start('server', [str(server)], dict(os.environ, CT_LISTEN=endpoint, CT_TURN_PORT='0', CT_PUBLIC_IP='127.0.0.1', CT_TURN_SECRET='android-e2e-only', CT_LOG_LEVEL='error'))
            def Healthy():
                try:
                    with urllib.request.urlopen(f'http://{endpoint}/healthz', timeout=1) as response:
                        return response.status == 200
                except OSError:
                    return False
            WaitFor(Healthy)
            Adb('reverse', 'tcp:19090', f'tcp:{port}')
            reversed_port = True
            Shell('am', 'force-stop', args.package)
            backup = 'files.before-' + work.name
            App('sh', '-c', f'if [ -d files ]; then mv files {shlex.quote(backup)}; fi')
            prepared = True
            received = 'app_flutter/Received-' + work.name
            App('mkdir', '-p', 'files', received)
            config = {'server': {'host': '127.0.0.1', 'port': 19090, 'tls': False}, 'save_dir': f'{app_dir}/{received}', 'log_level': 'debug'}
            App('sh', '-c', 'cat > files/config.json', input=json.dumps(config).encode())
            for name in ['cold', 'warm']:
                source = work / name
                (source / '子目录' / 'empty').mkdir(parents=True)
                for filename, size in [('zero.bin', 0), ('tiny.bin', 19), ('子目录/中文.bin', 8 * 1024 * 1024 + 37)]:
                    (source / filename).write_bytes(os.urandom(size))
                sender, log = Start(name, [str(Path(args.cli).resolve()), 'share', str(source), '--server', endpoint, '--data-dir', str(work / (name + '-core')), '--timeout', '120', '--log-level', 'warn'])
                def Code():
                    if sender.poll() is not None:
                        raise RuntimeError(log.read_text())
                    return next((line.split()[1] for line in log.read_text().splitlines() if line.startswith('CODE ')), None)
                code = WaitFor(Code)
                Shell('am', 'start', '-W', '-a', 'android.intent.action.VIEW', '-d', f'crosstransfer://r/{code}', '-p', args.package)
                def ServiceActive():
                    return 'isForeground=true' in Shell('dumpsys', 'activity', 'services', args.package)
                WaitFor(ServiceActive, timeout=30)
                if name == 'warm':
                    Shell('input', 'keyevent', 'KEYCODE_HOME')
                    assert ServiceActive(), 'Foreground service stopped when Activity left foreground'
                def Complete():
                    if sender.poll() is not None and sender.returncode != 0:
                        raise RuntimeError(log.read_text())
                    for file in source.rglob('*'):
                        target = f'{received}/{name}/{file.relative_to(source)}'
                        if file.is_dir():
                            try:
                                App('test', '-d', target)
                            except subprocess.CalledProcessError:
                                return False
                        else:
                            expected = hashlib.sha256(file.read_bytes()).hexdigest()
                            try:
                                actual = App('sha256sum', target).stdout.decode().split()[0]
                            except subprocess.CalledProcessError:
                                return False
                            if actual != expected:
                                return False
                    return True
                WaitFor(Complete)
                assert sender.wait(timeout=30) == 0, log.read_text()
                WaitFor(lambda: not ServiceActive(), timeout=15)
                print(f'PASS Android {name} scheme receive: Unicode, empty file/directory, 8 MiB SHA-256, foreground service lifecycle', flush=True)
            activity = Shell('cmd', 'package', 'resolve-activity', '--brief', '-a', 'android.intent.action.MAIN', '-c', 'android.intent.category.LAUNCHER', args.package).splitlines()[-1]
            Shell('am', 'start', '-W', '-n', activity)
            (ROOT / 'dist').mkdir(exist_ok=True)
            (ROOT / 'dist/android-receive.png').write_bytes(Adb('exec-out', 'screencap', '-p').stdout)
        except BaseException:
            for log in work.glob('*.log'):
                print(log.name, log.read_text(errors='replace')[-8000:])
            print(Adb('logcat', '-d', '-t', '300').stdout.decode(errors='replace'))
            raise
        finally:
            Shell('am', 'force-stop', args.package)
            for process in reversed(processes):
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()
            for handle in handles:
                handle.close()
            if reversed_port:
                Adb('reverse', '--remove', 'tcp:19090')
            if prepared:
                App('rm', '-rf', 'files')
                if received:
                    App('rm', '-rf', received)
                App('sh', '-c', f'if [ -d {shlex.quote(backup)} ]; then mv {shlex.quote(backup)} files; fi')


if __name__ == '__main__':
    Main()
