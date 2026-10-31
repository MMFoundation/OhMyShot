#!/bin/sh
# Builds the Debug app, quits any running copy, and launches the new build.
set -eu
cd "$(dirname "$0")/.."

# Capture the build output first: a pipe would hide a failed build and relaunch the old binary.
OUTPUT=$(Scripts/build.sh Debug) || { echo "Build failed." >&2; exit 1; }
APP=$(printf '%s\n' "$OUTPUT" | tail -1)
# Match this build's own binary: a release OhMyShot has the same process name.
BINARY="$(cd "$APP" && pwd)/Contents/MacOS/$(basename "$APP" .app)"

if pgrep -f "^$BINARY" >/dev/null; then
  pkill -f "^$BINARY" || true
  while pgrep -f "^$BINARY" >/dev/null; do sleep 0.1; done
fi

# LaunchServices can lag a moment behind a process that just exited (error -600), so retry briefly.
for attempt in 1 2 3 4 5; do
  if open "$APP" 2>/dev/null; then
    echo "Launched $APP"
    exit 0
  fi
  sleep 0.5
done
echo "Could not launch $APP" >&2
exit 1
