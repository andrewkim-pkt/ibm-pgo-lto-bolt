#!/bin/bash
set -euo pipefail
source /etc/environment
export http_proxy https_proxy no_proxy
ROOT=/data/velox-fdo
cd "$ROOT/src"
if [ ! -d velox ]; then
  echo "== cloning velox =="
  git clone --recursive https://github.com/facebookincubator/velox.git
fi
cd velox
git log -1 --format='PIN commit=%H date=%ci subject=%s' | tee "$ROOT/results/velox-pin.txt"
git submodule status | tee "$ROOT/results/velox-submodules.txt"
du -sh .
echo "CLONE_DONE"
