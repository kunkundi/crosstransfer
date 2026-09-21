#!/usr/bin/env bash
# Builds and starts a local ctserver for development (foreground).
#   tools/start_server.sh [extra env assignments...]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
(cd "$ROOT/server" && go build -o /tmp/ctserver ./cmd/ctserver)
export CT_LISTEN="${CT_LISTEN:-127.0.0.1:8080}"
export CT_PUBLIC_IP="${CT_PUBLIC_IP:-127.0.0.1}"
export CT_TURN_SECRET="${CT_TURN_SECRET:-test}"
# This helper intentionally supports local loopback TURN development.
export CT_TURN_ALLOW_PRIVATE_PEERS="${CT_TURN_ALLOW_PRIVATE_PEERS:-true}"
export CT_LOG_LEVEL="${CT_LOG_LEVEL:-info}"
exec /tmp/ctserver "$@"
