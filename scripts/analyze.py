#!/usr/bin/env python3
"""Aggregate a mirrored Velox FDO campaign into per-query and geomean deltas.

Reads folly's own JSON dumps (-bm_json_verbose); nothing is scraped from the
human-readable table. Per (arm, query) the headline is the MEDIAN across rounds --
robust to a single disturbed round on a shared box -- and the spread (max/min) is
reported beside it so a number that rests on noisy data is visible as such.

The cross-query headline is a GEOMETRIC mean of per-query ratios: TPC-H query times
span 0.6 s to 22 s here, so an arithmetic mean over queries would just track q4.
"""
import json, os, sys, glob, statistics
from collections import defaultdict

OUT = sys.argv[1] if len(sys.argv) > 1 else None
if not OUT or not os.path.isdir(OUT):
    sys.exit("usage: analyze.py <campaign-dir>")
BASE = os.environ.get("BASE_ARM", "base")

def load(path):
    """folly writes a JSON array of [file, benchmark_name, time_ns] triples."""
    try:
        raw = json.load(open(path))
    except Exception as e:
        return None, f"unreadable: {e}"
    out = {}
    for row in raw:
        if not isinstance(row, (list, tuple)) or len(row) < 3:
            continue
        name, val = str(row[1]), row[2]
        name = name.lstrip("%")           # folly marks relative rows with '%'
        if not name or not isinstance(val, (int, float)) or val <= 0:
            continue
        out[name] = float(val)
    return (out, None) if out else (None, "no usable rows")

# arm -> query -> [times]
data = defaultdict(lambda: defaultdict(list))
bad = []
for path in sorted(glob.glob(f"{OUT}/*.r*.json")):
    fn = os.path.basename(path)
    arm, rnd = fn.split(".r")[0], fn.split(".r")[1].split(".")[0]
    rows, err = load(path)
    if err:
        bad.append(f"{arm} r{rnd}: {err}")
        continue
    if len(rows) != 22:
        bad.append(f"{arm} r{rnd}: {len(rows)} queries (expected 22) -- EXCLUDED")
        continue
    for q, v in rows.items():
        data[arm][q].append(v)

if BASE not in data:
    sys.exit(f"no data for base arm {BASE!r}; found: {sorted(data)}")

def qkey(q):
    d = "".join(c for c in q if c.isdigit())
    return int(d) if d else 0
queries = sorted(data[BASE], key=qkey)
arms = [BASE] + [a for a in sorted(data) if a != BASE]

# ---- per-query table -------------------------------------------------------
tsv = [f"query\t" + "\t".join(f"{a}_med_ms\t{a}_delta_pct" for a in arms)]
geo = {}
for a in arms:
    ratios = []
    for q in queries:
        if data[a].get(q) and data[BASE].get(q):
            ratios.append(statistics.median(data[BASE][q]) / statistics.median(data[a][q]))
    # ratio>1 means this arm is FASTER than base
    geo[a] = (statistics.geometric_mean(ratios) - 1) * 100 if ratios else float("nan")

for q in queries:
    cells = []
    for a in arms:
        v = data[a].get(q)
        if not v:
            cells += ["-", "-"]; continue
        med = statistics.median(v)
        d = (statistics.median(data[BASE][q]) / med - 1) * 100
        cells += [f"{med/1e6:.1f}", f"{d:+.2f}"]
    tsv.append(q + "\t" + "\t".join(cells))
open(f"{OUT}/bench.tsv", "w").write("\n".join(tsv) + "\n")

# ---- summary --------------------------------------------------------------
L = []
L.append("# Velox TPC-H SF100 - gcc 15.2.0 FDO campaign")
L.append("")
man = f"{OUT}/MANIFEST.txt"
if os.path.exists(man):
    L.append("```"); L.append(open(man).read().strip()); L.append("```"); L.append("")
nr = {a: max((len(v) for v in data[a].values()), default=0) for a in arms}
L.append(f"Rounds per arm (after gating): " + ", ".join(f"{a}={nr[a]}" for a in arms))
if min(nr.values()) < 5:
    L.append("")
    L.append(f"**NOT REPORTABLE**: lowest arm has only {min(nr.values())} clean rounds (>=5 expected).")
L.append("")
L.append("## Headline - geometric mean over the 22 queries, vs base")
L.append("")
L.append("| arm | geomean vs base | rounds |")
L.append("|---|---|---|")
for a in arms:
    tag = " (base)" if a == BASE else ""
    L.append(f"| {a}{tag} | {geo[a]:+.2f}% | {nr[a]} |")
L.append("")
L.append("Positive = faster than base.")
L.append("")
# per-arm worst spread, so noisy arms are flagged rather than silently averaged
L.append("## Run-to-run spread (max/min per query, worst query per arm)")
L.append("")
L.append("| arm | worst spread | query |")
L.append("|---|---|---|")
for a in arms:
    worst, wq = 0.0, "-"
    for q in queries:
        v = data[a].get(q)
        if v and len(v) > 1 and min(v) > 0:
            s = max(v) / min(v)
            if s > worst: worst, wq = s, q
    # With a single round there is no spread to report -- say so rather than printing
    # the -100% that an unset "worst" would produce.
    L.append(f"| {a} | {'n/a (1 round)' if worst == 0.0 else f'{(worst-1)*100:+.1f}%'} | {wq} |")
L.append("")
L.append("## Per-query detail")
L.append("")
L.append("| query | " + " | ".join(f"{a} ms" if a == BASE else f"{a} %" for a in arms) + " |")
L.append("|" + "---|" * (len(arms) + 1))
for q in queries:
    cells = []
    for a in arms:
        v = data[a].get(q)
        if not v: cells.append("-"); continue
        med = statistics.median(v)
        cells.append(f"{med/1e6:.0f}" if a == BASE
                     else f"{(statistics.median(data[BASE][q])/med-1)*100:+.1f}")
    L.append(f"| {q} | " + " | ".join(cells) + " |")
if bad:
    L.append(""); L.append("## Gated out"); L.append("")
    for b in bad: L.append(f"- {b}")
open(f"{OUT}/summary.md", "w").write("\n".join(L) + "\n")
print("\n".join(L[:40]))
print(f"\nwrote {OUT}/summary.md and {OUT}/bench.tsv")
