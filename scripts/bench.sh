#!/bin/bash
# Mirrored measurement across all arms.
#
# Mirroring: round 1 runs the arms in list order, round 2 in REVERSE order, and so on.
# Any monotonic drift on the box (thermals, another user's work, page-cache state)
# therefore hits each arm at both an early and a late slot, instead of always
# penalising whichever arm is measured last.
#
# Each pass is a fresh process: the Velox in-process cache starts cold every time, so
# -bm_min_iters 2 lets the first iteration warm it and the best-of pick the steady
# state. Per-query results come from folly's own JSON (-bm_json_verbose), never scraped
# from the human-readable table.
set -euo pipefail
source /data/velox-fdo/scripts/env.sh
source /data/velox-fdo/scripts/workload.sh
TGT=velox_tpch_benchmark
ARMS=${ARMS:-"base pgo pgob pgolto pgoltob afdo afdob afdolto afdoltob"}
ROUNDS=${ROUNDS:-6}
BM_MIN_ITERS=${BM_MIN_ITERS:-2}
BM_MAX_SECS=${BM_MAX_SECS:-8}
CAMPAIGN=${CAMPAIGN:-campaign-$(date -u +%Y%m%d-%H%M%S)}
OUT=$RES/$CAMPAIGN
mkdir -p "$OUT"

# Only measure arms that actually exist, and say which are skipped.
avail=(); missing=()
for a in $ARMS; do
  if [ -x "$ROOT/arms/$a/$TGT" ]; then avail+=("$a"); else missing+=("$a"); fi
done
[ ${#missing[@]} -eq 0 ] || echo "SKIPPING (not built): ${missing[*]}"
[ ${#avail[@]} -gt 0 ] || { echo "no arms built" >&2; exit 1; }

{
  echo "campaign: $CAMPAIGN"
  echo "host: $(hostname)  box: $(nproc) vCPU, $(numactl -H | sed -n 's/^available: \(.*\)/\1/p')"
  echo "arms: ${avail[*]}"
  echo "rounds: $ROUNDS (mirrored: odd forward, even reverse)"
  echo "scope: ${NODE:+NUMA node $NODE via [$NUMA]}${NODE:-whole system, all nodes}"
  echo "work point: $(velox_workload_args) -bm_min_iters $BM_MIN_ITERS -bm_max_secs $BM_MAX_SECS"
  echo "gcc: $($CXX --version | head -1)"
  for a in "${avail[@]}"; do echo "md5 $a: $(cat "$ROOT/arms/$a/md5.txt" 2>/dev/null | awk '{print $1}')"; done
} | tee "$OUT/MANIFEST.txt"

for r in $(seq 1 "$ROUNDS"); do
  order=("${avail[@]}")
  if [ $((r % 2)) -eq 0 ]; then                      # even rounds run mirrored
    order=(); for ((i=${#avail[@]}-1; i>=0; i--)); do order+=("${avail[$i]}"); done
  fi
  echo "=== round $r/$ROUNDS  order: ${order[*]} ==="
  for a in "${order[@]}"; do
    json="$OUT/$a.r$r.json"; log="$OUT/$a.r$r.out"
    printf "  %-10s round %d ... " "$a" "$r"
    start=$(date +%s)
    # shellcheck disable=SC2046
    if $NUMA "$ROOT/arms/$a/$TGT" $(velox_workload_args) \
         -bm_min_iters "$BM_MIN_ITERS" -bm_max_secs "$BM_MAX_SECS" \
         -bm_json_verbose "$json" > "$log" 2>&1; then
      n=$(grep -cE "^q[0-9]+" "$log" || true)
      echo "ok  $(( $(date +%s) - start ))s  queries=$n"
      [ "$n" -eq 22 ] || echo "    GATE: expected 22 queries, got $n -> pass marked BAD" | tee -a "$OUT/BAD.txt"
    else
      echo "FAILED rc=$? $(( $(date +%s) - start ))s"
      { echo "$a r$r FAILED"; tail -5 "$log"; } >> "$OUT/BAD.txt"
    fi
  done
done
echo "BENCH_DONE $OUT"
