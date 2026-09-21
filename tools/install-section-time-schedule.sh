#!/usr/bin/env bash
#
# install-section-time-schedule.sh: install the MONTHLY section time reading (claude-config#520).
#
# A reading is a whole suite run, so it is scheduled once a month, at night, and it waits for the
# machine to be quiet before it starts rather than competing with whoever is working. Dan chose
# monthly with a quiet window on 2026-09-21, over weekly and over leaving it manual, because the
# cost lands on a Mac somebody is using.
#
# The plist records an ABSOLUTE path to this checkout, because a launch agent is a COPY and goes on
# running the definition it was written with (L423). Re-run this after moving the checkout.
#
# Usage: install-section-time-schedule.sh [--remove]
#   SECTION_TIME_LAUNCHAGENTS   where to write the plist (default: ~/Library/LaunchAgents)
#   SECTION_TIME_NO_LAUNCHCTL=1 write the plist and do not load it (what the tests do)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTDIR="${SECTION_TIME_LAUNCHAGENTS:-$HOME/Library/LaunchAgents}"
PLIST="$AGENTDIR/com.claudeconfig.sectiontime.plist"
TAKER="$HERE/take-section-time-reading.sh"

if [ "${1:-}" = "--remove" ]; then
  [ "${SECTION_TIME_NO_LAUNCHCTL:-0}" = "1" ] || launchctl unload "$PLIST" 2>/dev/null || true
  rm -f "$PLIST"
  printf 'Removed the monthly section time reading (%s).\n' "$PLIST"
  exit 0
fi
[ -x "$TAKER" ] || { printf 'install-section-time-schedule: no runnable %s, so there is nothing to schedule.\n' "$TAKER" >&2; exit 1; }

mkdir -p "$AGENTDIR"
# launchd gives a job a minimal PATH with no Homebrew, and the suite this measures needs the tools
# a login shell has.
jobpath="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.claudeconfig.sectiontime</string>
  <key>ProgramArguments</key>
  <array><string>/bin/bash</string><string>$TAKER</string></array>
  <key>EnvironmentVariables</key><dict><key>PATH</key><string>$jobpath</string></dict>
  <key>StartCalendarInterval</key><dict><key>Day</key><integer>1</integer><key>Hour</key><integer>2</integer><key>Minute</key><integer>0</integer></dict>
  <key>StandardOutPath</key><string>$HOME/.claude-section-time.log</string>
  <key>StandardErrorPath</key><string>$HOME/.claude-section-time.log</string>
</dict></plist>
PL
if [ "${SECTION_TIME_NO_LAUNCHCTL:-0}" != "1" ]; then
  launchctl unload "$PLIST" 2>/dev/null || true
  launchctl load "$PLIST" 2>/dev/null || printf 'install-section-time-schedule: wrote %s but launchctl would not load it, so it is installed and not running yet.\n' "$PLIST" >&2
fi
printf 'Installed the monthly section time reading: 1st of each month at 02:00, waiting for a quiet window.\n'
printf 'Job: %s\n' "$PLIST"
printf 'Log: %s\n' "$HOME/.claude-section-time.log"
printf 'Remove it with: %s --remove\n' "$0"
exit 0
