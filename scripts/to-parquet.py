#!/usr/bin/env python3
"""Convert TPC-H .tbl chunks -> Parquet in the per-table-directory layout
velox_tpch_benchmark expects (-data_path/<table>/<files>).

Canonical TPC-H column names: Velox binds its queries by name and infers types
from the Parquet file itself. .tbl rows carry a trailing '|', so every schema
ends in a throwaway 'dummy' column that is not selected.
"""
import os, subprocess, sys, glob
from concurrent.futures import ThreadPoolExecutor

ROOT = "/data/velox-fdo"
SF = os.environ.get("SF", "100")
RAW = f"{ROOT}/tpch-raw-sf{SF}"
OUT = f"{ROOT}/tpch-sf{SF}"
DUCKDB = f"{ROOT}/tools/duckdb"
PAR = int(os.environ.get("PAR", "24"))

SCHEMA = {
 "lineitem": [("l_orderkey","BIGINT"),("l_partkey","BIGINT"),("l_suppkey","BIGINT"),
   ("l_linenumber","INTEGER"),("l_quantity","DOUBLE"),("l_extendedprice","DOUBLE"),
   ("l_discount","DOUBLE"),("l_tax","DOUBLE"),("l_returnflag","VARCHAR"),
   ("l_linestatus","VARCHAR"),("l_shipdate","DATE"),("l_commitdate","DATE"),
   ("l_receiptdate","DATE"),("l_shipinstruct","VARCHAR"),("l_shipmode","VARCHAR"),
   ("l_comment","VARCHAR")],
 "orders": [("o_orderkey","BIGINT"),("o_custkey","BIGINT"),("o_orderstatus","VARCHAR"),
   ("o_totalprice","DOUBLE"),("o_orderdate","DATE"),("o_orderpriority","VARCHAR"),
   ("o_clerk","VARCHAR"),("o_shippriority","INTEGER"),("o_comment","VARCHAR")],
 "customer": [("c_custkey","BIGINT"),("c_name","VARCHAR"),("c_address","VARCHAR"),
   ("c_nationkey","BIGINT"),("c_phone","VARCHAR"),("c_acctbal","DOUBLE"),
   ("c_mktsegment","VARCHAR"),("c_comment","VARCHAR")],
 "part": [("p_partkey","BIGINT"),("p_name","VARCHAR"),("p_mfgr","VARCHAR"),
   ("p_brand","VARCHAR"),("p_type","VARCHAR"),("p_size","INTEGER"),
   ("p_container","VARCHAR"),("p_retailprice","DOUBLE"),("p_comment","VARCHAR")],
 "supplier": [("s_suppkey","BIGINT"),("s_name","VARCHAR"),("s_address","VARCHAR"),
   ("s_nationkey","BIGINT"),("s_phone","VARCHAR"),("s_acctbal","DOUBLE"),
   ("s_comment","VARCHAR")],
 "partsupp": [("ps_partkey","BIGINT"),("ps_suppkey","BIGINT"),("ps_availqty","INTEGER"),
   ("ps_supplycost","DOUBLE"),("ps_comment","VARCHAR")],
 "nation": [("n_nationkey","BIGINT"),("n_name","VARCHAR"),("n_regionkey","BIGINT"),
   ("n_comment","VARCHAR")],
 "region": [("r_regionkey","BIGINT"),("r_name","VARCHAR"),("r_comment","VARCHAR")],
}

def job(args):
    table, src, dst = args
    cols = SCHEMA[table]
    collist = ",".join(c for c, _ in cols)
    colspec = ",".join(f"'{c}':'{t}'" for c, t in cols) + ",'dummy':'VARCHAR'"
    sql = (f"SET preserve_insertion_order=false; "
           f"COPY (SELECT {collist} FROM read_csv('{src}', delim='|', header=false, "
           f"quote='', escape='', columns={{{colspec}}})) "
           f"TO '{dst}' (FORMAT PARQUET, COMPRESSION 'snappy');")
    r = subprocess.run([DUCKDB, "-c", sql], capture_output=True, text=True)
    if r.returncode != 0 or not os.path.exists(dst):
        return f"FAIL {table} {os.path.basename(src)}: {r.stderr.strip()[:300]}"
    return None

tasks = []
tables = os.environ.get("TABLES", " ".join(SCHEMA)).split()
for t in tables:
    os.makedirs(f"{OUT}/{t}", exist_ok=True)
    srcs = sorted(glob.glob(f"{RAW}/{t}.tbl")) + sorted(glob.glob(f"{RAW}/{t}.tbl.*"))
    for s in srcs:
        if os.path.getsize(s) == 0:
            continue
        suf = os.path.basename(s)[len(t)+5:].lstrip(".") or "0"
        dst = f"{OUT}/{t}/{t}.{suf}.parquet"
        if os.path.exists(dst) and os.path.getsize(dst) > 0:
            continue
        tasks.append((t, s, dst))

print(f"{len(tasks)} conversion jobs, {PAR} parallel", flush=True)
fails = []
with ThreadPoolExecutor(max_workers=PAR) as ex:
    for i, res in enumerate(ex.map(job, tasks), 1):
        if res:
            fails.append(res); print(res, flush=True)
        if i % 32 == 0:
            print(f"  {i}/{len(tasks)} done", flush=True)

print("=== inventory ===")
for t in tables:
    files = os.listdir(f"{OUT}/{t}")
    size = sum(os.path.getsize(f"{OUT}/{t}/{f}") for f in files)
    print(f"{t:10s} {len(files):3d} files {size/2**30:8.2f} GiB")
print(f"FAILURES: {len(fails)}")
sys.exit(1 if fails else 0)
