#!/bin/bash
# Chain: wait for PGO training, then build pgo -> pgolto -> (BOLT) pgoltob.
#
# All three share build/pgo, which is also where training left the .gcda. Rebuilding with
# -fprofile-use only replaces the .o files; the .gcda sit alongside and are re-read by each
# arm. PGO_USE already carries -fprofile-correction (counts are racy BY DESIGN -- see
# -fprofile-update=single in train-pgo.sh) and -Wno-error=coverage-mismatch, needed once
# -flto changes inlining relative to the instrumented build.
#
# bolt-arm96.sh is deliberately NOT modified: it produced the existing afdoltob arm, and
# changing its profiling would make pgoltob non-comparable to it. It does however wait on
# `activeWorkers >= 1`, which a stale just-killed node can satisfy (that trap once cost six
# training queries), and it never restarts the coordinator. So we hand it a FRESH
# coordinator with an empty node list, which makes the >= safe without touching its logic.
set -uo pipefail
R=/data/velox-fdo
JAVA_HOME=${JAVA_HOME:-$R/tools/jdk17}
SRV=$R/tools/presto-server-0.299
log() { echo "[$(date -u +%H:%M)] $*"; }

while pgrep -f "[t]rain-pgo" > /dev/null; do sleep 30; done
log "training finished"

n=$(find "$R/build/pgo" -name "*.gcda" 2>/dev/null | wc -l)
log "profile: $n .gcda files"
[ "$n" -gt 0 ] || { log "ABORT: no profile, refusing to build a fake pgo arm"; exit 1; }

for arm in pgo pgolto; do
  if [ -x "$R/arms/$arm/presto_server" ]; then
    log "$arm already built, skipping"
    continue
  fi
  log "build $arm"
  if "$R/scripts/build-arm96-run.sh" "$arm" >> "$R/logs/build96-$arm.log" 2>&1; then
    log "$arm done  md5=$(cut -d' ' -f1 "$R/arms/$arm/md5.txt" 2>/dev/null)"
  else
    log "$arm FAILED"; tail -6 "$R/logs/build96-$arm.log"; exit 1
  fi
done

if [ ! -x "$R/arms/pgoltob/presto_server" ]; then
  log "restarting coordinator so BOLT's activeWorkers>=1 cannot match a stale node"
  pkill -f "[p]resto_server --etc_dir" 2>/dev/null
  pkill -f "com.facebook.[p]resto.server.PrestoServer" 2>/dev/null
  sleep 8
  ulimit -n 524288
  PATH=$JAVA_HOME/bin:$PATH nohup "$SRV/bin/launcher.py" \
      --etc-dir "$R/cluster/coordinator/etc" --data-dir "$R/cluster/coordinator/data" run \
      > "$R/cluster/coordinator/server.log" 2>&1 &
  for i in $(seq 1 150); do
    curl -s http://127.0.0.1:8080/v1/info 2>/dev/null | grep -q '"starting":false' && break
    sleep 2
  done
  curl -s http://127.0.0.1:8080/v1/info 2>/dev/null | grep -q '"starting":false' \
      || { log "ABORT: coordinator did not start"; exit 1; }
  log "coordinator up (0 workers registered)"

  log "BOLT pgolto -> pgoltob (perf at SF=1000, same as afdoltob)"
  if "$R/scripts/bolt-arm96.sh" pgolto >> "$R/logs/bolt96-pgolto.log" 2>&1; then
    log "pgoltob done"
  else
    log "pgoltob FAILED"; tail -6 "$R/logs/bolt96-pgolto.log"; exit 1
  fi
fi

log "PGO_ARMS_READY: $(ls "$R/arms" | tr '\n' ' ')"
