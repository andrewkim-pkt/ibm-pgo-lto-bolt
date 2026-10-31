#!/bin/bash
# Mirrored measurement: 4 arms x 3 rounds, Jantz's shape (4 concurrent streams x the 15
# CPU-heaviest queries at SF=1000), metric = queries/hour.
#
# Mirrored: odd rounds run the arms in list order, even rounds reversed, so any drift on
# the box hits each arm in both an early and a late slot.
# Resumable at (arm, round) granularity -- the host is stopped every ~25 min and a run is
# 16.3 min, so a stop costs at most one run. driver.py also checkpoints per query.
set -uo pipefail
R=/data/prestissimo-fdo
ARMS=${ARMS:-"base pgo pgolto pgoltob afdo afdolto afdoltob"}
ROUNDS=${ROUNDS:-4}
STREAMS=${STREAMS:-4}
SUMM=$R/results/tput-summary.tsv
JAVA_HOME=${JAVA_HOME:-$R/tools/jdk17}
SRV=$R/tools/presto-server-0.299
COORD_LOG=$R/cluster/coordinator/server.log
ulimit -n 524288
cd $R
log() { echo "[$(date -u +%H:%M)] $*"; }

start_arm() {   # $1 = arm; bring the 6 workers up on that binary
  local arm=$1 bin=$R/arms/$1/presto_server
  [ -x "$bin" ] || { log "missing $bin"; return 1; }
  echo "$arm" > $R/cluster/ACTIVE_ARM
  # Restart the COORDINATOR as well as the workers. Killing workers while the coordinator
  # survives leaves zombie tasks whose node URIs no longer resolve; abort() then throws
  # "scheme has not been set" in a tight retry loop that wrote server.log at ~160 MB/s and
  # reached 1.5 TB, filling the volume the 354 GB dataset is read from. That is what made
  # throughput decay 505 -> 465 q/h in wall-clock order across the first campaign.
  pkill -f "[p]resto_server --etc_dir" 2>/dev/null
  pkill -f "com.facebook.[p]resto.server.PrestoServer" 2>/dev/null
  sleep 8
  # '>' not '>>': the log starts empty for every arm.
  PATH=$JAVA_HOME/bin:$PATH nohup "$SRV/bin/launcher.py" \
      --etc-dir $R/cluster/coordinator/etc --data-dir $R/cluster/coordinator/data run \
      > "$COORD_LOG" 2>&1 &
  for i in $(seq 1 150); do
    curl -s http://127.0.0.1:8080/v1/info 2>/dev/null | grep -q '"starting":false' && break
    sleep 2
  done
  curl -s http://127.0.0.1:8080/v1/info 2>/dev/null | grep -q '"starting":false' \
      || { log "coordinator did not come up for $arm"; return 1; }
  for i in 0 1 2; do
    cpus=$(numactl -H | sed -n "s/^node $i cpus: //p" | tr -s ' ' ',' | sed 's/^,//;s/,$//')
    : > $R/cluster/worker$i/worker.log
    setsid numactl --physcpubind="$cpus" --preferred="$i" "$bin" \
        --etc_dir=$R/cluster/worker$i/etc >> $R/cluster/worker$i/worker.log 2>&1 &
  done
  for i in $(seq 1 90); do
    n=$(curl -s http://127.0.0.1:8080/v1/cluster 2>/dev/null | grep -oE '"activeWorkers":[0-9]+' | grep -oE '[0-9]+$')
    [ "${n:-0}" -eq 3 ] && return 0
    sleep 5
  done
  log "cluster did not reach 3 workers for $arm (saw ${n:-0})"; return 1
}

# activeWorkers==6 is NOT sufficient: Presto reports the nodes before they can accept
# tasks, so the first query of a run died with "No worker nodes available" /
# "sortedCandidates is null or empty" -- which is what invalidated every base run.
# Probe with a real query against a tiny table until it actually succeeds.
wait_schedulable() {
  for i in $(seq 1 60); do
    if python3 -I - <<'PY' 2>/dev/null
import json,urllib.request,time,sys
H={"X-Presto-User":"probe","X-Presto-Catalog":"hive","X-Presto-Schema":"tpcds"}
r=json.load(urllib.request.urlopen(urllib.request.Request(
    "http://127.0.0.1:8080/v1/statement", data=b"SELECT count(*) FROM reason", headers=H)))
while True:
    if "error" in r: sys.exit(1)
    n=r.get("nextUri")
    if not n: sys.exit(0)
    time.sleep(0.1); r=json.load(urllib.request.urlopen(n))
PY
    then return 0; fi
    sleep 5
  done
  return 1
}

# Discarded warm-up of the heaviest query before every timed run. See cmd_warm in
# driver.py -- this is what fixes the q50 "sortedCandidates is null or empty" start-up
# race that invalidated 10 of the first 13 runs, and it also removes the cold-cache swing
# on the single query that dominates the wall time.
# If the coordinator ever starts storming again, truncate rather than let it fill the
# volume the dataset lives on. 20 GiB is ~2 min of the observed 160 MB/s storm and far
# more than a healthy run produces (a few MB).
log_guard() {
  local sz
  sz=$(stat -c %s "$COORD_LOG" 2>/dev/null || echo 0)
  if [ "$sz" -gt 21474836480 ]; then
    truncate -s 0 "$COORD_LOG" 2>/dev/null
    log "WARNING coordinator log hit $((sz/1073741824)) GiB - truncated (storm is back)"
  fi
}

warm_arm() {
  for i in 1 2 3 4; do
    python3 -I $R/scripts/driver.py warm --list $R/results/queries-top.txt --n 1 --timeout 900 && return 0
    log "warm-up attempt $i failed, settling"
    sleep 20
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
    # Only a VALID run counts (all 60 query-executions succeeded). An invalid run is
    # wiped -- both its summary line and its per-query checkpoints -- so it genuinely
    # re-executes instead of resuming into a short wall time and an inflated q/h.
    if grep -q "^$label	.*valid=yes" "$SUMM" 2>/dev/null; then
      log "$label already measured (valid), skipping"; continue
    fi
    if grep -q "^$label	" "$SUMM" 2>/dev/null; then
      log "$label present but INVALID - discarding and re-running"
      grep -v "^$label	" "$SUMM" > "$SUMM.tmp" && mv "$SUMM.tmp" "$SUMM"
    fi
    rm -f $R/results/tput-$label.tsv
    [ -x $R/arms/$arm/presto_server ] || { log "$arm not built yet, skipping"; continue; }
    start_arm "$arm" || continue
    wait_schedulable || { log "$arm never became schedulable, skipping"; continue; }
    warm_arm || { log "$arm failed warm-up, skipping"; continue; }
    log "measuring $label"
    python3 -I $R/scripts/driver.py tput --list $R/results/queries-top.txt \
        --streams "$STREAMS" --label "$label" --out $R/results/tput-$label.tsv \
        --timeout 1800 2>&1 | tail -2
    log_guard
  done
done
log "MEASURE_DONE  $(wc -l < "$SUMM" 2>/dev/null || echo 0) runs recorded"
