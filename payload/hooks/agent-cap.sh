#!/usr/bin/env bash
#
# agent-cap.sh
# Claude Code SessionStart hook (every source: startup, resume, /clear, compaction).
#
# Says in one line how many subagents this session may have running at once, which depends on the
# Mac (claude-config#2546). Dan asked on 2026-11-09 for seven per session on the work MacBook, then
# just replaced with an 18 core machine, while the personal MacBook stays at the default. The global
# CLAUDE.md is one file both Macs load, so it cannot carry a number per Mac: it says the cap is the
# number on this line, and the default when no line arrived.
#
# THIS FILE IS THE NUMBER'S ONE HOME. Every skill and document that needs the cap points at the
# `[Agent cap]` line instead of writing a number out, and test-agent-cap.sh fails on a document that
# writes one out by hand (L613). Before this, four was written in eight documents and held there by
# two suites.
#
# Once per session start, never per prompt: the line is re-sent on every request of the session, so
# it stays one short line. SessionStart delivers it again after /clear and each compaction, exactly
# when the earlier copy is gone (the same reasoning as tdd-nudge.sh).
#
# Which Mac this is comes from lib/this-mac.sh, the one reading every hook makes (claude-config#2561).
# A name that cannot be read gets the default and the line says so, never a silent guess (L11).
#
#   agent-cap.sh            the session start line
#   agent-cap.sh --number   this Mac's cap alone, for a script that needs the number
#   agent-cap.sh --table    every named Mac and its cap, one per line, for the suite
#
# AGENT_CAP_HOST judges as a named machine instead of this one, for the suite. Set and empty, it
# stands for a Mac whose name could not be read.
#
# stdout on exit 0 is added to the session's context.

# The cap for any Mac the table does not name.
AGENT_CAP_DEFAULT=4

# One Mac per line: its short hostname, one space, its cap. Dan, 2026-11-09: "raise the session
# subagent limit to 7 agents each", for the work MacBook.
agent_cap_table() {
  cat <<'TABLE'
Dans-MacBook-Pro 7
TABLE
}

if [ "${1:-}" = "--table" ]; then
  agent_cap_table
  exit 0
fi

case "${BASH_SOURCE[0]}" in */*) HOOK_DIR="${BASH_SOURCE[0]%/*}" ;; *) HOOK_DIR=. ;; esac
unread="this Mac's name could not be read"
if . "$HOOK_DIR/lib/this-mac.sh" 2>/dev/null; then
  host="$(this_mac_name ${AGENT_CAP_HOST+"$AGENT_CAP_HOST"})"
else
  host=""
  unread="lib/this-mac.sh is missing beside this hook, so which Mac this is could not be read"
fi
cap=""
if [ -n "$host" ]; then
  cap="$(agent_cap_table | awk -v h="$host" '$1 == h { print $2; exit }')"
fi
named=1
if [ -z "$cap" ]; then
  cap="$AGENT_CAP_DEFAULT"
  named=0
fi

if [ "${1:-}" = "--number" ]; then
  echo "$cap"
  exit 0
fi

if [ -z "$host" ]; then
  echo "[Agent cap] At most $cap subagents running at once: $unread, so the default applies."
elif [ "$named" -eq 1 ]; then
  echo "[Agent cap] At most $cap subagents running at once on this Mac ($host)."
else
  echo "[Agent cap] At most $cap subagents running at once on this Mac ($host, the default for a Mac not named)."
fi
exit 0
