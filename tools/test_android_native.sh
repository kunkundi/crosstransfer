#!/usr/bin/env bash
# Runtime Dart FFI transfers on an emulator/device with an isolated host server.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEVICE="${1:?Pass an adb device serial}"
SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
ADB="$SDK/platform-tools/adb"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ct-android-tests.XXXXXX")"
SERVER_PID=''
REVERSED=false
Cleanup() {
  if $REVERSED; then "$ADB" -s "$DEVICE" reverse --remove tcp:19090 || true; fi
  if [ -n "$SERVER_PID" ]; then kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; fi
  rm -rf "$WORK"
}
trap Cleanup EXIT
if "$ADB" -s "$DEVICE" reverse --list | rg -q 'tcp:19090 '; then
  echo 'Device already has a reverse mapping on port 19090; choose another test device.' >&2
  exit 1
fi
PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
(cd "$ROOT/server" && go build -o "$WORK/ctserver" ./cmd/ctserver)
CT_LISTEN="127.0.0.1:$PORT" CT_TURN_PORT=0 CT_PUBLIC_IP=127.0.0.1 \
  CT_TURN_SECRET=android-test-only CT_LOG_LEVEL=error "$WORK/ctserver" > "$WORK/server.log" 2>&1 &
SERVER_PID=$!
python3 - "$SERVER_PID" "$PORT" <<'PY'
import os, sys, time, urllib.request
for _ in range(50):
    os.kill(int(sys.argv[1]), 0)
    try:
        with urllib.request.urlopen(f'http://127.0.0.1:{sys.argv[2]}/healthz', timeout=1) as r:
            if r.status == 200: break
    except OSError:
        time.sleep(.1)
else:
    raise SystemExit('Test server failed to start')
PY
"$ADB" -s "$DEVICE" reverse tcp:19090 "tcp:$PORT"
REVERSED=true
cd "$ROOT/app"
flutter test integration_test/mobile_transfer_test.dart -d "$DEVICE"
