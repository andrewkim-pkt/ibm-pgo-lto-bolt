#!/usr/bin/env python3
"""Base-arm absolutes + an A/A null check.

Two things the arm table cannot show:
 1. what base actually COSTS, so the percentages have an anchor;
 2. what "no difference" looks like in this harness. Base was measured 6 times with the
    SAME binary, so comparing base round r against base round r' is a pure A/A test:
    every such ratio SHOULD be 0%, and whatever spread it has is the floor below which
    no arm delta can be believed.
"""
import json, os, sys, glob, statistics, itertools
from collections import defaultdict

OUT = sys.argv[1]

def load(p):
    rows = {}
    for r in json.load(open(p)):
        if isinstance(r, (list, tuple)) and len(r) >= 3 and isinstance(r[2], (int, float)) and r[2] > 0:
            rows[str(r[1]).lstrip("%")] = float(r[2])
    return rows

d = defaultdict(dict)
for p in sorted(glob.glob(f"{OUT}/*.r*.json")):
    fn = os.path.basename(p)
    arm = fn.split(".r")[0]; rnd = int(fn.split(".r")[1].split(".")[0])
    rows = load(p)
    if len(rows) == 22:
        d[arm][rnd] = rows

B = d["base"]; rounds = sorted(B)
qs = sorted(B[rounds[0]], key=lambda x: int("".join(c for c in x if c.isdigit()) or 0))

print("## base arm, absolute\n")
print("| round | suite total (s) |")
print("|---|---|")
totals = []
for r in rounds:
    t = sum(B[r][q] for q in qs) / 1e9
    totals.append(t); print(f"| r{r} | {t:.2f} |")
print(f"| **median** | **{statistics.median(totals):.2f}** |")
print(f"\nsuite total spread across rounds: {(max(totals)/min(totals)-1)*100:+.1f}% "
      f"(min {min(totals):.2f}s, max {max(totals):.2f}s)\n")

print("| query | base median ms | share of suite |")
print("|---|---|---|")
med = {q: statistics.median([B[r][q] for r in rounds]) for q in qs}
tot = sum(med.values())
for q in qs:
    print(f"| {q} | {med[q]/1e6:,.0f} | {med[q]/tot*100:.1f}% |")
print(f"| **total** | **{tot/1e6:,.0f}** | |")

print("\n## A/A null: base vs base across rounds (same binary, should be 0%)\n")
aa = []
for r1, r2 in itertools.combinations(rounds, 2):
    g = statistics.geometric_mean([B[r1][q] / B[r2][q] for q in qs])
    aa.append((g - 1) * 100)
aa_abs = [abs(x) for x in aa]
print(f"- {len(aa)} round pairs")
print(f"- range: {min(aa):+.2f}% .. {max(aa):+.2f}%")
print(f"- stdev: {statistics.stdev(aa):.2f}pp, mean |delta|: {statistics.mean(aa_abs):.2f}pp")
print(f"- 95th pct of |delta|: {sorted(aa_abs)[int(0.95*len(aa_abs))-1]:.2f}pp")
print("\n| arm | mean vs base | inside the A/A range? |")
print("|---|---|---|")
lo, hi = min(aa), max(aa)
for a in sorted(d):
    if a == "base":
        continue
    vals = []
    for r in rounds:
        if r in d[a]:
            vals.append((statistics.geometric_mean([B[r][q] / d[a][r][q] for q in qs]) - 1) * 100)
    m = statistics.mean(vals)
    print(f"| {a} | {m:+.2f}% | {'yes' if lo <= m <= hi else 'NO -- exceeds A/A noise'} |")
