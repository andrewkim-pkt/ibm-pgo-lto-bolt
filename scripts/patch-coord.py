#!/usr/bin/env python3
"""Restart the Presto COORDINATOR per arm, not just the native workers.

Why: start_arm() pkill'ed the 6 workers between arms but left the Java coordinator up for
the whole campaign. That leaves zombie tasks whose worker URIs no longer resolve, and
HttpRemoteTaskWithEventLoop.abort() then throws

    java.lang.IllegalStateException: scheme has not been set

in a tight retry loop -- ~395 stack traces per 400 KB, measured growing at 4.8 GB per 30 s
(~160 MB/s) and reaching a 1.5 TB server.log that filled the 2 TB root volume to 100%.
The dataset (354 GB of Parquet) is read from that same EBS volume, so the storm stole
read bandwidth and throughput decayed monotonically across the campaign:
505 -> 465 q/h in wall-clock order, independent of which arm was running.

A fresh coordinator per arm also hands the first query a clean node map, and the launcher
redirect uses '>' so server.log is reset at every arm instead of growing all campaign.
Belt-and-braces: a size guard truncates the log if it ever runs away again mid-run.
"""
import os

os.chdir("/data/velox-fdo")

p = "scripts/measure.sh"
s = open(p).read()

if "PrestoServer" in s:
    print("measure.sh: already restarts the coordinator")
    raise SystemExit(0)

# --- 1. paths the coordinator launcher needs -----------------------------------
anchor = "SUMM=$R/results/tput-summary.tsv"
assert anchor in s
s = s.replace(
    anchor,
    anchor + "\n"
    "JAVA_HOME=${JAVA_HOME:-$R/tools/jdk17}\n"
    "SRV=$R/tools/presto-server-0.299\n"
    "COORD_LOG=$R/cluster/coordinator/server.log",
    1,
)

# --- 2. replace the worker-only restart with a full cluster restart ------------
old = '''  pkill -f "[p]resto_server --etc_dir" 2>/dev/null; sleep 5'''
assert old in s, "start_arm worker-kill line not found"
new = '''  # Restart the COORDINATOR as well as the workers. Killing workers while the coordinator
  # survives leaves zombie tasks whose node URIs no longer resolve; abort() then throws
  # "scheme has not been set" in a tight retry loop that wrote server.log at ~160 MB/s and
  # reached 1.5 TB, filling the volume the 354 GB dataset is read from. That is what made
  # throughput decay 505 -> 465 q/h in wall-clock order across the first campaign.
  pkill -f "[p]resto_server --etc_dir" 2>/dev/null
  pkill -f "com.facebook.[p]resto.server.PrestoServer" 2>/dev/null
  sleep 8
  # '>' not '>>': the log starts empty for every arm.
  PATH=$JAVA_HOME/bin:$PATH nohup "$SRV/bin/launcher.py" \\
      --etc-dir $R/cluster/coordinator/etc --data-dir $R/cluster/coordinator/data run \\
      > "$COORD_LOG" 2>&1 &
  for i in $(seq 1 150); do
    curl -s http://127.0.0.1:8080/v1/info 2>/dev/null | grep -q '"starting":false' && break
    sleep 2
  done
  curl -s http://127.0.0.1:8080/v1/info 2>/dev/null | grep -q '"starting":false' \\
      || { log "coordinator did not come up for $arm"; return 1; }'''
s = s.replace(old, new, 1)

# --- 3. log-size guard, so a runaway can never fill the volume again -----------
anchor = 'warm_arm() {'
assert anchor in s
guard = '''# If the coordinator ever starts storming again, truncate rather than let it fill the
# volume the dataset lives on. 20 GiB is ~2 min of the observed 160 MB/s storm and far
# more than a healthy run produces (a few MB).
log_guard() {
  local sz
  sz=$(stat -c %s "$COORD_LOG" 2>/dev/null || echo 0)
  if [ "$sz" -gt 21474836480 ]; then
    truncate -s 0 "$COORD_LOG" 2>/dev/null
    log "WARNING coordinator log hit $((sz/1073741824)) GiB - truncated (storm is back)"
  fi
}

'''
s = s.replace(anchor, guard + anchor, 1)

# call the guard after each timed run
anchor = '        --timeout 1800 2>&1 | tail -2'
assert anchor in s
s = s.replace(anchor, anchor + "\n    log_guard", 1)

open(p, "w").write(s)
print("measure.sh: coordinator restart + log guard wired in")
