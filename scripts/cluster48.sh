#!/bin/bash
# Prestissimo cluster in Jantz's shape on one box: 1 Java coordinator + N native workers,
# each worker pinned to its own NUMA node (he used 6 worker containers, one per SNC node,
# because remote memory access cost him "quite a bit").
#
#   cluster96.sh setup            write all configs
#   cluster96.sh start <arm> [N]  start coordinator + N workers using arms/<arm>/presto_server
#   cluster96.sh stop
#   cluster96.sh status
#   cluster96.sh register <sf>    create schema + external tables over tpcds-sf<sf> parquet
#   cluster96.sh sql "<query>"    run one statement via the REST API
set -uo pipefail
source /data/velox-fdo/scripts/env48.sh
ulimit -n 524288 || echo "WARNING: fd limit not raised"
PV=0.299
COORD_VERSION=${COORD_VERSION:-0.299-7d50721}
SRV=$ROOT/tools/presto-server-$PV
RUN=$ROOT/cluster
COORD_PORT=8080
WORKERS=${WORKERS:-3}
export JAVA_HOME=${JAVA_HOME:-$ROOT/tools/jdk17}

setup() {
  rm -rf "$RUN"; mkdir -p "$RUN"/{coordinator/etc/catalog,metastore,data}
  # ---- coordinator (Java) ----
  cat > "$RUN/coordinator/etc/node.properties" <<EOF
node.environment=prestofdo
node.id=coordinator
node.data-dir=$RUN/coordinator/data
EOF
  cat > "$RUN/coordinator/etc/jvm.config" <<EOF
-server
-Xmx64G
-XX:+UseG1GC
-XX:G1HeapRegionSize=32M
-XX:+ExplicitGCInvokesConcurrent
-Djdk.attach.allowAttachSelf=true
EOF
  # native-execution-enabled tells the coordinator its workers are C++ (Prestissimo),
  # so it plans with the native function namespace and skips Java-only optimizations.
  cat > "$RUN/coordinator/etc/config.properties" <<EOF
coordinator=true
node-scheduler.include-coordinator=false
http-server.http.port=$COORD_PORT
discovery-server.enabled=true
discovery.uri=http://127.0.0.1:$COORD_PORT
query.max-memory=750GB
native-execution-enabled=true
optimizer.optimize-hash-generation=false
regex-library=RE2J
use-alternative-function-signatures=true
EOF
  # File-based Hive metastore: no Hive/MySQL needed, metadata lives on local disk.
  cat > "$RUN/coordinator/etc/catalog/hive.properties" <<EOF
connector.name=hive-hadoop2
hive.metastore=file
hive.metastore.catalog.dir=file://$RUN/metastore
hive.allow-drop-table=true
hive.allow-rename-table=true
hive.allow-add-column=true
hive.allow-drop-column=true
hive.storage-format=PARQUET
hive.parquet.use-column-names=true
EOF
  # ---- native workers, one per NUMA node ----
  for i in $(seq 0 $((WORKERS-1))); do
    d=$RUN/worker$i; mkdir -p "$d/etc/catalog" "$d/data"
    cat > "$d/etc/node.properties" <<EOF
node.environment=prestofdo
node.id=worker$i
node.data-dir=$d/data
node.location=/prestofdo/worker$i
node.ip=127.0.0.1
EOF
    cat > "$d/etc/config.properties" <<EOF
discovery.uri=http://127.0.0.1:$COORD_PORT
presto.version=$COORD_VERSION
http-server.http.port=$((7771+i))
shutdown-onset-sec=1
runtime-metrics-collection-enabled=true
system-memory-gb=440
query-memory-gb=360
memory-arbitrator-kind=SHARED
shared-arbitrator.reserved-capacity=8GB
shared-arbitrator.memory-pool-initial-capacity=2GB
spill-enabled=true
join-spill-enabled=true
aggregation-spill-enabled=true
order-by-spill-enabled=true
experimental.spiller-spill-path=$ROOT/spill/worker\$i
EOF
    cat > "$d/etc/velox.properties" <<EOF
EOF
    cat > "$d/etc/catalog/hive.properties" <<EOF
connector.name=hive-hadoop2
hive.parquet.use-column-names=true
EOF
  done
  echo "setup OK: coordinator + $WORKERS workers under $RUN"
}

start() {
  local arm=${1:?arm} n=${2:-$WORKERS}
  local bin=$ROOT/arms/$arm/presto_server
  [ -x "$bin" ] || { echo "missing $bin"; exit 1; }
  echo "=== coordinator ==="
  PATH=$JAVA_HOME/bin:$PATH nohup "$SRV/bin/launcher.py" \
      --etc-dir "$RUN/coordinator/etc" --data-dir "$RUN/coordinator/data" run \
      > "$RUN/coordinator/server.log" 2>&1 &
  for i in $(seq 1 90); do
    curl -s "http://127.0.0.1:$COORD_PORT/v1/info" 2>/dev/null | grep -q '"starting":false' && break
    sleep 2
  done
  curl -s "http://127.0.0.1:$COORD_PORT/v1/info" | head -c 200; echo
  echo "=== $n native workers ($arm), one per NUMA node ==="
  for i in $(seq 0 $((n-1))); do
    cpus=$(NODE_CPUS "$i")
    nohup numactl --physcpubind="$cpus" --preferred="$i" \
        "$bin" --etc_dir="$RUN/worker$i/etc" \
        > "$RUN/worker$i/worker.log" 2>&1 &
    echo "  worker$i -> node $i"
  done
  sleep 25
  echo "=== registered nodes ==="
  curl -s "http://127.0.0.1:$COORD_PORT/v1/node" | grep -oE '"uri":"[^"]*"' | head -8
}

stop() {
  pkill -f "presto_server --etc_dir=$RUN" 2>/dev/null || true
  pkill -f "com.facebook.presto.server.PrestoServer" 2>/dev/null || true
  sleep 3; echo "stopped"
}

status() {
  echo "coordinator: $(curl -s "http://127.0.0.1:$COORD_PORT/v1/info" 2>/dev/null | head -c 120)"
  echo "workers up: $(curl -s "http://127.0.0.1:$COORD_PORT/v1/node" 2>/dev/null | grep -oc '"uri"')"
  echo "procs: coordinator=$(pgrep -cf PrestoServer) native=$(pgrep -cf "[p]resto_server --etc_dir")"
}

# Minimal REST client: POST /v1/statement then follow nextUri.
sql() {
  python3 - "$COORD_PORT" "$1" <<'PY'
import json,sys,urllib.request,time
port,q=sys.argv[1],sys.argv[2]
req=urllib.request.Request(f"http://127.0.0.1:{port}/v1/statement",data=q.encode(),
    headers={"X-Presto-User":"fdo","X-Presto-Catalog":"hive","X-Presto-Schema":"tpcds"})
r=json.load(urllib.request.urlopen(req)); rows=[]; err=None
while True:
    if "error" in r: err=r["error"].get("message"); break
    rows += r.get("data") or []
    nxt=r.get("nextUri")
    if not nxt: break
    time.sleep(0.05)
    r=json.load(urllib.request.urlopen(nxt))
print("ERROR:",err) if err else print(json.dumps(rows[:20]))
PY
}

register() {
  local sf=${1:?sf}
  local dir=$ROOT/tpcds-sf$sf
  sql "CREATE SCHEMA IF NOT EXISTS hive.tpcds WITH (location='file://$RUN/data')"
  for t in $(ls "$dir"); do
    local cols
    cols=$(awk -F'\t' -v t="$t" '$1==t{print $2}' "$ROOT/tpcds-raw-sf$sf/schema.tsv" 2>/dev/null \
        | tr ';' '\n' | awk -F: '{gsub(/VARCHAR/,"varchar",$2); printf "%s%s %s", (NR>1?", ":""), $1, tolower($2)}')
    [ -n "$cols" ] || { echo "no schema for $t -- skipped"; continue; }
    sql "DROP TABLE IF EXISTS hive.tpcds.$t" >/dev/null
    echo -n "$t: "
    sql "CREATE TABLE hive.tpcds.$t ($cols) WITH (format='PARQUET', external_location='file://$dir/$t')"
  done
}

case "${1:-}" in
  setup) setup ;;
  start) shift; start "$@" ;;
  stop) stop ;;
  status) status ;;
  register) shift; register "$@" ;;
  sql) shift; sql "$1" ;;
  *) echo "usage: $0 {setup|start <arm> [n]|stop|status|register <sf>|sql <q>}"; exit 2 ;;
esac
