#!/bin/bash
# MAX-STACK run: -march=native x (instrumented PGO | hardware-sampled AutoFDO) + LTO + BOLT.
# Target is akim's +10% vs base. FDO alone gives +5.50% here (Jantz's icx HW PGO: +3.5%), so
# the remaining headroom is most likely architectural.
#
# EVERY arm so far was built with only "-O3 -g" -- no -march/-mtune -- i.e. x86-64 BASELINE
# code on a Granite Rapids box (gcc -march=native => graniterapids). For a vectorised
# columnar engine that is a large untapped, FDO-independent lever.
#
# Five measured arms separate the contributions cleanly:
#   base             today's reference (generic -O3)
#   base-native      ARCH alone
#   pgoltob          FDO alone                      (+5.50% already measured)
#   pgoltob-native   ARCH + instrumented PGO+LTO+BOLT   <- best shot at >=10%
#   afdoltob-native  ARCH + HARDWARE-SAMPLED FDO+LTO+BOLT  <- the "HW PGO" framing
#
# Separate BDIRs (build/base-native, build/pgo-native, build/afdo-native) so the generic
# campaign's 830-.gcda profile and presto.afdo are never touched.
set -uo pipefail
source /data/prestissimo-fdo/scripts/env-gnr.sh
M=$ROOT/.markers
JAVA_HOME=${JAVA_HOME:-$ROOT/tools/jdk17}
SRV=$ROOT/tools/presto-server-0.299
MIN_GCDA=${MIN_GCDA:-400}
ulimit -n 524288
cd "$ROOT"
log() { echo "[$(date -u +%H:%M)] $*"; }

# do not contend with the 2-node campaign
while pgrep -f "[m]easure-2node-run" > /dev/null; do sleep 120; done
log "2-node campaign done ($(grep -c valid=yes results/tput-2node-summary.tsv 2>/dev/null || echo 0)/8 valid)"

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
build() {
  local arm=$1
  [ -x "arms/$arm/presto_server" ] && { log "$arm present"; return 0; }
  log "build $arm"
  ./scripts/build-arm-gnr.sh "$arm" >> "$LOGS/build-$arm.log" 2>&1 \
    || { log "$arm FAILED"; tail -12 "$LOGS/build-$arm.log"; return 1; }
  log "$arm md5=$(cut -d' ' -f1 arms/$arm/md5.txt 2>/dev/null)"
}

log "free: $(df -h /data | awk 'NR==2{print $4}')  -march=native => $($CC -march=native -Q --help=target 2>/dev/null | awk '/^  -march=  /{print $2; exit}')"

# ---------------- 1. ARCH alone ------------------------------------------
if ! build base-native; then
  log "aggressive ARCH failed; retrying base-native with -march=x86-64-v3 -mtune=native"
  rm -rf arms/base-native
  ARCH_FLAGS="-march=x86-64-v3 -mtune=native" build base-native     || { log "ABORT: base-native fails under both ARCH sets"; exit 1; }
  echo "-march=x86-64-v3 -mtune=native" > "$ROOT/.markers/arch-flags"
fi
[ -f "$ROOT/.markers/arch-flags" ] && export ARCH_FLAGS="$(cat $ROOT/.markers/arch-flags)"
log "ARCH_FLAGS in effect: ${ARCH_FLAGS:-default aggressive}"

# ---------------- 2. ARCH + instrumented PGO ------------------------------
if [ ! -f "$M/pgo-native-trained" ]; then
  rm -rf arms/pgo-gen-native
  build pgo-gen-native || exit 1
  # -fprofile-generate instruments the build's OWN code generators; running them deposits
  # ~124 .gcda, which once silently SKIPPED training and produced zero-profile arms.
  find build/pgo-native -name "*.gcda" -delete 2>/dev/null
  log "training native PGO: one worker on node 1 (NIC is on node 0), SF=10"
  start_coord || exit 1
  : > cluster/worker1/worker.log
  setsid numactl --physcpubind="$(NODE_CPUS 1)" --preferred=1 \
      arms/pgo-gen-native/presto_server --etc_dir=$ROOT/cluster/worker1/etc \
      >> cluster/worker1/worker.log 2>&1 &
  n=0
  for i in $(seq 1 150); do
    n=$(curl -s http://127.0.0.1:8080/v1/cluster 2>/dev/null | grep -oE '"activeWorkers":[0-9]+' | grep -oE '[0-9]+$')
    [ "${n:-0}" -eq 1 ] && break; sleep 5
  done
  [ "${n:-0}" -eq 1 ] || { log "ABORT: training worker never registered"; exit 1; }
  PRESTO_SCHEMA=tpcds10 python3 -I scripts/driver.py warm \
      --list results/queries-top.txt --n 15 --timeout 1800 > "$LOGS/pgo-native-train.log" 2>&1 || true
  # gcov flushes .gcda from an atexit() handler -- SIGKILL yields NOTHING.
  pkill -TERM -f "[p]resto_server --etc_dir" 2>/dev/null
  for i in $(seq 1 120); do pgrep -f "[p]resto_server --etc_dir" >/dev/null || break; sleep 2; done
  touch "$M/pgo-native-trained"
fi
ngcda=$(find build/pgo-native -name "*.gcda" 2>/dev/null | wc -l)
log "native PGO profile: $ngcda .gcda (floor $MIN_GCDA; generic reference 830)"
[ "$ngcda" -ge "$MIN_GCDA" ] || { log "ABORT: profile too small, training did not run"; exit 1; }

build pgo-native   || exit 1
build pgolto-native || exit 1
if [ ! -x arms/pgoltob-native/presto_server ]; then
  log "BOLT pgolto-native -> pgoltob-native, perf on node 1"
  start_coord || exit 1
  BOLT_NODE=1 ./scripts/bolt-arm-gnr.sh pgolto-native >> "$LOGS/bolt-pgolto-native.log" 2>&1 \
    || { log "pgoltob-native FAILED"; tail -12 "$LOGS/bolt-pgolto-native.log"; exit 1; }
fi

# ---------------- 3. ARCH + hardware-sampled AutoFDO ----------------------
# Profile is re-collected FROM base-native: applying the generic-binary presto.afdo to a
# native build is a mismatch -fauto-profile accepts SILENTLY, understating the arm.
if [ ! -s "$PROF/presto-native.afdo" ]; then
  log "AutoFDO: perf LBR on a node-1 worker of base-native"
  start_coord || exit 1
  ARM=base-native BOLT_NODE=1 AFDO_OUT=$PROF/presto-native.afdo \
    ./scripts/afdo-profile-gnr.sh > "$LOGS/afdo-native-profile.log" 2>&1 \
    || { log "native afdo profile FAILED"; tail -20 "$LOGS/afdo-native-profile.log" | cut -c1-160; exit 1; }
fi
log "presto-native.afdo: $(ls -la $PROF/presto-native.afdo 2>/dev/null | awk '{printf "%.1f MB", $5/1048576}') (generic ref 13.0 MB)"

build afdo-native    || exit 1
build afdolto-native || exit 1
if [ ! -x arms/afdoltob-native/presto_server ]; then
  log "BOLT afdolto-native -> afdoltob-native, perf on node 1"
  start_coord || exit 1
  BOLT_NODE=1 ./scripts/bolt-arm-gnr.sh afdolto-native >> "$LOGS/bolt-afdolto-native.log" 2>&1 \
    || { log "afdoltob-native FAILED"; tail -12 "$LOGS/bolt-afdolto-native.log"; exit 1; }
fi

log "md5s (all must differ):"
for a in base base-native pgoltob pgoltob-native afdoltob-native; do
  printf '  %-18s %s\n' "$a" "$(cut -d' ' -f1 arms/$a/md5.txt 2>/dev/null)"
done

# ---------------- 4. measure the 5-way comparison on 3 nodes --------------
log "starting 5-arm x 4-round measurement (3 nodes)"
setsid nohup ./scripts/measure-native-run.sh > "$LOGS/measure-native.log" 2>&1 < /dev/null &
sleep 10
log "NATIVE_HANDOFF_DONE procs=$(pgrep -cf '[m]easure-native-run')"
