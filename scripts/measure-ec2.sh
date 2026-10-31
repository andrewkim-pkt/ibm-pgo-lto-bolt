#!/bin/bash
# EC2-equivalent core-count points on the GNR box, at SF=1000 (NO scale confound).
#
# This box: 3 NUMA nodes x 32 physical cores = 64 logical cpus per node, 192 total.
#   node 0 = logical 0-31  + 96-127
#   node 1 = logical 32-63 + 128-159
#   node 2 = logical 64-95 + 160-191
#
# SIZE=16xl  r8i.16xl = 64 vCPU  -> node 0 entirely, ONE worker, 1 NUMA node. Exact fit.
# SIZE=24xl  r8i.24xl = 96 vCPU  -> 48 cores over TWO nodes (24 each), two workers, which
#            matches the real 24xl's 2-NUMA-node layout.
#
# SF=1000 is affordable here (~41 min/run at 64 cpu, ~27 at 96) unlike the 8/16-core slices,
# which had to use SF=10 and therefore carry a scale confound alongside the core count.
# That makes these two points directly comparable to the 6/3/2-node SF=1000 results.
set -uo pipefail
R=/data/prestissimo-fdo
source $R/scripts/env-gnr.sh
SIZE=${SIZE:-16xl}
case "$SIZE" in
  16xl) WORKER_CPUS=("0-15,96-111" "32-47,128-143"); WORKER_NODES=(0 1); VCPU=64 ;;
  24xl) WORKER_CPUS=("0-23,96-119" "32-55,128-151"); WORKER_NODES=(0 1); VCPU=96 ;;
  *) echo "SIZE must be 16xl or 24xl"; exit 2 ;;
esac
NW=${#WORKER_CPUS[@]}
ARMS=${ARMS:-"base pgoltob"}
ROUNDS=${ROUNDS:-4}
STREAMS=${STREAMS:-4}
export PRESTO_SCHEMA=${PRESTO_SCHEMA:-tpcds}
LIST=$R/results/queries-top.txt
SUMM=$R/results/tput-$SIZE-summary.tsv
export TPUT_SUMMARY=$SUMM
JAVA_HOME=${JAVA_HOME:-$R/tools/jdk17}
SRV=$R/tools/presto-server-0.299
COORD_LOG=$R/cluster/coordinator/server.log
ulimit -n 524288
cd "$R"
log() { echo "[$(date -u +%H:%M)] $*"; }
log "SIZE=$SIZE ($VCPU vCPU, $NW worker(s)) schema=$PRESTO_SCHEMA streams=$STREAMS rounds=$ROUNDS"
for i in $(seq 0 $((NW-1))); do log "  worker$i node ${WORKER_NODES[$i]} cpus ${WORKER_CPUS[$i]}"; done

start_arm() {
  local arm=$1 bin=$R/arms/$1/presto_server
  [ -x "$bin" ] || { log "missing $bin"; return 1; }
  # Restart the coordinator per arm: leaving it up leaves zombie tasks whose node URIs no
  # longer resolve, and abort() then throws "scheme has not been set" in a tight loop that
  # once wrote server.log at ~160 MB/s and filled a 2 TB volume.
  pkill -f "[p]resto_server --etc_dir" 2>/dev/null
  pkill -f "com.facebook.[p]resto.server.PrestoServer" 2>/dev/null
  sleep 20
  for _w in $(seq 1 30); do ss -ltn 2>/dev/null | grep -qE ":(7771|7772|7773)" || break; sleep 2; done
  PATH=$JAVA_HOME/bin:$PATH nohup "$SRV/bin/launcher.py" \
      --etc-dir $R/cluster/coordinator/etc --data-dir $R/cluster/coordinator/data run \
      > "$COORD_LOG" 2>&1 &
  for i in $(seq 1 150); do
    curl -s http://127.0.0.1:8080/v1/info 2>/dev/null | grep -q '"starting":false' && break
    sleep 2
  done
  curl -s http://127.0.0.1:8080/v1/info 2>/dev/null | grep -q '"starting":false' \
      || { log "coordinator did not start"; return 1; }
  for i in $(seq 0 $((NW-1))); do
    : > $R/cluster/worker$i/worker.log
    # --preferred, never --membind: a hard membind to one node OOMs on this hardware.
    setsid numactl --physcpubind="${WORKER_CPUS[$i]}" --preferred="${WORKER_NODES[$i]}" "$bin" \
        --etc_dir=$R/cluster/worker$i/etc >> $R/cluster/worker$i/worker.log 2>&1 &
  done
  local n=0
  for i in $(seq 1 150); do   # EXACT count, never >=: a just-killed node lingers in the list
    n=$(curl -s http://127.0.0.1:8080/v1/cluster 2>/dev/null \
        | grep -oE '"activeWorkers":[0-9]+' | grep -oE '[0-9]+$')
    [ "${n:-0}" -eq "$NW" ] && return 0
    sleep 5
  done
  log "workers reached ${n:-0}, wanted $NW"; return 1
}

# Untimed warm-up of the heaviest query: fixes the "sortedCandidates is null or empty"
# start-up race AND the cold-cache swing that once made base-r1 195.8 vs 505 q/h.
warm_arm() {
  for i in 1 2 3; do
    python3 -I $R/scripts/driver.py warm --list "$LIST" --n 1 --timeout 1800 && return 0
    log "warm-up attempt $i failed, settling"; sleep 20
  done
  return 1
}

read -ra A <<< "$ARMS"
for r in $(seq 1 "$ROUNDS"); do
  order=("${A[@]}")
  if [ $(( r % 2 )) -eq 0 ]; then
    order=(); for ((i=${#A[@]}-1; i>=0; i--)); do order+=("${A[$i]}"); done
  fi
  log "=== round $r/$ROUNDS order: ${order[*]} ==="
  for arm in "${order[@]}"; do
    label="$arm-r$r"
    if grep -q "^$label	.*valid=yes" "$SUMM" 2>/dev/null; then
      log "$label already valid, skipping"; continue
    fi
    grep -q "^$label	" "$SUMM" 2>/dev/null && {
      log "$label present but INVALID - discarding"
      grep -v "^$label	" "$SUMM" > "$SUMM.tmp" && mv "$SUMM.tmp" "$SUMM"; }
    rm -f $R/results/tput-$SIZE-$label.tsv
    [ -x $R/arms/$arm/presto_server ] || { log "ARM $arm NOT BUILT - skipping (check the name!)"; continue; }
    start_arm "$arm" || continue
    warm_arm || { log "$arm failed warm-up, skipping"; continue; }
    log "measuring $label"
    python3 -I $R/scripts/driver.py tput --list "$LIST" \
        --streams "$STREAMS" --label "$label" \
        --out $R/results/tput-$SIZE-$label.tsv --timeout 7200 2>&1 | tail -2
    sz=$(stat -c %s "$COORD_LOG" 2>/dev/null || echo 0)
    [ "$sz" -gt 21474836480 ] && { truncate -s 0 "$COORD_LOG"; log "WARNING coord log storm"; }
  done
done
log "${SIZE}_DONE  $(grep -c valid=yes "$SUMM" 2>/dev/null || echo 0)/$(( ${#A[@]} * ROUNDS )) valid"
