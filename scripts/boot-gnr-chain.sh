#!/bin/bash
# Master chain for the GNR box: waits for phase23 (deps+tooling+datasets), then runs
# cluster bring-up + validation, then builds every arm, then starts the measurement.
#
# WHY A MASTER CHAIN: my visibility into this box keeps failing (four multi-hour proxy
# outages, plus session restarts that kill monitors). Phase 1 sat finished-and-idle for
# 2h47m purely because nothing followed it. Everything here is marker-guarded, so the box
# keeps advancing whether or not I can see it.
set -uo pipefail
source /data/prestissimo-fdo/scripts/env-gnr.sh
M=$ROOT/.markers
JAVA_HOME=${JAVA_HOME:-$ROOT/tools/jdk17}
SRV=$ROOT/tools/presto-server-0.299
MIN_GCDA=${MIN_GCDA:-400}
ulimit -n 524288
cd "$ROOT"
log() { echo "[$(date -u +%H:%M)] $*"; }

while pgrep -f "[b]oot-gnr-phase23" > /dev/null; do sleep 60; done
[ -f "$M/data-sf1000" ] || { log "ABORT: phase23 did not finish (no SF=1000 dataset)"; exit 1; }
log "phase23 complete; SF=1000 = $(du -sh "$ROOT/tpcds-sf1000" | cut -f1)"

start_coord() {
  pkill -f "[p]resto_server --etc_dir" 2>/dev/null
  pkill -f "com.facebook.[p]resto.server.PrestoServer" 2>/dev/null
  sleep 8
  PATH=$JAVA_HOME/bin:$PATH nohup "$SRV/bin/launcher.py" \
      --etc-dir $ROOT/cluster/coordinator/etc --data-dir $ROOT/cluster/coordinator/data run \
      > $ROOT/cluster/coordinator/server.log 2>&1 &
  for i in $(seq 1 150); do
    curl -s http://127.0.0.1:8080/v1/info 2>/dev/null | grep -q '"starting":false' && break
    sleep 2
  done
  curl -s http://127.0.0.1:8080/v1/info 2>/dev/null | grep -q '"starting":false'
}

# ---------------- cluster + registration + validation ----------------------
if [ ! -f "$M/cluster-setup" ]; then
  log "cluster setup (3 workers, memory budgets halved for 755 GB box)"
  WORKERS=3 ./scripts/cluster-gnr.sh setup > "$LOGS/setup.log" 2>&1 \
    || { log "setup FAILED"; tail -15 "$LOGS/setup.log"; exit 1; }
  touch "$M/cluster-setup"
fi

if [ ! -x "$ROOT/arms/base/presto_server" ]; then
  log "build base"
  ./scripts/build-arm-gnr.sh base >> "$LOGS/build-base.log" 2>&1 \
    || { log "base FAILED"; tail -10 "$LOGS/build-base.log"; exit 1; }
fi
log "base: $(ls -la arms/base/presto_server | awk '{printf "%.2f GB", $5/1073741824}')"

log "starting cluster on base"
WORKERS=3 ./scripts/cluster-gnr.sh start base > "$LOGS/start.log" 2>&1 || true
n=0
for i in $(seq 1 150); do
  n=$(curl -s http://127.0.0.1:8080/v1/cluster 2>/dev/null \
      | grep -oE '"activeWorkers":[0-9]+' | grep -oE '[0-9]+$')
  [ "${n:-0}" -eq 3 ] && break
  sleep 5
done
log "activeWorkers=${n:-0}"
[ "${n:-0}" -eq 3 ] || { log "ABORT: cluster not ready"; tail -20 cluster/worker0/worker.log | cut -c1-160; exit 1; }

for reg in reg1000 reg10; do
  [ -f "$M/$reg" ] && continue
  log "registering via $reg.py"
  python3 -I scripts/$reg.py > "$LOGS/$reg.log" 2>&1 \
    || { log "$reg FAILED"; tail -12 "$LOGS/$reg.log"; exit 1; }
  touch "$M/$reg"
done
log "store_sales (canonical 2,879,987,999): $(./scripts/cluster-gnr.sh sql 'SELECT count(*) FROM hive.tpcds.store_sales' 2>&1 | tail -1)"
log "q19 end-to-end: $(python3 -I scripts/driver.py warm --list <(echo q19.sql) --n 1 --timeout 1800 2>&1 | tail -1)"

# ---------------- PGO arms (node 1: the NIC is on node 0) ------------------
if [ ! -f "$M/pgo-trained" ]; then
  log "build pgo-gen (instrumented, -fprofile-update=single)"
  rm -rf arms/pgo-gen
  ./scripts/build-arm-gnr.sh pgo-gen >> "$LOGS/build-pgo-gen.log" 2>&1 \
    || { log "pgo-gen FAILED"; tail -10 "$LOGS/build-pgo-gen.log"; exit 1; }
  # Building with -fprofile-generate instruments the build's OWN code generators; running
  # them deposits ~124 .gcda, which once silently SKIPPED training entirely and produced
  # arms with zero workload profile. Wipe immediately before training.
  find build/pgo -name "*.gcda" -delete 2>/dev/null
  log "training PGO on node 1, SF=10"
  start_coord || exit 1
  N1=$(NODE_CPUS 1)
  : > cluster/worker1/worker.log
  setsid numactl --physcpubind="$N1" --preferred=1 \
      arms/pgo-gen/presto_server --etc_dir=$ROOT/cluster/worker1/etc \
      >> cluster/worker1/worker.log 2>&1 &
  for i in $(seq 1 150); do
    n=$(curl -s http://127.0.0.1:8080/v1/cluster 2>/dev/null | grep -oE '"activeWorkers":[0-9]+' | grep -oE '[0-9]+$')
    [ "${n:-0}" -eq 1 ] && break; sleep 5
  done
  [ "${n:-0}" -eq 1 ] || { log "ABORT: training worker never registered"; exit 1; }
  PRESTO_SCHEMA=tpcds10 python3 -I scripts/driver.py warm \
      --list results/queries-top.txt --n 15 --timeout 1800 > "$LOGS/pgo-train.log" 2>&1 || true
  # gcov writes .gcda from an atexit() handler: SIGKILL yields NOTHING.
  pkill -TERM -f "[p]resto_server --etc_dir" 2>/dev/null
  for i in $(seq 1 120); do pgrep -f "[p]resto_server --etc_dir" >/dev/null || break; sleep 2; done
  touch "$M/pgo-trained"
fi
ngcda=$(find build/pgo -name "*.gcda" 2>/dev/null | wc -l)
log "PGO profile: $ngcda .gcda (floor $MIN_GCDA; 48xl reference 830)"
[ "$ngcda" -ge "$MIN_GCDA" ] || { log "ABORT: profile too small, training did not run"; exit 1; }

for arm in pgo pgolto; do
  [ -x "arms/$arm/presto_server" ] && continue
  log "build $arm"
  ./scripts/build-arm-gnr.sh "$arm" >> "$LOGS/build-$arm.log" 2>&1 \
    || { log "$arm FAILED"; tail -10 "$LOGS/build-$arm.log"; exit 1; }
done

if [ ! -x arms/pgoltob/presto_server ]; then
  log "BOLT pgolto -> pgoltob, perf on node 1"
  start_coord || exit 1
  BOLT_NODE=1 ./scripts/bolt-arm-gnr.sh pgolto >> "$LOGS/bolt-pgolto.log" 2>&1 \
    || { log "pgoltob FAILED"; tail -12 "$LOGS/bolt-pgolto.log"; exit 1; }
fi

# ---------------- AutoFDO arms (node 1) ------------------------------------
if [ ! -s "$PROF/presto.afdo" ]; then
  log "AutoFDO: perf LBR on a node-1 worker, full 3-worker cluster"
  start_coord || exit 1
  BOLT_NODE=1 ./scripts/afdo-profile-gnr.sh > "$LOGS/afdo-profile.log" 2>&1 \
    || { log "afdo profile FAILED"; tail -20 "$LOGS/afdo-profile.log" | cut -c1-160; exit 1; }
fi
log "presto.afdo: $(ls -la $PROF/presto.afdo 2>/dev/null | awk '{printf "%.1f MB", $5/1048576}')"

for arm in afdo afdolto; do
  [ -x "arms/$arm/presto_server" ] && continue
  log "build $arm"
  ./scripts/build-arm-gnr.sh "$arm" >> "$LOGS/build-$arm.log" 2>&1 \
    || { log "$arm FAILED"; tail -10 "$LOGS/build-$arm.log"; exit 1; }
done

if [ ! -x arms/afdoltob/presto_server ]; then
  log "BOLT afdolto -> afdoltob, perf on node 1"
  start_coord || exit 1
  BOLT_NODE=1 ./scripts/bolt-arm-gnr.sh afdolto >> "$LOGS/bolt-afdolto.log" 2>&1 \
    || { log "afdoltob FAILED"; tail -12 "$LOGS/bolt-afdolto.log"; exit 1; }
fi

log "arms: $(ls arms | tr '\n' ' ')"
for a in base pgo pgolto pgoltob afdo afdolto afdoltob; do
  printf '  %-10s %s\n' "$a" "$(cut -d' ' -f1 arms/$a/md5.txt 2>/dev/null)"
done

# ---------------- measurement ----------------------------------------------
log "starting 7-arm x 4-round measurement"
./scripts/mctl-gnr.sh start
log "CHAIN_HANDOFF_DONE measurement running"
