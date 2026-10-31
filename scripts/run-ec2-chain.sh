#!/bin/bash
# 24xl (96 vCPU, 2 nodes) first since it is the faster of the two, then 16xl (64 vCPU, 1 node).
set -uo pipefail
R=/data/prestissimo-fdo
cd $R
for s in 24xl 16xl; do
  echo "[$(date -u +%H:%M)] === $s ==="
  SIZE=$s ARMS="base pgoltob" ROUNDS=4 ./scripts/measure-ec2.sh > $R/logs/measure-$s.log 2>&1 || echo "$s nonzero"
  echo "[$(date -u +%H:%M)] $s: $(grep -c valid=yes $R/results/tput-$s-summary.tsv 2>/dev/null || echo 0)/8 valid"
done
echo "[$(date -u +%H:%M)] EC2_SWEEP_DONE"
