#!/bin/bash
# Phase 5: the PGO arms on the 48xl -- pgo-gen -> train -> pgo -> pgolto -> BOLT pgoltob.
#
# Priority order is deliberate: PGO is the arm that actually won on Velox (+6.18% pgolto)
# and the one that closes the NUMA question, so it goes first. The AutoFDO arms need
# create_gcov built from google/autofdo and can follow.
#
# Carried over from the 96xl (do not rediscover):
#  * pgo-gen MUST use -fprofile-update=single. gcc 15 picks ATOMIC counters whenever
#    -pthread is present, and Presto/Velox always is: every hot arc becomes `lock add` on a
#    shared line and instrumentation goes from ~5x to >300x. The flag is already in
#    build-arm48.sh; this script verifies it took by checking for lock-prefixed gcov sites.
#  * Train with ALL workers, not one: a single worker produces no remote exchanges, so the
#    profile misses the shuffle paths that are hot under measurement.
#  * gcov writes .gcda from an atexit() handler -> SIGTERM, never SIGKILL.
#  * bolt-arm48.sh waits on activeWorkers>=1 and does not restart the coordinator, so it
#    gets a freshly restarted one here to make that >= safe.
set -uo pipefail
R=/data/velox-fdo
source $R/scripts/env48.sh
M=$R/.markers
JAVA_HOME=${JAVA_HOME:-$R/tools/jdk17}
SRV=$R/tools/presto-server-0.299
ulimit -n 524288
cd "$R"
log() { echo "[$(date -u +%H:%M)] $*"; }

# --- 1. register the SF=10 training schema (cluster is already up on base) ---
if [ ! -f "$M/tables10-registered" ]; then
  log "registering SF=10 as hive.tpcds10"
  python3 -I scripts/reg10.py > "$LOGS/p48-reg10.log" 2>&1 \
    || { log "reg10 FAILED"; tail -12 "$LOGS/p48-reg10.log"; exit 1; }
  touch "$M/tables10-registered"
fi
log "tpcds10 store_sales: $(./scripts/cluster48.sh sql 'SELECT count(*) FROM hive.tpcds10.store_sales' 2>&1 | tail -1)"

# --- 2. instrumented build ---------------------------------------------------
if [ ! -x "$R/arms/pgo-gen/presto_server" ]; then
  log "build pgo-gen (instrumented, non-atomic counters)"
  ./scripts/build-arm48-run.sh pgo-gen >> "$LOGS/build48-pgo-gen.log" 2>&1 \
    || { log "pgo-gen FAILED"; tail -8 "$LOGS/build48-pgo-gen.log"; exit 1; }
fi
log "pgo-gen: $(ls -la arms/pgo-gen/presto_server | awk '{printf "%.2f GB", $5/1073741824}')"
# verify the counters really are non-atomic -- this is the whole reason PGO is feasible
o=$(find build/pgo/presto_cpp -name "PeriodicTaskManager.cpp.o" 2>/dev/null | head -1)
if [ -n "$o" ]; then
  objdump -dr "$o" 2>/dev/null | awk '
    /[[:space:]]lock[[:space:]]/ { p=1; next }
    /__gcov/ { t++; if(p) a++; p=0; next } { p=0 }
    END { printf "[verify] gcov sites=%d with-lock=%d\n", t, a+0 }'
fi

# --- 3. train ---------------------------------------------------------------
ngcda=$(find build/pgo -name "*.gcda" 2>/dev/null | wc -l)
if [ "$ngcda" -eq 0 ]; then
  log "training at SF=10 on all $(numactl -H | grep -c '^node [0-9]* cpus') workers"
  ARM=pgo-gen SCHEMA=tpcds10 NWORKERS=3 TMO=1800 ./scripts/train-pgo48.sh \
      >> "$LOGS/p48-train.log" 2>&1 || { log "train FAILED"; tail -12 "$LOGS/p48-train.log"; exit 1; }
  ngcda=$(find build/pgo -name "*.gcda" 2>/dev/null | wc -l)
fi
log "profile: $ngcda .gcda files"
[ "$ngcda" -gt 0 ] || { log "ABORT: no profile, refusing to build a fake pgo arm"; exit 1; }

# --- 4. optimised arms ------------------------------------------------------
for arm in pgo pgolto; do
  if [ -x "$R/arms/$arm/presto_server" ]; then log "$arm already built"; continue; fi
  log "build $arm"
  ./scripts/build-arm48-run.sh "$arm" >> "$LOGS/build48-$arm.log" 2>&1 \
    || { log "$arm FAILED"; tail -8 "$LOGS/build48-$arm.log"; exit 1; }
  log "$arm md5=$(cut -d' ' -f1 arms/$arm/md5.txt 2>/dev/null)"
done

# --- 5. BOLT ----------------------------------------------------------------
if [ ! -x "$R/arms/pgoltob/presto_server" ]; then
  log "fresh coordinator so BOLT's activeWorkers>=1 cannot match a stale node"
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
  log "BOLT pgolto -> pgoltob (perf at SF=1000, same recipe as the 96xl)"
  ./scripts/bolt-arm48.sh pgolto >> "$LOGS/bolt48-pgolto.log" 2>&1 \
    || { log "pgoltob FAILED"; tail -10 "$LOGS/bolt48-pgolto.log"; exit 1; }
fi
log "arms: $(ls arms | tr '\n' ' ')"
log "PHASE5_DONE"
