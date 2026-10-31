#!/bin/bash
# SINGLE-NUMA-NODE Prestissimo measurement -- the arm that was never tested.
#
# WHY: every gcc FDO configuration was a null on the 6-node whole box (afdo -0.10,
# afdolto -3.39, afdoltob -2.46, pgo +0.36, pgolto -0.73, pgoltob -0.76, noise floor 0.76%).
# That matches the Velox campaign's WHOLE-BOX null rather than its pinned result: there,
# whole-box was also flat and only node-1 pinning revealed pgolto +6.18%, with the whole-box
# run burning ~half its CPU in the kernel (sys 1,966 s vs user 1,942 s, against
# sys 245 s / user 4,048 s pinned). Hypothesis: whole-box NUMA/kernel overhead dominates and
# masks FDO gains. This script is the direct analogue of the experiment that falsified the
# Velox null.
#
# Deliberate deviations from the whole-box campaign, and why:
#   * ONE worker on node 1 (not 6 across 6 nodes) -- that IS the independent variable.
#   * Coordinator pinned to node 0 so the Java process cannot steal node-1 cores.
#   * SF=10, not SF=1000: one node has 1/6 of the box's cores, and SF=10 (4.4 GB) fits in
#     node-local memory, keeping the run CPU-bound. At SF=1000 a single node would be
#     EBS-bound, which is the regime that produced the null in the first place.
# So this is NOT comparable to the 505 q/h whole-box number -- it answers a different
# question: "does FDO pay off once NUMA/kernel overhead is removed?"
#
# Results go to their own summary so the whole-box campaign is never clobbered.
set -uo pipefail
R=/data/velox-fdo
ARMS=${ARMS:-"base pgo pgolto pgoltob"}
ROUNDS=${ROUNDS:-4}
STREAMS=${STREAMS:-4}
NODE=${NODE:-1}
COORD_NODE=${COORD_NODE:-0}
export PRESTO_SCHEMA=${PRESTO_SCHEMA:-tpcds10}
SUMM=$R/results/tput-pinned-summary.tsv
export TPUT_SUMMARY=$SUMM   # driver.py writes its summary line here, not to the whole-box file
JAVA_HOME=${JAVA_HOME:-$R/tools/jdk17}
SRV=$R/tools/presto-server-0.299
COORD_LOG=$R/cluster/coordinator/server.log
ulimit -n 524288
cd "$R"
log() { echo "[$(date -u +%H:%M)] $*"; }

NODE_CPUS=$(numactl -H | sed -n "s/^node $NODE cpus: //p" | tr -s ' ' ',' | sed 's/^,//;s/,$//')
COORD_CPUS=$(numactl -H | sed -n "s/^node $COORD_NODE cpus: //p" | tr -s ' ' ',' | sed 's/^,//;s/,$//')
log "worker node=$NODE schema=$PRESTO_SCHEMA streams=$STREAMS rounds=$ROUNDS"

start_arm() {
  local arm=$1 bin=$R/arms/$1/presto_server
  [ -x "$bin" ] || { log "missing $bin"; return 1; }
  echo "$arm" > $R/cluster/ACTIVE_ARM
  # Coordinator restarts per arm too: leaving it up across arms leaves zombie tasks whose
  # node URIs no longer resolve, and abort() then throws "scheme has not been set" in a
  # tight loop that wrote server.log at ~160 MB/s and filled the volume (10-20).
  pkill -f "[p]resto_server --etc_dir" 2>/dev/null
  pkill -f "com.facebook.[p]resto.server.PrestoServer" 2>/dev/null
  sleep 8
  PATH=$JAVA_HOME/bin:$PATH nohup numactl --physcpubind="$COORD_CPUS" --preferred="$COORD_NODE" \
      "$SRV/bin/launcher.py" \
      --etc-dir $R/cluster/coordinator/etc --data-dir $R/cluster/coordinator/data run \
      > "$COORD_LOG" 2>&1 &
  for i in $(seq 1 150); do
    curl -s http://127.0.0.1:8080/v1/info 2>/dev/null | grep -q '"starting":false' && break
    sleep 2
  done
  curl -s http://127.0.0.1:8080/v1/info 2>/dev/null | grep -q '"starting":false' \
      || { log "coordinator did not come up for $arm"; return 1; }

  : > $R/cluster/worker0/worker.log
  # --preferred, NOT --membind: a hard membind to one node OOMs on this hardware (the
  # worker config asks for system-memory-gb=440), and the campaign already has a recorded
  # case of --membind=1 OOMing where --preferred=1 was fine.
  setsid numactl --physcpubind="$NODE_CPUS" --preferred="$NODE" "$bin" \
      --etc_dir=$R/cluster/worker0/etc >> $R/cluster/worker0/worker.log 2>&1 &
  # EXACT 1, never >=1: a just-killed node lingers in the coordinator's list and tasks get
  # scheduled onto it.
  local n=0
  for i in $(seq 1 120); do
    n=$(curl -s http://127.0.0.1:8080/v1/cluster 2>/dev/null \
        | grep -oE '"activeWorkers":[0-9]+' | grep -oE '[0-9]+$')
    [ "${n:-0}" -eq 1 ] && return 0
    sleep 5
  done
  log "worker never reached exactly 1 for $arm (saw ${n:-0})"; return 1
}

# Untimed warm-up of the heaviest query: fixes the "sortedCandidates is null or empty"
# start-up race AND removes the cold-cache swing that made base-r1 195.8 vs 505 q/h.
warm_arm() {
  for i in 1 2 3 4; do
    python3 -I $R/scripts/driver.py warm --list $R/results/queries-top.txt --n 1 --timeout 900 \
      && return 0
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
      log "$label already measured (valid), skipping"; continue
    fi
    if grep -q "^$label	" "$SUMM" 2>/dev/null; then
      log "$label present but INVALID - discarding and re-running"
      grep -v "^$label	" "$SUMM" > "$SUMM.tmp" && mv "$SUMM.tmp" "$SUMM"
    fi
    rm -f $R/results/tput-pinned-$label.tsv
    [ -x $R/arms/$arm/presto_server ] || { log "$arm not built, skipping"; continue; }
    start_arm "$arm" || continue
    warm_arm || { log "$arm failed warm-up, skipping"; continue; }
    log "measuring $label (node $NODE, $PRESTO_SCHEMA)"
    python3 -I $R/scripts/driver.py tput --list $R/results/queries-top.txt \
        --streams "$STREAMS" --label "$label" --out $R/results/tput-pinned-$label.tsv \
        --timeout 1800 2>&1 | tail -2
    sz=$(stat -c %s "$COORD_LOG" 2>/dev/null || echo 0)
    [ "$sz" -gt 21474836480 ] && { truncate -s 0 "$COORD_LOG"; log "WARNING coord log storm"; }
  done
done
log "PINNED_DONE  $(wc -l < "$SUMM" 2>/dev/null || echo 0) runs recorded"
