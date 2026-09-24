#!/usr/bin/env python3
"""Exercise admin HTTP -> WebSocket -> MiniRTC -> Ct events/query on a dev build.

Build ctserver and a developer crosstransfer_native library first, then run:
python3 tools/test_notifications.py --server server/ctserver \
  --library build/macosx/arm64/release/libcrosstransfer_native.dylib
No third-party Python dependencies; all state and credentials are temporary.
"""
import argparse
import ctypes
import json
import os
from pathlib import Path
import queue
import secrets
import socket
import subprocess
import tempfile
import time
import urllib.request


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--server', required=True)
    parser.add_argument('--library', required=True)
    args = parser.parse_args()
    with socket.socket() as listener:
        listener.bind(('127.0.0.1', 0))
        port = listener.getsockname()[1]
    token = secrets.token_hex(32)
    base = f'http://127.0.0.1:{port}'
    lib = ctypes.CDLL(str(Path(args.library).resolve()))
    ptr = ctypes.c_void_p
    callback_type = ctypes.CFUNCTYPE(None, ctypes.c_char_p, ptr)
    lib.CtCreate.argtypes, lib.CtCreate.restype = [ctypes.c_char_p], ptr
    lib.CtDestroy.argtypes = [ptr]
    lib.CtSetEventCallback.argtypes = [ptr, callback_type, ptr]
    lib.CtQuery.argtypes, lib.CtQuery.restype = [ptr, ctypes.c_char_p], ptr
    lib.CtFreeString.argtypes = [ptr]
    events = queue.Queue()
    callback = callback_type(lambda data, _: events.put(json.loads(data)))

    def query(core):
        raw = lib.CtQuery(core, b'{"what":"all"}')
        try:
            return json.loads(ctypes.string_at(raw))
        finally:
            lib.CtFreeString(raw)

    def wait_for(predicate):
        end = time.monotonic() + 15
        while time.monotonic() < end:
            if predicate():
                return
            time.sleep(.05)
        raise AssertionError('Timed out waiting for notification state')

    def request(method, suffix='', payload=None):
        data = None if payload is None else json.dumps(payload).encode()
        req = urllib.request.Request(base + '/admin/api/notifications' + suffix,
            data=data, method=method, headers={'Authorization': 'Bearer ' + token,
                                              'Content-Type': 'application/json'})
        with urllib.request.urlopen(req, timeout=5) as response:
            body = response.read()
            return json.loads(body) if body else None

    with tempfile.TemporaryDirectory(prefix='ct-notifications-e2e-') as tmp:
        env = {k: v for k, v in os.environ.items() if not k.startswith('CT_')}
        env.update(CT_LISTEN=f'127.0.0.1:{port}', CT_TURN_PORT='0',
                   CT_ADMIN_TOKEN=token, CT_NOTIFICATION_FILE=f'{tmp}/notices.json')
        core, process = None, None
        log = open(f'{tmp}/server.log', 'w')
        def start_server():
            process = subprocess.Popen([str(Path(args.server).resolve())], env=env,
                                       stdout=log, stderr=log)
            def healthy():
                if process.poll() is not None:
                    raise AssertionError('Server failed to start')
                try:
                    with urllib.request.urlopen(base + '/healthz', timeout=.2) as response:
                        return response.status == 200
                except OSError:
                    return False
            wait_for(healthy)
            return process
        def connect():
            core = lib.CtCreate(json.dumps({'data_dir':f'{tmp}/client',
                'server':{'host':'127.0.0.1','port':port,'tls':False},
                'turn_mode':'off','log_level':'error'}).encode())
            assert core, 'CtCreate failed (use a developer build)'
            lib.CtSetEventCallback(core, callback, None)
            return core
        try:
            process = start_server()
            core = connect()
            wait_for(lambda: query(core).get('notifications') == [])
            item = request('POST', payload={'title':'服务更新通知', 'body':'跨端测试\n第二行', 'level':'important'})
            wait_for(lambda: query(core).get('notifications', [{}])[0:1] == [item])
            received = []
            while not events.empty():
                received.append(events.get_nowait())
            assert any(event.get('type') == 'notifications' and event.get('items') == [item]
                       for event in received), 'No notification callback delivered'
            lib.CtDestroy(core); core = None
            process.terminate(); process.wait(timeout=10); process = None
            process = start_server()
            core = connect()
            wait_for(lambda: query(core).get('notifications') == [item])
            request('DELETE', '/' + item['id'])
            wait_for(lambda: query(core).get('notifications') == [])
            assert request('GET')['items'][0]['revoked_at'] > 0
            print('PASS: admin publish -> native callback/query, server restart, reconnect catch-up, revoke')
        finally:
            if core:
                lib.CtDestroy(core)
            if process:
                process.terminate(); process.wait(timeout=10)
            log.close()


if __name__ == '__main__':
    main()
