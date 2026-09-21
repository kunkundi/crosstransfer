#!/usr/bin/env python3
"""Install iOS Simulator app and verify cold/warm scheme transfers from ct_cli.

The simulator must already be booted. Uses an isolated test
Application Support, restoring any pre-existing directory after the run.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import socket
import subprocess
import tempfile
import time
import urllib.request

ROOT = Path(__file__).resolve().parents[1]


def Run(*args, **kwargs):
    return subprocess.run(args, check=True, text=True, **kwargs)


def WaitFor(predicate, timeout=90):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(.2)
    raise TimeoutError('iOS E2E timed out')


def Main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--device', default='booted')
    parser.add_argument('--app', default='app/build/ios/iphonesimulator/Runner.app')
    parser.add_argument('--cli', default='build/macosx/arm64/release/ct_cli')
    args = parser.parse_args()
    app = Path(args.app).resolve()
    bundle = plistlib.loads((app / 'Info.plist').read_bytes())['CFBundleIdentifier']
    cli = str(Path(args.cli).resolve())
    processes, handles = [], []
    data = backup = None
    data_created = False
    with tempfile.TemporaryDirectory(prefix='ct-ios-e2e-') as tmp:
        work = Path(tmp)
        def Start(name, command, env=None):
            path = work / f'{name}.log'
            handle = path.open('w')
            handles.append(handle)
            process = subprocess.Popen(command, stdout=handle, stderr=subprocess.STDOUT, env=env)
            processes.append(process)
            return process, path
        try:
            server = work / 'ctserver'
            Run('go', 'build', '-o', str(server), './cmd/ctserver', cwd=ROOT / 'server')
            with socket.socket() as sock:
                sock.bind(('127.0.0.1', 0))
                port = sock.getsockname()[1]
            endpoint = f'127.0.0.1:{port}'
            Start('server', [str(server)], dict(os.environ, CT_LISTEN=endpoint, CT_PUBLIC_IP='127.0.0.1', CT_TURN_PORT='0', CT_TURN_SECRET='local-ios-test', CT_LOG_LEVEL='error'))
            def Healthy():
                try:
                    return urllib.request.urlopen(f'http://{endpoint}/healthz', timeout=1).status == 200
                except OSError:
                    return False
            WaitFor(Healthy)
            Run('xcrun', 'simctl', 'install', args.device, str(app))
            container = Path(Run('xcrun', 'simctl', 'get_app_container', args.device, bundle, 'data', capture_output=True).stdout.strip())
            subprocess.run(['xcrun', 'simctl', 'terminate', args.device, bundle], capture_output=True)
            data = container / 'Library' / 'Application Support'
            backup = data.with_name('Application Support.before-' + work.name)
            if data.exists():
                data.rename(backup)
            data.mkdir(parents=True)
            data_created = True
            received = container / 'Documents' / ('Received-' + work.name)
            received.mkdir(parents=True)
            (data / 'config.json').write_text(json.dumps({'server': {'host': '127.0.0.1', 'port': port, 'tls': False}, 'save_dir': str(received), 'log_level': 'debug'}))
            for name in ['cold', 'warm']:
                source = work / name
                (source / '子目录' / 'empty').mkdir(parents=True)
                for filename, size in [('zero.bin', 0), ('tiny.bin', 19), ('子目录/中文.bin', 3 * 1024 * 1024 + 37)]:
                    (source / filename).write_bytes(os.urandom(size))
                sender, log = Start(name, [cli, 'share', str(source), '--server', endpoint, '--data-dir', str(work / (name + '-core')), '--timeout', '120', '--log-level', 'warn'])
                def Code():
                    if sender.poll() is not None:
                        raise RuntimeError(log.read_text())
                    return next((line.split()[1] for line in log.read_text().splitlines() if line.startswith('CODE ')), None)
                code = WaitFor(Code)
                # First link can arrive during startup; second targets the existing scene.
                Run('xcrun', 'simctl', 'openurl', args.device, f'crosstransfer://r/{code}')
                def Complete():
                    for file in source.rglob('*'):
                        target = received / name / file.relative_to(source)
                        if not target.exists():
                            return False
                        if file.is_file() and hashlib.sha256(file.read_bytes()).digest() != hashlib.sha256(target.read_bytes()).digest():
                            return False
                    return True
                WaitFor(Complete, timeout=120)
                if sender.wait(timeout=30) != 0:
                    raise RuntimeError(log.read_text())
                assert not list(received.rglob('*.ctpart'))
                print(f'PASS iOS {name} scheme receive: empty file/directory, Unicode, multi-block SHA-256')
            (ROOT / 'dist').mkdir(exist_ok=True)
            Run('xcrun', 'simctl', 'io', args.device, 'screenshot', str(ROOT / 'dist/ios-receive.png'))
            print(f'Received fixtures: {received}')
        except BaseException:
            if data_created:
                for log in data.rglob('*.log'):
                    print(log.name, log.read_text(errors='replace')[-8000:])
            for log in work.glob('*.log'):
                print(log.name, log.read_text(errors='replace')[-8000:])
            raise
        finally:
            subprocess.run(['xcrun', 'simctl', 'terminate', args.device, bundle], capture_output=True)
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
            if data is not None:
                if data_created and data.exists():
                    shutil.rmtree(data)
                if backup is not None and backup.exists() and not data.exists():
                    backup.rename(data)


if __name__ == '__main__':
    Main()
