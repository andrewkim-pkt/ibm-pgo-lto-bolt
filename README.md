# ibm-pgo-lto-bolt

gcc 15.2.0 **PGO + LTO + BOLT** for the IBM watsonx.data query engine
(**Presto + Prestissimo / Velox**), measured on TPC-DS SF=1000.

**Headline: `pgoltob` is +10.92% vs `base` at r8i.16xl scale (64 vCPU), SF=1000,
4 concurrent streams, 60/60 queries clean in all 8 runs, noise floor 0.66%.**
For reference, icx HW PGO measured ~+3.5% on this workload.

Full method, every config, and all results: **[PGOLTOB-METHOD.md](PGOLTOB-METHOD.md)**

---

## Why this workload

IBM watsonx.data runs open-source **Presto**, but the CPU is spent almost entirely in
**Prestissimo** — the native C++ worker built on **Velox**. The Java coordinator is light.
So nearly all the time lives in one C++ binary, `presto_server`, which IBM ships prebuilt:
a better-compiled binary is a drop-in win with no change to queries, data, or topology.

IBM will not switch compilers (icx results are Intel-internal only), so the deliverable has
to be a **gcc** toolchain change. IBM's stated bar: <5% uninteresting, ~20% compelling.

## Results

`pgoltob` vs `base`, 4 mirrored rounds each, every row 4/4 rounds favouring:

| config | vCPU | EC2 equiv | base q/h | pgoltob q/h | delta | noise | scale |
|---|---|---|---|---|---|---|---|
| 6 NUMA nodes | 384 | 96xl | 505.2 | 501.3 | **−0.76%** | 0.76% | SF=1000 |
| 3 nodes | 192 | 48xl | 249.6 | 263.3 | **+5.50%** | 1.6% | SF=1000 |
| 2 nodes | 128 | ~32xl | 184.0 | 196.8 | **+6.95%** | 2.2% | SF=1000 |
| 2×24 cores | 96 | 24xl | 182.15 | 194.95 | **+7.03%** | 0.38% | SF=1000 |
| **2×16 cores** | **64** | **16xl** | **152.0** | **168.6** | **+10.92%** | **0.66%** | **SF=1000** |
| 1×16 cores | 32 | ~8xl | 6113.4 | 6822.5 | +11.60% | 1.3% | SF=10 |
| 1×8 cores | 16 | ~4xl | 4068.0 | 4580.2 | +12.60% | 2.0% | SF=10 |

**The gain is topology-dependent and monotonic:** a flat null on a 6-node whole box, rising
as vCPU falls, crossing 10% between 96 and 64 vCPU. Quote the configuration with the number.

### Full 7-arm lattice (3 nodes, SF=1000, noise floor 1.6%)

| arm | mean q/h | vs base | rounds | verdict |
|---|---|---|---|---|
| base | 249.6 | — | — | reference |
| afdo | 249.8 | +0.06% | 2/4 | null |
| afdolto | 251.6 | +0.78% | 4/4 | below noise |
| afdoltob | 256.9 | +2.94% | 4/4 | real |
| pgo | 252.3 | +1.08% | 4/4 | below noise |
| pgolto | 260.6 | +4.39% | 4/4 | real |
| **pgoltob** | **263.3** | **+5.50%** | **4/4** | **best** |

`-march=native` was tested and is a **null** (−0.09%): Velox already hand-vectorises its hot
kernels per file, so a global `-march` only reaches cold code.

## The four build steps

```bash
# 0. base
EX_CXX=""

# 1. PGO — instrument, train, use
EX_CXX="-fprofile-generate -fprofile-update=single"     # the critical flag, see below
#    wipe build-time .gcda, then train on node 1 at SF=10, stop with SIGTERM
EX_CXX="-fprofile-use -fprofile-correction -Wno-missing-profile -Wno-error=coverage-mismatch"

# 2. + LTO
EX_CXX="$PGO_USE -flto=160 -ffat-lto-objects"   EX_LD="-flto=160"

# 3. + BOLT (post-link)
perf record -e cycles:u -j any,u -F 199 -o perf.data -- presto_server ...
perf2bolt -p perf.data -o perf.fdata arms/pgolto/presto_server
llvm-bolt arms/pgolto/presto_server -o arms/pgoltob/presto_server -data=perf.fdata \
  -reorder-blocks=ext-tsp -reorder-functions=hfsort+ \
  -split-functions -split-all-cold -split-eh -icf=1 -dyno-stats
```

Shared by every arm, so the FDO layer is the only variable:

```
-O3 -g -include cstdint                     # -g needed for BOLT/AutoFDO symbolisation
-Wl,--emit-relocs -Wl,-rpath,$GCC15/lib64   # --emit-relocs is MANDATORY for BOLT
```

## The five things that cost the most time

1. **`-fprofile-update=single` is mandatory.** gcc 15 picks *atomic* counters whenever
   `-pthread` is present, and Prestissimo always is — every hot arc becomes a `lock add` on a
   shared cache line. Instrumentation overhead exceeded **300×** and a single SF=1 query could
   not finish in 300 s. With `single`: **0 lock-prefixed** gcov sites and **~4.8×** overhead.
   Memory is *not* the issue (counters cost ~235 MB/process).
2. **Wipe `.gcda` immediately before training.** Building with `-fprofile-generate`
   instruments the build's own code generators; running them deposits ~124 `.gcda`. A
   "skip if a profile exists" guard then skips training entirely and yields arms with **zero
   workload data** that measure as a believable null. Gate on a marker; sanity-check the
   count (healthy = 830 `.gcda`).
3. **Profile off the NIC node.** `ens67` is on node 0, so node 0 carries driver/interrupt
   load. Moving PGO training and BOLT/AutoFDO sampling to **node 1** roughly doubled
   `pgolto`/`pgoltob` at 3 nodes. Use `--preferred=N`, never `--membind=N` (OOMs).
4. **Restart the coordinator per arm.** Otherwise zombie tasks reference dead worker URIs and
   `abort()` throws `scheme has not been set` in a tight loop — it wrote `server.log` at
   **~160 MB/s**, reached 1.5 TB, filled a 2 TB volume and made throughput decay across the
   whole campaign.
5. **Gate every run on 60/60 queries.** Failed queries return in ~0 s, shrinking wall time
   while the success count stays moderate, which *inflates* queries/hour. Before this gate,
   `base` reported 153.6 and 608.8 q/h for the same binary.

Plus: warm up the heaviest query untimed before each timed run (fixes the
`sortedCandidates is null or empty` start-up race and a cold-cache swing that produced
195.8 vs 505 q/h for the same binary), and use an **even** number of mirrored rounds — with 3
rounds the first arm gets the favourable slot 2/3 of the time.

## Layout

| path | contents |
|---|---|
| `PGOLTOB-METHOD.md` | full step-by-step: system, workload, build, PGO, LTO, BOLT, selection, results |
| `scripts/` | every script used — bootstrap, deps, dataset gen, build, train, BOLT, measure, analyse |
| `results/` | all campaign summaries (`tput-*-summary.tsv`), the 15-query list, TPC-DS DDL, arm md5s |
| `configs/` | coordinator / worker / node / hive properties as actually run |
| `profiles/` | `pgo-gcda.tar.gz` (830 `.gcda`) and `presto.afdo` (13 MB) — rebuild the arms without retraining |

Binaries are **not** included: `base` is 6.68 GB and even BOLT's stripped `pgoltob` is
180 MB, over GitHub's per-file limit. The profiles are here instead, which is what you need
to reproduce the arms.

## Reproducing

```
presto  7d50721602  (git describe = 0.299)
velox   1d9c83a
FB_OS_VERSION = v2026.01.05.00
gcc 15.2.0 · llvm-bolt 18.1.3 · Temurin JDK 17 (JDK 21 breaks Presto 0.29x)
```

Also required: `kernel.perf_event_paranoid=0` and `ulimit -n 524288` in the shell that spawns
workers. See `PGOLTOB-METHOD.md` §1–3 for the rest, and §2 for known deviations
(`PRESTO_ENABLE_SPATIAL=OFF`, the 4 GB per-query pool cap excluding ~40 queries, and the fact
that the 15-query set is our CPU ranking rather than IBM's exact list).
