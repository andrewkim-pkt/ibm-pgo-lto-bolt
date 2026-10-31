#!/usr/bin/env python3
"""Paired per-round analysis of a Velox FDO campaign.

The unpaired view (analyze.py) takes a median per (arm, query) across rounds and then a
geomean over queries. That throws away the pairing: every arm was measured in the SAME
round as base, minutes apart, so any slow drift in box state is common to both and can
be cancelled by comparing WITHIN a round first.

For each round r:  ratio_r(arm) = geomean over queries of  base[q,r] / arm[q,r]
Then report the mean of those 6 round-level ratios and their spread. The spread across
rounds is a direct noise estimate ON THE HEADLINE METRIC, which is what decides whether
a sub-1% delta means anything.
"""
import json, os, sys, glob, statistics
from collections import defaultdict

OUT = sys.argv[1]
BASE = "base"

def load(path):
    rows = {}
    for r in json.load(open(path)):
        if isinstance(r, (list, tuple)) and len(r) >= 3 and isinstance(r[2], (int, float)) and r[2] > 0:
            rows[str(r[1]).lstrip("%")] = float(r[2])
    return rows

# arm -> round -> {query: ns}
d = defaultdict(dict)
for p in sorted(glob.glob(f"{OUT}/*.r*.json")):
    fn = os.path.basename(p)
    arm = fn.split(".r")[0]; rnd = int(fn.split(".r")[1].split(".")[0])
    rows = load(p)
    if len(rows) == 22:
        d[arm][rnd] = rows

arms = [BASE] + sorted(a for a in d if a != BASE)
rounds = sorted(d[BASE])
print(f"rounds with base data: {rounds}\n")

print("## Paired per-round geomean vs base (positive = faster than base)\n")
hdr = "| arm | " + " | ".join(f"r{r}" for r in rounds) + " | mean | median | spread |"
print(hdr); print("|" + "---|" * (len(rounds) + 4))
summary = {}
for a in arms:
    if a == BASE:
        continue
    per = []
    for r in rounds:
        if r not in d[a]:
            per.append(None); continue
        qs = [q for q in d[BASE][r] if q in d[a][r]]
        ratios = [d[BASE][r][q] / d[a][r][q] for q in qs]
        per.append((statistics.geometric_mean(ratios) - 1) * 100)
    vals = [v for v in per if v is not None]
    summary[a] = vals
    cells = " | ".join("-" if v is None else f"{v:+.2f}" for v in per)
    print(f"| {a} | {cells} | **{statistics.mean(vals):+.2f}%** | {statistics.median(vals):+.2f}% | "
          f"{max(vals)-min(vals):.2f}pp |")

print("\n## Is any arm separable from base?\n")
print("| arm | mean | stdev | 95% CI (t, n=6) | verdict |")
print("|---|---|---|---|---|")
for a, vals in summary.items():
    n = len(vals); m = statistics.mean(vals)
    sd = statistics.stdev(vals) if n > 1 else float("nan")
    # t_0.975 for n-1 dof; n=6 -> 2.571
    tcrit = {2:12.706,3:4.303,4:3.182,5:2.776,6:2.571,7:2.447,8:2.365}.get(n, 2.0)
    half = tcrit * sd / (n ** 0.5)
    lo, hi = m - half, m + half
    sep = "SEPARABLE" if (lo > 0 or hi < 0) else "not separable from base"
    print(f"| {a} | {m:+.2f}% | {sd:.2f}pp | [{lo:+.2f}, {hi:+.2f}] | {sep} |")

# Per-query noise profile: which queries are usable at all?
print("\n## Per-query noise in the BASE arm (round-to-round)\n")
print("| query | median ms | spread |")
print("|---|---|---|")
prof = []
for q in sorted(d[BASE][rounds[0]], key=lambda x: int("".join(c for c in x if c.isdigit()) or 0)):
    v = [d[BASE][r][q] for r in rounds if q in d[BASE][r]]
    prof.append((q, statistics.median(v) / 1e6, (max(v) / min(v) - 1) * 100))
for q, ms, sp in prof:
    print(f"| {q} | {ms:,.0f} | {sp:+.1f}% |")
print(f"\nmedian per-query spread in base: {statistics.median([s for _,_,s in prof]):.1f}%")
