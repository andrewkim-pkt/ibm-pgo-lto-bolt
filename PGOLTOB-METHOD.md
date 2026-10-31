# Prestissimo `pgoltob` — full method and results

gcc 15.2.0 PGO + LTO + BOLT on Presto-native (Prestissimo / Velox), TPC-DS SF=1000.
Everything below is taken from the live rig, not reconstructed.

---

## 0. The IBM cloud workload — what this is and why it matters

### 0.1 What IBM runs

**IBM watsonx.data** is IBM's cloud lakehouse. Its SQL query engine is **open-source Presto**,
and the part that actually burns CPU is **Prestissimo** — Presto's *native execution* layer,
a C++ worker built on **Velox** (Meta's vectorised columnar execution engine).

The deployment splits into two very unequal halves:

| component | language | role | CPU share |
|---|---|---|---|
| Presto **coordinator** | Java | parse, plan, schedule, serve REST | light |
| **Prestissimo workers** (Velox) | C++ | scan Parquet, join, aggregate, spill | **dominant** |

That asymmetry is the entire reason this is an FDO target. Essentially all the time is in a
**single C++ binary** (`presto_server`) that IBM ships prebuilt — so a better-compiled binary
is a drop-in win requiring no change to queries, data layout, or cluster topology. Nothing
about the Java coordinator is touched by any of this work.

### 0.2 The workload as IBM measures it

Specified by **Jantz Tran** (Intel), from the 2026-10-13 bi-weekly and
`bi-weekly update for HWPGO.docx`:

| | |
|---|---|
| Engine | Presto + Prestissimo native workers (= Velox) |
| Data | **TPC-DS SF=1000** (1 TB) |
| Queries | **15 hand-picked CPU-bound queries** out of the 99 |
| Load | **throughput test, 4 concurrent streams** |
| Topology | **6 worker containers, one pinned per SNC node**, + 1 coordinator |
| Hardware | 2-socket Granite Rapids, ~1.5 TB RAM |
| Saturation | **~90% CPU** |
| Metric | **queries/hour**, 3 runs per binary |
| Baseline compiler | **GCC 12** — the Presto dev-container default, i.e. what IBM actually ships |

This is a **throughput** benchmark, not a latency one: concurrent streams keep every worker
busy and the score is aggregate completed-queries-per-hour. It is deliberately CPU-bound —
the 15 queries were chosen as the most compute-heavy of the 99 — which is precisely the
regime where code layout and branch-prediction quality show up.

### 0.3 The reference result we are measuring against

Jantz's own numbers on this workload:

- **icx HW PGO: ~+3.5% geomean** (hardware-sampled PGO using the Intel compiler)
- S2O: slightly worse
- **~1% is noise** on his rig
- He profiled at **SF=1 over all 99 queries on one worker** and openly notes "there is some
  disconnect there" — training scale and topology do not match measurement

### 0.4 IBM's acceptance bar, and the constraint that shapes everything

- **IBM will not switch off GCC.** The icx result is internal Intel data only. Any deliverable
  has to be a **gcc** toolchain change.
- **<5% is uninteresting to IBM. ~20% would start a conversation.**

That bar is why this campaign exists, and why the work pushed past a first null result: a
3–5% gcc number is a footnote, whereas a clean >10% on a real instance size is a product
argument. It is also why the arm that matters is `pgoltob` (gcc PGO+LTO+BOLT) rather than
anything requiring a different compiler.

### 0.5 How our rig maps onto theirs

| | IBM / Jantz | this campaign |
|---|---|---|
| Engine, data, query count, streams | identical | identical (SF=1000, 15 queries, 4 streams) |
| Workers | 6, one per SNC node | 3 or 2, one per SNC node (box has 3 nodes) |
| Hardware | 2S Granite Rapids, ~1.5 TB | 1S Xeon 6973P-C, 755 GB |
| Baseline | GCC 12 container default | **gcc 15.2 `-O3`** — a *harder* baseline |
| Which 15 queries | his hand-picked list | our CPU ranking of the 53 that run (his list never obtained) |
| Training | SF=1, all 99, one worker | SF=10, the measured 15, node-1 worker |

Two differences are worth stating plainly when quoting results. First, our baseline is
**gcc 15.2 `-O3`**, not IBM's GCC 12 container — so our deltas isolate FDO alone and are
*conservative* relative to what IBM would see from a full toolchain upgrade. Second, we never
obtained Jantz's exact 15-query list, so absolute q/h is not comparable to his; only the
relative deltas are.

---

## 1. System configuration

| | |
|---|---|
| Host | `ushs-ap-gnr3` (10.54.112.122), shared lab box |
| CPU | Intel Xeon 6973P-C (Granite Rapids), 1 socket, 96 cores, 2 threads/core = **192 logical** |
| NUMA | **3 nodes** (SNC3), 32 physical cores / 64 logical per node |
| Node→CPU map | node0 `0-31,96-127` · node1 `32-63,128-159` · node2 `64-95,160-191` |
| HT siblings | `cpuN ↔ cpuN+96` (verified: `cpu0` siblings `0,96`, core_id 0) |
| RAM | 755 GB (~251 GB/node) |
| L3 | 480 MiB |
| OS / kernel | Ubuntu 24.04.2 LTS / 6.19.11 |
| Compiler | gcc **15.2.0** (bootstrapped at `/data/velox-fdo/toolchain/gcc15`, needs `-rpath`) |
| BOLT | `llvm-bolt` **18.1.3** (apt `bolt-18`) |
| perf | 6.8.12 |
| JDK | Temurin **17.0.13** (JDK 21 breaks Presto 0.29x: `[Guice/JitDisabled]`) |

Required kernel settings:

```bash
kernel.perf_event_paranoid = 0      # else AutoFDO + BOLT sampling silently fail
ulimit -n 524288                     # in the shell that SPAWNS workers (974 parquet files)
```

THP left at distro default `madvise`.

### Source pins (identical across all boxes used)

```
presto  7d50721602   (git describe = 0.299)
velox   1d9c83a
FB_OS_VERSION = v2026.01.05.00
```

`presto.version` in worker `node.properties` must equal the coordinator's **git-describe**
string `0.299-7d50721`, not `0.299`. A mismatch silently excludes the worker from the ACTIVE
set; the only symptom is "0 workers are active".

---

## 2. Workload configuration

### Shape (Jantz Tran's IBM spec)

| | |
|---|---|
| Benchmark | TPC-DS **SF=1000** (354 GB parquet, 24 tables, 974 files) |
| Queries | **15** CPU-heaviest of the 53 that run |
| Concurrency | **4 streams** |
| Metric | **queries/hour** = completed ÷ wall × 3600 |
| Workers | one container pinned per NUMA node |
| Validity | a run counts only if **60/60** query executions succeed |

Query set (`results/queries-top.txt`):

```
q50 q61 q13 q48 q70 q46 q79 q27 q98 q36 q28 q71 q60 q56 q19
```

Training dataset: **SF=10** (4.4 GB), registered as a separate schema `hive.tpcds10`, so the
SF=1000 tables are untouched.

### Coordinator `config.properties`

```properties
coordinator=true
node-scheduler.include-coordinator=false
http-server.http.port=8080
discovery-server.enabled=true
discovery.uri=http://127.0.0.1:8080
query.max-memory=350GB
native-execution-enabled=true
optimizer.optimize-hash-generation=false
regex-library=RE2J
use-alternative-function-signatures=true
```

### Worker `config.properties`

```properties
discovery.uri=http://127.0.0.1:8080
presto.version=0.299-7d50721
http-server.http.port=7771            # 7771+i per worker
shutdown-onset-sec=1
runtime-metrics-collection-enabled=true
system-memory-gb=210                  # sized for 251 GB/node
query-memory-gb=170
memory-arbitrator-kind=SHARED
shared-arbitrator.reserved-capacity=8GB
shared-arbitrator.memory-pool-initial-capacity=2GB
spill-enabled=true
join-spill-enabled=true
aggregation-spill-enabled=true
order-by-spill-enabled=true
experimental.spiller-spill-path=/data/prestissimo-fdo/spill/worker$i
```

Worker `node.properties` must include `node.location` (the repo template omits it).

Hive catalog is a **file metastore** — no Hive/MySQL:

```properties
connector.name=hive-hadoop2
hive.metastore=file
hive.metastore.catalog.dir=file:///data/prestissimo-fdo/cluster/metastore
hive.storage-format=PARQUET
hive.parquet.use-column-names=true
```

### Known deviations / limitations

- `-DPRESTO_ENABLE_SPATIAL=OFF` — bundled s2geometry won't compile under gcc 15. TPC-DS has
  no geospatial queries, and the removal is identical in every arm.
- ~40 of 103 shipped queries fail with "Exceeded memory pool capacity … 4.00GB", a per-query
  pool cap with no raisable knob in 0.299. All arms use the same 15 queries.
- The 15 queries are **our** CPU ranking, not Jantz's list (never obtained).
- `spiller-spill-path` contains a literal unexpanded `$i`, so workers share one spill
  directory. Harmless (spill filenames are unique) but not the intended isolation.

---

## 3. Shared build configuration

Identical for **every** arm, so the FDO layer is the only variable:

```bash
COMMON_C   = "-O3 -g"
COMMON_CXX = "-O3 -g -include cstdint"
COMMON_LD  = "-Wl,--emit-relocs -Wl,-rpath,$GCC15/lib64"
JOBS       = 160
```

- `-g` is required: BOLT and AutoFDO both need debug info to map samples.
- `-Wl,--emit-relocs` is **required by BOLT**; without it `llvm-bolt` refuses the binary.
  Verify with `readelf -S | grep .rela.text`.
- `-include cstdint` because gcc 15's libstdc++ no longer pulls it in transitively and this
  velox pin's mvfst relies on that.

CMake, same for every arm:

```bash
cmake -B $BDIR -S $PRESTO -GNinja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER=$CC -DCMAKE_CXX_COMPILER=$CXX \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DTREAT_WARNINGS_AS_ERRORS=0 -DENABLE_ALL_WARNINGS=0 \
  -DPRESTO_ENABLE_PARQUET=ON -DPRESTO_ENABLE_TESTING=OFF -DPRESTO_ENABLE_SPATIAL=OFF \
  -DCMAKE_PREFIX_PATH=$ROOT/deps \
  -DCMAKE_CXX_FLAGS="$COMMON_CXX $EX_CXX" \
  -DCMAKE_C_FLAGS="$COMMON_C $EX_CXX" \
  -DCMAKE_EXE_LINKER_FLAGS="$COMMON_LD $EX_LD"
ninja -C $BDIR -j160 presto_server
```

Target is `presto_server`. Build time ~15–25 min per arm at `-j160`.

---

## 4. Step 0 — `base` (the reference)

```bash
EX_CXX=""   EX_LD=""
```

Result: **6.68 GB**, md5 `732baf27e6876e78f0870efb94dd3dae`.

---

## 5. Step 1 — PGO (instrumented)

### 5a. Build the instrumented binary

```bash
EX_CXX="-fprofile-generate -fprofile-update=single"
EX_LD="-fprofile-generate"
```

**`-fprofile-update=single` is the critical flag.** gcc 15 selects *atomic* counters whenever
`-pthread` is present, and Presto/Velox always is. Every hot arc then becomes a `lock add` on
a **shared cache line** with ~64 threads per worker — instrumentation overhead exceeded
**300×** and a single SF=1 query could not finish in 300 s. With `single`:

```
gcc-15 -fprofile-generate -pthread                        -> 7 lock-prefixed insns
gcc-15 -fprofile-generate -pthread -fprofile-update=single -> 0
```

Verified on the real object: `PeriodicTaskManager.cpp.o` has **2053 gcov counter sites, 0
with a lock prefix**. Overhead fell to **~4.8×** (SF=1, 16 cpus: 3.5 s → 16.8 s).

Counters are *not* a memory problem — measured section growth is `.data` +94 MB, `.bss`
+50 MB, `.text` +90 MB ⇒ ~235 MB/process, ~0.05% of this box.

### 5b. Wipe build-time counters — do not skip this

```bash
find build/pgo -name "*.gcda" -delete
```

Building with `-fprofile-generate` instruments the build's **own code generators**; running
them during the build deposits ~124 `.gcda`. A guard of the form
`if [ $(count .gcda) -eq 0 ]` therefore sees a non-empty profile and **skips training
entirely**, producing arms with zero workload data that measure as a plausible-looking null.
Gate training on an explicit marker, never on `.gcda` presence.

### 5c. Train

One worker, **pinned to node 1**, SF=10, the 15 measured queries:

```bash
numactl --physcpubind=$(node1 cpus) --preferred=1 \
    arms/pgo-gen/presto_server --etc_dir=cluster/worker1/etc
# wait for activeWorkers == 1  (EXACT, never >=)
PRESTO_SCHEMA=tpcds10 driver.py warm --list results/queries-top.txt --n 15
pkill -TERM -f presto_server          # SIGTERM only
```

- **Node 1, not node 0**, because the NIC is on node 0 (`ens67 → numa_node 0`) and node 0
  carries the driver/interrupt load. Use `--preferred=N`, never `--membind=N` (hard membind
  OOMs on this hardware).
- **`activeWorkers` must EQUAL the expected count.** A `>=` test is satisfied by
  just-killed nodes the coordinator hasn't aged out, and tasks get scheduled onto dead
  workers.
- **gcov writes `.gcda` from an `atexit()` handler — `SIGKILL` produces nothing.** Stop with
  SIGTERM and verify the files appeared.

Result: **830 `.gcda`, 52.8 MB**. Sanity floor: reject anything under ~400.

### 5d. Build `pgo`

```bash
EX_CXX="-fprofile-use -fprofile-correction -Wno-missing-profile -Wno-error=coverage-mismatch"
EX_LD=""
```

- `-fprofile-correction` is mandatory: counters are deliberately racy under
  `-fprofile-update=single`.
- `-Wno-error=coverage-mismatch` is needed once LTO changes inlining relative to the
  instrumented build.
- Caution: `-Wno-missing-profile` **suppresses** the warning that would reveal poor coverage,
  so never use the build log to judge profile quality — count `.gcda` instead.

Result: **5.57 GB**, md5 `0f746fb43a541445ac8160f4154af125`.

---

## 6. Step 2 — LTO (on top of PGO)

```bash
EX_CXX="$PGO_USE -flto=160 -ffat-lto-objects"
EX_LD="-flto=160"
```

Same `build/pgo` tree and the same 830 `.gcda`. `-ffat-lto-objects` keeps real object code
alongside the IR, which is what lets BOLT work on the result afterwards.

Result: **5.08 GB**, md5 `7bef71246415f7ff80a101984e63b754`.

---

## 7. Step 3 — BOLT (on top of PGO+LTO)

BOLT is a **separate post-link pass**, not a compiler flag. Three stages:

### 7a. Sample the linked binary

Kill all workers, start **one** worker from `pgolto` on **node 1** under perf, run one pass
of the 15 queries at SF=1000:

```bash
numactl --physcpubind=$(node1 cpus) --preferred=1 \
  perf record -e cycles:u -j any,u -F 199 -o prof/bolt-pgolto/perf.data -- \
  arms/pgolto/presto_server --etc_dir=cluster/worker1/etc
driver.py stream --list results/queries-top.txt
# graceful stop so perf.data is complete:
curl -X PUT -d '"SHUTTING_DOWN"' http://127.0.0.1:777x/v1/info/state
pkill -INT -f "perf record -e cycles"
```

- `-j any,u` = LBR branch records, which BOLT needs; `cycles:u` = user space only.
- **`-F 199`, not the 3000 default.** High-frequency LBR capture wrote 30 GB in 5 minutes and
  destabilised a box. perf costs ~9× here (q50 28.5 s → 266 s), which is also why only one
  worker is sampled.

### 7b. Convert

```bash
perf2bolt -p perf.data -o perf.fdata arms/pgolto/presto_server
```

### 7c. Optimise

```bash
llvm-bolt arms/pgolto/presto_server -o arms/pgoltob/presto_server \
    -data=perf.fdata \
    -reorder-blocks=ext-tsp \
    -reorder-functions=hfsort+ \
    -split-functions \
    -split-all-cold \
    -split-eh \
    -icf=1 \
    -dyno-stats
```

Result: **0.18 GB** (BOLT emits a stripped binary), md5
`9e5de67224bf6f08fd96bdd70ab54c5a`. Whole BOLT stage ≈ 35–45 min, dominated by the perf run
(2156 s of queries).

---

## 8. How `pgoltob` was chosen

Seven arms were built and measured head-to-head on the same box, same 4 mirrored rounds,
SF=1000, 3 nodes:

| arm | mean q/h | vs base | rounds favouring | verdict |
|---|---|---|---|---|
| base | 249.6 | — | — | reference |
| afdo | 249.8 | +0.06% | 2/4 | null |
| afdolto | 251.6 | +0.78% | 4/4 | below noise |
| afdoltob | 256.9 | +2.94% | 4/4 | real |
| pgo | 252.3 | +1.08% | 4/4 | below noise |
| pgolto | 260.6 | +4.39% | 4/4 | real |
| **pgoltob** | **263.3** | **+5.50%** | **4/4** | **best** |

Noise floor (base vs itself) **1.6%**. Decision rules applied:

1. **Beat the noise floor.** Only `afdoltob`, `pgolto`, `pgoltob` did.
2. **Win in every round.** `pgoltob` 4/4.
3. **Survive order reversal.** Rounds 2 and 4 run the arms backwards; `base` was still
   lowest while running *last*, so the ranking is arm-driven, not cache drift.
4. **Each layer must pay.** PGO +1.08 → +LTO +4.39 → +BOLT +5.50. Both layers contribute
   (BOLT +1.11 pp on the PGO path, +2.16 pp on the AutoFDO path).
5. **Instrumented beats sampled.** `pgoltob` +5.50% vs `afdoltob` +2.94%.

Note on terminology: `pgoltob` uses **instrumented** PGO. The hardware-sampled ("HW PGO")
equivalent is the `afdo*` family, whose best arm is `afdoltob` **+2.94%** — that is the
like-for-like comparison against icx HW PGO's +3.5%.

Rejected axis: **`-march=native` is a null** (−0.09%, 2/4 rounds). Velox already
hand-vectorises its hot kernels per-file with `-mavx -mavx2 -mfma -mbmi2 -mf16c -mlzcnt`, so
a global `-march` only reaches cold code. It also needs
`-mno-avx512f -mno-avx10.1-512` to compile at all, because graniterapids enables AVX10.1/512
which widens `xsimd::batch<uint32_t>` to 512-bit while velox hardcodes `_mm256_testc_si256`.

---

## 9. Measurement protocol

Per run: restart **coordinator and workers**, warm up, then time 4 concurrent streams.

- **Restart the coordinator per arm.** Leaving it up across arms leaves zombie tasks whose
  worker URIs no longer resolve; `abort()` then throws `scheme has not been set` in a tight
  loop that wrote `server.log` at **~160 MB/s** and filled a 2 TB volume. That storm also
  stole EBS bandwidth and made throughput decay monotonically across a campaign.
- **Untimed warm-up of the heaviest query before every timed run.** Fixes the start-up race
  `sortedCandidates is null or empty for ModularHashingNodeProvider` (Presto reports
  `activeWorkers==6` and serves a trivial scan while the node snapshot the real plan needs is
  still empty), and removes a cold-cache swing that once produced `base-r1` 195.8 vs 505 q/h.
- **4 mirrored rounds** — even count, odd rounds forward, even rounds reversed. An odd number
  does not balance: with 3 rounds the first arm gets the favourable slot 2/3 of the time.
- **`valid=yes` only if 60/60 succeed.** Failed queries return in ~0 s, shrinking wall while
  the success count stays moderate, which *inflates* q/h. One early campaign reported base at
  153.6 and 608.8 q/h for the same binary before this gate existed.
- Report the **paired per-round delta** and the **base-vs-itself spread** as the noise floor.
  Never quote a delta below it.

---

## 10. All results

### 10.1 `pgoltob` vs `base` across topologies

| config | vCPU | EC2 equiv | base q/h | pgoltob q/h | delta | rounds | noise | scale |
|---|---|---|---|---|---|---|---|---|
| 6 nodes (r8i.metal-96xl) | 384 | 96xl | 505.2 | 501.3 | **−0.76%** | 0/3 | 0.76% | SF=1000 |
| 3 nodes | 192 | 48xl | 249.6 | 263.3 | **+5.50%** | 4/4 | 1.6% | SF=1000 |
| 2 nodes | 128 | ~32xl | 184.0 | 196.8 | **+6.95%** | 4/4 | 2.2% | SF=1000 |
| 2×24 cores | 96 | **24xl** | 182.15 | 194.95 | **+7.03%** | 4/4 | **0.38%** | SF=1000 |
| 2×16 cores | 64 | **16xl** | 152.0 | 168.6 | **+10.92%** | 4/4 | **0.66%** | SF=1000 |
| 1×16 cores | 32 | ~8xl | 6113.4 | 6822.5 | **+11.60%** | 3/3 | 1.3% | SF=10 |
| 1×8 cores | 16 | ~4xl | 4068.0 | 4580.2 | **+12.60%** | 4/4 | 2.0% | SF=10 |

Monotonic: a flat null at 384 vCPU rising steadily as vCPU falls, with the knee between 96
and 64 vCPU. The SF=1000 16xl point confirms the small-slice results were the topology trend,
not a scale artifact.

### 10.2 Headline, 16xl / 64 vCPU, SF=1000

| | r1 | r2 | r3 | r4 | mean |
|---|---|---|---|---|---|
| base | 152.1 | 151.5 | 152.5 | 151.9 | **152.0** |
| pgoltob | 168.3 | 168.5 | 168.4 | 169.2 | **168.6** |
| delta | +10.65% | +11.22% | +10.43% | +11.39% | **+10.92%** |

60/60 queries clean in all 8 runs; noise floor 0.66%, so the gain is ~16× the noise.

### 10.3 Full 7-arm lattice (3 nodes, SF=1000)

See §8.

### 10.4 Cross-box comparison, same pins / dataset / queries / harness

| arm | 96xl 6-node | 48xl 3-node (node-0 BOLT profile) | GNR 3-node (node-1 profiles) |
|---|---|---|---|
| pgo | +0.36% | +1.39% | +1.08% |
| pgolto | −0.73% | +1.93% | +4.39% |
| pgoltob | −0.76% | +3.63% | +5.50% |
| afdoltob | −2.46% | n/a | +2.94% |

Moving the profile collection off the NIC node roughly doubled `pgolto`/`pgoltob` at 3 nodes.
Confounded by box differences (CPU, RAM), so treat as suggestive, not isolated.

### 10.5 Reference point

Jantz Tran measured **+3.5%** with icx HW PGO on this workload on a 2S GNR, 6 workers,
~90% CPU. IBM stated <5% is uninteresting and ~20% would start a conversation.

---

## 11. Artifact inventory

| arm | md5 | size |
|---|---|---|
| base | `732baf27e6876e78f0870efb94dd3dae` | 6.68 GB |
| pgo | `0f746fb43a541445ac8160f4154af125` | 5.57 GB |
| pgolto | `7bef71246415f7ff80a101984e63b754` | 5.08 GB |
| **pgoltob** | `9e5de67224bf6f08fd96bdd70ab54c5a` | 0.18 GB |
| afdo | `90a9b04b57d1144942683d14d8d07b1b` | 6.73 GB |
| afdolto | `cc7512e143e28355fb1d9a65605bb3a7` | 6.03 GB |
| afdoltob | `825d4d24c76f0da9a5c0f2aff3e4eb5f` | 0.22 GB |

Profiles: PGO 830 `.gcda` / 52.8 MB · AutoFDO `presto.afdo` 13.0 MB.
