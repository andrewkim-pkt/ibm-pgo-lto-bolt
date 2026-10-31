#!/bin/bash
# Convert TPC-H .tbl chunks -> Parquet in the per-table-directory layout velox_tpch_benchmark wants.
# Canonical TPC-H column names (Velox binds queries by name; it infers types from the file).
# .tbl lines carry a TRAILING '|', so each schema ends in a throwaway "dummy" column.
set -euo pipefail
ROOT=/data/velox-fdo
SF=${SF:-100}
RAW=$ROOT/tpch-raw-sf$SF
OUT=$ROOT/tpch-sf$SF
DUCKDB=$ROOT/tools/duckdb
PAR=${PAR:-32}

declare -A SCHEMA=(
[lineitem]="l_orderkey BIGINT, l_partkey BIGINT, l_suppkey BIGINT, l_linenumber INTEGER, l_quantity DOUBLE, l_extendedprice DOUBLE, l_discount DOUBLE, l_tax DOUBLE, l_returnflag VARCHAR, l_linestatus VARCHAR, l_shipdate DATE, l_commitdate DATE, l_receiptdate DATE, l_shipinstruct VARCHAR, l_shipmode VARCHAR, l_comment VARCHAR, dummy VARCHAR"
[orders]="o_orderkey BIGINT, o_custkey BIGINT, o_orderstatus VARCHAR, o_totalprice DOUBLE, o_orderdate DATE, o_orderpriority VARCHAR, o_clerk VARCHAR, o_shippriority INTEGER, o_comment VARCHAR, dummy VARCHAR"
[customer]="c_custkey BIGINT, c_name VARCHAR, c_address VARCHAR, c_nationkey BIGINT, c_phone VARCHAR, c_acctbal DOUBLE, c_mktsegment VARCHAR, c_comment VARCHAR, dummy VARCHAR"
[part]="p_partkey BIGINT, p_name VARCHAR, p_mfgr VARCHAR, p_brand VARCHAR, p_type VARCHAR, p_size INTEGER, p_container VARCHAR, p_retailprice DOUBLE, p_comment VARCHAR, dummy VARCHAR"
[supplier]="s_suppkey BIGINT, s_name VARCHAR, s_address VARCHAR, s_nationkey BIGINT, s_phone VARCHAR, s_acctbal DOUBLE, s_comment VARCHAR, dummy VARCHAR"
[partsupp]="ps_partkey BIGINT, ps_suppkey BIGINT, ps_availqty INTEGER, ps_supplycost DOUBLE, ps_comment VARCHAR, dummy VARCHAR"
[nation]="n_nationkey BIGINT, n_name VARCHAR, n_regionkey BIGINT, n_comment VARCHAR, dummy VARCHAR"
[region]="r_regionkey BIGINT, r_name VARCHAR, r_comment VARCHAR, dummy VARCHAR"
)

mk_cols() {  # strip the dummy column and the types -> bare select list
  echo "$1" | tr ',' '\n' | awk '{print $1}' | grep -v '^dummy$' | paste -sd, -
}

jobs_running=0
for t in "${!SCHEMA[@]}"; do
  mkdir -p "$OUT/$t"
  cols=$(mk_cols "${SCHEMA[$t]}")
  shopt -s nullglob
  files=("$RAW/$t.tbl" "$RAW/$t.tbl".*)
  shopt -u nullglob
  for f in "${files[@]}"; do
    [ -s "$f" ] || continue
    suffix="${f##*/}"; suffix="${suffix#"$t".tbl}"; suffix="${suffix#.}"
    [ -n "$suffix" ] || suffix=0
    target="$OUT/$t/$t.$suffix.parquet"
    [ -s "$target" ] && continue
    (
      "$DUCKDB" -c "SET preserve_insertion_order=false;
        COPY (SELECT $cols FROM read_csv('$f', delim='|', header=false, quote='', escape='',
              columns={$(echo "${SCHEMA[$t]}" | sed "s/\([a-z_]*\) \([A-Z]*\)/'\1':'\2'/g")}))
        TO '$target' (FORMAT PARQUET, COMPRESSION 'snappy');" >/dev/null
    ) &
    jobs_running=$((jobs_running+1))
    if [ "$jobs_running" -ge "$PAR" ]; then wait -n 2>/dev/null || wait; jobs_running=$((jobs_running-1)); fi
  done
done
wait
echo "=== inventory ==="
for t in "${!SCHEMA[@]}"; do printf "%-10s %3s files %8s\n" "$t" "$(ls "$OUT/$t" | wc -l)" "$(du -sh "$OUT/$t" | cut -f1)"; done
du -sh "$OUT"
echo "TO_PARQUET_DONE"
