#!/bin/bash
#
# launch-debug-prompt-editor.sh — launch the Debug-configuration Ghostty
# build (macos/build/Debug/Ghostty.app) with --prompt-editor=true and
# stderr captured to a log file. Use this for testing prompt-editor
# work-in-progress against the wrb/prompt-editor branch.
#
# The Debug build has bundle id com.mitchellh.ghostty.debug, so it runs
# alongside production /Applications/Ghostty.app without conflict.

set -u

LOG="$HOME/Downloads/ghostty-debug-prompt-editor.log"
APP="/Users/wrb/fun/code/ghostty/macos/build/Debug/Ghostty.app/Contents/MacOS/ghostty"

if [[ ! -x "$APP" ]]; then
  echo "Debug ghostty binary not found at: $APP" >&2
  echo "Build it first: cd /Users/wrb/fun/code/ghostty/macos && nu build.nu --configuration Debug" >&2
  exit 1
fi

# Roll the previous run's log so we don't conflate runs.
if [[ -f "$LOG" ]]; then
  mv "$LOG" "${LOG%.log}.prev.log"
fi

echo "=== launch $(date) ==="     >  "$LOG"
echo "binary: $APP"               >> "$LOG"
echo "branch: $(cd /Users/wrb/fun/code/ghostty && git rev-parse --abbrev-ref HEAD)" >> "$LOG"
echo "head:   $(cd /Users/wrb/fun/code/ghostty && git rev-parse --short HEAD)" >> "$LOG"
echo "==========================" >> "$LOG"

export OS_ACTIVITY_MODE=disable

exec "$APP" --prompt-editor=true >> "$LOG" 2>&1
