#!/usr/bin/env bash
# Resume check: kill the receiver mid-transfer (SIGKILL), start it again with
# the same data dir and take-code, and verify it resumes via resume_token
# without a second copy and with the file intact.
#
#   tools/run_cli_resume.sh [size_mb] [kill_after_sec] [extra ct_cli flags...]
set -euo pipefail

SIZE_MB="${1:-200}"
KILL_AFTER="${2:-2}"
shift 2 || true
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI="$(ls "$ROOT"/build/*/*/release/ct_cli 2>/dev/null | head -1)"
[ -n "$CLI" ] || { echo "ct_cli not built" >&2; exit 2; }
WORK="$(mktemp -d /tmp/ct_resume.XXXXXX)"
mkdir -p "$WORK/src" "$WORK/dst" "$WORK/data_a" "$WORK/data_b"
head -c $((SIZE_MB * 1024 * 1024)) /dev/urandom > "$WORK/src/big.bin"
COMMON=(--server 127.0.0.1:8080 --log-level warn --timeout 300 "$@")

"$CLI" share "$WORK/src/big.bin" --data-dir "$WORK/data_a" "${COMMON[@]}" \
  > "$WORK/share.out" 2> "$WORK/share.err" &
SHARE_PID=$!
CODE=""
for _ in $(seq 1 100); do
  CODE="$(grep -m1 '^CODE ' "$WORK/share.out" 2>/dev/null | awk '{print $2}' || true)"
  [ -n "$CODE" ] && break
  sleep 0.1
done
[ -n "$CODE" ] || { echo "no code" >&2; kill $SHARE_PID; exit 1; }
echo "[resume] code $CODE"

# First receiver: killed after KILL_AFTER seconds.
"$CLI" receive "$CODE" --dir "$WORK/dst" --data-dir "$WORK/data_b" --json "${COMMON[@]}" \
  > "$WORK/recv1.out" 2> "$WORK/recv1.err" &
RECV1=$!
sleep "$KILL_AFTER"
kill -9 "$RECV1" 2>/dev/null || true
wait "$RECV1" 2>/dev/null || true
LAST1="$(grep '"transfer_progress"' "$WORK/recv1.out" | tail -1 | sed -E 's/.*"bytes_done":([0-9]+).*/\1/')"
echo "[resume] killed receiver at ${LAST1:-0} bytes"
if [ -z "$LAST1" ] || [ "$LAST1" -eq 0 ]; then
  echo "receiver had not started transferring; increase kill_after" >&2
  kill $SHARE_PID; exit 1
fi
[ -f "$WORK/dst/big.bin.ctpart" ] || { echo "no .ctpart left behind" >&2; kill $SHARE_PID; exit 1; }
grep -q '"resume_token"' "$WORK/data_b/transfers.json" || { echo "no resume token persisted" >&2; kill $SHARE_PID; exit 1; }

# Second receiver: same data dir + code -> resume.
sleep 1
START=$(date +%s)
set +e
"$CLI" receive "$CODE" --dir "$WORK/dst" --data-dir "$WORK/data_b" --json "${COMMON[@]}" \
  > "$WORK/recv2.out" 2> "$WORK/recv2.err"
RC=$?
wait "$SHARE_PID"
SRC=$?
set -e
END=$(date +%s)
echo "[resume] second run rc=$RC share rc=$SRC in $((END - START))s"
if [ "$RC" -ne 0 ] || [ "$SRC" -ne 0 ]; then
  tail -20 "$WORK/recv2.err" >&2; tail -20 "$WORK/share.err" >&2; exit 1
fi
FIRST2="$(grep '"transfer_progress"' "$WORK/recv2.out" | head -1 | sed -E 's/.*"bytes_done":([0-9]+).*/\1/')"
echo "[resume] second run started at ${FIRST2:-0} bytes"
grep -q '"resumable":true' "$WORK/recv2.out" || { echo "second run did not use the resume token" >&2; exit 1; }
[ "${FIRST2:-0}" -gt 0 ] || { echo "second run did not resume from the bitmap" >&2; exit 1; }
[ "$(ls "$WORK/dst" | wc -l | tr -d ' ')" = "1" ] || { echo "unexpected extra files in dst" >&2; ls "$WORK/dst" >&2; exit 1; }
A=$(shasum -a 256 "$WORK/src/big.bin" | awk '{print $1}')
B=$(shasum -a 256 "$WORK/dst/big.bin" | awk '{print $1}')
[ "$A" = "$B" ] || { echo "hash mismatch" >&2; exit 1; }
echo "[resume] OK"
rm -rf "$WORK"
