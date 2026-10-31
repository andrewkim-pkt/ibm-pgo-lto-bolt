#!/usr/bin/env python3
"""Regenerate Velox's folly-gflags-glog.patch against the folly version Velox pins.

Velox pins folly v2026.09.07.00, but its checked-in patch still expects the older
folly-deps.cmake where glog was linked via ${GLOG_LIBRARY}. Upstream folly changed
that line to glog::glog and added a Glog-0.7 export block, so `git apply` fails and
the BUNDLED dependency path cannot configure. Velox CI uses the SYSTEM path, which is
why this is unnoticed upstream.

The patch's PURPOSE is unchanged: make folly resolve gflags/glog through their CMake
config packages (the same ones Velox itself uses) instead of folly's MODULE finders,
so only ONE copy of gflags/glog ends up in the link. Two gflags copies would each
register the same flags and abort at startup.

Regenerated here by editing a pristine copy and diffing, so the hunk offsets and
context always match the pinned folly rather than being hand-counted.
"""
import subprocess, sys, os, shutil

PRISTINE = "/data/velox-fdo/build/base/_deps/folly-src/CMake/folly-deps.cmake"
PATCH_OUT = "/data/velox-fdo/src/velox/CMake/resolve_dependency_modules/folly/folly-gflags-glog.patch"

GFLAGS_OLD = """find_package(Gflags MODULE)
set(FOLLY_HAVE_LIBGFLAGS ${LIBGFLAGS_FOUND})
if(LIBGFLAGS_FOUND)
  list(APPEND FOLLY_LINK_LIBRARIES ${LIBGFLAGS_LIBRARY})
  list(APPEND FOLLY_INCLUDE_DIRECTORIES ${LIBGFLAGS_INCLUDE_DIR})
  set(FOLLY_LIBGFLAGS_LIBRARY ${LIBGFLAGS_LIBRARY})
  set(FOLLY_LIBGFLAGS_INCLUDE ${LIBGFLAGS_INCLUDE_DIR})
endif()"""
GFLAGS_NEW = """find_package(gflags)
set(FOLLY_HAVE_LIBGFLAGS ${gflags_FOUND})
if(gflags_FOUND)
  list(APPEND FOLLY_LINK_LIBRARIES ${gflags_LIBRARY})
  list(APPEND FOLLY_INCLUDE_DIRECTORIES ${gflags_INCLUDE_DIR})
  set(FOLLY_LIBGFLAGS_LIBRARY ${gflags_LIBRARY})
  set(FOLLY_LIBGFLAGS_INCLUDE ${gflags_INCLUDE_DIR})
endif()"""
# Note: glog::glog (not ${GLOG_LIBRARY}) -- this is the line that drifted.
GLOG_OLD = """find_package(Glog MODULE)
set(FOLLY_HAVE_LIBGLOG ${GLOG_FOUND})
list(APPEND FOLLY_LINK_LIBRARIES glog::glog)
list(APPEND FOLLY_INCLUDE_DIRECTORIES ${GLOG_INCLUDE_DIR})"""
GLOG_NEW = """find_package(glog)
set(FOLLY_HAVE_LIBGLOG ${glog_FOUND})
list(APPEND FOLLY_LINK_LIBRARIES ${glog_LIBRARY})
list(APPEND FOLLY_INCLUDE_DIRECTORIES ${glog_INCLUDE_DIR})
message(STATUS "glog_LIBRARY: ${glog_LIBRARY}")"""

src = open(PRISTINE).read()
for name, old in (("gflags", GFLAGS_OLD), ("glog", GLOG_OLD)):
    if old not in src:
        sys.exit(f"ERROR: pristine folly-deps.cmake does not contain the expected {name} block; "
                 "folly changed again -- re-inspect before regenerating.")
new = src.replace(GFLAGS_OLD, GFLAGS_NEW).replace(GLOG_OLD, GLOG_NEW)

work = "/tmp/follypatch"
shutil.rmtree(work, ignore_errors=True)
os.makedirs(f"{work}/a/CMake"); os.makedirs(f"{work}/b/CMake")
open(f"{work}/a/CMake/folly-deps.cmake", "w").write(src)
open(f"{work}/b/CMake/folly-deps.cmake", "w").write(new)
d = subprocess.run(["diff", "-u", "a/CMake/folly-deps.cmake", "b/CMake/folly-deps.cmake"],
                   cwd=work, capture_output=True, text=True)
if d.returncode != 1:
    sys.exit(f"ERROR: unexpected diff rc={d.returncode}: {d.stderr}")

header = open(PATCH_OUT).read().split("--- a/")[0]   # keep Velox's Apache licence header
open(PATCH_OUT, "w").write(header + d.stdout)
print(f"regenerated {PATCH_OUT}")
print(d.stdout[:400])
