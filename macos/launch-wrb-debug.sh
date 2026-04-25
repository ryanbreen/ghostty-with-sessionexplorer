#!/bin/bash
#
# launch-wrb-debug.sh — launch Ghostty WRB with stderr captured and Swift
# backtraces enabled, so a fatalError / precondition / @panic that would
# otherwise produce no .ips report leaves a readable postmortem on disk.
#
# Why this exists: macOS Crash Reporter only files .ips reports for actual
# Mach exceptions (segfault, abort, uncaught Obj-C exception). A Swift
# `fatalError` or Zig `@panic` calls exit() cleanly with a stderr message.
# When Ghostty WRB is launched via Finder / `open`, stderr goes to /dev/null
# so that message is lost. Launch via this script and it lives in the log.

set -u

LOG="$HOME/Downloads/ghostty-wrb-crash.log"
APP="/Applications/Ghostty WRB.app/Contents/MacOS/ghostty"

if [[ ! -x "$APP" ]]; then
  echo "ghostty binary not found at: $APP" >&2
  exit 1
fi

# Roll the previous run's log so we don't conflate runs.
if [[ -f "$LOG" ]]; then
  mv "$LOG" "${LOG%.log}.prev.log"
fi

echo "=== launch $(date) ==="     >  "$LOG"
echo "binary: $APP"               >> "$LOG"
echo "PID will be: $$"            >> "$LOG"
echo "==========================" >> "$LOG"

# NOTE: SWIFT_BACKTRACE is intentionally NOT set here. It would be inherited
# by every child process Ghostty spawns (every shell, lazygit, claude, ssh,
# etc.), and on each fork the Swift runtime prints a warning to stderr —
# "backtrace-on-crash is not supported for privileged executables" — which
# child programs sometimes capture into argv/PATH and choke on. We give up
# the Swift stack trace in exchange for not breaking every child process.
# We still capture the panic message itself, which is usually enough to
# locate the failing site.

# OS_ACTIVITY_MODE=disable quiets noisy os_log spam from AppKit so the log
# stays readable when we have to grep through it later. This one is safe to
# inherit — child processes that don't use os_log just ignore it.
export OS_ACTIVITY_MODE=disable

exec "$APP" >> "$LOG" 2>&1
