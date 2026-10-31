#!/bin/bash
# Environment for the Prestissimo (Presto native) FDO campaign on r8i.metal-48xl.
# Differences from the GNR lab box: gcc 15.2.0 comes from apt (no bootstrap, no custom
# prefix, so no -rpath needed), there is no Intel proxy, and the target is presto_server
# rather than velox_tpch_benchmark.
ROOT=/data/velox-fdo
PRESTO=$ROOT/src/presto/presto-native-execution
VELOX=$PRESTO/velox
PROF=$ROOT/prof
LOGS=$ROOT/logs
RES=$ROOT/results
DATA=${DATA:-$ROOT/tpcds-sf1000}
JOBS=${JOBS:-160}

export TMPDIR=$ROOT/tmp
mkdir -p "$TMPDIR"
export CC=/usr/bin/gcc-15
export CXX=/usr/bin/g++-15
export GLOG_log_dir=$TMPDIR
CREATE_GCOV=${CREATE_GCOV:-$ROOT/toolchain/autofdo/build-gcov/create_gcov}
DUMP_GCOV=${DUMP_GCOV:-$ROOT/toolchain/autofdo/build-gcov/dump_gcov}

# Shared by every arm, so the only variable is the FDO/LTO/BOLT layer.
COMMON_C="-O3 -g"
COMMON_CXX="-O3 -g -include cstdint"
COMMON_LD="-Wl,--emit-relocs"
PGO_USE="-fprofile-use -fprofile-correction -Wno-missing-profile -Wno-error=coverage-mismatch"

# Jantz's topology: 3 worker containers (this box has 3 SNC nodes, not 6), one pinned per SNC node, 4 concurrent query
# streams, ~90% CPU. 3 nodes x 64 vCPU on this box.
NODE_CPUS() { numactl -H | sed -n "s/^node $1 cpus: //p" | tr -s ' ' ',' | sed 's/^,//;s/,$//'; }
NUM_NODES=$(numactl -H | sed -n 's/^available: \([0-9]*\) nodes.*/\1/p')
