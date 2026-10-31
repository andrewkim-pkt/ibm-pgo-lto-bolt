#!/bin/bash
# Build gcc 15.2.0 -> /data/velox-fdo/toolchain/gcc15
# Source: github mirror (ftp.gnu.org is TLS-MITM'd by the Intel proxy and unverifiable).
# Prerequisites: Ubuntu system gmp/mpfr/mpc/isl (contrib/download_prerequisites also hits gcc.gnu.org).
set -euo pipefail
source /etc/environment
export http_proxy https_proxy no_proxy
ROOT=/data/velox-fdo
PREFIX=$ROOT/toolchain/gcc15
SRC=$ROOT/toolchain/src
TAG=releases/gcc-15.2.0
mkdir -p "$SRC" "$PREFIX"
cd "$SRC"
if [ ! -d gcc-15.2.0 ]; then
  echo "== cloning $TAG =="
  git clone --depth 1 --branch "$TAG" https://github.com/gcc-mirror/gcc.git gcc-15.2.0
fi
cd gcc-15.2.0
git log -1 --format='gcc source: %H %ci' | tee "$ROOT/results/gcc15-pin.txt"
cat gcc/BASE-VER | tee -a "$ROOT/results/gcc15-pin.txt"
rm -rf ../build-gcc && mkdir -p ../build-gcc && cd ../build-gcc
echo "== configure =="
../gcc-15.2.0/configure --prefix="$PREFIX" \
  --enable-languages=c,c++ --disable-multilib --enable-lto \
  --enable-plugin --with-linker-hash-style=gnu --enable-__cxa_atexit \
  --disable-werror --with-system-zlib
echo "== make -j160 (bootstrap) =="
make -j160
echo "== install =="
make install
"$PREFIX/bin/g++" --version
"$PREFIX/bin/g++" -v 2>&1 | tail -1
echo "GCC15_BUILD_DONE"
