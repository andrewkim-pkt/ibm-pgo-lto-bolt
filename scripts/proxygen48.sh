#!/bin/bash
# proxygen with samples OFF: its sample binaries fail to link because boost_context is
# absent from their link line (a proxygen samples issue -- libproxygen.a itself builds
# fine), and ninja stopping there means `install` never runs.
set -euo pipefail
source /data/velox-fdo/scripts/env48.sh
cd "$ROOT/deps-src/proxygen"
cmake -B _build2 -GNinja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER=/usr/bin/gcc-15 -DCMAKE_CXX_COMPILER=/usr/bin/g++-15 \
  -DCMAKE_CXX_FLAGS="-mavx2 -mfma -mavx -mf16c -mlzcnt -mbmi2 -O3 -DNDEBUG" \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DBUILD_TESTS=OFF -DBUILD_SAMPLES=OFF -DBUILD_SHARED_LIBS=OFF \
  -DCMAKE_INSTALL_PREFIX="$ROOT/deps" -DCMAKE_PREFIX_PATH="$ROOT/deps" \
  > "$LOGS/proxygen-cmake.log" 2>&1 || { tail -20 "$LOGS/proxygen-cmake.log"; exit 1; }
echo "configure OK"
ninja -C _build2 -j"$JOBS" install > "$LOGS/proxygen-build.log" 2>&1 \
  || { grep -m1 -A15 "FAILED:" "$LOGS/proxygen-build.log" | cut -c1-200; exit 1; }
find "$ROOT/deps" -name "libproxygen.a" | head -2
echo "PROXYGEN_OK"
