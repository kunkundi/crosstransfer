#!/usr/bin/env bash
# Open-mode check: one share, two receivers claiming concurrently, both must
# complete with intact files. Also receives twice into the same directory to
# exercise "name (1)" de-duplication.
#
#   tools/run_cli_open.sh [extra ct_cli flags...]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI="$(ls "$ROOT"/build/*/*/release/ct_cli 2>/dev/null | head -1)"
[ -n "$CLI" ] || { echo "ct_cli not built" >&2; exit 2; }
WORK="$(mktemp -d /tmp/ct_open.XXXXXX)"
mkdir -p "$WORK/src/dir" "$WORK/dst" "$WORK/data_a" "$WORK/data_b" "$WORK/data_c"
head -c $((20 * 1024 * 1024)) /dev/urandom > "$WORK/src/dir/a.bin"
head -c 5000 /dev/urandom > "$WORK/src/dir/b.bin"
COMMON=(--server 127.0.0.1:8080 --log-level warn --timeout 300 "$@")

"$CLI" share "$WORK/src/dir" --mode open --wait 2 --data-dir "$WORK/data_a" "${COMMON[@]}" \
  > "$WORK/share.out" 2> "$WORK/share.err" &
SHARE_PID=$!
CODE=""
for _ in $(seq 1 100); do
  CODE="$(grep -m1 '^CODE ' "$WORK/share.out" 2>/dev/null | awk '{print $2}' || true)"
  [ -n "$CODE" ] && break
  sleep 0.1
done
[ -n "$CODE" ] || { echo "no code" >&2; kill $SHARE_PID; exit 1; }
echo "[open] code $CODE"

"$CLI" receive "$CODE" --dir "$WORK/dst" --data-dir "$WORK/data_b" "${COMMON[@]}" \
  > "$WORK/recv1.out" 2> "$WORK/recv1.err" &
R1=$!
"$CLI" receive "$CODE" --dir "$WORK/dst" --data-dir "$WORK/data_c" "${COMMON[@]}" \
  > "$WORK/recv2.out" 2> "$WORK/recv2.err" &
R2=$!
set +e
wait $R1; RC1=$?
wait $R2; RC2=$?
wait $SHARE_PID; RCS=$?
set -e
echo "[open] receivers rc=$RC1/$RC2 share rc=$RCS"
if [ $RC1 -ne 0 ] || [ $RC2 -ne 0 ] || [ $RCS -ne 0 ]; then
  tail -15 "$WORK/recv1.err" "$WORK/recv2.err" "$WORK/share.err" >&2; exit 1
fi
ls "$WORK/dst"
[ -d "$WORK/dst/dir" ] && [ -d "$WORK/dst/dir (1)" ] || { echo "expected dir and 'dir (1)'" >&2; exit 1; }
A=$(shasum -a 256 "$WORK/src/dir/a.bin" | awk '{print $1}')
for d in "dir" "dir (1)"; do
  B=$(shasum -a 256 "$WORK/dst/$d/a.bin" | awk '{print $1}')
  [ "$A" = "$B" ] || { echo "hash mismatch in $d" >&2; exit 1; }
  cmp -s "$WORK/src/dir/b.bin" "$WORK/dst/$d/b.bin" || { echo "b.bin mismatch in $d" >&2; exit 1; }
done
echo "[open] OK"
rm -rf "$WORK"
