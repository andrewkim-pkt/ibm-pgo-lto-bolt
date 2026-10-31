#!/usr/bin/env python3
"""Register the SF=10 dataset as schema hive.tpcds for PGO TRAINING.

Training runs at SF=10, measurement at SF=1000. An instrumented Prestissimo is far too
slow for SF=1000 (instrumented Velox measured ~375x), which is the same reason Jantz
trained at SF=1. Registering a separate schema leaves the SF=1000 tables untouched.
"""
import json, os, urllib.request, time, sys
R="/data/prestissimo-fdo"; SF="1000"; PORT=8080
H={"X-Presto-User":"fdo","X-Presto-Catalog":"hive","X-Presto-Schema":"tpcds"}
def sql(q):
    r=json.load(urllib.request.urlopen(urllib.request.Request(
        f"http://127.0.0.1:{PORT}/v1/statement", data=q.encode(), headers=H)))
    err=None
    while True:
        if "error" in r: err=str(r["error"].get("message"))[:150]; break
        n=r.get("nextUri")
        if not n: break
        time.sleep(0.05); r=json.load(urllib.request.urlopen(n))
    return err
spec={}
for line in open(f"{R}/tpcds-raw-sf{SF}/schema.tsv"):
    t,cols=line.rstrip("\n").split("\t")
    spec[t]=[c.split(":",1) for c in cols.split(";")]
print("CREATE SCHEMA:", sql(f"CREATE SCHEMA IF NOT EXISTS hive.tpcds WITH (location='file://{R}/cluster/data')") or "ok")
ok=0
for t in sorted(os.listdir(f"{R}/tpcds-sf{SF}")):
    if t not in spec: print(f"{t}: no schema, skipped"); continue
    cols=", ".join(f"{n} {ty.lower()}" for n,ty in spec[t])
    sql(f"DROP TABLE IF EXISTS hive.tpcds.{t}")
    e=sql(f"CREATE TABLE hive.tpcds.{t} ({cols}) WITH (format='PARQUET', "
          f"external_location='file://{R}/tpcds-sf{SF}/{t}')")
    print(f"{t}: {e or 'ok'}"); ok += (e is None)
print(f"registered {ok} tables in hive.tpcds")
