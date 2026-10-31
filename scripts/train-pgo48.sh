#!/bin/bash
# Instrumented PGO training for Prestissimo.
#
# BACKGROUND -- why this works now when it didn't before.
# Instrumented PGO was abandoned because an instrumented presto_server could not finish
# TPC-DS q01 at SF=1 in 300 s. The cause was NOT the counters' memory cost (measured:
# .data +94 MB, .bss +50 MB, .text +90 MB => ~235 MB/process, 0.05% of this box's 3 TB)
# but ATOMIC counter updates. Verified on this box:
#     gcc-15 -fprofile-generate -pthread                        -> lock-prefixed increments
#     gcc-15 -fprofile-generate -pthread -fprofile-update=single -> none
# Presto/Velox compiles with -pthread, so gcc silently chose atomics and every hot arc
# became a `lock add` on a SHARED cache line with ~64 threads/worker across 384 vCPUs.
# Rebuilt with -fprofile-update=single: 2053 gcov counter sites in PeriodicTaskManager.o,
# ZERO with a lock prefix. Measured overhead fell from >300x to ~4.8x (SF=1, 16 CPUs,
# q19/q50/q13: 3.5 s -> 16.8 s). -fprofile-correction handles the resulting racy counts.
#
# NWORKERS defaults to the full 6, one per NUMA node, because a single worker produces NO
# remote exchanges -- the profile would miss the shuffle/exchange paths that are hot in the
# measured 6-worker configuration. All workers write .gcda into the same object dirs;
# libgcov locks and SUMS them, which is the normal multi-process training path.
#
# TRAP: gcov writes .gcda from an atexit() handler. SIGKILL produces NOTHING, so the
# workers are stopped with SIGTERM and we verify the files appeared.
# TRAP: wait for activeWorkers to EQUAL NWORKERS, never >= -- a just-killed node lingers in
# the coordinator's node list and tasks get scheduled onto it (cost six training queries).
set -uo pipefail
R=/data/velox-fdo
ARM=${ARM:-pgo-gen}
BIN=$R/arms/$ARM/presto_server
SCHEMA=${SCHEMA:-tpcds10}
NWORKERS=${NWORKERS:-3}
NCPU=${NCPU:-0}            # 0 = all CPUs of the node; otherwise first NCPU of it
LIST=${LIST:-$R/results/queries-top.txt}
TMO=${TMO:-1800}
JAVA_HOME=${JAVA_HOME:-$R/tools/jdk17}
SRV=$R/tools/presto-server-0.299
OUT=$R/results/train-pgo.tsv
ulimit -n 524288
cd "$R"
log() { echo "[$(date -u +%H:%M:%S)] $*"; }

[ -x "$BIN" ] || { log "missing $BIN"; exit 1; }
log "arm=$ARM schema=$SCHEMA workers=$NWORKERS ncpu=$NCPU timeout=${TMO}s"

# --- fresh coordinator --------------------------------------------------------
pkill -f "[p]resto_server --etc_dir" 2>/dev/null
pkill -f "com.facebook.[p]resto.server.PrestoServer" 2>/dev/null
sleep 8
PATH=$JAVA_HOME/bin:$PATH nohup "$SRV/bin/launcher.py" \
    --etc-dir "$R/cluster/coordinator/etc" --data-dir "$R/cluster/coordinator/data" run \
    > "$R/cluster/coordinator/server.log" 2>&1 &
for i in $(seq 1 150); do
  curl -s http://127.0.0.1:8080/v1/info 2>/dev/null | grep -q '"starting":false' && break
  sleep 2
done
curl -s http://127.0.0.1:8080/v1/info 2>/dev/null | grep -q '"starting":false' \
    || { log "coordinator did not start"; exit 1; }
log "coordinator up"

# --- instrumented workers, one per NUMA node ----------------------------------
for i in $(seq 0 $((NWORKERS-1))); do
  cpus=$(numactl -H | sed -n "s/^node $i cpus: //p" | tr -s ' ' ',' | sed 's/^,//;s/,$//')
  if [ "$NCPU" -gt 0 ]; then
    cpus=$(printf '%s' "$cpus" | tr ',' '\n' | head -"$NCPU" | paste -sd,)
  fi
  : > "$R/cluster/worker$i/worker.log"
  setsid numactl --physcpubind="$cpus" --preferred="$i" "$BIN" \
      --etc_dir="$R/cluster/worker$i/etc" >> "$R/cluster/worker$i/worker.log" 2>&1 &
done

n=0
for i in $(seq 1 150); do
  n=$(curl -s http://127.0.0.1:8080/v1/cluster 2>/dev/null \
      | grep -oE '"activeWorkers":[0-9]+' | grep -oE '[0-9]+$')
  [ "${n:-0}" -eq "$NWORKERS" ] && break
  sleep 5
done
[ "${n:-0}" -eq "$NWORKERS" ] || { log "ABORT activeWorkers=${n:-0} (want exactly $NWORKERS)"; exit 1; }
log "$NWORKERS workers active"

# --- training queries ---------------------------------------------------------
: > "$OUT"
ok=0; bad=0; t_all=$(date +%s)
while read -r q; do
  [ -n "$q" ] || continue
  printf '%s\n' "$q" > /tmp/one-query.txt
  t0=$(date +%s)
  PRESTO_SCHEMA=$SCHEMA python3 -I "$R/scripts/driver.py" warm \
      --list /tmp/one-query.txt --n 1 --timeout "$TMO" > /tmp/train-q.out 2>&1
  rc=$?
  t1=$(date +%s)
  log "$q rc=$rc $((t1-t0))s $(tail -1 /tmp/train-q.out | cut -c1-66)"
  printf '%s\t%s\t%s\n' "$q" "$rc" "$((t1-t0))" >> "$OUT"
  [ "$rc" -eq 0 ] && ok=$((ok+1)) || bad=$((bad+1))
done < "$LIST"
log "queries ok=$ok failed=$bad in $(( $(date +%s)-t_all ))s"

# --- flush the profile --------------------------------------------------------
log "SIGTERM workers so gcov's atexit handler writes the .gcda"
pkill -TERM -f "[p]resto_server --etc_dir" 2>/dev/null
for i in $(seq 1 120); do
  pgrep -f "[p]resto_server --etc_dir" > /dev/null || break
  sleep 2
done
pgrep -f "[p]resto_server --etc_dir" > /dev/null \
    && log "WARNING workers still alive after 240 s; .gcda may be incomplete"
ngcda=$(find "$R/build/pgo" -name "*.gcda" 2>/dev/null | wc -l)
szgcda=$(find "$R/build/pgo" -name "*.gcda" -printf '%s\n' 2>/dev/null | awk '{s+=$1} END{printf "%.1f", s/1048576}')
log "TRAIN_PGO_DONE gcda=$ngcda files ${szgcda:-0} MB"
[ "$ARM" != pgo-gen ] || [ "$ngcda" -gt 0 ] \
    || { log "FAILED: no .gcda written (gcov did not flush)"; exit 1; }
