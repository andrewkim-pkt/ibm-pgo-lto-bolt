#!/bin/bash
# Phase 3: data-generation tooling (dsdgen + duckdb + the TPC-DS schema).
# Light enough to run alongside a presto_server build.
#
# Blockers encoded here:
#  * dsdgen will NOT build under gcc 15 without -std=gnu89 -fcommon: gcc 15 defaults to
#    C23, where implicit-int is a hard error, and -fno-common is the default while the
#    TPC-DS tools rely on common symbols.
#  * The table schemas come from duckdb's tpcds extension, NOT hand-written DDL -- getting
#    column order or types wrong silently produces garbage Parquet.
#  * .dat rows carry a TRAILING '|', so each read_csv needs one throwaway column. That is
#    handled in gen-tpcds48.sh, which consumes the schema this script writes.
set -uo pipefail
source /data/velox-fdo/scripts/env48.sh
M=$ROOT/.markers
mkdir -p "$M" "$LOGS" "$RES" "$ROOT/tools"
log() { echo "[$(date -u +%H:%M)] $*"; }
done_already() { [ -f "$M/$1" ]; }
mark() { touch "$M/$1"; }

# --- 1. duckdb CLI ----------------------------------------------------------
if ! done_already tool-duckdb; then
  log "fetching duckdb CLI"
  cd "$ROOT/tools"
  curl -fsSL -o duckdb.zip \
    https://github.com/duckdb/duckdb/releases/download/v1.1.3/duckdb_cli-linux-amd64.zip \
    >> "$LOGS/p48-duckdb.log" 2>&1 || { log "duckdb download FAILED"; exit 1; }
  unzip -o -q duckdb.zip && rm -f duckdb.zip && chmod +x duckdb
  mark tool-duckdb
fi
log "duckdb: $("$ROOT/tools/duckdb" --version 2>/dev/null)"

# --- 2. TPC-DS schema straight out of duckdb's tpcds extension --------------
if ! done_already tool-schema; then
  log "extracting TPC-DS DDL from duckdb tpcds extension"
  cd "$ROOT/tools"
  rm -f /tmp/sf1.duckdb
  ./duckdb /tmp/sf1.duckdb -c "INSTALL tpcds; LOAD tpcds; SELECT * FROM dsdgen(sf=1);" \
      > "$LOGS/p48-schema.log" 2>&1 || { log "dsdgen(sf=1) FAILED"; tail -10 "$LOGS/p48-schema.log"; exit 1; }
  ./duckdb /tmp/sf1.duckdb -noheader -list -c \
      "SELECT sql||';' FROM duckdb_tables() WHERE schema_name='main' ORDER BY table_name;" \
      > "$RES/tpcds-schema.sql" 2>> "$LOGS/p48-schema.log"
  mark tool-schema
fi
ntab=$(grep -c "CREATE TABLE" "$RES/tpcds-schema.sql" 2>/dev/null || echo 0)
log "schema: $ntab tables in $RES/tpcds-schema.sql"
[ "$ntab" -eq 24 ] || { log "ABORT: expected 24 TPC-DS tables, got $ntab"; exit 1; }

# --- 3. dsdgen from tpcds-kit ----------------------------------------------
if ! done_already tool-dsdgen; then
  log "building dsdgen (gcc 15 needs -std=gnu89 -fcommon)"
  cd "$ROOT/tools"
  rm -rf tpcds-kit
  git clone --quiet --depth 1 https://github.com/gregrahn/tpcds-kit.git \
      >> "$LOGS/p48-dsdgen.log" 2>&1 || { log "tpcds-kit clone FAILED"; exit 1; }
  cd tpcds-kit/tools
  make -j"$JOBS" CC="$CC" OS=LINUX \
       CFLAGS="-DLINUX -std=gnu89 -fcommon -O2 -Wno-implicit-function-declaration -Wno-int-conversion" \
       >> "$LOGS/p48-dsdgen.log" 2>&1 \
    || { log "dsdgen build FAILED"; grep -m5 -i error "$LOGS/p48-dsdgen.log" | cut -c1-160; exit 1; }
  mark tool-dsdgen
fi
[ -x "$ROOT/tools/tpcds-kit/tools/dsdgen" ] || { log "ABORT: no dsdgen binary"; exit 1; }
log "dsdgen built OK"

log "PHASE3_DONE"
