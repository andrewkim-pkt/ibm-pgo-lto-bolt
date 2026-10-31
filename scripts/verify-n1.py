#!/usr/bin/env python3
"""Verification checks for the node-1 result that do not rely on a variance estimate.

The paired t-test says the PGO arms are separable; the unpaired A/A range says pgo's
+4.29% is inside noise. Those disagree because the A/A test compares base in round r to
base in round r', so it CONTAINS between-round drift, while the arm deltas are measured
within a round and cancel it. There is only one base pass per round, so a paired A/A is
not available. These checks sidestep variance entirely:

 1. SIGN TEST: how many of the 6 rounds favour the arm. Under the null each round is a
    coin flip, so 6/6 is p=0.031 two-sided regardless of how noisy the rounds are.
 2. ODD/EVEN SPLIT: base runs FIRST in odd rounds and LAST in even rounds (mirroring).
    If an arm's gain differs systematically between the two halves, the delta is a
    position artifact rather than a code effect.
 3. The same checks on the whole-box round for comparison.
"""
import json, os, sys, glob, statistics
from collections import defaultdict

def load_campaign(d):
    out = defaultdict(dict)
    for p in sorted(glob.glob(f"{d}/*.r*.json")):
        fn = os.path.basename(p)
        arm = fn.split(".r")[0]; rnd = int(fn.split(".r")[1].split(".")[0])
        rows = {}
        for r in json.load(open(p)):
            if isinstance(r, (list, tuple)) and len(r) >= 3 and isinstance(r[2], (int, float)) and r[2] > 0:
                rows[str(r[1]).lstrip("%")] = float(r[2])
        if len(rows) == 22:
            out[arm][rnd] = rows
    return out

def per_round(d, arm):
    B = d["base"]; res = {}
    for r in sorted(B):
        if r in d[arm]:
            qs = [q for q in B[r] if q in d[arm][r]]
            res[r] = (statistics.geometric_mean([B[r][q] / d[arm][r][q] for q in qs]) - 1) * 100
    return res

P_SIGN = {6: 0.031, 5: 0.219, 4: 0.688, 3: 1.0}
for label, path in [("NODE 1", sys.argv[1]), ("WHOLE BOX", sys.argv[2])]:
    d = load_campaign(path)
    if "base" not in d:
        continue
    print(f"\n=== {label} ===")
    print("| arm | mean | rounds favouring arm | sign-test p | odd(base 1st) | even(base last) | gap |")
    print("|---|---|---|---|---|---|---|")
    for arm in sorted(a for a in d if a != "base"):
        pr = per_round(d, arm)
        vals = list(pr.values())
        pos = sum(1 for v in vals if v > 0)
        odd = [v for r, v in pr.items() if r % 2 == 1]
        even = [v for r, v in pr.items() if r % 2 == 0]
        mo, me = statistics.mean(odd), statistics.mean(even)
        p = P_SIGN.get(max(pos, len(vals) - pos), 1.0)
        print(f"| {arm} | {statistics.mean(vals):+.2f}% | {pos}/{len(vals)} | {p:.3f} | "
              f"{mo:+.2f}% | {me:+.2f}% | {abs(mo-me):.2f}pp |")
