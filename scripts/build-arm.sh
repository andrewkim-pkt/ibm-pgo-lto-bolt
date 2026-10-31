#!/bin/bash
# Build one arm of the Velox gcc15 FDO campaign.
#   usage: build-arm.sh <base|pgo-gen|pgo|pgolto|afdo|afdolto>
# BOLT arms are produced by bolt-arm.sh from the pgolto / afdolto binaries.
#
# PGO note: the instrumented build and both -fprofile-use builds share ONE build
# directory (build-pgo) because gcc looks for <objdir>/<file>.gcda beside each object.
# The .gcda set is tarred to $PROF after training so it survives a wiped build dir.
set -euo pipefail
source /data/velox-fdo/scripts/env.sh
ARM=${1:?arm name required}
TGT=velox_tpch_benchmark
PGO_USE="-fprofile-use -fprofile-correction -Wno-missing-profile -Wno-error=coverage-mismatch"
mkdir -p "$ROOT/arms" "$PROF"

case "$ARM" in
  base)     BDIR=$ROOT/build/base;    EXTRA_CXX="";                                                     EXTRA_LD="" ;;
  # -fprofile-update=prefer-atomic was MEASURED here at >200x slowdown: Velox's
  # vectorized inner loops get an arc counter per row, and with 144 driver threads the
  # counter cache lines ping-pong so badly that TPC-H q1 (1.3s normally) did not finish
  # in 90s even at 16 drivers. Non-atomic counters race and lose counts instead, which
  # is why every -fprofile-use arm below also passes -fprofile-correction.
  pgo-gen)  BDIR=$ROOT/build/pgo;     EXTRA_CXX="-fprofile-generate ${PGO_ATOMIC:+-fprofile-update=prefer-atomic}"; EXTRA_LD="-fprofile-generate" ;;
  # -Wno-error=coverage-mismatch is REQUIRED for the LTO arm and harmless for the plain
  # one: -flto changes the CFG of heavily templated headers (geos' bundled nlohmann/json
  # here) relative to the instrumented build, so some .gcda arc checksums no longer
  # match, and gcc makes coverage-mismatch an ERROR by default. Those functions just
  # lose their profile; the rest still use it.
  pgo)      BDIR=$ROOT/build/pgo;     EXTRA_CXX="$PGO_USE"; EXTRA_LD="" ;;
  pgolto)   BDIR=$ROOT/build/pgo;     EXTRA_CXX="$PGO_USE -flto=$JOBS -ffat-lto-objects"; EXTRA_LD="-flto=$JOBS" ;;
  afdo)     BDIR=$ROOT/build/afdo;    EXTRA_CXX="-fauto-profile=$PROF/velox.afdo";                       EXTRA_LD="" ;;
  afdolto)  BDIR=$ROOT/build/afdo;    EXTRA_CXX="-fauto-profile=$PROF/velox.afdo -flto=$JOBS -ffat-lto-objects"; EXTRA_LD="-flto=$JOBS" ;;
  *) echo "unknown arm: $ARM" >&2; exit 2 ;;
esac

echo "=== arm=$ARM  builddir=$BDIR ==="
echo "    CXX extra: $EXTRA_CXX"
echo "    LD  extra: $EXTRA_LD"
"$CXX" --version | head -1

mkdir -p "$BDIR"
cd "$VELOX_SRC"
# shellcheck disable=SC2046
cmake -B "$BDIR" -S "$VELOX_SRC" -GNinja \
  $(velox_cmake_common) \
  -DCMAKE_CXX_FLAGS="$COMMON_CXX $EXTRA_CXX" \
  -DCMAKE_C_FLAGS="$COMMON_C $EXTRA_CXX" \
  -DCMAKE_EXE_LINKER_FLAGS="$COMMON_LD $EXTRA_LD" \
  > "$LOGS/cmake-$ARM.log" 2>&1 || { tail -40 "$LOGS/cmake-$ARM.log"; exit 1; }

echo "=== ninja $TGT -j$JOBS ==="
# Keep the FULL ninja output: a truncated tail hides the FAILED: block that names the
# actual compile error.
if ! ninja -C "$BDIR" -j"$JOBS" "$TGT" > "$LOGS/ninja-$ARM.log" 2>&1; then
  echo "--- ninja failed; first error ---"
  grep -m1 -A25 "FAILED:" "$LOGS/ninja-$ARM.log" || tail -30 "$LOGS/ninja-$ARM.log"
  exit 1
fi
tail -3 "$LOGS/ninja-$ARM.log"

BIN=$(find "$BDIR" -name "$TGT" -type f -perm -u+x | head -1)
[ -n "$BIN" ] || { echo "BUILD FAILED: no $TGT produced" >&2; exit 1; }
mkdir -p "$ROOT/arms/$ARM"
cp -f "$BIN" "$ROOT/arms/$ARM/$TGT"
cd "$ROOT/arms/$ARM"
md5sum "$TGT" | tee "$ROOT/arms/$ARM/md5.txt"
ls -la "$TGT"
# BOLT refuses a binary with no .rela.text; prove it is there on every arm.
# grep -c, not -q: see the note in bolt-arm.sh -- -q + pipefail misreports on these sizes.
nrela=$(readelf -S "$TGT" 2>/dev/null | grep -c "\.rela\.text" || true)
[ "${nrela:-0}" -gt 0 ] && echo "rela.text: present" || echo "rela.text: MISSING"
printf ".text bytes: "; readelf -S "$TGT" 2>/dev/null | grep -A1 " \.text " | tail -1 | awk '{print strtonum("0x"$1)}'
echo "ARM_${ARM}_BUILD_DONE"
