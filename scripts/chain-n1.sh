#!/bin/bash
# Round 2: everything pinned to NUMA node 1. Runs unattended in this order, because the
# stages cannot safely overlap:
#   profiles (quiet box) -> builds (whole box, untimed) -> BOLT perf (quiet) -> measure (quiet)
# base is NOT rebuilt: it carries no profile, so it is the same binary as round 1 and
# stays the common reference.
cd /data/velox-fdo
log() { echo "[$(date -u +%H:%M)] $*"; }

# --- wait for the two jobs already in flight ---
log "waiting for node-1 AutoFDO profile + pgo-gen build"
for i in $(seq 1 240); do
  a=$(grep -c AFDO_TRAIN_DONE logs/train-afdo-n1.log 2>/dev/null)
  b=$(grep -c ARM_pgo-gen_BUILD_DONE logs/build-pgo-gen-n1.log 2>/dev/null)
  [ "$a" = "1" ] && [ "$b" = "1" ] && break
  grep -qE "REJECTED|TOO SMALL|PERF RUN FAILED|ninja failed" logs/train-afdo-n1.log logs/build-pgo-gen-n1.log 2>/dev/null \
      && { log "PREREQ FAILED"; exit 1; }
  sleep 15
done
log "prereqs ready (afdo profile $(stat -c%s prof/velox.afdo) bytes)"

# --- PGO training, node 1, node-1 concurrency (48 drivers) ---
# Still SF=10: an instrumented pass over SF=100 is intractable (~375x). Concurrency now
# MATCHES the measurement even though the scale factor does not.
log "PGO training (node 1, SF=10, node-1 concurrency)"
NODE=1 DATA=/data/velox-fdo/tpch-sf10 WL_CACHE_GB=32 \
  ./scripts/train.sh pgo > logs/train-pgo-n1.log 2>&1 || { log "PGO TRAIN FAILED"; exit 1; }
log "PGO training done: $(grep PGO_TRAIN_DONE logs/train-pgo-n1.log)"

# --- builds (whole box; untimed, so unpinned is fine and faster) ---
for a in afdo afdolto pgo pgolto; do
  log "build $a"
  ./scripts/build-arm-run.sh "$a" > logs/build-$a-n1.log 2>&1 \
     || { log "BUILD $a FAILED"; exit 1; }
  log "build $a done"
done

# --- BOLT, node-1 perf records ---
for a in pgo pgolto afdo afdolto; do
  log "BOLT $a"
  NODE=1 ./scripts/bolt-arm-run.sh "$a" > logs/bolt-$a-n1.log 2>&1 || { log "BOLT $a FAILED"; exit 1; }
  rm -f prof/bolt-$a/perf.data
  log "BOLT $a done"
done

./scripts/inventory.sh > results/inventory-n1.txt 2>/dev/null
log "all 9 arms ready"

# --- mirrored measurement, node 1 ---
log "measurement: 9 arms x 6 mirrored rounds, node 1"
NODE=1 ROUNDS=6 BM_MIN_ITERS=1 BM_MAX_SECS=5 CAMPAIGN=velox-fdo-9arm-node1 \
  ./scripts/bench-run.sh > logs/bench-n1.log 2>&1
log "measurement finished"
python3 -I scripts/analyze.py results/velox-fdo-9arm-node1 > results/velox-fdo-9arm-node1/summary.md 2>&1
python3 -I scripts/analyze-paired.py results/velox-fdo-9arm-node1 > results/velox-fdo-9arm-node1/paired.md 2>&1
python3 -I scripts/analyze-base.py results/velox-fdo-9arm-node1 > results/velox-fdo-9arm-node1/base-and-aa.md 2>&1
log "CHAIN_N1_DONE"
