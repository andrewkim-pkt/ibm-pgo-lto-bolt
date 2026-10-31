#!/usr/bin/env python3
"""Add -march=native AutoFDO arms (the hardware-sampled 'HW PGO' path) to build-arm-gnr.sh.

NATIVE_AFDO note: the profile must be re-collected FROM base-native. Applying the existing
generic-binary presto.afdo to a native build is a mismatch that -fauto-profile accepts
SILENTLY, which would understate the arm -- the same class of failure as the empty-profile
trap, just quieter.
"""
p = "/data/prestissimo-fdo/scripts/build-arm-gnr.sh"
s = open(p).read()

if "afdo-native" in s:
    print("already patched")
    raise SystemExit(0)

anchor = "  pgolto-native) BDIR=$ROOT/build/pgo-native;"
assert anchor in s, "pgolto-native case not found"
i = s.index("\n", s.index(anchor)) + 1

NEW = (
    '  afdo-native)    BDIR=$ROOT/build/afdo-native; '
    'EX_CXX="$ARCH -fauto-profile=$PROF/presto-native.afdo"; EX_LD="" ;;\n'
    '  afdolto-native) BDIR=$ROOT/build/afdo-native; '
    'EX_CXX="$ARCH -fauto-profile=$PROF/presto-native.afdo -flto=$JOBS -ffat-lto-objects"; '
    'EX_LD="-flto=$JOBS" ;;\n'
)
s = s[:i] + NEW + s[i:]
open(p, "w").write(s)
print("added afdo-native, afdolto-native")
