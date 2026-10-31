#!/bin/bash
# Build the Facebook dep stack that Velox refuses to bundle, with gcc 15.2, into
# /data/velox-fdo/deps.
#
# Why this exists: VELOX_ENABLE_PARQUET pulls in FBThrift (the Parquet format is
# Thrift-based), and Velox requires fizz/wangle/FBThrift as SYSTEM CONFIG packages
# (see the explicit TODO at CMakeLists.txt:732). FBThrift links folly, so folly must
# be the SAME copy Velox uses -- two folly/gflags copies in one link would register
# duplicate flags and abort at startup. So folly comes from here too, and Velox runs
# with VELOX_DEPENDENCY_SOURCE=AUTO: it picks these up plus the apt packages, and
# bundles only leaf deps (arrow, protobuf, simdjson, xsimd, ...).
#
# These are built ONCE and shared by every arm: the per-arm FDO/LTO flags apply to
# Velox's own code. BOLT, which rewrites the final linked binary, still covers this
# dep code because it is statically linked in.
set -euo pipefail
source /etc/environment; export http_proxy https_proxy no_proxy
ROOT=/data/velox-fdo
GCC15=$ROOT/toolchain/gcc15
export PATH=$GCC15/bin:$PATH
export LD_LIBRARY_PATH=$GCC15/lib64:${LD_LIBRARY_PATH:-}
export CC=$GCC15/bin/gcc
export CXX=$GCC15/bin/g++
export INSTALL_PREFIX=$ROOT/deps
export DEPENDENCY_DIR=$ROOT/deps-src
export NPROC=${NPROC:-160}
export SUDO=""
export PROMPT_ALWAYS_RESPOND=n
export INSTALL_PREREQUISITES=N
mkdir -p "$INSTALL_PREFIX" "$DEPENDENCY_DIR"
cd "$ROOT/src/velox"
"$CXX" --version | head -1
# Order matters: fmt/fast_float/flatbuffers/openzl are folly deps; fizz/wangle/mvfst
# precede fbthrift.
for f in install_fmt install_fast_float install_flatbuffers install_openzl \
         install_folly install_fizz install_wangle install_mvfst install_fbthrift; do
  echo "=== $f ==="
  bash scripts/setup-ubuntu.sh "$f" || { echo "DEPS_FAILED at $f"; exit 1; }
done
echo "=== installed ==="
ls "$INSTALL_PREFIX/lib"/*.a 2>/dev/null | head -20
find "$INSTALL_PREFIX" -name "*onfig.cmake" | sed "s|$INSTALL_PREFIX/||" | head -20
echo "DEPS_BUILD_DONE"
