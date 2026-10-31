#!/usr/bin/env python3
"""Add -march=native arm variants to build-arm-gnr.sh.

Why: every arm so far is built with just "-O3 -g" -- NO -march/-mtune -- so we have been
compiling x86-64 baseline code on a Granite Rapids box (gcc -march=native resolves to
`graniterapids`). That is a large, untapped, FDO-independent lever, and the 10% target is
unlikely from FDO alone (our best is +5.50%, Jantz's icx HW PGO was +3.5%).

SEPARATE BUILD DIRS are essential: the native PGO arms must NOT share build/pgo, or
rebuilding would overwrite the instrumented objects and destroy the generic campaign's
830 .gcda profile.
"""
import re

p = "/data/prestissimo-fdo/scripts/build-arm-gnr.sh"
s = open(p).read()

if "base-native" in s:
    print("already patched")
    raise SystemExit(0)

anchor = '  afdolto)  BDIR=$ROOT/build/afdo;'
assert anchor in s, "could not find afdolto case"
line_end = s.index("\n", s.index(anchor)) + 1

NATIVE = '''  # ---- -march=native variants. Separate BDIRs so the generic arms' profile survives. ----
  base-native)   BDIR=$ROOT/build/base-native; EX_CXX="$ARCH";                      EX_LD="" ;;
  pgo-gen-native) BDIR=$ROOT/build/pgo-native; EX_CXX="$ARCH -fprofile-generate -fprofile-update=single"; EX_LD="-fprofile-generate" ;;
  pgo-native)    BDIR=$ROOT/build/pgo-native;  EX_CXX="$ARCH $PGO_USE";             EX_LD="" ;;
  pgolto-native) BDIR=$ROOT/build/pgo-native;  EX_CXX="$ARCH $PGO_USE -flto=$JOBS -ffat-lto-objects"; EX_LD="-flto=$JOBS" ;;
'''
s = s[:line_end] + NATIVE + s[line_end:]

# define ARCH before the case statement
m = re.search(r'^case .*ARM.* in$', s, re.M)
assert m, "could not find case statement"
s = s[:m.start()] + 'ARCH="-march=native -mtune=native"\n' + s[m.start():]

open(p, "w").write(s)
print("patched: added base-native, pgo-gen-native, pgo-native, pgolto-native")
