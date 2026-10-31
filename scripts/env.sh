#!/bin/bash
# Common environment for the Velox gcc15 FDO campaign (GNR box ushs-ap-gnr3).
ROOT=/data/velox-fdo
GCC15=$ROOT/toolchain/gcc15
VELOX_SRC=$ROOT/src/velox
DATA=${DATA:-$ROOT/tpch-sf100}
PROF=$ROOT/prof
LOGS=$ROOT/logs
RES=$ROOT/results
NPROC=$(nproc)                     # 192
JOBS=160

# / has ~16 GB free on this box (it is 99% full and shared), and gcc writes its temp
# .s files to TMPDIR -- a build of this size exhausts /tmp and fails with
# "error writing to /tmp/ccXXXX.s: No space left on device". Keep all scratch on /data.
export TMPDIR=$ROOT/tmp
mkdir -p "$TMPDIR"

export PATH=$GCC15/bin:$PATH
export LD_LIBRARY_PATH=$GCC15/lib64:${LD_LIBRARY_PATH:-}
export CC=$GCC15/bin/gcc
export CXX=$GCC15/bin/g++

# AutoFDO tooling: use the SOURCE-BUILT google/autofdo f95d1a1 (same commit the MariaDB
# gcc15 campaign used), NOT Ubuntu's autofdo 0.19 package -- 0.19 attributes zero
# functions here even on a 3-function test program. The source build takes
# --gcov_version=2 as a format selector for gcc 15.
CREATE_GCOV=${CREATE_GCOV:-$ROOT/toolchain/autofdo/build-gcov/create_gcov}
DUMP_GCOV=${DUMP_GCOV:-$ROOT/toolchain/autofdo/build-gcov/dump_gcov}
# glog otherwise writes 1.8 GB log files into /tmp (on the 99%-full shared root fs).
export GLOG_log_dir=$TMPDIR
source /etc/environment 2>/dev/null || true
export http_proxy https_proxy no_proxy

# Flags shared by every arm, so the only variable between arms is the FDO/LTO/BOLT layer.
#  -g            : required by AutoFDO (create_gcov needs line info) and helps BOLT; no codegen effect.
#  --emit-relocs : required by BOLT. Applied to ALL arms so the link is identical across arms.
#  -rpath        : the gcc15 libstdc++ must be found at runtime.
#  -include cstdint : duckdb 0.8.1 (pulled in by velox_exec_test_lib, which the TPC-H
#                     benchmark links) and other older bundled deps rely on <cstdint>
#                     arriving transitively, which libstdc++ 15 no longer does. C++ ONLY --
#                     cstdint is not a C header, so it must not reach CMAKE_C_FLAGS.
COMMON_C="-O3 -g"
COMMON_CXX="-O3 -g -include cstdint"
COMMON_LD="-Wl,--emit-relocs -Wl,-rpath,$GCC15/lib64"

# TPC-H benchmark work point. Velox's own tuning doc (velox/docs/develop/TpchBenchmark.rst):
#   num_drivers    = max(20, vCPU * 3/4)
#   num_io_threads = max(16, vCPU * 3/8)
#   cache_gb       = ~50% of RAM
#
# NODE=<n> pins everything -- profile collection, training AND measurement -- to one NUMA
# node, and scales the work point to that node's size. Round 1 ran whole-system across
# all 3 nodes, where the kernel re-rolls thread/memory placement on every process start;
# base beat ITSELF by up to 2.16% (A/A test), which swamped every arm delta. Pinning also
# makes this comparable to the MariaDB/MySQL gcc15 rounds, which trained on node 1.
#
# --preferred, not --membind: membind OOM-killed on this CPU family (see the MariaDB round).
NODE=${NODE:-}
if [ -n "$NODE" ]; then
  NODE_CPUS=$(numactl -H | sed -n "s/^node $NODE cpus: //p" | tr -s ' ' ',' | sed 's/^,//;s/,$//')
  NODE_NCPU=$(echo "$NODE_CPUS" | tr ',' '\n' | grep -c .)
  NODE_MB=$(numactl -H | sed -n "s/^node $NODE size: \([0-9]*\) MB/\1/p")
  NUMA="numactl --physcpubind=$NODE_CPUS --preferred=$NODE"
  : "${WL_DRIVERS:=$(( NODE_NCPU * 3 / 4 ))}"
  : "${WL_IO_THREADS:=$(( NODE_NCPU * 3 / 8 ))}"
  : "${WL_CACHE_GB:=$(( NODE_MB / 1024 / 2 ))}"
  export WL_DRIVERS WL_IO_THREADS WL_CACHE_GB
else
  NUMA=""
fi

# cmake flags common to all arms. TREAT_WARNINGS_AS_ERRORS=0 is mandatory: Velox targets
# gcc 11-13 and gcc 15.2 raises new warnings that would otherwise fail the build.
velox_cmake_common() {
  echo "-DCMAKE_BUILD_TYPE=Release \
 -DCMAKE_C_COMPILER=$CC -DCMAKE_CXX_COMPILER=$CXX \
 -DTREAT_WARNINGS_AS_ERRORS=0 -DENABLE_ALL_WARNINGS=0 \
 -DVELOX_BUILD_TESTING=OFF -DVELOX_ENABLE_BENCHMARKS=ON -DVELOX_BUILD_RUNNER=OFF \
 -DVELOX_DEPENDENCY_SOURCE=AUTO -DVELOX_ENABLE_PARQUET=ON \
 -DCMAKE_PREFIX_PATH=$ROOT/deps"
}
