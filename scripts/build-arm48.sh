#!/bin/bash
# Build one arm of the Prestissimo FDO lattice.
#   usage: build-arm96.sh <base|pgo-gen|pgo|pgolto|afdo|afdolto>
# BOLT arms come from bolt-arm96.sh. Target = presto_server (the native worker; the
# Java coordinator is untouched and carries almost no CPU).
#
# The instrumented and both -fprofile-use builds SHARE one build dir, because gcc looks
# for <objdir>/<file>.gcda beside each object.
set -euo pipefail
source /data/velox-fdo/scripts/env48.sh
ARM=${1:?arm name required}
TGT=presto_server

case "$ARM" in
  base)     BDIR=$ROOT/build/base; EX_CXX="";                                   EX_LD="" ;;
  pgo-gen)  BDIR=$ROOT/build/pgo;  EX_CXX="-fprofile-generate -fprofile-update=single"; EX_LD="-fprofile-generate" ;;
  pgo)      BDIR=$ROOT/build/pgo;  EX_CXX="$PGO_USE";                           EX_LD="" ;;
  pgolto)   BDIR=$ROOT/build/pgo;  EX_CXX="$PGO_USE -flto=$JOBS -ffat-lto-objects"; EX_LD="-flto=$JOBS" ;;
  afdo)     BDIR=$ROOT/build/afdo; EX_CXX="-fauto-profile=$PROF/presto.afdo";   EX_LD="" ;;
  afdolto)  BDIR=$ROOT/build/afdo; EX_CXX="-fauto-profile=$PROF/presto.afdo -flto=$JOBS -ffat-lto-objects"; EX_LD="-flto=$JOBS" ;;
  *) echo "unknown arm: $ARM" >&2; exit 2 ;;
esac

echo "=== arm=$ARM builddir=$BDIR  $(date -u +%H:%M) ==="
echo "    CXX extra: $EX_CXX"
echo "    LD  extra: $EX_LD"
"$CXX" --version | head -1
mkdir -p "$BDIR" "$ROOT/arms/$ARM"
cd "$PRESTO"

# TREAT_WARNINGS_AS_ERRORS=0: Presto/Velox target gcc 11-13; gcc 15.2 raises new warnings.
# CMAKE_POLICY_VERSION_MINIMUM=3.5: cmake 4.x on Ubuntu 26.04 dropped <3.5 policy compat,
#   which some older bundled deps still declare.
# PRESTO_ENABLE_TESTING=OFF: not part of a production worker, and it drags in duckdb.
cmake -B "$BDIR" -S "$PRESTO" -GNinja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DTREAT_WARNINGS_AS_ERRORS=0 -DENABLE_ALL_WARNINGS=0 \
  -DPRESTO_ENABLE_PARQUET=ON -DPRESTO_ENABLE_TESTING=OFF -DPRESTO_ENABLE_SPATIAL=OFF \
  -DCMAKE_PREFIX_PATH="$ROOT/deps" \
  -DCMAKE_CXX_FLAGS="$COMMON_CXX $EX_CXX" \
  -DCMAKE_C_FLAGS="$COMMON_C $EX_CXX" \
  -DCMAKE_EXE_LINKER_FLAGS="$COMMON_LD $EX_LD" \
  > "$LOGS/cmake96-$ARM.log" 2>&1 || { tail -40 "$LOGS/cmake96-$ARM.log"; exit 1; }
echo "configure OK $(date -u +%H:%M)"

if ! ninja -C "$BDIR" -j"$JOBS" "$TGT" > "$LOGS/ninja96-$ARM.log" 2>&1; then
  echo "--- ninja failed; first error ---"
  grep -m1 -A25 "FAILED:" "$LOGS/ninja96-$ARM.log" || tail -30 "$LOGS/ninja96-$ARM.log"
  exit 1
fi
tail -2 "$LOGS/ninja96-$ARM.log"

BIN=$(find "$BDIR" -name "$TGT" -type f -perm -u+x | head -1)
[ -n "$BIN" ] || { echo "BUILD FAILED: no $TGT produced" >&2; exit 1; }
cp -f "$BIN" "$ROOT/arms/$ARM/$TGT"
cd "$ROOT/arms/$ARM" && md5sum "$TGT" | tee md5.txt
nrela=$(readelf -S "$TGT" 2>/dev/null | grep -c "\.rela\.text" || true)
[ "${nrela:-0}" -gt 0 ] && echo "rela.text: present" || echo "rela.text: MISSING"
printf ".text bytes: "; readelf -S "$TGT" 2>/dev/null | grep -A1 " \.text " | tail -1 | awk '{print strtonum("0x"$1)}'
ls -la "$TGT" | awk '{print "size:", $5}'
echo "ARM96_${ARM}_DONE $(date -u +%H:%M)"
