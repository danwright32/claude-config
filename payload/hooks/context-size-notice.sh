#!/usr/bin/env bash
#
# context-size-notice.sh
# Claude Code PostToolUse hook, on every tool (no matcher), in the main session and in subagents,
# and Stop hook in the main session (claude-config#3307).
#
# Two notices read from the size of each request, both first decided by Dan on 2026-11-01:
#
# - The context line (claude-config#1960, #2283). A builder (any subagent) or an orchestrator (a
#   main session that has dispatched an agent or set a /goal) whose last request carried more than
#   CONTEXT_LINE_TOKENS (330,000, Dan 2026-11-05) of work, its context above the floor of its first
#   request or its first since its latest compaction, is told, once per band of the line, to write
#   down what it has decided and then restart or compact: an orchestrator puts decisions on their issues and the rest
#   in a handoff note, and tells Dan so he can /compact or start fresh; a builder writes the note and
#   hands back so the main session gives the rest to a fresh agent.
# - The long session question (claude-config#1940, #3307). A main session compacted
#   CONTEXT_COMPACTIONS_NUDGE (5) times has Dan asked in a picker, at the end of a turn, whether to
#   hand off to a fresh session, with what it has read and what a fresh session would save. This
#   script is also the Stop hook that asks: run there, it holds the turn's end once per crossing.
#
# Both thresholds, their measurements and how to re-measure them are in lib/context_size.py, which
# does the work. No existing hook read a request's usage: the status-bar mod reads the main
# session's context through the client for Dan's band, and never speaks to the session or sees a
# subagent, so this does not duplicate it. PostToolUse because it is the one event that fires inside
# subagents as well as in the main session (measured: subagent transcripts on this Mac carry
# PostToolUse hook records) and during a /goal run, where no prompt is typed.
#
# Cheap, because it runs after every tool call: one python3 that reads only the bytes appended to
# the transcript since its last run, and says nothing on the ordinary call. Never blocks a tool:
# exits 0. At a turn's end it holds the turn once per crossing of the long session line, to ask.
#
# The payload goes straight to python3 on this script's own stdin, never through a shell variable or
# jq, so nothing here needs lib/push-scope.sh's cleaning: python3 reads it as bytes, decodes with
# errors="replace", and a lone surrogate escape only ever reaches a value it checks against a plain
# name pattern before using it.

set -uo pipefail
case "${BASH_SOURCE[0]}" in */*) HOOK_DIR="${BASH_SOURCE[0]%/*}" ;; *) HOOK_DIR=. ;; esac
# As the Stop hook (--stop) it asks Dan a question, so while the Mac sleeps (sleep mode,
# claude-config#841) it stops here and the question waits for the first turn's end after wake.
# Asked only at a turn's end, never after every tool call, where it would cost a read of the sleep
# record each time for a notice that asks nobody. Unreadable counts as awake (lib/sleep.sh).
if [ "${1:-}" = --stop ] && . "$HOOK_DIR/lib/sleep.sh" 2>/dev/null && sleep_active; then
  exit 0
fi
python3 "$HOOK_DIR/lib/context_size.py" 2>/dev/null
exit 0
