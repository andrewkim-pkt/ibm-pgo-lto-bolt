#!/bin/bash
# BOLT a built Prestissimo arm:  bolt-arm96.sh <pgo|pgolto>  ->  arms/<src>b/
#
# The profile must come from the SAME binary being rewritten, so each BOLT arm gets its
# own perf run. We record on ONE worker (node 0) driving the real SF=1000 query set: a
# 6-worker record would multiply the LBR data rate by six for no extra coverage.
# -F 199, not the 3000 default: at 3000 with LBR this wrote 30 GB in 5 min on the GNR box
# and destabilised it.
set -uo pipefail
R=/data/velox-fdo
SRC=${1:?source arm: pgo|pgolto}
OUT="${SRC}b"
IN=$R/arms/$SRC/presto_server
[ -x "$IN" ] || { echo "missing $IN"; exit 1; }
ulimit -n 524288
mkdir -p $R/arms/$OUT $R/prof/bolt-$SRC
cd $R/prof/bolt-$SRC

nrela=$(readelf -S "$IN" 2>/dev/null | grep -c "\.rela\.text" || true)
[ "${nrela:-0}" -gt 0 ] || { echo "$IN has no .rela.text -- BOLT would refuse"; exit 1; }

echo "=== 1/3 perf record on one $SRC worker, SF=1000 query set  $(date -u +%H:%M) ==="
pkill -f "[p]resto_server --etc_dir" 2>/dev/null; sleep 4
BOLT_NODE=${BOLT_NODE:-1}
cpus=$(numactl -H | sed -n "s/^node $BOLT_NODE cpus: //p" | tr -s " " "," | sed "s/^,//;s/,$//")
: > $R/cluster/worker0/worker.log
setsid numactl --physcpubind="$cpus" --preferred=$BOLT_NODE \
    perf record -e cycles:u -j any,u -F 199 -o $R/prof/bolt-$SRC/perf.data -- \
    "$IN" --etc_dir=$R/cluster/worker0/etc >> $R/cluster/worker0/worker.log 2>&1 &
for i in $(seq 1 60); do
  n=$(curl -s http://127.0.0.1:8080/v1/cluster 2>/dev/null | grep -oE '"activeWorkers":[0-9]+' | grep -oE '[0-9]+$')
  [ "${n:-0}" -ge 1 ] && break; sleep 5
done
echo "activeWorkers=${n:-0}"
[ "${n:-0}" -ge 1 ] || { echo "ABORT: worker never registered"; exit 1; }

# one pass of the measured query set is plenty of coverage for a layout profile
python3 -I $R/scripts/driver.py stream --list $R/results/queries-top.txt \
    --out $R/results/bolt-profile-$SRC.tsv --timeout 1800 2>&1 | tail -6

echo "=== stopping perf cleanly so perf.data is complete ==="
curl -s -X PUT -H "Content-Type: application/json" -d '"SHUTTING_DOWN"' \
     http://127.0.0.1:7771/v1/info/state >/dev/null 2>&1
for i in $(seq 1 120); do pgrep -f "[p]erf record -e cycles" >/dev/null || break; sleep 2; done
pkill -INT -f "[p]erf record -e cycles" 2>/dev/null; sleep 5
ls -la perf.data | awk '{print "perf.data:", $5, "bytes"}'

echo "=== 2/3 perf2bolt  $(date -u +%H:%M) ==="
perf2bolt -p perf.data -o perf.fdata "$IN" 2>&1 | tail -4
[ -s perf.fdata ] || { echo "empty perf.fdata"; exit 1; }
ls -la perf.fdata | awk '{print "fdata:", $5, "bytes"}'

echo "=== 3/3 llvm-bolt  $(date -u +%H:%M) ==="
llvm-bolt "$IN" -o $R/arms/$OUT/presto_server \
    -data=perf.fdata \
    -reorder-blocks=ext-tsp \
    -reorder-functions=hfsort+ \
    -split-functions \
    -split-all-cold \
    -split-eh \
    -icf=1 \
    -dyno-stats 2>&1 | tee $R/logs/bolt96-$SRC.log | tail -12
[ -x $R/arms/$OUT/presto_server ] || { echo "BOLT produced no binary"; exit 1; }
cd $R/arms/$OUT && md5sum presto_server | tee md5.txt
ls -la presto_server | awk '{print "size:", $5}'
rm -f $R/prof/bolt-$SRC/perf.data
echo "BOLT96_${OUT}_DONE $(date -u +%H:%M)"
