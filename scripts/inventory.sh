#!/bin/bash
# Record what each arm actually IS: md5, size, .text bytes, and whether BOLT's
# relocation requirement is satisfied. .text is the evidence that a profile was really
# applied rather than silently ignored -- gcc accepts a bad/empty profile without error,
# so "it built" is not proof.
set -uo pipefail
source /data/velox-fdo/scripts/env.sh
TGT=velox_tpch_benchmark
printf "%-10s %-34s %14s %14s %s\n" arm md5 bytes .text rela.text
for a in base pgo pgob pgolto pgoltob afdo afdob afdolto afdoltob pgo-gen; do
  f=$ROOT/arms/$a/$TGT
  [ -x "$f" ] || { printf "%-10s %s\n" "$a" "(not built)"; continue; }
  md5=$(awk '{print $1}' "$ROOT/arms/$a/md5.txt" 2>/dev/null)
  sz=$(stat -c%s "$f")
  tx=$(readelf -S "$f" 2>/dev/null | grep -A1 " \.text " | tail -1 | awk '{print strtonum("0x"$1)}')
  nr=$(readelf -S "$f" 2>/dev/null | grep -c "\.rela\.text" || true)
  printf "%-10s %-34s %14s %14s %s\n" "$a" "$md5" "$sz" "${tx:-?}" "${nr:-0}"
done
echo
echo "profiles:"
printf "  PGO  .gcda files : %s (%s bytes archived)\n" "$(cat "$PROF/pgo-gcda.count" 2>/dev/null)" "$(stat -c%s "$PROF/pgo-gcda.tgz" 2>/dev/null)"
printf "  AutoFDO profile  : %s bytes\n" "$(stat -c%s "$PROF/velox.afdo" 2>/dev/null)"
for a in pgo pgolto afdo afdolto; do
  printf "  BOLT fdata %-8s: %s bytes\n" "$a" "$(stat -c%s "$PROF/bolt-$a/perf.fdata" 2>/dev/null || echo -)"
done
