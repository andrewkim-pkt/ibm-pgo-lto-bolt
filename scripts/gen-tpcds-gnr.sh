#!/bin/bash
# TPC-DS -> Parquet in the per-table-directory layout the Hive connector wants.
#   SF=<n> CHILDREN=<n> WAVE=<n> ./gen-tpcds.sh
#
# Generates in WAVES: each wave runs dsdgen for a subset of children, converts those
# .dat chunks to Parquet, then DELETES the .dat. SF=1000 raw is ~1 TB, so holding it all
# would need ~1.4 TB alongside the Parquet; waving keeps peak raw at roughly 1TB*WAVE/CHILDREN.
#
# Schemas come from duckdb's tpcds extension (results/tpcds-schema.sql), not hand-written.
# .dat rows carry a TRAILING '|', so each read_csv gets an extra throwaway column.
set -euo pipefail
source /data/prestissimo-fdo/scripts/env-gnr.sh
SF=${SF:-10}
CHILDREN=${CHILDREN:-96}
WAVE=${WAVE:-12}
PAR=${PAR:-24}
RAW=$ROOT/tpcds-raw-sf$SF
OUT=$ROOT/tpcds-sf$SF
DS=$ROOT/tools/tpcds-kit/tools
DUCK=$ROOT/tools/duckdb
SCHEMA=$RES/tpcds-schema.sql
mkdir -p "$RAW" "$OUT"
[ -s "$SCHEMA" ] || { echo "missing $SCHEMA"; exit 1; }

# table -> "col:TYPE,col:TYPE,..." from the duckdb DDL
python3 - "$SCHEMA" > "$RAW/schema.tsv" <<'PY'
import re,sys
ddl=open(sys.argv[1]).read()
for m in re.finditer(r'CREATE TABLE (\w+)\((.*?)\);', ddl, re.S):
    t,cols=m.group(1),m.group(2)
    out=[]
    depth=0; cur=''
    for ch in cols:            # split on commas not inside DECIMAL(7,2)
        if ch=='(': depth+=1
        if ch==')': depth-=1
        if ch==',' and depth==0: out.append(cur.strip()); cur=''
        else: cur+=ch
    if cur.strip(): out.append(cur.strip())
    spec=[]
    for c in out:
        parts=c.split(None,1)
        spec.append(parts[0]+':'+parts[1].strip())
    print(t+'\t'+';'.join(spec))
PY
echo "tables in schema: $(wc -l < "$RAW/schema.tsv")"

convert_chunk() {  # $1=table $2=datfile
  local t=$1 f=$2 spec cols colspec dst
  spec=$(awk -F'\t' -v t="$t" '$1==t{print $2}' "$RAW/schema.tsv")
  [ -n "$spec" ] || { echo "no schema for $t"; return 0; }
  cols=$(echo "$spec" | tr ';' '\n' | cut -d: -f1 | paste -sd, -)
  colspec=$(echo "$spec" | tr ';' '\n' | awk -F: '{printf "%s'\''%s'\'':'\''%s'\''", (NR>1?",":""), $1, $2}')
  dst="$OUT/$t/$(basename "$f" .dat).parquet"
  mkdir -p "$OUT/$t"
  [ -s "$dst" ] && return 0
  "$DUCK" -c "SET preserve_insertion_order=false; SET threads=8;
    COPY (SELECT $cols FROM read_csv('$f', delim='|', header=false, quote='', escape='',
          nullstr='', columns={$colspec,'dummy':'VARCHAR'}))
    TO '$dst' (FORMAT PARQUET, COMPRESSION 'snappy');" >/dev/null 2>&1 \
    || { echo "CONVERT FAIL $t $(basename "$f")"; return 1; }
}

echo "=== SF=$SF, $CHILDREN children, waves of $WAVE  $(date -u +%H:%M) ==="
c=1
while [ "$c" -le "$CHILDREN" ]; do
  hi=$(( c + WAVE - 1 )); [ "$hi" -gt "$CHILDREN" ] && hi=$CHILDREN
  echo "--- wave children $c..$hi  $(date -u +%H:%M)"
  for i in $(seq "$c" "$hi"); do
    ( cd "$RAW" && "$DS/dsdgen" -scale "$SF" -dir "$RAW" -parallel "$CHILDREN" -child "$i" \
        -distributions "$DS/tpcds.idx" -force -quiet >/dev/null 2>&1 ) &
  done
  wait
  n=0
  for f in "$RAW"/*.dat; do
    [ -s "$f" ] || continue
    t=$(basename "$f" .dat | sed 's/_[0-9]*_[0-9]*$//')
    convert_chunk "$t" "$f" &
    n=$((n+1)); [ $(( n % PAR )) -eq 0 ] && wait
  done
  wait
  rm -f "$RAW"/*.dat
  df -h "$ROOT" | tail -1
  c=$(( hi + 1 ))
done

echo "=== inventory ==="
tot=0
for d in "$OUT"/*/; do
  t=$(basename "$d"); nf=$(ls "$d" | wc -l); sz=$(du -sm "$d" | cut -f1)
  printf "%-24s %4s files %8s MB\n" "$t" "$nf" "$sz"; tot=$((tot+sz))
done
echo "TOTAL ${tot} MB"
echo "GEN_TPCDS_DONE sf=$SF $(date -u +%H:%M)"
