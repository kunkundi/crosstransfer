#!/usr/bin/env bash
# Repeats tools/run_cli_e2e.sh until it fails (or N runs pass), keeping the
# work dir of the failing run for inspection.
#   tools/repeat_e2e.sh [runs] [name] [extra flags...]
set -uo pipefail
RUNS="${1:-20}"
NAME="${2:-rep}"
shift 2 || true
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
for i in $(seq 1 "$RUNS"); do
  OUT="$("$ROOT/tools/run_cli_e2e.sh" "$NAME$i" "$@" 2>&1)"
  if echo "$OUT" | grep -q "OK:"; then
    echo "run $i ok"
  else
    echo "run $i FAILED"
    echo "$OUT" | grep -v "^\s*[0-9.]*%" | tail -40
    exit 1
  fi
done
echo "all $RUNS runs passed"
