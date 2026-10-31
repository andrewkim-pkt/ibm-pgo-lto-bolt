#!/bin/bash
# Environment for the Prestissimo FDO campaign on the GNR lab box (ushs-ap-gnr3,
# root@10.54.112.122). Replaces env48.sh after the 48xl was lost.
#
# Differences from the AWS boxes, all of which bit somewhere:
#  * gcc 15.2.0 is BOOTSTRAPPED at /data/velox-fdo/toolchain/gcc15, not from apt, so every
#    link needs -Wl,-rpath,$GCC15/lib64 or the binaries will not find libstdc++.
#  * Ubuntu 24.04 with cmake 3.28, NOT 26.04/cmake 4.x -> CMAKE_POLICY_VERSION_MINIMUM=3.5
#    is unnecessary here (it was needed for both the deps and the autofdo/glog build on AWS).
#  * apt Boost is 1.83: < 1.87, HAS boost/asio/io_service.hpp, and exports Boost.Context
#    UNMANGLED (T make_fcontext / T jump_fcontext). So it satisfies Presto directly and the
#    whole "build Boost 1.84 and purge apt Boost" dance is NOT needed -- that was an artifact
#    of Ubuntu 26.04 shipping Boost 1.90. Do NOT remove apt Boost here: it is a SHARED box.
#  * create_gcov is ALREADY built at /data/velox-fdo/toolchain/autofdo, and llvm-bolt /
#    perf2bolt are on PATH, and perf_event_paranoid is already 0.
#  * RAM is 755 GB across 3 nodes = 251 GB/node, HALF the 48xl's 503 GB/node, so the worker
#    memory budgets are halved. Copying the 48xl's 440/360 would over-commit the box.
ROOT=/data/prestissimo-fdo
GCC15=/data/velox-fdo/toolchain/gcc15
PRESTO=$ROOT/src/presto/presto-native-execution
VELOX=$PRESTO/velox
PROF=$ROOT/prof
LOGS=$ROOT/logs
RES=$ROOT/results
DATA=${DATA:-$ROOT/tpcds-sf1000}
JOBS=${JOBS:-160}

export TMPDIR=$ROOT/tmp
mkdir -p "$TMPDIR" "$LOGS" "$RES" "$PROF"
export CC=$GCC15/bin/gcc
export CXX=$GCC15/bin/g++
export LD_LIBRARY_PATH=$GCC15/lib64:${LD_LIBRARY_PATH:-}
export GLOG_log_dir=$TMPDIR
CREATE_GCOV=${CREATE_GCOV:-/data/velox-fdo/toolchain/autofdo/build-gcov/create_gcov}
DUMP_GCOV=${DUMP_GCOV:-/data/velox-fdo/toolchain/autofdo/build-gcov/dump_gcov}

# Shared by every arm, so the only variable is the FDO/LTO/BOLT layer.
COMMON_C="-O3 -g"
COMMON_CXX="-O3 -g -include cstdint"
COMMON_LD="-Wl,--emit-relocs -Wl,-rpath,$GCC15/lib64"
PGO_USE="-fprofile-use -fprofile-correction -Wno-missing-profile -Wno-error=coverage-mismatch"

# Jantz's topology: one worker container pinned per SNC node, 4 concurrent query streams.
# This box is 3 nodes x 64 cpus, the same shape as the lost 48xl.
NODE_CPUS() { numactl -H | sed -n "s/^node $1 cpus: //p" | tr -s ' ' ',' | sed 's/^,//;s/,$//'; }
NUM_NODES=$(numactl -H | sed -n 's/^available: \([0-9]*\) nodes.*/\1/p')

# Halved vs the 48xl because this box has half the RAM per node.
WORKER_SYS_GB=${WORKER_SYS_GB:-210}
WORKER_QUERY_GB=${WORKER_QUERY_GB:-170}
CLUSTER_MAX_GB=${CLUSTER_MAX_GB:-350}

# This box is on the Intel internal network: outbound HTTP needs the proxy. ssh sessions get
# these via PAM/\/etc\/environment, but detached jobs are safer with them set explicitly.
export http_proxy=${http_proxy:-http://proxy-dmz.intel.com:911}
export https_proxy=${https_proxy:-http://proxy-dmz.intel.com:912}
export no_proxy=${no_proxy:-localhost,127.0.0.1,10.0.0.0/8,.intel.com}
