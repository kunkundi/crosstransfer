#!/usr/bin/env python3
"""Isolated WSS CLI transfer and wrong-host rejection (macOS/Linux).

The generated CA is trusted only by these child processes via SSL_CERT_FILE;
no system trust store or existing app configuration is changed.
"""
import argparse
import hashlib
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def Main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cli', required=True, type=Path)
    parser.add_argument('--openssl', default='openssl')
    args = parser.parse_args()
    if os.name == 'nt':
        parser.error('Windows uses its native trust store; run memory TLS core tests there')
    cli = str(args.cli.resolve())
    processes, handles = [], []
    with tempfile.TemporaryDirectory(prefix='ct-tls-e2e-') as tmp:
        work = Path(tmp)
        def Run(*command, **kwargs):
            return subprocess.run(command, cwd=work, check=True, capture_output=True, **kwargs)
        def Start(name, command, env):
            log = work / f'{name}.log'
            handle = log.open('w')
            handles.append(handle)
            process = subprocess.Popen(command, cwd=work, env=env, stdout=handle, stderr=subprocess.STDOUT)
            processes.append(process)
            return process, log
        def WaitFor(predicate, timeout=30):
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline:
                value = predicate()
                if value:
                    return value
                time.sleep(.1)
            raise TimeoutError('TLS E2E timed out')
        try:
            (work / 'root.cnf').write_text('[req]\ndistinguished_name=dn\nx509_extensions=ca\n[dn]\n[ca]\nbasicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign,cRLSign\n')
            Run(args.openssl, 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', 'root.key', '-out', 'root.pem', '-days', '1', '-subj', '/CN=CrossTransfer Ephemeral Test CA', '-config', 'root.cnf')
            for name, san in [('valid', 'IP:127.0.0.1'), ('wrong-host', 'DNS:wrong.test')]:
                Run(args.openssl, 'req', '-newkey', 'rsa:2048', '-nodes', '-keyout', name + '.key', '-out', name + '.csr', '-subj', '/CN=wrong.test')
                (work / (name + '.ext')).write_text(f'basicConstraints=critical,CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName={san}\n')
                Run(args.openssl, 'x509', '-req', '-in', name + '.csr', '-CA', 'root.pem', '-CAkey', 'root.key', '-CAcreateserial', '-out', name + '.pem', '-days', '1', '-extfile', name + '.ext')
            server = work / 'ctserver'
            subprocess.run(['go', 'build', '-o', str(server), './cmd/ctserver'], cwd=ROOT / 'server', check=True)
            source = work / '中文.bin'
            source.write_bytes(os.urandom(1024 * 1024 + 37))
            env = dict(os.environ, SSL_CERT_FILE=str(work / 'root.pem'))
            for name in ['valid', 'wrong-host']:
                with socket.socket() as sock:
                    sock.bind(('127.0.0.1', 0))
                    port = sock.getsockname()[1]
                endpoint = f'127.0.0.1:{port}'
                service, _ = Start(name + '-server', [str(server)], dict(env, CT_LISTEN=endpoint, CT_TURN_PORT='0', CT_PUBLIC_IP='127.0.0.1', CT_TURN_SECRET='tls-test-only', CT_LOG_LEVEL='error', CT_TLS_CERT=str(work / (name + '.pem')), CT_TLS_KEY=str(work / (name + '.key'))))
                def Listening():
                    if service.poll() is not None:
                        raise RuntimeError('Test TLS server exited')
                    try:
                        with socket.create_connection(('127.0.0.1', port), timeout=.5):
                            return True
                    except OSError:
                        return False
                WaitFor(Listening)
                flags = ['--server', endpoint, '--tls', '--relay', 'force', '--timeout', '30', '--log-level', 'warn']
                sender, log = Start(name + '-sender', [cli, 'share', str(source), '--data-dir', str(work / (name + '-state')), *flags], env)
                if name == 'wrong-host':
                    assert sender.wait(timeout=15) != 0, 'Wrong-host certificate was accepted'
                    text = log.read_text()
                    assert 'tls_error' in text and 'CODE ' not in text, text
                    print('PASS WSS wrong-host certificate rejected before share registration', flush=True)
                else:
                    def Code():
                        if sender.poll() is not None:
                            raise RuntimeError(log.read_text())
                        return next((line.split()[1] for line in log.read_text().splitlines() if line.startswith('CODE ')), None)
                    code = WaitFor(Code)
                    receiver, received_log = Start('receiver', [cli, 'receive', code, '--dir', str(work / 'received'), '--data-dir', str(work / 'receiver-state'), *flags], env)
                    assert receiver.wait(timeout=45) == 0, received_log.read_text()
                    assert sender.wait(timeout=15) == 0, log.read_text()
                    received = work / 'received' / source.name
                    assert hashlib.sha256(received.read_bytes()).digest() == hashlib.sha256(source.read_bytes()).digest()
                    print('PASS trusted WSS relay: 1 MiB+37 B Unicode file SHA-256 matched', flush=True)
                service.terminate()
                service.wait(timeout=5)
        except BaseException:
            for log in work.glob('*.log'):
                print(log.name, log.read_text(errors='replace')[-6000:])
            raise
        finally:
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


if __name__ == '__main__':
    Main()
