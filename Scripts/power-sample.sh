#!/bin/sh
# Samples the idle-power proxies of a running OhMyShot: CPU, idle wakeups, and memory footprint.
# Leave the app alone while it runs; the targets assume nothing of ours is on screen.
#
# Usage: Scripts/power-sample.sh [seconds] [app or process name]
#   defaults: 60 seconds, the Debug build (build/Build/Products/Debug/OhMyShot.app)
#   Pass a .app path to sample that copy, or a process name such as "OhMyShot" for the first one running.
#   A release OhMyShot has the same process name as the Debug build, so a name may pick either.
# For energy in milliwatts, also run (needs sudo):
#   sudo powermetrics -i 1000 -n 60 --samplers tasks --show-process-energy
set -eu

SECONDS_TO_SAMPLE=${1:-60}
NAME=${2:-"$(cd "$(dirname "$0")/.." && pwd)/build/Build/Products/Debug/OhMyShot.app"}
case "$NAME" in
  *.app|*.app/)
    [ -d "$NAME" ] || { echo "$NAME does not exist." >&2; exit 1; }
    APP=$(cd "$NAME" && pwd)
    PID=$(pgrep -f "^$APP/Contents/MacOS/" | head -1 || true)
    ;;
  *)
    PID=$(pgrep -x "$NAME" | head -1 || true)
    ;;
esac
if [ -z "$PID" ]; then
  echo "$NAME is not running." >&2
  exit 1
fi

echo "Sampling $NAME (pid $PID) for $SECONDS_TO_SAMPLE s..."
# top's first sample covers the time since launch, so take one extra and skip it.
top -l $((SECONDS_TO_SAMPLE + 1)) -s 1 -stats pid,cpu,idlew -pid "$PID" \
  | awk -v pid="$PID" -v seconds="$SECONDS_TO_SAMPLE" '
      $1 == pid {
        samples++
        if (samples == 1) { first_wakeups = $3; next }
        cpu += $2
        if ($2 > peak) peak = $2
        last_wakeups = $3
      }
      END {
        n = samples - 1
        if (n < 1) { print "No samples."; exit 1 }
        wakeups = last_wakeups - first_wakeups
        if (wakeups < 0) wakeups = last_wakeups
        printf "CPU            average %.2f%%, peak %.1f%%\n", cpu / n, peak
        printf "Idle wakeups   %d in %d s (%.2f per second)\n", wakeups, n, wakeups / n
      }'

footprint "$PID" 2>/dev/null | awk '/Footprint:/ { sub(/.*Footprint:[ \t]*/, ""); sub(/ \(.*/, ""); print "Footprint      " $0; exit }'
