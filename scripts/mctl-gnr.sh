#!/bin/bash
# Start/stop the measurement WITHOUT the caller's command line containing the process
# pattern. `pkill -f <pat>` matches the invoking shell too when the ssh command line
# mentions <pat>, which has now killed my own shell three times in this campaign.
R=/data/prestissimo-fdo
PAT='measure-gnr-run'
case "${1:-}" in
  stop)
    pkill -f "$PAT" 2>/dev/null
    pkill -f 'driver.py tput' 2>/dev/null
    sleep 3
    echo "stopped (remaining: $(pgrep -cf "$PAT"))"
    ;;
  start)
    pkill -f "$PAT" 2>/dev/null; pkill -f 'driver.py tput' 2>/dev/null; sleep 3
    setsid nohup "$R/scripts/measure-gnr-run.sh" >> "$R/logs/measure-gnr.log" 2>&1 < /dev/null &
    sleep 5
    echo "started (procs: $(pgrep -cf "$PAT"))"
    ;;
  status)
    echo "procs=$(pgrep -cf "$PAT") valid=$(grep -c 'valid=yes' $R/results/tput-summary.tsv 2>/dev/null)/28"
    tail -3 "$R/logs/measure-gnr.log" 2>/dev/null | cut -c1-100
    ;;
  *) echo "usage: mctl.sh {start|stop|status}";;
esac
