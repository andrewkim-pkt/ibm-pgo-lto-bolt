#!/usr/bin/env python3
"""Add an untimed warm-up pass to the Prestissimo measurement harness.

Why: 10 of 13 measured runs were invalidated by ONE failure mode -- the first query of
every stream (q50) dying with "sortedCandidates is null or empty for
ModularHashingNodeProvider" ~10-13 s after a fresh cluster start, in all 4 streams at
once. Presto reports activeWorkers==6 and will run a trivial unbucketed scan (the old
probe, SELECT count(*) FROM reason) while the node snapshot the real plan needs is still
empty. Secondary win: q50 is the heaviest query and swung 145 s -> 101 s cold-vs-warm on
the SAME binary, the largest single noise term in queries/hour.
"""
import ast
import os

os.chdir("/data/velox-fdo")

# ---- 1. driver.py: add a "warm" mode ------------------------------------------
p = "scripts/driver.py"
s = open(p).read()
if "def cmd_warm" not in s:
    fn = '''def cmd_warm(a):
    """Run the first N queries of the list once, UNTIMED, and discard the results.

    Two jobs. (a) The first query against a freshly started cluster dies with
    "sortedCandidates is null or empty for ModularHashingNodeProvider": Presto reports
    activeWorkers==6 and will happily serve a trivial unbucketed scan while the node
    snapshot the real plan needs is still empty. Every invalid run in this campaign was
    exactly this, always on the first query of all 4 streams at once. (b) q50 is the
    heaviest query and swung 145s -> 101s cold-vs-warm on the SAME binary, which is the
    largest single noise term in queries/hour. The warm-up is identical for every arm.
    """
    qs = [l.strip() for l in open(a.list) if l.strip()][:a.n]
    bad = 0
    for q in qs:
        ok, el, cpu, rows, err = run_query(load_sql(q), timeout=a.timeout)
        print("warm %s ok=%d %7.1fs %s" % (q, int(ok), el / 1000, err or ""), flush=True)
        bad += 0 if ok else 1
    sys.exit(1 if bad else 0)


'''
    anchor = "p = argparse.ArgumentParser()"
    assert anchor in s
    s = s.replace(anchor, fn + anchor, 1)

    reg = ('s = sub.add_parser("warm");   s.add_argument("--list", required=True); '
           's.add_argument("--n", type=int, default=1); '
           's.add_argument("--timeout", type=int, default=1800); '
           's.set_defaults(f=cmd_warm)\n')
    anchor = "a = p.parse_args()"
    assert anchor in s
    s = s.replace(anchor, reg + anchor, 1)
    open(p, "w").write(s)
    print("driver.py: warm mode added")
else:
    print("driver.py: already patched")

ast.parse(open(p).read())
print("driver.py parses")

# ---- 2. measure.sh: call the warm-up before every timed run -------------------
p = "scripts/measure.sh"
s = open(p).read()
if "warm_arm()" not in s:
    warm = '''# Discarded warm-up of the heaviest query before every timed run. See cmd_warm in
# driver.py -- this is what fixes the q50 "sortedCandidates is null or empty" start-up
# race that invalidated 10 of the first 13 runs, and it also removes the cold-cache swing
# on the single query that dominates the wall time.
warm_arm() {
  for i in 1 2 3 4; do
    python3 -I $R/scripts/driver.py warm --list $R/results/queries-top.txt --n 1 --timeout 900 && return 0
    log "warm-up attempt $i failed, settling"
    sleep 20
  done
  return 1
}

'''
    anchor = 'read -ra A <<< "$ARMS"'
    assert anchor in s
    s = s.replace(anchor, warm + anchor, 1)

    old = '    wait_schedulable || { log "$arm never became schedulable, skipping"; continue; }'
    assert old in s
    new = old + '\n    warm_arm || { log "$arm failed warm-up, skipping"; continue; }'
    s = s.replace(old, new, 1)
    open(p, "w").write(s)
    print("measure.sh: warm_arm wired in")
else:
    print("measure.sh: already patched")
