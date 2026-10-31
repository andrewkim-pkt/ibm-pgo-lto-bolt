#!/bin/bash
# AutoFDO profile collection on the 48xl, PMU-sampled on NUMA NODE 1 (not node 0).
#
# Node 1 because the NIC lives on node 0 on these boxes, so node 0 carries the
# driver/interrupt load and is the noisiest place to sample. Every prior campaign of ours
# used node 1 for exactly this reason; the 96xl scripts sampled node 0 by oversight.
#
# Full 3-worker cluster so queries run at the real operating point and the profile includes
# the remote-exchange paths, but only ONE worker is wrapped in perf: the hot code is
# identical across workers and perf costs ~9x here (q50 28.5s -> 266s), so sampling all of
# them is unaffordable. -F 199 deliberately, not the 3000 default: high-frequency LBR
# capture wrote 30 GB in 5 minutes and destabilised a box earlier in this work.
set -uo pipefail
R=/data/prestissimo-fdo
source $R/scripts/env-gnr.sh
NODE=${BOLT_NODE:-1}
ARM=${ARM:-base}
BIN=$R/arms/$ARM/presto_server
SCHEMA=${SCHEMA:-tpcds}
LIST=${LIST:-$R/results/queries-top.txt}
WORKERS=${WORKERS:-3}
ulimit -n 524288
cd "$R"
mkdir -p "$PROF" "$R/tmp"
[ -x "$BIN" ] || { echo "missing $BIN"; exit 1; }

NCPUS=$(numactl -H | sed -n "s/^node $NODE cpus: //p" | tr -s ' ' ',' | sed 's/^,//;s/,$//')
echo "=== profiled worker on node $NODE, arm=$ARM, schema=$SCHEMA  $(date -u +%H:%M) ==="

pkill -f "[p]resto_server --etc_dir" 2>/dev/null; sleep 5

# plain workers: every node except the profiled one
for i in $(seq 0 $((WORKERS-1))); do
  [ "$i" -eq "$NODE" ] && continue
  cpus=$(numactl -H | sed -n "s/^node $i cpus: //p" | tr -s ' ' ',' | sed 's/^,//;s/,$//')
  : > $R/cluster/worker$i/worker.log
  setsid numactl --physcpubind="$cpus" --preferred="$i" "$BIN" \
      --etc_dir=$R/cluster/worker$i/etc >> $R/cluster/worker$i/worker.log 2>&1 &
done

echo "=== worker$NODE under perf (LBR) on node $NODE ==="
: > $R/cluster/worker$NODE/worker.log
rm -f $PROF/perf.data
setsid numactl --physcpubind="$NCPUS" --preferred="$NODE" \
    perf record -e cycles:u -j any,u -F 199 -o $PROF/perf.data -- \
    "$BIN" --etc_dir=$R/cluster/worker$NODE/etc >> $R/cluster/worker$NODE/worker.log 2>&1 &

# EXACT count, never >=: a just-killed node lingers in the coordinator's list and tasks get
# scheduled onto a dead worker (this once wasted six training queries).
n=0
for i in $(seq 1 150); do
  n=$(curl -s http://127.0.0.1:8080/v1/cluster 2>/dev/null \
      | grep -oE '"activeWorkers":[0-9]+' | grep -oE '[0-9]+$')
  [ "${n:-0}" -eq "$WORKERS" ] && break
  sleep 5
done
echo "activeWorkers=${n:-0}"
[ "${n:-0}" -eq "$WORKERS" ] || { echo "ABORT: cluster did not reach $WORKERS workers"; exit 1; }

echo "=== profiling workload: $(wc -l < "$LIST") queries, schema $SCHEMA  $(date -u +%H:%M) ==="
PRESTO_SCHEMA=$SCHEMA python3 -I $R/scripts/driver.py stream --list "$LIST" \
    --out $R/results/afdo-profile-n$NODE.tsv --timeout 1800 2>&1 | tail -18

echo "=== stop the profiled worker gracefully so perf.data is complete ==="
PORT=$(grep -oE 'http-server.http.port=[0-9]+' $R/cluster/worker$NODE/etc/config.properties 2>/dev/null | grep -oE '[0-9]+$')
PORT=${PORT:-$((7771+NODE))}
echo "worker$NODE http port=$PORT"
curl -s -X PUT -H "Content-Type: application/json" -d '"SHUTTING_DOWN"' \
     "http://127.0.0.1:$PORT/v1/info/state" >/dev/null 2>&1
for i in $(seq 1 120); do pgrep -f "[p]erf record -e cycles" >/dev/null || break; sleep 2; done
pkill -INT -f "[p]erf record -e cycles" 2>/dev/null; sleep 6
ls -la $PROF/perf.data | awk '{print "perf.data:", $5, "bytes"}'

echo "=== create_gcov  $(date -u +%H:%M) ==="
export GLOG_log_dir=$R/tmp
"$CREATE_GCOV" --binary="$BIN" \
    --profile=$PROF/perf.data --gcov=${AFDO_OUT:-$PROF/presto.afdo} --gcov_version=2 \
    2>&1 | grep -v "^WARNING" | tail -4
sz=$(stat -c%s ${AFDO_OUT:-$PROF/presto.afdo} 2>/dev/null || echo 0)
echo "presto.afdo: $sz bytes"
# Gate 1: a near-empty profile is the signature failure of the WRONG create_gcov, and
# -fauto-profile accepts it SILENTLY -- the arm would build and measure as a null while
# looking perfectly healthy.
[ "$sz" -gt 1000000 ] || { echo "AFDO_FAILED: profile too small ($sz bytes)"; exit 1; }
# Gate 2: prove THIS gcc accepts it before spending a 20-minute build on it.
echo 'int main(){return 0;}' > $R/tmp/p.c
if "$CC" -O2 -fauto-profile=${AFDO_OUT:-$PROF/presto.afdo} $R/tmp/p.c -o $R/tmp/p 2>$R/tmp/p.err; then
  echo "gcc accepts the profile: OK"
else
  echo "gcc REJECTED the profile:"; head -3 $R/tmp/p.err; exit 1
fi
echo "AFDO_PROFILE_DONE $(date -u +%H:%M)"
