#!/bin/bash
# Phase 5b: REDO the PGO arms with a real training profile.
#
# WHY THIS EXISTS. Phase 5 guarded training with `if [ $(count .gcda) -eq 0 ]`, intending
# "skip if already trained". But building pgo-gen with -fprofile-generate instruments the
# build's OWN code generators, and running them during the build deposited 124 .gcda. The
# guard therefore saw a non-empty profile and skipped training entirely, so pgo/pgolto/
# pgoltob were built from a profile of build-time codegen utilities with ZERO TPC-DS data.
# Those three binaries are invalid and are rebuilt here.
#
# Fixes:
#   * training is gated on an explicit MARKER, never on the presence of .gcda;
#   * .gcda are wiped AFTER the instrumented build and immediately BEFORE training, so
#     build-time counters cannot contaminate the workload profile;
#   * the profile is sanity-checked against a floor, not just "> 0" (the 96xl produced 830
#     .gcda for this same 15-query SF=10 run, so 124 is not a plausible workload profile).
set -uo pipefail
R=/data/velox-fdo
source $R/scripts/env48.sh
M=$R/.markers
MIN_GCDA=${MIN_GCDA:-400}
JAVA_HOME=${JAVA_HOME:-$R/tools/jdk17}
SRV=$R/tools/presto-server-0.299
ulimit -n 524288
cd "$R"
log() { echo "[$(date -u +%H:%M)] $*"; }

# --- 0. discard the arms built from the bogus profile ------------------------
if [ ! -f "$M/pgo-redo-cleaned" ]; then
  log "discarding pgo/pgolto/pgoltob built from the build-time profile"
  rm -rf arms/pgo arms/pgolto arms/pgoltob
  touch "$M/pgo-redo-cleaned"
fi

# --- 1. re-instrument (pgo/pgolto overwrote build/pgo with plain objects) ----
if [ ! -f "$M/pgo-gen-rebuilt" ]; then
  log "rebuilding pgo-gen to re-instrument build/pgo"
  rm -rf arms/pgo-gen
  ./scripts/build-arm48-run.sh pgo-gen >> "$LOGS/build48b-pgo-gen.log" 2>&1 \
    || { log "pgo-gen FAILED"; tail -8 "$LOGS/build48b-pgo-gen.log"; exit 1; }
  touch "$M/pgo-gen-rebuilt"
fi
log "pgo-gen: $(ls -la arms/pgo-gen/presto_server | awk '{printf "%.2f GB", $5/1073741824}')"
o=$(find build/pgo/presto_cpp -name "PeriodicTaskManager.cpp.o" 2>/dev/null | head -1)
[ -n "$o" ] && objdump -dr "$o" 2>/dev/null | awk '
  /[[:space:]]lock[[:space:]]/ { p=1; next }
  /__gcov/ { t++; if(p) a++; p=0; next } { p=0 }
  END { printf "[verify] gcov sites=%d with-lock=%d (want with-lock=0)\n", t, a+0 }'

# --- 2. train, gated on a MARKER ---------------------------------------------
if [ ! -f "$M/pgo-trained" ]; then
  n_before=$(find build/pgo -name "*.gcda" 2>/dev/null | wc -l)
  log "wiping $n_before build-time .gcda before training"
  find build/pgo -name "*.gcda" -delete 2>/dev/null
  log "training: 15 queries, SF=10, 3 workers (one per SNC node)"
  ARM=pgo-gen SCHEMA=tpcds10 NWORKERS=3 TMO=1800 \
      ./scripts/train-pgo48.sh > "$LOGS/p48b-train.log" 2>&1 \
    || { log "train FAILED"; tail -20 "$LOGS/p48b-train.log" | cut -c1-150; exit 1; }
  grep -E "queries ok|TRAIN_PGO_DONE" "$LOGS/p48b-train.log" | tail -2
  touch "$M/pgo-trained"
fi
ngcda=$(find build/pgo -name "*.gcda" 2>/dev/null | wc -l)
log "profile: $ngcda .gcda files (96xl reference: 830)"
[ "$ngcda" -ge "$MIN_GCDA" ] \
  || { log "ABORT: only $ngcda .gcda, below floor $MIN_GCDA -- training did not really run"; exit 1; }

# --- 3. optimised arms -------------------------------------------------------
for arm in pgo pgolto; do
  if [ -x "$R/arms/$arm/presto_server" ]; then log "$arm already built"; continue; fi
  log "build $arm"
  ./scripts/build-arm48-run.sh "$arm" >> "$LOGS/build48b-$arm.log" 2>&1 \
    || { log "$arm FAILED"; tail -8 "$LOGS/build48b-$arm.log"; exit 1; }
  log "$arm md5=$(cut -d' ' -f1 arms/$arm/md5.txt 2>/dev/null)"
done

# --- 4. BOLT -----------------------------------------------------------------
if [ ! -x "$R/arms/pgoltob/presto_server" ]; then
  log "fresh coordinator for BOLT's perf run"
  pkill -f "[p]resto_server --etc_dir" 2>/dev/null
  pkill -f "com.facebook.[p]resto.server.PrestoServer" 2>/dev/null
  sleep 8
  PATH=$JAVA_HOME/bin:$PATH nohup "$SRV/bin/launcher.py" \
      --etc-dir $R/cluster/coordinator/etc --data-dir $R/cluster/coordinator/data run \
      > $R/cluster/coordinator/server.log 2>&1 &
  for i in $(seq 1 150); do
    curl -s http://127.0.0.1:8080/v1/info 2>/dev/null | grep -q '"starting":false' && break
    sleep 2
  done
  log "BOLT pgolto -> pgoltob"
  ./scripts/bolt-arm48.sh pgolto >> "$LOGS/bolt48b-pgolto.log" 2>&1 \
    || { log "pgoltob FAILED"; tail -10 "$LOGS/bolt48b-pgolto.log"; exit 1; }
fi

log "md5s:"
for a in base pgo pgolto pgoltob; do printf '  %-9s %s\n' "$a" "$(cut -d' ' -f1 arms/$a/md5.txt 2>/dev/null)"; done
log "PHASE5B_DONE"
