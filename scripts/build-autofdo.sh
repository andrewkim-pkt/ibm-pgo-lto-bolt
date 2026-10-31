#!/bin/bash
# Build create_gcov from google/autofdo f95d1a1 -- the SAME tool and commit the MariaDB
# gcc15 campaign used (mariaDB-pgo-lto-bolt/gcc15).
#
# Why not Ubuntu's autofdo 0.19 package: it is a different, older tool. Its
# --gcov_version takes gcc's PACKED gcov version (default 875575082 = gcc 4.7) rather
# than a format selector, and even given the right value (B52* = 1110782506) it
# attributes ZERO functions here -- verified down to a 3-function test program, so it is
# not a Velox or DWARF-version problem. It also spams 1.8 GB glog files into /tmp
# (53 GB, which filled the shared root filesystem). Upstream f95d1a1 takes
# --gcov_version=2 for gcc 15 and produces real profiles.
set -euo pipefail
source /etc/environment; export http_proxy https_proxy no_proxy
ROOT=/data/velox-fdo
SRC=$ROOT/toolchain/autofdo
mkdir -p "$ROOT/toolchain"
if [ ! -d "$SRC" ]; then
  git clone --recursive https://github.com/google/autofdo.git "$SRC"
fi
cd "$SRC"
git checkout f95d1a1 2>/dev/null || git checkout -q f95d1a1
git submodule update --init --recursive
# The unnamed-symbol guard: stock f95d1a1 CHECK-fails on debug info that has a sample
# location with an empty function name instead of skipping it.
if ! git diff --quiet symbol_map.h 2>/dev/null; then
  echo "patch already applied"
else
  patch -p1 --forward < "$ROOT/scripts/autofdo-f95d1a1-unnamed-symbol.patch" || echo "patch may already be applied"
fi
rm -rf build-gcov && mkdir -p build-gcov && cd build-gcov
cmake -G Ninja -DENABLE_TOOL=GCOV -DCMAKE_BUILD_TYPE=Release .. > "$ROOT/logs/autofdo-cmake.log" 2>&1 \
  || { tail -30 "$ROOT/logs/autofdo-cmake.log"; exit 1; }
ninja create_gcov dump_gcov 2>&1 | tail -15
ls -la create_gcov dump_gcov
echo "AUTOFDO_BUILD_DONE"
