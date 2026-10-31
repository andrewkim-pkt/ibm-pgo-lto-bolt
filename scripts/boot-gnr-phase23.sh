#!/bin/bash
# GNR box phases 2+3+data, CHAINED so there are no idle gaps between them (phase 1 sat
# finished-and-idle for 2h47m because nothing followed it).
#
# Deps differ from the AWS recipe in three ways, all verified on this box:
#  * NO install_boost and NO apt-Boost purge. apt Boost here is 1.83: < 1.87, HAS
#    boost/asio/io_service.hpp, and exports Boost.Context UNMANGLED
#    (T make_fcontext / T jump_fcontext). It therefore satisfies Presto directly. The whole
#    "build 1.84, purge apt" dance on AWS was an artifact of Ubuntu 26.04 shipping 1.90.
#    This is also a SHARED box, so removing 71 system -dev packages is not acceptable.
#  * NO CMAKE_POLICY_VERSION_MINIMUM: cmake is 3.28 here, not 4.x.
#  * NO install_flatbuffers / install_openzl -- they do not exist at this velox pin
#    (FB_OS_VERSION v2026.01.05.00) and calling them aborts the run.
# Still required: EXTRA_PKG_CXXFLAGS=" -include cstdint" for this pin's mvfst under gcc 15,
# chmod u+w between dep installs (they leave deps/lib root-owned), and proxygen with
# BUILD_SAMPLES=OFF (its sample binaries fail to link; libproxygen.a itself is fine).
set -uo pipefail
source /data/prestissimo-fdo/scripts/env-gnr.sh
M=$ROOT/.markers
mkdir -p "$M"
log() { echo "[$(date -u +%H:%M)] $*"; }
done_already() { [ -f "$M/$1" ]; }
mark() { touch "$M/$1"; }
cd "$ROOT"

export INSTALL_PREFIX=$ROOT/deps DEPENDENCY_DIR=$ROOT/deps-src NPROC=${NPROC:-160}
export SUDO="" PROMPT_ALWAYS_RESPOND=n INSTALL_PREREQUISITES=N
export EXTRA_PKG_CXXFLAGS=" -include cstdint"
mkdir -p "$INSTALL_PREFIX" "$DEPENDENCY_DIR"

log "apt Boost $(grep -m1 'define BOOST_LIB_VERSION' /usr/include/boost/version.hpp | grep -oE '1_[0-9]+') used directly"
[ -f /usr/include/boost/asio/io_service.hpp ] \
  || { log "ABORT: apt Boost has no io_service.hpp -> too new for Presto"; exit 1; }

# ============================ deps ==========================================
for f in install_fmt install_fast_float install_folly install_fizz \
         install_wangle install_mvfst install_fbthrift; do
  if done_already "dep-$f"; then log "$f already done"; continue; fi
  log "$f"
  cd "$VELOX"
  bash scripts/setup-ubuntu.sh "$f" > "$LOGS/dep-$f.log" 2>&1 \
     || { log "FAILED at $f"; tail -25 "$LOGS/dep-$f.log" | cut -c1-180; exit 1; }
  chmod -R u+w "$ROOT/deps" 2>/dev/null || true
  mark "dep-$f"
done

if ! done_already dep-proxygen; then
  log "proxygen"
  cd "$PRESTO"
  bash scripts/setup-ubuntu.sh install_proxygen > "$LOGS/dep-proxygen.log" 2>&1 || true
  if [ ! -f "$ROOT/deps/lib/libproxygen.a" ]; then
    log "retrying proxygen with BUILD_SAMPLES=OFF"
    cd "$ROOT/deps-src/proxygen" 2>/dev/null || { log "no proxygen source"; exit 1; }
    cmake -B _build2 -GNinja -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
      -DCMAKE_CXX_FLAGS="-mavx2 -mfma -mavx -mf16c -mlzcnt -mbmi2 -O3 -DNDEBUG" \
      -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
      -DBUILD_TESTS=OFF -DBUILD_SAMPLES=OFF -DBUILD_SHARED_LIBS=OFF \
      -DCMAKE_INSTALL_PREFIX="$ROOT/deps" -DCMAKE_PREFIX_PATH="$ROOT/deps" \
      >> "$LOGS/dep-proxygen2.log" 2>&1 \
      && ninja -C _build2 -j"$NPROC" install >> "$LOGS/dep-proxygen2.log" 2>&1 \
      || { log "PROXYGEN FAILED"; tail -15 "$LOGS/dep-proxygen2.log" | cut -c1-180; exit 1; }
  fi
  chmod -R u+w "$ROOT/deps" 2>/dev/null || true
  mark dep-proxygen
fi
[ -f "$ROOT/deps/lib/libproxygen.a" ] || { log "ABORT: no libproxygen.a"; exit 1; }

if ! done_already dep-datasketches; then
  log "datasketches"
  cd "$PRESTO"
  bash scripts/setup-ubuntu.sh install_datasketches > "$LOGS/dep-ds.log" 2>&1 || true
  chmod -R u+w "$ROOT/deps" 2>/dev/null || true
  mark dep-datasketches
fi

# The check that actually matters. Use libfolly.a, NOT libfolly_fibers_core.a: the latter
# does not exist in a static build, so nm on a missing file fails the grep and produces a
# bogus "found a different Boost" warning (that false alarm cost time on the 48xl).
if nm "$ROOT/deps/lib/libfolly.a" 2>/dev/null | grep -qE "U +(make|jump)_fcontext"; then
  log "folly wants UNMANGLED fcontext -- consistent with apt Boost 1.83 OK"
else
  log "WARNING folly fcontext refs look MANGLED:"
  nm "$ROOT/deps/lib/libfolly.a" 2>/dev/null | grep -m2 fcontext
fi
log "deps: $(find "$ROOT/deps" -name '*onfig.cmake' | wc -l) cmake configs, $(du -sh "$ROOT/deps" | cut -f1)"

# ============================ tooling =======================================
if ! done_already tool-duckdb; then
  log "duckdb CLI"
  mkdir -p "$ROOT/tools"; cd "$ROOT/tools"
  curl -fsSL -o duckdb.zip \
    https://github.com/duckdb/duckdb/releases/download/v1.1.3/duckdb_cli-linux-amd64.zip \
    >> "$LOGS/duckdb.log" 2>&1 || { log "duckdb download FAILED"; exit 1; }
  unzip -o -q duckdb.zip && rm -f duckdb.zip && chmod +x duckdb
  mark tool-duckdb
fi

if ! done_already tool-schema; then
  log "TPC-DS DDL from duckdb's tpcds extension (NOT hand-written)"
  cd "$ROOT/tools"
  rm -f /tmp/sf1.duckdb
  ./duckdb /tmp/sf1.duckdb -c "INSTALL tpcds; LOAD tpcds; SELECT * FROM dsdgen(sf=1);" \
      > "$LOGS/schema.log" 2>&1 || { log "dsdgen(sf=1) FAILED"; tail -10 "$LOGS/schema.log"; exit 1; }
  ./duckdb /tmp/sf1.duckdb -noheader -list -c \
      "SELECT sql||';' FROM duckdb_tables() WHERE schema_name='main' ORDER BY table_name;" \
      > "$RES/tpcds-schema.sql" 2>> "$LOGS/schema.log"
  mark tool-schema
fi
ntab=$(grep -c "CREATE TABLE" "$RES/tpcds-schema.sql" 2>/dev/null || echo 0)
log "schema: $ntab tables"
[ "$ntab" -eq 24 ] || { log "ABORT: expected 24 TPC-DS tables, got $ntab"; exit 1; }

if ! done_already tool-dsdgen; then
  # -DLINUX must be kept: overriding CFLAGS wholesale drops the makefile's own -DLINUX and
  # config.h then fails with "#error The code now requires 64b support".
  log "dsdgen (gcc 15 needs -DLINUX -std=gnu89 -fcommon)"
  cd "$ROOT/tools"
  rm -rf tpcds-kit
  git clone --quiet --depth 1 https://github.com/gregrahn/tpcds-kit.git \
      >> "$LOGS/dsdgen.log" 2>&1 || { log "clone FAILED"; exit 1; }
  cd tpcds-kit/tools
  make -j32 CC="$CC" OS=LINUX \
       CFLAGS="-DLINUX -std=gnu89 -fcommon -O2 -Wno-implicit-function-declaration -Wno-int-conversion -Wno-error" \
       >> "$LOGS/dsdgen.log" 2>&1 \
    || { log "dsdgen FAILED"; grep -m5 -i error "$LOGS/dsdgen.log" | cut -c1-160; exit 1; }
  mark tool-dsdgen
fi
[ -x "$ROOT/tools/tpcds-kit/tools/dsdgen" ] || { log "ABORT: no dsdgen"; exit 1; }
log "dsdgen OK"

# ============================ datasets ======================================
for sf in 10 1000; do
  if done_already "data-sf$sf"; then log "SF=$sf already generated"; continue; fi
  log "generating SF=$sf  (free: $(df -h /data | awk 'NR==2{print $4}'))"
  if [ "$sf" = 1000 ]; then CH=96; WV=12; PR=24; else CH=12; WV=12; PR=12; fi
  cd "$ROOT" && SF=$sf CHILDREN=$CH WAVE=$WV PAR=$PR "$ROOT/scripts/gen-tpcds-gnr.sh" > "$LOGS/gen-sf$sf.log" 2>&1 \
    || { log "SF=$sf generation FAILED"; tail -15 "$LOGS/gen-sf$sf.log" | cut -c1-160; exit 1; }
  mark "data-sf$sf"
  log "SF=$sf done: $(du -sh "$ROOT/tpcds-sf$sf" 2>/dev/null | cut -f1)"
done

log "PHASE23_DONE  /data free: $(df -h /data | awk 'NR==2{print $4}')"
