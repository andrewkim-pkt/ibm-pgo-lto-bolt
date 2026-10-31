#!/bin/bash
# Phase 1 of the Prestissimo FDO port to r8i.metal-48xl (192 vCPU, 3 SNC nodes, 1511 GB).
# OS prep + toolchain + pinned source. Resumable: every step is guarded by its own marker,
# so re-running after a host stop costs nothing.
#
# Carried over from the 96xl campaign (do not rediscover these):
#  * gcc 15.2.0 comes from apt on Ubuntu 26.04 - no bootstrap needed.
#  * JDK 21 breaks Presto 0.29x with [Guice/JitDisabled] on every JsonCodec -> Temurin 17,
#    and apt has no openjdk-17.
#  * Presto needs Boost <1.87 (boost/asio/io_service.hpp) and folly must link the SAME
#    Boost it compiled against. find_package CONFIG mode prefers the HIGHEST version, so
#    apt's Boost silently beats a local 1.84 -> the apt Boost dev packages MUST be removed.
#  * perf_event_paranoid defaults to 4 on this image, which silently kills AutoFDO/BOLT.
#  * This box has NO separate /data volume, unlike the 96xl: / is 2 TB, so /data is a plain
#    directory on root. TMPDIR must live there too (the 96xl filled / once).
set -uo pipefail
ROOT=/data/velox-fdo
M=$ROOT/.markers
log() { echo "[$(date -u +%H:%M)] $*"; }
done_already() { [ -f "$M/$1" ]; }
mark() { touch "$M/$1"; }

sudo mkdir -p /data && sudo chown -R "$(id -u):$(id -g)" /data
mkdir -p "$ROOT"/{src,deps,deps-src,logs,results,prof,arms,toolchain,tmp,cluster} "$M"
export TMPDIR=$ROOT/tmp
cd "$ROOT"

# --- 1. base packages -------------------------------------------------------
if ! done_already apt-base; then
  log "apt base packages"
  sudo apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
      build-essential git curl wget unzip pkg-config \
      cmake ninja-build python3 python3-pip python3-venv \
      numactl bison flex libtool autoconf automake \
      libssl-dev libcurl4-openssl-dev libxml2-dev libxslt1-dev \
      zlib1g-dev liblz4-dev libzstd-dev libsnappy-dev libbz2-dev \
      linux-tools-common linux-tools-generic \
      gcc-15 g++-15 >> "$ROOT/logs/apt.log" 2>&1 \
    || { log "apt FAILED"; tail -20 "$ROOT/logs/apt.log"; exit 1; }
  mark apt-base
fi
log "gcc: $(/usr/bin/gcc-15 --version | head -1)"
log "cmake: $(cmake --version | head -1)   ninja: $(ninja --version)"

# --- 2. remove apt Boost (blocker: find_package prefers the highest version) ----
if ! done_already boost-purge; then
  n=$(dpkg -l 2>/dev/null | grep -c "libboost.*-dev" || true)
  log "removing $n apt boost dev packages"
  sudo DEBIAN_FRONTEND=noninteractive apt-get remove -y -qq 'libboost*-dev' \
      >> "$ROOT/logs/apt.log" 2>&1 || true
  mark boost-purge
fi

# --- 3. perf counters -------------------------------------------------------
if ! done_already perf-sysctl; then
  printf 'kernel.perf_event_paranoid = 0\nkernel.kptr_restrict = 0\n' \
      | sudo tee /etc/sysctl.d/99-perf.conf > /dev/null
  sudo sysctl --system > /dev/null 2>&1
  mark perf-sysctl
fi
log "perf_event_paranoid=$(cat /proc/sys/kernel/perf_event_paranoid)"

# --- 4. Temurin JDK 17 ------------------------------------------------------
if ! done_already jdk17; then
  log "installing Temurin JDK 17"
  cd "$ROOT/toolchain"
  curl -fsSL -o jdk17.tar.gz \
    "https://github.com/adoptium/temurin17-binaries/releases/download/jdk-17.0.13%2B11/OpenJDK17U-jdk_x64_linux_hotspot_17.0.13_11.tar.gz" \
    >> "$ROOT/logs/jdk.log" 2>&1 || { log "JDK download FAILED"; exit 1; }
  tar xzf jdk17.tar.gz && rm -f jdk17.tar.gz
  ln -sfn "$ROOT/toolchain/$(ls -d jdk-17* | head -1)" "$ROOT/tools-jdk17"
  mkdir -p "$ROOT/tools" && ln -sfn "$ROOT/tools-jdk17" "$ROOT/tools/jdk17"
  mark jdk17
fi
log "java: $("$ROOT/tools/jdk17/bin/java" -version 2>&1 | head -1)"

# --- 5. Presto 0.299 server tarball (coordinator) ---------------------------
if ! done_already presto-server; then
  log "fetching presto-server 0.299"
  mkdir -p "$ROOT/tools" && cd "$ROOT/tools"
  curl -fsSL -o presto-server-0.299.tar.gz \
    "https://repo1.maven.org/maven2/com/facebook/presto/presto-server/0.299/presto-server-0.299.tar.gz" \
    >> "$ROOT/logs/presto-dl.log" 2>&1 || { log "presto-server download FAILED"; exit 1; }
  tar xzf presto-server-0.299.tar.gz
  mark presto-server
fi
log "presto-server: $(ls -d "$ROOT"/tools/presto-server-0.299 2>/dev/null || echo MISSING)"

# --- 6. source at the exact 96xl pin ---------------------------------------
if ! done_already src-presto; then
  log "cloning prestodb/presto @ 7d507216 (0.299) with velox submodule"
  cd "$ROOT/src"
  rm -rf presto
  git clone --quiet https://github.com/prestodb/presto.git >> "$ROOT/logs/clone.log" 2>&1 \
    || { log "clone FAILED"; exit 1; }
  cd presto && git checkout --quiet 7d507216 >> "$ROOT/logs/clone.log" 2>&1 \
    || { log "checkout 7d507216 FAILED"; exit 1; }
  git submodule update --init --recursive --depth 1 presto-native-execution/velox \
      >> "$ROOT/logs/clone.log" 2>&1 || { log "submodule FAILED"; exit 1; }
  mark src-presto
fi
cd "$ROOT/src/presto"
log "presto HEAD: $(git rev-parse --short HEAD)  describe: $(git describe --tags 2>/dev/null || echo n/a)"
log "velox HEAD : $(git -C presto-native-execution/velox rev-parse --short HEAD 2>/dev/null)"

log "PHASE1_DONE  nodes=$(numactl -H | grep -c '^node [0-9]* cpus')  cpus=$(nproc)"
