#!/usr/bin/env bash
# Runtime FFI, P2P/relay and reconnect tests on a booted simulator, without system UI input.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEVICE="${1:?Pass the booted simulator UDID}"
cd "$ROOT"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ct-ios-native-tests.XXXXXX")"
SERVER_PID=''
Cleanup() {
  if [ -n "$SERVER_PID" ]; then kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; fi
  rm -rf "$WORK"
}
trap Cleanup EXIT
(cd server && go build -o "$WORK/ctserver" ./cmd/ctserver)
CT_LISTEN=127.0.0.1:19090 CT_TURN_PORT=0 CT_PUBLIC_IP=127.0.0.1 \
  CT_TURN_SECRET=ios-test-only CT_LOG_LEVEL=error "$WORK/ctserver" > "$WORK/server.log" 2>&1 &
SERVER_PID=$!
python3 - "$SERVER_PID" <<'PY'
import os, sys, time, urllib.request
for _ in range(50):
    os.kill(int(sys.argv[1]), 0)
    try:
        with urllib.request.urlopen('http://127.0.0.1:19090/healthz', timeout=1) as response:
            if response.status == 200:
                break
    except OSError:
        time.sleep(.1)
else:
    raise SystemExit('Test server failed to start on port 19090')
PY
mkdir -p "$ROOT/dist"
RESULT="$ROOT/dist/ios-native-$(date +%Y%m%d-%H%M%S).xcresult"
xcodebuild -workspace app/ios/Runner.xcworkspace -scheme Runner \
  -configuration Debug -sdk iphonesimulator -destination "id=$DEVICE" \
  -parallel-testing-enabled NO -only-testing:RunnerTests \
  -resultBundlePath "$RESULT" test
