#!/bin/bash
# BOLT a built arm:  bolt-arm.sh <pgo|pgolto|afdo|afdolto>  ->  arms/<src>b/
# A BOLT profile is specific to the exact binary it was recorded on, so each BOLT arm
# gets its OWN perf run against its OWN parent binary -- profiles are never shared.
# Option set is the standard C/C++ set from the IBOT BKM (BKM_c_cpp.md step 3).
set -euo pipefail
source /data/velox-fdo/scripts/env.sh
source /data/velox-fdo/scripts/workload.sh
SRC=${1:?source arm: pgo|pgolto|afdo|afdolto}
TGT=velox_tpch_benchmark
OUT="${SRC}b"
IN_BIN=$ROOT/arms/$SRC/$TGT
[ -x "$IN_BIN" ] || { echo "missing parent binary $IN_BIN" >&2; exit 1; }
mkdir -p "$ROOT/arms/$OUT" "$PROF/bolt-$SRC"
cd "$PROF/bolt-$SRC"

# BOLT refuses a binary with no .rela.text; every arm is linked with --emit-relocs.
# Use grep -c, not grep -q: -q exits on the first match, readelf then dies of SIGPIPE on
# these multi-GB binaries, and `set -o pipefail` reports that as a failed check -- which
# made this gate claim ".rela.text missing" on binaries that have it.
nrela=$(readelf -S "$IN_BIN" 2>/dev/null | grep -c "\.rela\.text" || true)
[ "${nrela:-0}" -gt 0 ] || { echo "$IN_BIN has no .rela.text" >&2; exit 1; }

echo "=== 1/3 perf record (LBR) on $SRC ==="
# shellcheck disable=SC2046
perf record -e cycles:u -j any,u -F ${BOLT_FREQ:-199} -o perf.data -- \
    $NUMA "$IN_BIN" $(velox_workload_args) -bm_min_iters 1 -bm_max_secs 20 \
    > "$LOGS/bolt-perf-$SRC.out" 2>&1 || { tail -20 "$LOGS/bolt-perf-$SRC.out"; exit 1; }
ls -la perf.data

echo "=== 2/3 perf2bolt ==="
perf2bolt -p perf.data -o perf.fdata "$IN_BIN" 2>&1 | tail -5
[ -s perf.fdata ] || { echo "empty perf.fdata" >&2; exit 1; }

echo "=== 3/3 llvm-bolt ==="
llvm-bolt "$IN_BIN" -o "$ROOT/arms/$OUT/$TGT" \
    -data=perf.fdata \
    -reorder-blocks=ext-tsp \
    -reorder-functions=hfsort+ \
    -split-functions \
    -split-all-cold \
    -split-eh \
    -icf=1 \
    -dyno-stats 2>&1 | tee "$LOGS/bolt-$SRC.log" | tail -25

[ -x "$ROOT/arms/$OUT/$TGT" ] || { echo "BOLT produced no binary" >&2; exit 1; }
cd "$ROOT/arms/$OUT" && md5sum "$TGT" | tee md5.txt
ls -la "$TGT"
echo "BOLT_${OUT}_DONE"
