#!/bin/bash
# Builds minirtc for Linux inside Ubuntu 24.04:
#   docker run --rm -v "$PWD/minirtc":/src -v "$PWD/tools/linux_build_minirtc.sh":/build.sh -v /tmp/linux-out:/out ubuntu:24.04 bash /build.sh
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null
apt-get install -y -qq curl git build-essential cmake ninja-build perl pkg-config ca-certificates unzip >/dev/null
curl -fsSL https://xmake.io/shget.text | bash >/dev/null 2>&1
source ~/.xmake/profile
export XMAKE_ROOT=y
cd /src
xmake f -p linux -m release -y -o /out 2>&1 | tail -5
xmake build -y 2>&1 | grep -E "error|warning: |build ok" | head -30
ls -la /out/linux/*/release/
