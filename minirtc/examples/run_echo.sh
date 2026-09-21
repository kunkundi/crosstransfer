#!/bin/bash
# Runs data_echo share + receive against a local ctserver.
# usage: run_echo.sh <label> [extra data_echo args...]
set -u
MODE="${MODE:-release}"
B="$(cd "$(dirname "$0")/.." && pwd)/build/macosx/arm64/${MODE}/data_echo"
LABEL="$1"; shift
D=/tmp/e2e/$LABEL
rm -rf "$D"; mkdir -p "$D/s" "$D/r"
(cd "$D/s" && "$B" share --seconds 4 "$@" > share.out 2>&1; echo "rc=$?" >> share.out) &
SPID=$!
CODE=""
for i in $(seq 1 60); do
  sleep 0.25
  CODE=$(grep -m1 "^CODE" "$D/s/share.out" 2>/dev/null | awk '{print $2}')
  [ -n "$CODE" ] && break
done
if [ -z "$CODE" ]; then echo "no code"; kill $SPID 2>/dev/null; exit 1; fi
(cd "$D/r" && "$B" receive --code "$CODE" --seconds 4 "$@" > recv.out 2>&1; echo "rc=$?" >> recv.out) &
RPID=$!
# watchdog
for i in $(seq 1 120); do
  sleep 0.5
  kill -0 $SPID 2>/dev/null || kill -0 $RPID 2>/dev/null || break
done
kill $SPID $RPID 2>/dev/null
wait 2>/dev/null
echo "===== $LABEL RECEIVER ====="; grep -vE "^\[stats\]|^\[20" "$D/r/recv.out" | tail -12
echo "----- receiver stats (last 3)"; grep -E "^\[stats\]" "$D/r/recv.out" | tail -3
echo "===== $LABEL SENDER ====="; grep -vE "^\[stats\]|^\[20" "$D/s/share.out" | tail -12
echo "----- sender stats (last 3)"; grep -E "^\[stats\]" "$D/s/share.out" | tail -3
echo "----- warnings/errors"; grep -hE "\[(warning|error)\]" "$D"/*/logs/*.log | sort | uniq -c | sort -rn | head -10
