#!/usr/bin/env python3
"""Analyse the Prestissimo FDO campaign: per-arm queries/hour vs base.

Only valid=yes runs are used. A run is valid when all 60 query-executions succeeded --
the first campaign was invalidated because failed queries return in ~0 s, shrinking wall
time and INFLATING queries/hour, which made base look 4x faster than itself.

Headline is the PAIRED per-round delta: each arm is compared with base from the SAME
round, then averaged. Pairing cancels drift between rounds, which matters here because
the host was being restarted throughout. The unpaired mean is shown alongside so any
disagreement between the two is visible rather than hidden.
"""
import sys, statistics as st
from collections import defaultdict

path = sys.argv[1] if len(sys.argv) > 1 else "/data/prestissimo-fdo/results/tput-summary.tsv"
BASE = "base"
runs = defaultdict(dict)      # arm -> round -> qph
invalid = []
cal = None
for line in open(path):
    f = line.rstrip("\n").split("\t")
    if not f or not f[0]:
        continue
    kv = dict(x.split("=", 1) for x in f[1:] if "=" in x)
    qph = float(kv.get("queries_per_hour", 0))
    label = f[0]
    if label == "base-cal":
        cal = qph; continue
    if kv.get("valid") != "yes":
        invalid.append((label, kv.get("queries", "?"), kv.get("fail", "?"))); continue
    arm, _, rnd = label.rpartition("-r")
    runs[arm][int(rnd)] = qph

print("# Prestissimo TPC-DS SF=1000 — gcc 15.2.0 AutoFDO campaign\n")
if cal:
    print(f"calibration (base, 60/60, 97% CPU): **{cal:.1f} queries/hour**\n")
if invalid:
    print("## Runs excluded as invalid\n")
    for l, q, fl in invalid:
        print(f"- {l}: queries={q}, fail={fl}")
    print()
if BASE not in runs:
    print("No valid base runs yet — cannot compute deltas."); sys.exit(0)

rounds = sorted(runs[BASE])
arms = [BASE] + sorted(a for a in runs if a != BASE)
print(f"valid rounds per arm: " + ", ".join(f"{a}={len(runs[a])}" for a in arms) + "\n")

print("## queries/hour by run\n")
print("| arm | " + " | ".join(f"r{r}" for r in rounds) + " | mean |")
print("|" + "---|" * (len(rounds) + 2))
for a in arms:
    cells = [f"{runs[a][r]:.1f}" if r in runs[a] else "—" for r in rounds]
    vals = list(runs[a].values())
    print(f"| {a} | " + " | ".join(cells) + f" | **{st.mean(vals):.1f}** |")

print("\n## Paired vs base (same round), positive = faster\n")
print("| arm | " + " | ".join(f"r{r}" for r in rounds) + " | paired mean | unpaired mean | rounds favouring |")
print("|" + "---|" * (len(rounds) + 4))
for a in arms:
    if a == BASE:
        continue
    per, cells = [], []
    for r in rounds:
        if r in runs[a] and r in runs[BASE]:
            d = (runs[a][r] / runs[BASE][r] - 1) * 100
            per.append(d); cells.append(f"{d:+.2f}")
        else:
            cells.append("—")
    if not per:
        continue
    unp = (st.mean(runs[a].values()) / st.mean(runs[BASE].values()) - 1) * 100
    pos = sum(1 for d in per if d > 0)
    print(f"| {a} | " + " | ".join(cells) + f" | **{st.mean(per):+.2f}%** | {unp:+.2f}% | {pos}/{len(per)} |")

bs = list(runs[BASE].values())
if len(bs) > 1:
    spread = (max(bs) / min(bs) - 1) * 100
    print(f"\n## Noise floor\n\nbase against itself: {min(bs):.1f}–{max(bs):.1f} q/h "
          f"(**{spread:+.1f}%** spread over {len(bs)} runs).")
    print("Any arm delta smaller than this is not resolvable by this campaign.")
print("\nReference: Jantz measured **+3.5%** with icx HW PGO on this workload; "
      "<5% was stated as uninteresting to IBM, ~20% as conversation-starting.")
