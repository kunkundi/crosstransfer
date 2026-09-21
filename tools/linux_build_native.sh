#!/bin/bash
# Builds the crosstransfer_native shared library for Linux inside Ubuntu 24.04
# and drops it in /out (mounted from the host). Run from the repo root:
#
#   docker run --rm -v "$PWD":/src -v /tmp/ct-linux-out:/out ubuntu:24.04 \
#       bash /src/tools/linux_build_native.sh
#
# Then: cp /tmp/ct-linux-out/linux/<arch>/release/libcrosstransfer_native.so app/linux/native/
#
# Copyright (c) 2026 DI JUNKUN. All Rights Reserved. Proprietary.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null
apt-get install -y -qq curl git build-essential cmake ninja-build perl pkg-config \
    ca-certificates unzip >/dev/null
if ! command -v xmake >/dev/null; then
  curl -fsSL https://xmake.io/shget.text | bash >/dev/null 2>&1
fi
source ~/.xmake/profile
export XMAKE_ROOT=y
# Work on a copy so the host tree stays clean (.xmake / build are per-platform).
rm -rf /tmp/src && mkdir -p /tmp/src
cp -r /src/xmake.lua /src/core /src/cli /src/minirtc /tmp/src/
cd /tmp/src
xmake f -p linux -m release --ct_native=y --ct_tests=n --minirtc_examples=n -y -o /out
xmake build -y crosstransfer_native
ls -la /out/linux/*/release/libcrosstransfer_native.so
