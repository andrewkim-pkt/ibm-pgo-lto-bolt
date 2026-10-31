#!/usr/bin/env python3
"""Sensitivity of the headline to individual queries.

q16 and q17 improve in EVERY arm, including arms that are flat overall. That is not an
FDO signature -- it suggests base hits a slow mode on those queries -- so the headline
must be shown to survive their removal, or be reported with the caveat.
"""
import json, os, sys, glob, statistics
from collections import defaultdict

d = defaultdict(dict)
for p in sorted(glob.glob(f"{sys.argv[1]}/*.r*.json")):
    fn = os.path.basename(p); arm = fn.split(".r")[0]; rnd = int(fn.split(".r")[1].split(".")[0])
    rows = {}
    for r in json.load(open(p)):
        if isinstance(r, (list, tuple)) and len(r) >= 3 and isinstance(r[2], (int, float)) and r[2] > 0:
            rows[str(r[1]).lstrip("%")] = float(r[2])
    if len(rows) == 22:
        d[arm][rnd] = rows
B = d["base"]; rounds = sorted(B)
allq = sorted(B[rounds[0]], key=lambda x: int("".join(c for c in x if c.isdigit()) or 0))

def paired(arm, qs):
    vals = []
    for r in rounds:
        if r in d[arm]:
            vals.append((statistics.geometric_mean([B[r][q] / d[arm][r][q] for q in qs]) - 1) * 100)
    return vals

# per-query consistency: in how many ARMS does each query favour the arm?
print("## Queries where base loses to (almost) every arm -- suspect, not FDO\n")
print("| query | base ms | arms favouring arm (of 8) | mean delta across arms |")
print("|---|---|---|---|")
arms = sorted(a for a in d if a != "base")
susp = []
for q in allq:
    deltas = []
    for a in arms:
        bm = statistics.median([B[r][q] for r in rounds])
        am = statistics.median([d[a][r][q] for r in rounds if r in d[a]])
        deltas.append((bm / am - 1) * 100)
    pos = sum(1 for x in deltas if x > 0)
    bm = statistics.median([B[r][q] for r in rounds]) / 1e6
    if pos >= 8 and statistics.mean(deltas) > 5:
        susp.append(q)
    print(f"| {q} | {bm:,.0f} | {pos}/8 | {statistics.mean(deltas):+.1f}% |")

print(f"\nSuspect queries (all 8 arms beat base by >5% on average): **{susp or 'none'}**\n")

print("## Headline with and without the suspect queries\n")
keep = [q for q in allq if q not in susp]
print(f"full set = 22 queries; reduced set = {len(keep)} queries (dropped {susp})\n")
print("| arm | all 22 | suspect dropped | change | rounds favouring (reduced) |")
print("|---|---|---|---|---|")
for a in arms:
    f = paired(a, allq); r2 = paired(a, keep)
    pos = sum(1 for v in r2 if v > 0)
    print(f"| {a} | {statistics.mean(f):+.2f}% | **{statistics.mean(r2):+.2f}%** | "
          f"{statistics.mean(r2)-statistics.mean(f):+.2f}pp | {pos}/{len(r2)} |")
