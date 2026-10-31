#!/bin/bash
# Waits for the max-stack native campaign, PROBES one run to calibrate REPS, then runs both
# CPU slices. Queued now so the box never idles waiting on me (phase 1 once sat
# finished-and-idle for 2h47m, and a dead monitor cost ~22 h).
set -uo pipefail
R=/data/prestissimo-fdo
source $R/scripts/env-gnr.sh
log() { echo "[$(date -u +%H:%M)] $*"; }
cd "$R"

while pgrep -f "[m]easure-native-run" > /dev/null || pgrep -f "[b]oot-gnr-native" > /dev/null; do
  sleep 180
done
log "native campaign finished ($(grep -c valid=yes results/tput-native-summary.tsv 2>/dev/null || echo 0)/20 valid)"

# The max-stack arm must exist; otherwise fall back to the generic best so the slices still
# produce a usable FDO delta rather than silently comparing base to base.
ARM2=pgoltob-native
[ -x "arms/$ARM2/presto_server" ] || { ARM2=pgoltob; log "pgoltob-native missing, using pgoltob"; }
log "slice arms: base $ARM2"

# --- calibrate REPS on slice b (the faster one) -----------------------------
# Target ~20 min per run: long enough that start-up transients do not dominate (a single
# SF=10 pass once finished in 31 s and q/h then climbed monotonically with execution order).
if [ ! -f "$R/.markers/slice-calibrated" ]; then
  log "probe: 1 rep on slice b to measure per-rep cost"
  SLICE=b ARMS="base" ROUNDS=1 REPS=1 \
    TPUT_SUMMARY=$R/results/tput-probe-summary.tsv \
    ./scripts/measure-slice.sh > "$LOGS/slice-probe.log" 2>&1 || true
  w=$(awk -F'wall_s=' '/wall_s=/{split($2,a," "); print a[1]; exit}' "$R/results/tput-probe-summary.tsv" 2>/dev/null)
  log "probe wall=${w:-unknown}s for 1 rep on slice b"
  touch "$R/.markers/slice-calibrated"
  echo "${w:-0}" > "$R/.markers/slice-probe-wall"
fi
w=$(cat "$R/.markers/slice-probe-wall" 2>/dev/null | cut -d. -f1)
w=${w:-0}
if [ "$w" -gt 0 ]; then
  REPS_B=$(( 1200 / w )); [ "$REPS_B" -lt 1 ] && REPS_B=1; [ "$REPS_B" -gt 20 ] && REPS_B=20
  REPS_A=$(( REPS_B / 2 )); [ "$REPS_A" -lt 1 ] && REPS_A=1
else
  REPS_B=3; REPS_A=2
fi
log "chosen REPS: slice b=$REPS_B, slice a=$REPS_A (slice a has half the cores)"

# --- slice b first (16 cores, faster) then slice a (8 cores) ---------------
for cfg in "b $REPS_B" "a $REPS_A"; do
  set -- $cfg
  s=$1; reps=$2
  log "=== slice $s: 2 arms x 4 mirrored rounds, REPS=$reps ==="
  SLICE=$s ARMS="base $ARM2" ROUNDS=4 REPS=$reps \
    ./scripts/measure-slice.sh > "$LOGS/measure-slice$s.log" 2>&1 \
    || log "slice $s returned nonzero"
  log "slice $s: $(grep -c valid=yes results/tput-slice$s-summary.tsv 2>/dev/null || echo 0)/8 valid"
done

log "SLICES_DONE"
