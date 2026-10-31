# Prebuilt `pgoltob` binary

The winning arm: gcc 15.2.0 **PGO + LTO + BOLT** `presto_server` for Presto 0.299 /
Prestissimo. **+10.92% vs `base`** at r8i.16xl scale (64 vCPU), TPC-DS SF=1000.

| | |
|---|---|
| file | `presto_server-pgoltob.xz` |
| compressed | 25,783,236 bytes (24.6 MB) |
| decompressed | 196,109,584 bytes (187.0 MB) |
| **md5 (decompressed)** | **`9e5de67224bf6f08fd96bdd70ab54c5a`** |

Stored xz-compressed because the raw 187 MB binary exceeds GitHub's 100 MB per-file limit.
`base` (6.68 GB) and the other arms are not published for the same reason — use
`../profiles/` to rebuild them without retraining.

## Extract and verify

```bash
xz -dc presto_server-pgoltob.xz > presto_server
chmod +x presto_server
md5sum presto_server    # must be 9e5de67224bf6f08fd96bdd70ab54c5a
```

## Runtime requirements

This is **not** a static binary. It needs the same environment it was linked against:

- **gcc 15.2.0 runtime.** It was linked with `-Wl,-rpath,<gcc15>/lib64`, so the gcc 15
  `libstdc++`/`libgcc_s` must exist at that path, or set `LD_LIBRARY_PATH` to a gcc 15
  `lib64`. A distro gcc 12/13 `libstdc++` is **not** sufficient.
- **Boost 1.83–1.86** shared libs (built against 1.83; Presto needs `<1.87` because
  `boost/asio/io_service.hpp` was removed in 1.87).
- `ulimit -n 524288` in the shell that launches it — 974 parquet files at SF=1000 will
  otherwise exhaust file descriptors.
- `presto.version=0.299-7d50721` in the worker's `node.properties`, matching the
  coordinator's git-describe **exactly**, or the worker is silently excluded from the
  ACTIVE set.

Check what it actually wants:

```bash
ldd presto_server | grep -E "not found|libstdc|boost" 
```

## Provenance

Built from presto `7d50721602` (describe `0.299`), velox `1d9c83a`,
`FB_OS_VERSION=v2026.01.05.00`, with:

```
-O3 -g -include cstdint
-fprofile-use -fprofile-correction -Wno-missing-profile -Wno-error=coverage-mismatch
-flto=160 -ffat-lto-objects
-Wl,--emit-relocs -Wl,-rpath,<gcc15>/lib64
```

then `llvm-bolt 18.1.3 -reorder-blocks=ext-tsp -reorder-functions=hfsort+ -split-functions
-split-all-cold -split-eh -icf=1`.

PGO profile: 830 `.gcda` trained at SF=10 on a node-1 worker over the 15 measured queries.
BOLT profile: `perf record -e cycles:u -j any,u -F 199` on a node-1 worker at SF=1000.

See [`../PGOLTOB-METHOD.md`](../PGOLTOB-METHOD.md) for the full method, and note that the
+10.92% is **topology-dependent** — the same binary is a null on a 6-node whole box.
