#!/bin/bash
# Generate TPC-H SF=100 Parquet for velox_tpch_benchmark.
# dbgen from github (extensions.duckdb.org and ftp.gnu.org are TLS-MITM'd by the Intel
# proxy and unverifiable; github is not, so every fetch here goes to github).
# Layout required by -data_path: one DIRECTORY per table holding its parquet file(s).
set -euo pipefail
source /etc/environment; export http_proxy https_proxy no_proxy
ROOT=/data/velox-fdo
SF=${SF:-100}
CHUNKS=${CHUNKS:-64}
RAW=$ROOT/tpch-raw-sf$SF
OUT=$ROOT/tpch-sf$SF
DUCKDB=$ROOT/tools/duckdb
mkdir -p "$ROOT/tools" "$RAW" "$OUT"

# --- dbgen ---
cd "$ROOT/tools"
if [ ! -x dbgen/dbgen ]; then
  [ -d tpch-dbgen ] || git clone --depth 1 https://github.com/electrum/tpch-dbgen.git
  cd tpch-dbgen && make -s CC=gcc 2>&1 | tail -3 && cd ..
  mkdir -p dbgen && cp tpch-dbgen/dbgen tpch-dbgen/dists.dss dbgen/
fi
cd "$RAW"
cp -f "$ROOT/tools/dbgen/dists.dss" .

# --- generate .tbl in parallel chunks ---
# nation/region are tiny and not chunkable: emit them once with -T followed by the small-table code.
if [ ! -f .gen-done ]; then
  echo "== dbgen SF=$SF in $CHUNKS chunks =="
  "$ROOT/tools/dbgen/dbgen" -f -s "$SF" -T n >/dev/null 2>&1 || true   # nation
  "$ROOT/tools/dbgen/dbgen" -f -s "$SF" -T r >/dev/null 2>&1 || true   # region
  for t in c P S O L; do        # customer, part, partsupp, orders, lineitem
    for i in $(seq 1 "$CHUNKS"); do
      "$ROOT/tools/dbgen/dbgen" -f -s "$SF" -C "$CHUNKS" -S "$i" -T "$t" >/dev/null 2>&1 &
    done
  done
  wait
  "$ROOT/tools/dbgen/dbgen" -f -s "$SF" -T s >/dev/null 2>&1 || true   # supplier
  touch .gen-done
fi
ls -la "$RAW" | head -20
du -sh "$RAW"
echo "GEN_TBL_DONE"
