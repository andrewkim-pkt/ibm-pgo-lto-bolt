#!/bin/bash
# Phase 4: bring up the 3-worker cluster on `base`, register the 24 SF=1000 tables, and
# validate a real query end-to-end. Nothing downstream is trustworthy until a query returns
# correct results, so this phase is the gate before any FDO work.
#
# Blockers encoded:
#  * ulimit -n 524288 IN THE SPAWNING SHELL. 974 parquet files will otherwise kill workers
#    with "out of file descriptors"; setting it inside a function did not take.
#  * presto.version must match the coordinator EXACTLY -- it is a git-describe
#    (0.299-7d50721), not 0.299. A mismatch silently excludes workers from the ACTIVE set
#    and the only symptom is "Insufficient active worker nodes ... 0 workers are active".
#  * Wait for activeWorkers to EQUAL the worker count, never >=.
set -uo pipefail
R=/data/velox-fdo
source $R/scripts/env48.sh
M=$R/.markers
WORKERS=${WORKERS:-3}
ulimit -n 524288
log() { echo "[$(date -u +%H:%M)] $*"; }
cd "$R"

log "ulimit -n = $(ulimit -n)  workers=$WORKERS"

if [ ! -f "$M/cluster-setup" ]; then
  log "cluster setup (coordinator etc + $WORKERS worker etc dirs)"
  WORKERS=$WORKERS ./scripts/cluster48.sh setup > "$LOGS/p48-setup.log" 2>&1 \
    || { log "setup FAILED"; tail -15 "$LOGS/p48-setup.log"; exit 1; }
  touch "$M/cluster-setup"
fi
log "coordinator version in worker config: $(grep -h presto.version cluster/worker0/etc/node.properties 2>/dev/null)"

log "starting cluster on base"
WORKERS=$WORKERS ./scripts/cluster48.sh start base > "$LOGS/p48-start.log" 2>&1 \
  || { log "start returned nonzero"; tail -15 "$LOGS/p48-start.log"; }

n=0
for i in $(seq 1 120); do
  n=$(curl -s http://127.0.0.1:8080/v1/cluster 2>/dev/null \
      | grep -oE '"activeWorkers":[0-9]+' | grep -oE '[0-9]+$')
  [ "${n:-0}" -eq "$WORKERS" ] && break
  sleep 5
done
log "activeWorkers=${n:-0} (want exactly $WORKERS)"
[ "${n:-0}" -eq "$WORKERS" ] || { log "ABORT: cluster not ready"; tail -20 cluster/worker0/worker.log | cut -c1-160; exit 1; }

if [ ! -f "$M/tables-registered" ]; then
  log "registering 24 SF=1000 tables as hive.tpcds"
  python3 -I scripts/reg1000.py > "$LOGS/p48-reg1000.log" 2>&1 \
    || { log "registration FAILED"; tail -15 "$LOGS/p48-reg1000.log"; exit 1; }
  touch "$M/tables-registered"
fi
log "registration: $(grep -c OK "$LOGS/p48-reg1000.log" 2>/dev/null || echo "?") OK lines"

log "=== VALIDATION ==="
log "store_sales rowcount (canonical 2,879,987,999):"
./scripts/cluster48.sh sql "SELECT count(*) FROM hive.tpcds.store_sales" 2>&1 | tail -2
log "q19 end-to-end:"
python3 -I scripts/driver.py warm --list <(echo q19.sql) --n 1 --timeout 1800 2>&1 | tail -2

log "PHASE4_DONE"
