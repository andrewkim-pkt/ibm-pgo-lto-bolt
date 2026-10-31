#!/bin/bash
# Produce the two training profiles the campaign needs.
#   usage: train.sh pgo    -- run the INSTRUMENTED binary, collect .gcda  (-fprofile-use)
#          train.sh afdo   -- perf-record the BASE binary, create_gcov    (-fauto-profile)
# Both drive the identical TPC-H work point (workload.sh).
set -euo pipefail
source /data/velox-fdo/scripts/env.sh
source /data/velox-fdo/scripts/workload.sh
MODE=${1:?pgo|afdo}
TGT=velox_tpch_benchmark

case "$MODE" in
pgo)
  BIN=$ROOT/arms/pgo-gen/$TGT
  [ -x "$BIN" ] || { echo "missing instrumented binary $BIN" >&2; exit 1; }
  # The instrumented binary is several times slower, so train on one pass of the suite.
  echo "=== PGO training run (instrumented) ==="
  cd "$ROOT/build/pgo"
  find . -name "*.gcda" -delete
  # shellcheck disable=SC2046
  $NUMA "$BIN" $(velox_workload_args) -bm_min_iters 1 -bm_max_secs 20 \
      > "$LOGS/train-pgo.out" 2>&1 || { tail -20 "$LOGS/train-pgo.out"; echo "TRAIN FAILED"; exit 1; }
  n=$(find . -name "*.gcda" | wc -l)
  echo "gcda files: $n"
  [ "$n" -gt 0 ] || { echo "NO .gcda PRODUCED -- profile would be empty" >&2; exit 1; }
  tar czf "$PROF/pgo-gcda.tgz" $(find . -name "*.gcda")
  echo "$n" > "$PROF/pgo-gcda.count"
  echo "PGO_TRAIN_DONE gcda=$n"
  ;;
afdo)
  BIN=$ROOT/arms/base/$TGT
  [ -x "$BIN" ] || { echo "missing base binary $BIN" >&2; exit 1; }
  echo "=== AutoFDO profiling run (base binary, LBR) ==="
  cd "$PROF"
  # LBR branch sampling is what create_gcov needs; cycles:u keeps it user-only.
  # AFDO_FREQ default is deliberately LOW: at -F 3000 across 192 threads this writes
  # GBs/sec (30 GB in 5 min, and it destabilised the box), while -F 199 still yields
  # millions of LBR samples and per-query times within ~3% of an unprofiled run.
  # REUSE_PERF=1 skips re-recording when a usable perf.data is already present.
  # shellcheck disable=SC2046
  if [ "${REUSE_PERF:-0}" = "1" ] && [ -s "$PROF/perf.data" ]; then
    echo "reusing existing $PROF/perf.data ($(stat -c%s "$PROF/perf.data") bytes)"
  else
  perf record -e cycles:u -j any,u -F ${AFDO_FREQ:-199} -o "$PROF/perf.data" -- \
      $NUMA "$BIN" $(velox_workload_args) -bm_min_iters 1 -bm_max_secs 20 \
      > "$LOGS/train-afdo.out" 2>&1 || { tail -20 "$LOGS/train-afdo.out"; echo "PERF RUN FAILED"; exit 1; }
  fi
  ls -la "$PROF/perf.data"
  # create_gcov writes the gcov-format profile that gcc's -fauto-profile consumes.
  # --gcov_version=2 is the FORMAT selector the source-built autofdo f95d1a1 uses for
  # gcc 15. (Ubuntu's autofdo 0.19 instead wants gcc's packed gcov version and even then
  # attributes zero functions -- see the note in env.sh.)
  "$CREATE_GCOV" --binary="$BIN" --profile="$PROF/perf.data" \
      --gcov="$PROF/velox.afdo" --gcov_version=2 2>&1 | grep -v "^WARNING" | tail -4
  [ -s "$PROF/velox.afdo" ] || { echo "EMPTY velox.afdo" >&2; exit 1; }
  ls -la "$PROF/velox.afdo"
  # Gate 1: the profile must not be the near-empty file the WRONG tool produces
  # (autofdo 0.19 emitted a valid-looking 1600-byte profile with zero functions, and
  # -fauto-profile accepts that silently -- an arm would then build and measure as a
  # null while looking healthy). A real Velox profile is megabytes.
  #
  # Size, not dump_gcov, is the gate: dump_gcov aborts on profiles this large
  # ("gcov.cc:177 Check failed: bytes < GCOV_BLOCK_BYTE_SIZE"), which is a limit of that
  # diagnostic tool, not a defect in the profile gcc goes on to accept.
  sz=$(stat -c%s "$PROF/velox.afdo")
  echo "profile size: $sz bytes"
  [ "$sz" -gt 1000000 ] || { echo "PROFILE TOO SMALL ($sz bytes) -- near-empty profile" >&2; exit 1; }
  # Gate 2: prove this gcc accepts it before spending a full build on it.
  echo "int main(){return 0;}" > "$TMPDIR/afdo-probe.c"
  if "$CC" -O2 -fauto-profile="$PROF/velox.afdo" "$TMPDIR/afdo-probe.c" -o "$TMPDIR/afdo-probe" 2>"$TMPDIR/afdo-probe.err"; then
    echo "gcc accepts the profile: OK"
  else
    echo "gcc REJECTED the profile:"; cat "$TMPDIR/afdo-probe.err"; exit 1
  fi
  echo "AFDO_TRAIN_DONE"
  ;;
*) echo "unknown mode $MODE" >&2; exit 2 ;;
esac
