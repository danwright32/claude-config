#!/usr/bin/env bash
#
# install-lessons-core-rerank-schedule.sh: install the re-rank of the lessons core (claude-config#566)
# on THIS Mac. Run it on each Mac, from the clone the sync runs from (~/claude-config-sync).
#
# The job runs DAILY and delivers MONTHLY (run-lessons-core-rerank.sh says why): each day it keeps
# this Mac's citation counts no more than a week old, and once a month, as soon as both Macs' counts
# are fresh, it writes the page and posts one notification.
#
# The plist records an ABSOLUTE path to this checkout, because a launch agent is a COPY and goes on
# running the definition it was written with (L423). Re-run this after moving the checkout.
#
# Usage: install-lessons-core-rerank-schedule.sh [--remove]
#   RERANK_LAUNCHAGENTS   where to write the plist (default: ~/Library/LaunchAgents)
#   RERANK_NO_LAUNCHCTL=1 write the plist and do not load it (what the tests do)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTDIR="${RERANK_LAUNCHAGENTS:-$HOME/Library/LaunchAgents}"
LABEL="com.claudeconfig.lessonscorererank"
PLIST="$AGENTDIR/$LABEL.plist"
JOB="$HERE/run-lessons-core-rerank.sh"
LOG="$HOME/.claude-lessons-core-rerank.log"

if [ "${1:-}" = "--remove" ]; then
  [ "${RERANK_NO_LAUNCHCTL:-0}" = "1" ] || launchctl unload "$PLIST" 2>/dev/null || true
  rm -f "$PLIST"
  printf 'Removed the lessons core re-rank (%s).\n' "$PLIST"
  exit 0
fi
[ -f "$JOB" ] || { printf 'install-lessons-core-rerank-schedule: no %s, so there is nothing to schedule.\n' "$JOB" >&2; exit 1; }

mkdir -p "$AGENTDIR"
# launchd gives a job a minimal PATH with no Homebrew, where terminal-notifier lives.
jobpath="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>/bin/bash</string><string>$JOB</string></array>
  <key>EnvironmentVariables</key><dict><key>PATH</key><string>$jobpath</string></dict>
  <key>StartCalendarInterval</key><dict><key>Hour</key><integer>11</integer><key>Minute</key><integer>7</integer></dict>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict></plist>
PL
if [ "${RERANK_NO_LAUNCHCTL:-0}" != "1" ]; then
  launchctl unload "$PLIST" 2>/dev/null || true
  launchctl load "$PLIST" 2>/dev/null || printf 'install-lessons-core-rerank-schedule: wrote %s but launchctl would not load it, so it is installed and not running yet.\n' "$PLIST" >&2
fi
printf 'Installed the lessons core re-rank: every day at 11:07 local time (a missed run happens on wake), delivering once a month.\n'
printf 'Job: %s\n' "$PLIST"
printf 'Log: %s\n' "$LOG"
printf 'Remove it with: %s --remove\n' "$0"
exit 0
