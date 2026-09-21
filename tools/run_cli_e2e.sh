#!/usr/bin/env bash
# End-to-end check: ct_cli share / receive through a local ctserver.
#
#   tools/run_cli_e2e.sh [name] [extra ct_cli flags...]
#
# Expects a ctserver on 127.0.0.1:8080 (start one with tools/start_server.sh)
# and a built ct_cli (xmake build ct_cli). Creates a temp tree with mixed
# files, shares it, receives it into another temp dir and compares hashes.
# Exit code 0 on success. Set CT_E2E_BIG_MB to add a large random file.
set -euo pipefail

NAME="${1:-p2p}"
shift || true
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI="$(ls "$ROOT"/build/*/*/release/ct_cli 2>/dev/null | head -1)"
if [ -z "$CLI" ]; then
  echo "ct_cli not built (xmake build ct_cli)" >&2
  exit 2
fi
WORK="$(mktemp -d /tmp/ct_e2e_${NAME}.XXXXXX)"
SRC="$WORK/src"
DST="$WORK/dst"
mkdir -p "$SRC/tree/sub/empty_dir" "$DST" "$WORK/data_a" "$WORK/data_b"

# Test tree: empty file, < 1 block, exactly 1 block, multi-block, nested,
# non-ASCII names, name collision candidate.
: > "$SRC/tree/zero.bin"
head -c 100 /dev/urandom > "$SRC/tree/tiny.bin"
head -c 1100 /dev/urandom > "$SRC/tree/one_block.bin"
head -c $((3 * 1024 * 1024 + 321)) /dev/urandom > "$SRC/tree/sub/medium.bin"
head -c 4096 /dev/urandom > "$SRC/tree/中文 文件名.txt"
head -c 777 /dev/urandom > "$SRC/single.dat"
if [ -n "${CT_E2E_BIG_MB:-}" ]; then
  head -c $((CT_E2E_BIG_MB * 1024 * 1024)) /dev/urandom > "$SRC/tree/big.bin"
fi

COMMON=(--server 127.0.0.1:8080 --log-level warn --timeout 300 "$@")

echo "[$NAME] work dir $WORK"
"$CLI" share "$SRC/tree" "$SRC/single.dat" --data-dir "$WORK/data_a" "${COMMON[@]}" \
  > "$WORK/share.out" 2> "$WORK/share.err" &
SHARE_PID=$!

CODE=""
for _ in $(seq 1 100); do
  CODE="$(grep -m1 '^CODE ' "$WORK/share.out" 2>/dev/null | awk '{print $2}' || true)"
  [ -n "$CODE" ] && break
  if ! kill -0 "$SHARE_PID" 2>/dev/null; then
    echo "share process exited early" >&2
    cat "$WORK/share.err" >&2
    exit 1
  fi
  sleep 0.1
done
if [ -z "$CODE" ]; then
  echo "no take-code from share" >&2
  kill "$SHARE_PID" 2>/dev/null || true
  cat "$WORK/share.err" >&2
  exit 1
fi
echo "[$NAME] code $CODE"

START=$(date +%s)
set +e
"$CLI" receive "$CODE" --dir "$DST" --data-dir "$WORK/data_b" "${COMMON[@]}" \
  > "$WORK/recv.out" 2> "$WORK/recv.err"
RECV_RC=$?
wait "$SHARE_PID"
SHARE_RC=$?
set -e
END=$(date +%s)
echo "[$NAME] receive rc=$RECV_RC share rc=$SHARE_RC in $((END - START))s"
if [ "$RECV_RC" -ne 0 ] || [ "$SHARE_RC" -ne 0 ]; then
  echo "--- share.err ---" >&2; tail -30 "$WORK/share.err" >&2
  echo "--- recv.err ---" >&2; tail -30 "$WORK/recv.err" >&2
  exit 1
fi

# Compare every file by hash and make sure no .ctpart is left behind.
FAIL=0
while IFS= read -r -d '' f; do
  rel="${f#$SRC/}"
  if [ ! -f "$DST/$rel" ]; then
    echo "missing: $rel" >&2
    FAIL=1
    continue
  fi
  a="$(shasum -a 256 "$f" | awk '{print $1}')"
  b="$(shasum -a 256 "$DST/$rel" | awk '{print $1}')"
  if [ "$a" != "$b" ]; then
    echo "mismatch: $rel" >&2
    FAIL=1
  fi
done < <(find "$SRC" -type f -print0)
[ -d "$DST/tree/sub/empty_dir" ] || { echo "missing empty dir" >&2; FAIL=1; }
if find "$DST" -name '*.ctpart' | grep -q .; then
  echo "leftover .ctpart files" >&2
  FAIL=1
fi
if [ "$FAIL" -ne 0 ]; then
  exit 1
fi
BYTES=$(find "$SRC" -type f -print0 | xargs -0 stat -f %z | awk '{s+=$1} END {print s}')
echo "[$NAME] OK: $BYTES bytes verified"
rm -rf "$WORK"
