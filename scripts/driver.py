#!/usr/bin/env python3
"""TPC-DS driver for the Prestissimo FDO campaign.

Modes
  survey   run every query once, record elapsed + CPU time, pick the CPU-heaviest set
  stream   run one list of queries sequentially (one "stream")
  tput     run N concurrent streams of the query list -> queries/hour  (Jantz's shape)

Everything CHECKPOINTS per query to a TSV and resumes: this box is stopped by an external
policy roughly every two hours (three times so far, and two different keepalive designs
failed to prevent it), so any step that cannot resume will never finish.

Ranking metric is CPU time from Presto's own query stats (cpuTimeMillis), not wall time --
Jantz selected "the most compute-bound" queries, and wall time on a shared box also
reflects queueing and I/O.
"""
import json, os, sys, time, urllib.request, argparse, threading, re
from concurrent.futures import ThreadPoolExecutor

ROOT = "/data/prestissimo-fdo"
QDIR = f"{ROOT}/src/presto/presto-native-execution/src/test/resources/tpcds/queries"
PORT = 8080
HDRS = {"X-Presto-User": "fdo", "X-Presto-Catalog": "hive",
        "X-Presto-Schema": os.environ.get("PRESTO_SCHEMA", "tpcds")}
_lock = threading.Lock()

def load_sql(name):
    with open(f"{QDIR}/{name}") as f:
        q = f.read()
    q = q.replace("${database}", "hive").replace("${schema}", os.environ.get("PRESTO_SCHEMA", "tpcds"))
    return re.sub(r";\s*$", "", q.strip())

def run_query(sql, timeout=3600):
    """Submit and drain one query. Returns (ok, elapsed_ms, cpu_ms, rows, err)."""
    t0 = time.time()
    try:
        req = urllib.request.Request(f"http://127.0.0.1:{PORT}/v1/statement",
                                     data=sql.encode(), headers=HDRS)
        r = json.load(urllib.request.urlopen(req, timeout=60))
    except Exception as e:
        return False, 0, 0, 0, f"submit: {e}"
    rows, cpu, elapsed, err = 0, 0, 0, None
    while True:
        if "error" in r:
            err = str(r["error"].get("message"))[:200]; break
        st = r.get("stats") or {}
        cpu = st.get("cpuTimeMillis", cpu) or cpu
        elapsed = st.get("elapsedTimeMillis", elapsed) or elapsed
        rows += len(r.get("data") or [])
        nxt = r.get("nextUri")
        if not nxt:
            break
        if time.time() - t0 > timeout:
            err = "driver timeout"; break
        try:
            r = json.load(urllib.request.urlopen(nxt, timeout=120))
        except Exception as e:
            err = f"poll: {e}"; break
        time.sleep(0.05)
    wall = int((time.time() - t0) * 1000)
    return (err is None), (elapsed or wall), cpu, rows, err

def ckpt_load(path):
    done = {}
    if os.path.exists(path):
        for line in open(path):
            p = line.rstrip("\n").split("\t")
            if len(p) >= 5 and p[0] != "key":
                done[p[0]] = p
    return done

def ckpt_write(path, row):
    with _lock:
        new = not os.path.exists(path)
        with open(path, "a") as f:
            if new:
                f.write("key\tquery\tok\telapsed_ms\tcpu_ms\trows\terr\n")
            f.write("\t".join(str(x) for x in row) + "\n")
            f.flush(); os.fsync(f.fileno())

def cmd_survey(a):
    qs = sorted(f for f in os.listdir(QDIR) if f.endswith(".sql"))
    out = a.out or f"{ROOT}/results/survey.tsv"
    done = ckpt_load(out)
    print(f"{len(qs)} queries, {len(done)} already done -> {out}", flush=True)
    for q in qs:
        key = q[:-4]
        if key in done:
            continue
        ok, el, cpu, rows, err = run_query(load_sql(q), timeout=a.timeout)
        ckpt_write(out, [key, q, int(ok), el, cpu, rows, err or ""])
        print(f"{key:10s} ok={int(ok)} elapsed={el/1000:7.1f}s cpu={cpu/1000:9.1f}s rows={rows}"
              + (f" ERR={err[:70]}" if err else ""), flush=True)
    rank(out, a.top)

def rank(path, top):
    rows = [r for r in ckpt_load(path).values() if r[2] == "1"]
    rows.sort(key=lambda r: -int(r[4] or 0))
    print(f"\n=== top {top} by CPU time (the compute-bound set) ===")
    sel = []
    for r in rows[:top]:
        sel.append(r[1])
        print(f"{r[0]:10s} cpu={int(r[4])/1000:9.1f}s elapsed={int(r[3])/1000:7.1f}s")
    sel_path = os.path.dirname(path) + "/queries-top.txt"
    open(sel_path, "w").write("\n".join(sel) + "\n")
    print(f"\nwrote {sel_path} ({len(sel)} queries); failures: "
          f"{sum(1 for r in ckpt_load(path).values() if r[2] != '1')}")

def cmd_stream(a):
    qs = [l.strip() for l in open(a.list) if l.strip()]
    out = a.out or f"{ROOT}/results/stream.tsv"
    for q in qs:
        ok, el, cpu, rows, err = run_query(load_sql(q), timeout=a.timeout)
        ckpt_write(out, [f"{q}", q, int(ok), el, cpu, rows, err or ""])
        print(f"{q:12s} ok={int(ok)} {el/1000:7.1f}s", flush=True)

def cmd_tput(a):
    """N concurrent streams x the query list -> queries/hour. One row per query per stream."""
    qs = [l.strip() for l in open(a.list) if l.strip()]
    out = a.out or f"{ROOT}/results/tput.tsv"
    done = ckpt_load(out)
    label = a.label
    t0 = time.time()
    def stream(sid):
        n_ok = 0
        for q in qs:
            key = f"{label}|s{sid}|{q}"
            if key in done:
                n_ok += 1; continue
            ok, el, cpu, rows, err = run_query(load_sql(q), timeout=a.timeout)
            ckpt_write(out, [key, q, int(ok), el, cpu, rows, err or ""])
            n_ok += int(ok)
        return n_ok
    with ThreadPoolExecutor(max_workers=a.streams) as ex:
        oks = list(ex.map(stream, range(a.streams)))
    wall = time.time() - t0
    total = sum(oks)
    # A throughput figure is only valid if EVERY query succeeded: a failed query returns
    # in ~0 s, shrinking wall while the success count stays moderate, which INFLATES
    # queries/hour. The first campaign was invalidated exactly this way (base reported
    # 153.6 and 608.8 q/h for the same binary).
    expect = len(qs) * a.streams
    nfail = sum(1 for r in ckpt_load(out).values()
                if r[0].startswith(label + '|') and r[2] != '1')
    valid = 'yes' if (total == expect and nfail == 0) else 'no'
    qph = total / wall * 3600 if wall > 0 else 0
    summ = (f"{label}	streams={a.streams}	queries={total}/{expect}	fail={nfail}"
            f"	wall_s={wall:.1f}	queries_per_hour={qph:.1f}	valid={valid}")
    print(summ, flush=True)
    with open(os.environ.get("TPUT_SUMMARY", f"{ROOT}/results/tput-summary.tsv"), "a") as f:
        f.write(summ + "\n")

def cmd_warm(a):
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


p = argparse.ArgumentParser()
sub = p.add_subparsers(dest="cmd", required=True)
s = sub.add_parser("survey"); s.add_argument("--out"); s.add_argument("--top", type=int, default=15); s.add_argument("--timeout", type=int, default=1800); s.set_defaults(f=cmd_survey)
s = sub.add_parser("rank");   s.add_argument("--out", required=True); s.add_argument("--top", type=int, default=15); s.set_defaults(f=lambda a: rank(a.out, a.top))
s = sub.add_parser("stream"); s.add_argument("--list", required=True); s.add_argument("--out"); s.add_argument("--timeout", type=int, default=1800); s.set_defaults(f=cmd_stream)
s = sub.add_parser("tput");   s.add_argument("--list", required=True); s.add_argument("--streams", type=int, default=4); s.add_argument("--label", required=True); s.add_argument("--out"); s.add_argument("--timeout", type=int, default=1800); s.set_defaults(f=cmd_tput)
s = sub.add_parser("warm");   s.add_argument("--list", required=True); s.add_argument("--n", type=int, default=1); s.add_argument("--timeout", type=int, default=1800); s.set_defaults(f=cmd_warm)
a = p.parse_args(); a.f(a)
