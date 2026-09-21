#!/bin/bash
# Repeats the P2P echo until a side fails to reach CONNECTED within 4 s, then
# samples both processes' stacks (macOS `sample`) into /tmp/e2e/hang/.
MODE="${MODE:-release}"
B="$(cd "$(dirname "$0")/.." && pwd)/build/macosx/arm64/${MODE}/data_echo"
for run in $(seq 1 ${RUNS:-15}); do
  D=/tmp/e2e/hang; rm -rf "$D"; mkdir -p "$D/s" "$D/r"
  (cd "$D/s" && exec "$B" share --seconds 3 "$@" > share.out 2>&1) &
  SPID=$!
  CODE=""
  for i in $(seq 1 40); do sleep 0.25; CODE=$(grep -m1 "^CODE" "$D/s/share.out" 2>/dev/null | awk '{print $2}'); [ -n "$CODE" ] && break; done
  [ -z "$CODE" ] && { kill $SPID; continue; }
  (cd "$D/r" && exec "$B" receive --code "$CODE" --seconds 3 "$@" > recv.out 2>&1) &
  RPID=$!
  sleep 8
  if ! grep -q CONNECTED "$D/s/share.out" || ! grep -q CONNECTED "$D/r/recv.out"; then
    echo "HANG on run $run (sender=$SPID receiver=$RPID)"
    grep -q CONNECTED "$D/s/share.out" || /usr/bin/sample $SPID 1 -file "$D/sender.sample" >/dev/null 2>&1
    grep -q CONNECTED "$D/r/recv.out" || /usr/bin/sample $RPID 1 -file "$D/receiver.sample" >/dev/null 2>&1
    kill $SPID $RPID 2>/dev/null; wait 2>/dev/null
    exit 0
  fi
  kill $SPID $RPID 2>/dev/null; wait 2>/dev/null
  echo "run $run ok"
done
echo "no hang in ${RUNS:-15} runs"
