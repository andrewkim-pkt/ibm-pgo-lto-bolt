#!/usr/bin/env python3
"""Remap the 16xl point from 1 worker on node 0 to 2 workers over nodes 0+1.

Same 64 vCPU either way, but a real r8i.16xl has 512 GB RAM while node 0 alone gives only
251 GB. The 1-worker mapping was therefore memory-starved relative to the instance it is
meant to emulate, and 4 concurrent streams of SF=1000 hit real limits:
    q19: Exceeded memory pool capacity
    q61: Query exceeded per-query local spill limit of 100.00GB
Splitting the same 64 logical cpus over two nodes gives ~502 GB, matching the instance.

Worker CPU lists keep whole physical cores with BOTH hyperthread siblings:
  worker0  node 0  cores 0-15   -> logical 0-15,  96-111
  worker1  node 1  cores 64-79  -> logical 32-47, 128-143
"""
p = "/data/prestissimo-fdo/scripts/measure-ec2.sh"
s = open(p).read()

old = '  16xl) WORKER_CPUS=("0-31,96-127"); WORKER_NODES=(0); VCPU=64 ;;'
new = '  16xl) WORKER_CPUS=("0-15,96-111" "32-47,128-143"); WORKER_NODES=(0 1); VCPU=64 ;;'

if new in s:
    print("already remapped")
    raise SystemExit(0)
assert old in s, "16xl case line not found verbatim"
s = s.replace(old, new, 1)
open(p, "w").write(s)
print("16xl remapped to 2 workers over nodes 0+1 (64 vCPU, ~502 GB)")
