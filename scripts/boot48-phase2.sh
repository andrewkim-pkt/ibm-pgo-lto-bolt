#!/bin/bash
# Phase 2 of the Prestissimo FDO port to the 48xl: the dependency stack.
# Resumable via markers -- this is the step that cost days on the 96xl, so every known
# blocker is encoded here rather than rediscovered.
#
#  * BOOST 1.84 FIRST, and it must be the ONLY findable Boost. Presto's PrestoServer.cpp
#    includes <boost/asio/io_service.hpp>, removed in Boost 1.87, so Presto needs <1.87 =
#    Velox's pinned 1.84. Boost 1.84 exports Boost.Context as extern "C" (UNMANGLED
#    make_fcontext/jump_fcontext); folly built against it emits unmangled refs. Mixing
#    versions gives undefined make_fcontext/jump_fcontext at link. find_package in CONFIG
#    mode prefers the HIGHEST version, so apt Boost must be absent (verified in phase 1).
#  * NO install_flatbuffers / install_openzl: they do not exist at this velox pin
#    (FB_OS_VERSION v2026.01.05.00) and calling them aborts the run.
#  * EXTRA_PKG_CXXFLAGS=" -include cstdint": gcc 15's libstdc++ no longer pulls <cstdint>
#    in transitively and this pin's mvfst relies on that.
#  * proxygen's sample binaries fail to link -> BUILD_SAMPLES=OFF (libproxygen.a is fine).
#  * dep installs leave deps/lib root-owned -> chmod u+w between steps.
set -uo pipefail
source /data/velox-fdo/scripts/env48.sh
M=$ROOT/.markers
mkdir -p "$M" "$LOGS"
log() { echo "[$(date -u +%H:%M)] $*"; }
done_already() { [ -f "$M/$1" ]; }
mark() { touch "$M/$1"; }

export INSTALL_PREFIX=$ROOT/deps DEPENDENCY_DIR=$ROOT/deps-src NPROC=${NPROC:-160}
export SUDO="" PROMPT_ALWAYS_RESPOND=n INSTALL_PREREQUISITES=N CMAKE_POLICY_VERSION_MINIMUM=3.5
export EXTRA_PKG_CXXFLAGS=" -include cstdint"
mkdir -p "$INSTALL_PREFIX" "$DEPENDENCY_DIR"

log "velox pin: $(grep -m1 FB_OS_VERSION "$VELOX/scripts/setup-versions.sh" 2>/dev/null)"
log "gcc: $($CXX --version | head -1)  NPROC=$NPROC"

# --- 1. Velox's prerequisite system packages --------------------------------
if ! done_already dep-prereq; then
  log "velox prerequisite packages"
  cd "$VELOX"
  # This one wants sudo and installs apt packages; it may re-add Boost, so we purge after.
  SUDO="sudo" INSTALL_PREREQUISITES=Y PROMPT_ALWAYS_RESPOND=y \
      bash scripts/setup-ubuntu.sh install_build_prerequisites \
      > "$LOGS/p48-prereq.log" 2>&1 || log "prereq step returned nonzero (continuing)"
  sudo DEBIAN_FRONTEND=noninteractive apt-get remove -y -qq 'libboost*-dev' libboost-all-dev \
      >> "$LOGS/p48-prereq.log" 2>&1 || true
  mark dep-prereq
fi
nb=$(dpkg -l 2>/dev/null | grep -c "^ii.*libboost.*dev" || true)
log "apt boost dev packages present: $nb (MUST be 0)"
[ "$nb" -eq 0 ] || { log "ABORT: apt Boost present, it would beat 1.84 in find_package"; exit 1; }

# --- 2. Boost 1.84 ----------------------------------------------------------
if ! done_already dep-boost; then
  log "building Boost 1.84 (velox pin)"
  rm -rf "$DEPENDENCY_DIR/boost"
  cd "$VELOX"
  bash scripts/setup-ubuntu.sh install_boost > "$LOGS/p48-boost.log" 2>&1 \
     || { log "BOOST FAILED"; tail -25 "$LOGS/p48-boost.log" | cut -c1-180; exit 1; }
  chmod -R u+w "$ROOT/deps" 2>/dev/null || true
  mark dep-boost
fi
log "boost: $(grep -m1 BOOST_LIB_VERSION "$ROOT/deps/include/boost/version.hpp" 2>/dev/null)"
[ -f "$ROOT/deps/include/boost/asio/io_service.hpp" ] \
  || { log "ABORT: io_service.hpp missing -> Boost >=1.87, Presto will not compile"; exit 1; }
log "io_service.hpp present OK"
log "boost context syms: $(nm -D --defined-only "$ROOT/deps"/lib/libboost_context.so* 2>/dev/null | grep -ci fcontext) fcontext entries"

# --- 3. FB stack (NO flatbuffers / openzl at this pin) ----------------------
for f in install_fmt install_fast_float install_folly install_fizz \
         install_wangle install_mvfst install_fbthrift; do
  if done_already "dep-$f"; then log "$f already done"; continue; fi
  log "$f"
  cd "$VELOX"
  bash scripts/setup-ubuntu.sh "$f" > "$LOGS/p48-$f.log" 2>&1 \
     || { log "FAILED at $f"; tail -25 "$LOGS/p48-$f.log" | cut -c1-180; exit 1; }
  chmod -R u+w "$ROOT/deps" 2>/dev/null || true
  mark "dep-$f"
done

# --- 4. proxygen + datasketches (Presto-only extras) ------------------------
if ! done_already dep-proxygen; then
  log "proxygen"
  cd "$PRESTO"
  bash scripts/setup-ubuntu.sh install_proxygen > "$LOGS/p48-proxygen.log" 2>&1 || true
  if [ ! -f "$ROOT/deps/lib/libproxygen.a" ]; then
    log "retrying proxygen with BUILD_SAMPLES=OFF"
    "$ROOT/scripts/proxygen48.sh" > "$LOGS/p48-proxygen2.log" 2>&1 \
       || { log "PROXYGEN FAILED"; tail -15 "$LOGS/p48-proxygen2.log" | cut -c1-180; exit 1; }
  fi
  chmod -R u+w "$ROOT/deps" 2>/dev/null || true
  mark dep-proxygen
fi
[ -f "$ROOT/deps/lib/libproxygen.a" ] || { log "ABORT: no libproxygen.a"; exit 1; }
log "libproxygen.a OK"

if ! done_already dep-datasketches; then
  log "datasketches"
  cd "$PRESTO"
  bash scripts/setup-ubuntu.sh install_datasketches > "$LOGS/p48-ds.log" 2>&1 || true
  chmod -R u+w "$ROOT/deps" 2>/dev/null || true
  mark dep-datasketches
fi

# --- 5. the consistency check that actually matters -------------------------
if nm "$ROOT/deps/lib/libfolly_fibers_core.a" 2>/dev/null | grep -qE "U +(make|jump)_fcontext"; then
  log "folly wants UNMANGLED fcontext -- consistent with Boost 1.84 OK"
else
  log "WARNING folly fcontext refs look MANGLED -> it found a different Boost:"
  nm "$ROOT/deps/lib/libfolly_fibers_core.a" 2>/dev/null | grep -m2 fcontext
fi
log "installed configs: $(find "$ROOT/deps" -name "*onfig.cmake" | wc -l)"
log "PHASE2_DONE"
