#!/bin/bash
# Phase 6: re-collect ALL profiles pinned to NUMA NODE 1, then rebuild the full lattice.
#
# WHY NODE 1, NOT NODE 0. Every prior campaign of ours deliberately used node 1 --
# Velox gcc15 (whole-box null, node-1 pinned pgolto +6.18%), the MySQL gcc15 seven-arm
# matrix, the PG gcc15 six-arm HammerDB -- because on these boxes the NIC lives on node 0,
# so node 0 carries the driver/interrupt load and is the noisiest place to profile. I had
# nevertheless written `node 0` into afdo-profile.sh and bolt-arm48.sh as "the first node".
# That matters most for BOLT, whose entire job is code layout driven by RELATIVE hotness,
# and BOLT has been the least stable arm across this work (negative on the 96xl AutoFDO
# leg, +1.7pp -- the largest single contributor -- on the 48xl).
#
# Memory binding is --preferred=1, NEVER --membind=1: a hard membind to one node OOMs on
# this hardware (recorded from the gcc15 PG campaign).
#
# What changes vs the measured 48xl arms:
#   PGO  : training moves from ALL 3 nodes -> node 1 only
#   BOLT : perf profile moves from node 0 -> node 1
#   AFDO : new arms (none existed here); perf profile on node 1
# The MEASUREMENT config is untouched (whole box, 3 workers, SF=1000), so the only variable
# is where the profile came from.
set -uo pipefail
R=/data/velox-fdo
source $R/scripts/env48.sh
M=$R/.markers
NODE=${NODE:-1}
MIN_GCDA=${MIN_GCDA:-400}
JAVA_HOME=${JAVA_HOME:-$R/tools/jdk17}
SRV=$R/tools/presto-server-0.299
ulimit -n 524288
cd "$R"
log() { echo "[$(date -u +%H:%M)] $*"; }
N1CPUS=$(numactl -H | sed -n "s/^node $NODE cpus: //p" | tr -s ' ' ',' | sed 's/^,//;s/,$//')
log "profiling node=$NODE cpus=$(echo "$N1CPUS" | tr ',' ' ' | wc -w)"

start_coord() {
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
  curl -s http://127.0.0.1:8080/v1/info 2>/dev/null | grep -q '"starting":false'
}
wait_workers() {  # $1 = exact count. EXACT, never >=: a just-killed node lingers in the
  local want=$1 n=0   # coordinator's list and tasks get scheduled onto a dead worker.
  for i in $(seq 1 150); do
    n=$(curl -s http://127.0.0.1:8080/v1/cluster 2>/dev/null \
        | grep -oE '"activeWorkers":[0-9]+' | grep -oE '[0-9]+$')
    [ "${n:-0}" -eq "$want" ] && return 0
    sleep 5
  done
  log "workers reached ${n:-0}, wanted $want"; return 1
}

# --- 0. archive the node-0/all-node arms so they can be A/B'd later ----------
if [ ! -f "$M/n0-archived" ]; then
  mkdir -p arms-n0 results-n0
  for a in pgo pgolto pgoltob; do [ -d "arms/$a" ] && mv "arms/$a" "arms-n0/$a"; done
  cp results/tput-summary.tsv results-n0/ 2>/dev/null
  cp results/tput-base-r*.tsv results/tput-pgo*-r*.tsv results-n0/ 2>/dev/null
  log "archived old arms -> arms-n0/, results -> results-n0/"
  touch "$M/n0-archived"
fi

# --- 1. create_gcov (needed for any AutoFDO arm; never built on this box) ----
if [ ! -x "$R/toolchain/autofdo/build-gcov/create_gcov" ]; then
  log "building create_gcov from google/autofdo f95d1a1"
  ./scripts/build-autofdo48.sh > "$LOGS/p48-autofdo-build.log" 2>&1 \
    || { log "create_gcov FAILED"; tail -20 "$LOGS/p48-autofdo-build.log" | cut -c1-160; exit 1; }
fi
log "create_gcov: $(ls -la $R/toolchain/autofdo/build-gcov/create_gcov | awk '{printf "%.1f MB", $5/1048576}')"

# =========================== PGO on node 1 ==================================
if [ ! -f "$M/pgo-n1-trained" ]; then
  log "re-instrumenting build/pgo"
  rm -rf arms/pgo-gen
  ./scripts/build-arm48-run.sh pgo-gen >> "$LOGS/p6-pgo-gen.log" 2>&1 \
    || { log "pgo-gen FAILED"; tail -8 "$LOGS/p6-pgo-gen.log"; exit 1; }
  # Wipe build-time .gcda: building with -fprofile-generate instruments the build's OWN
  # code generators and running them deposits ~124 .gcda, which once silently skipped
  # training entirely and produced arms with ZERO workload profile.
  find build/pgo -name "*.gcda" -delete 2>/dev/null
  log "training PGO: ONE worker on node $NODE, SF=10"
  start_coord || { log "coordinator failed"; exit 1; }
  : > cluster/worker1/worker.log
  setsid numactl --physcpubind="$N1CPUS" --preferred="$NODE" \
      arms/pgo-gen/presto_server --etc_dir=$R/cluster/worker1/etc \
      >> cluster/worker1/worker.log 2>&1 &
  wait_workers 1 || exit 1
  PRESTO_SCHEMA=tpcds10 python3 -I scripts/driver.py warm \
      --list results/queries-top.txt --n 15 --timeout 1800 > "$LOGS/p6-pgo-train.log" 2>&1 \
    || log "some training queries failed (continuing)"
  grep -c "ok=1" "$LOGS/p6-pgo-train.log" | sed 's/^/training queries ok: /'
  # gcov writes .gcda from an atexit() handler -- SIGKILL yields NOTHING.
  pkill -TERM -f "[p]resto_server --etc_dir" 2>/dev/null
  for i in $(seq 1 120); do pgrep -f "[p]resto_server --etc_dir" >/dev/null || break; sleep 2; done
  touch "$M/pgo-n1-trained"
fi
ngcda=$(find build/pgo -name "*.gcda" 2>/dev/null | wc -l)
log "PGO node-$NODE profile: $ngcda .gcda (floor $MIN_GCDA, 3-node reference 868)"
[ "$ngcda" -ge "$MIN_GCDA" ] || { log "ABORT: profile too small, training did not really run"; exit 1; }

for arm in pgo pgolto; do
  [ -x "arms/$arm/presto_server" ] && { log "$arm present"; continue; }
  log "build $arm"
  ./scripts/build-arm48-run.sh "$arm" >> "$LOGS/p6-$arm.log" 2>&1 \
    || { log "$arm FAILED"; tail -8 "$LOGS/p6-$arm.log"; exit 1; }
  log "$arm md5=$(cut -d' ' -f1 arms/$arm/md5.txt 2>/dev/null)"
done

if [ ! -x arms/pgoltob/presto_server ]; then
  log "BOLT pgolto -> pgoltob, perf on node $NODE"
  start_coord || exit 1
  BOLT_NODE=$NODE ./scripts/bolt-arm48.sh pgolto >> "$LOGS/p6-bolt-pgolto.log" 2>&1 \
    || { log "pgoltob FAILED"; tail -10 "$LOGS/p6-bolt-pgolto.log"; exit 1; }
fi

# ========================== AutoFDO on node 1 ===============================
if [ ! -s "$PROF/presto.afdo" ]; then
  log "AutoFDO: perf LBR on a node-$NODE worker, full 3-worker cluster"
  BOLT_NODE=$NODE ./scripts/afdo-profile48.sh > "$LOGS/p6-afdo-profile.log" 2>&1 \
    || { log "afdo profile FAILED"; tail -20 "$LOGS/p6-afdo-profile.log" | cut -c1-160; exit 1; }
fi
log "presto.afdo: $(ls -la $PROF/presto.afdo 2>/dev/null | awk '{printf "%.1f MB", $5/1048576}') (96xl ref 11.8 MB)"

for arm in afdo afdolto; do
  [ -x "arms/$arm/presto_server" ] && { log "$arm present"; continue; }
  log "build $arm"
  ./scripts/build-arm48-run.sh "$arm" >> "$LOGS/p6-$arm.log" 2>&1 \
    || { log "$arm FAILED"; tail -8 "$LOGS/p6-$arm.log"; exit 1; }
  log "$arm md5=$(cut -d' ' -f1 arms/$arm/md5.txt 2>/dev/null)"
done

if [ ! -x arms/afdoltob/presto_server ]; then
  log "BOLT afdolto -> afdoltob, perf on node $NODE"
  start_coord || exit 1
  BOLT_NODE=$NODE ./scripts/bolt-arm48.sh afdolto >> "$LOGS/p6-bolt-afdolto.log" 2>&1 \
    || { log "afdoltob FAILED"; tail -10 "$LOGS/p6-bolt-afdolto.log"; exit 1; }
fi

log "arms: $(ls arms | tr '\n' ' ')"
for a in base pgo pgolto pgoltob afdo afdolto afdoltob; do
  printf '  %-10s %s\n' "$a" "$(cut -d' ' -f1 arms/$a/md5.txt 2>/dev/null)"
done
log "PHASE6_DONE"
