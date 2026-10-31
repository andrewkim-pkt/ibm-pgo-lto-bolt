#!/bin/bash
# Phase 1 on the GNR lab box: JDK 17, Presto 0.299 server tarball, pinned source.
# Much shorter than the AWS phase 1 because this box already has gcc 15.2.0 bootstrapped,
# create_gcov built, llvm-bolt/perf2bolt on PATH, perf_event_paranoid=0, and every velox
# apt prerequisite installed by the earlier Velox campaign.
#
# SHARED BOX: mrittika is logged in, / is 93% full. Everything stays under $ROOT on /data,
# and nothing touches system packages (notably apt Boost 1.83, which is left alone because
# it already satisfies Presto's <1.87 requirement).
set -uo pipefail
source /data/prestissimo-fdo/scripts/env-gnr.sh
M=$ROOT/.markers
mkdir -p "$M"
log() { echo "[$(date -u +%H:%M)] $*"; }
done_already() { [ -f "$M/$1" ]; }
mark() { touch "$M/$1"; }
cd "$ROOT"

log "gcc: $($CXX --version | head -1)   cmake: $(cmake --version | head -1)"
log "/data free: $(df -h /data | awk 'NR==2{print $4}')"

# --- 1. Temurin JDK 17 ------------------------------------------------------
# Presto 0.29x dies on JDK 21 with [Guice/JitDisabled] on every JsonCodec.
if ! done_already jdk17; then
  log "installing Temurin JDK 17"
  mkdir -p "$ROOT/tools" && cd "$ROOT/tools"
  curl -fsSL -o jdk17.tar.gz \
    "https://github.com/adoptium/temurin17-binaries/releases/download/jdk-17.0.13%2B11/OpenJDK17U-jdk_x64_linux_hotspot_17.0.13_11.tar.gz" \
    >> "$LOGS/jdk.log" 2>&1 || { log "JDK download FAILED"; exit 1; }
  tar xzf jdk17.tar.gz && rm -f jdk17.tar.gz
  ln -sfn "$ROOT/tools/$(ls -d jdk-17* | head -1)" "$ROOT/tools/jdk17"
  mark jdk17
fi
log "java: $("$ROOT/tools/jdk17/bin/java" -version 2>&1 | head -1)"

# --- 2. Presto 0.299 coordinator tarball ------------------------------------
if ! done_already presto-server; then
  log "fetching presto-server 0.299"
  cd "$ROOT/tools"
  curl -fsSL -o presto-server-0.299.tar.gz \
    "https://repo1.maven.org/maven2/com/facebook/presto/presto-server/0.299/presto-server-0.299.tar.gz" \
    >> "$LOGS/presto-dl.log" 2>&1 || { log "presto-server download FAILED"; exit 1; }
  tar xzf presto-server-0.299.tar.gz
  mark presto-server
fi
log "presto-server: $(ls -d "$ROOT"/tools/presto-server-0.299 2>/dev/null || echo MISSING)"

# --- 3. source at the exact pin used on both AWS boxes ----------------------
# presto 7d507216 (describe 0.299), velox 1d9c83a9, FB_OS_VERSION v2026.01.05.00.
# The coordinator's presto.version is a git-describe (0.299-7d50721), and workers must
# match it EXACTLY or they are silently excluded from the ACTIVE set.
if ! done_already src-presto; then
  log "cloning prestodb/presto @ 7d507216 with velox submodule"
  mkdir -p "$ROOT/src" && cd "$ROOT/src"
  rm -rf presto
  git clone --quiet https://github.com/prestodb/presto.git >> "$LOGS/clone.log" 2>&1 \
    || { log "clone FAILED"; exit 1; }
  cd presto && git checkout --quiet 7d507216 >> "$LOGS/clone.log" 2>&1 \
    || { log "checkout FAILED"; exit 1; }
  git submodule update --init --recursive --depth 1 presto-native-execution/velox \
      >> "$LOGS/clone.log" 2>&1 || { log "submodule FAILED"; exit 1; }
  mark src-presto
fi
cd "$ROOT/src/presto"
log "presto HEAD: $(git rev-parse --short HEAD)  describe: $(git describe --tags 2>/dev/null)"
log "velox HEAD : $(git -C presto-native-execution/velox rev-parse --short HEAD 2>/dev/null)"
log "velox pin  : $(grep -m1 'FB_OS_VERSION=' presto-native-execution/velox/scripts/setup-versions.sh 2>/dev/null)"

log "PHASE1_DONE  nodes=$NUM_NODES cpus=$(nproc) ram=$(free -g | awk 'NR==2{print $2}')GB"
