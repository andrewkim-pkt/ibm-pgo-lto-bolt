#!/bin/bash
# Small-CPU-slice measurement: ONE worker pinned to a specific CPU list on node 0.
#
# WHY: the FDO gain on this workload grows as the topology shrinks -- 6 nodes was a flat
# null, 3 nodes gives +5.50%. These slices are the extreme end of that sweep:
#   SLICE=a  cpus 0-7,96-103   =  8 physical cores / 16 threads
#   SLICE=b  cpus 0-15,96-111  = 16 physical cores / 32 threads
# cpu N and cpu N+96 are SMT siblings (verified: cpu0 siblings 0,96 core_id=0), so both
# slices are WHOLE physical cores with both hyperthreads, entirely within node 0.
#
# SF=10, NOT SF=1000. At SF=1000 a 16-thread slice is ~12x less compute than the 192 threads
# the main campaign uses, which extrapolates to ~2.7 h PER RUN (~22 h for 8 runs) on a shared
# box. At SF=10 the working set still exceeds cache but fits node-0 memory, so the run stays
# CPU-BOUND -- which is the regime FDO actually helps, and the point of shrinking the slice.
# Absolute q/h is therefore NOT comparable to the SF=1000 campaigns; the DELTA is.
#
# REPS makes each run long enough that start-up transients do not dominate: a single SF=10
# pass once finished in 31 s and q/h then rose monotonically with execution order, which is
# pure cache warming and would fake a win for whichever arm ran last.
set -uo pipefail
R=/data/prestissimo-fdo
source $R/scripts/env-gnr.sh
SLICE=${SLICE:-a}
case "$SLICE" in
  a) CPUS="0-7,96-103";   CORES=8  ;;
  b) CPUS="0-15,96-111";  CORES=16 ;;
  *) echo "SLICE must be a or b"; exit 2 ;;
esac
ARMS=${ARMS:-"base pgoltob-native"}
ROUNDS=${ROUNDS:-4}
STREAMS=${STREAMS:-4}
REPS=${REPS:-3}
export PRESTO_SCHEMA=${PRESTO_SCHEMA:-tpcds10}
SUMM=$R/results/tput-slice$SLICE-summary.tsv
export TPUT_SUMMARY=$SUMM
LIST=$R/results/queries-top-x$REPS.txt
JAVA_HOME=${JAVA_HOME:-$R/tools/jdk17}
SRV=$R/tools/presto-server-0.299
COORD_LOG=$R/cluster/coordinator/server.log
ulimit -n 524288
cd "$R"
log() { echo "[$(date -u +%H:%M)] $*"; }

# build the repeated query list
: > "$LIST"
for i in $(seq 1 "$REPS"); do cat "$R/results/queries-top.txt" >> "$LIST"; done
log "slice=$SLICE cpus=$CPUS ($CORES cores/$((CORES*2)) threads) schema=$PRESTO_SCHEMA reps=$REPS queries=$(wc -l < "$LIST")"

start_arm() {
  local arm=$1 bin=$R/arms/$1/presto_server
  [ -x "$bin" ] || { log "missing $bin"; return 1; }
  # Restart the coordinator too: leaving it up across arms leaves zombie tasks whose node
  # URIs no longer resolve, and abort() then throws "scheme has not been set" in a tight
  # loop that once wrote server.log at ~160 MB/s and filled a 2 TB volume.
  pkill -f "[p]resto_server --etc_dir" 2>/dev/null
  pkill -f "com.facebook.[p]resto.server.PrestoServer" 2>/dev/null
  sleep 8
  PATH=$JAVA_HOME/bin:$PATH nohup "$SRV/bin/launcher.py" \
      --etc-dir $R/cluster/coordinator/etc --data-dir $R/cluster/coordinator/data run \
      > "$COORD_LOG" 2>&1 &
  for i in $(seq 1 150); do
    curl -s http://127.0.0.1:8080/v1/info 2>/dev/null | grep -q '"starting":false' && break
    sleep 2
  done
  curl -s http://127.0.0.1:8080/v1/info 2>/dev/null | grep -q '"starting":false' \
      || { log "coordinator did not start"; return 1; }
  : > $R/cluster/worker0/worker.log
  # --preferred, never --membind: a hard membind to one node OOMs on this hardware.
  setsid numactl --physcpubind="$CPUS" --preferred=0 "$bin" \
      --etc_dir=$R/cluster/worker0/etc >> $R/cluster/worker0/worker.log 2>&1 &
  local n=0
  for i in $(seq 1 150); do   # EXACT 1, never >=: a just-killed node lingers in the list
    n=$(curl -s http://127.0.0.1:8080/v1/cluster 2>/dev/null \
        | grep -oE '"activeWorkers":[0-9]+' | grep -oE '[0-9]+$')
    [ "${n:-0}" -eq 1 ] && return 0
    sleep 5
  done
  log "worker never reached exactly 1 for $arm (saw ${n:-0})"; return 1
}

# Untimed warm-up of the FULL set: fixes the "sortedCandidates is null or empty" start-up
# race AND removes the cold-cache swing that once made base-r1 195.8 vs 505 q/h.
warm_arm() {
  for i in 1 2 3; do
    PRESTO_SCHEMA=$PRESTO_SCHEMA python3 -I $R/scripts/driver.py warm \
        --list $R/results/queries-top.txt --n 15 --timeout 1800 && return 0
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
    rm -f $R/results/tput-slice$SLICE-$label.tsv
    [ -x $R/arms/$arm/presto_server ] || { log "$arm not built, skipping"; continue; }
    start_arm "$arm" || continue
    warm_arm || { log "$arm failed warm-up, skipping"; continue; }
    log "measuring $label"
    python3 -I $R/scripts/driver.py tput --list "$LIST" \
        --streams "$STREAMS" --label "$label" \
        --out $R/results/tput-slice$SLICE-$label.tsv --timeout 3600 2>&1 | tail -2
    sz=$(stat -c %s "$COORD_LOG" 2>/dev/null || echo 0)
    [ "$sz" -gt 21474836480 ] && { truncate -s 0 "$COORD_LOG"; log "WARNING coord log storm"; }
  done
done
log "SLICE${SLICE}_DONE  $(wc -l < "$SUMM" 2>/dev/null || echo 0) runs"
