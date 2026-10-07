#!/usr/bin/env bash
#
# lesson-fanout-notice.sh
# Claude Code PostToolUse(Bash|Edit|Write|MultiEdit) hook: when LESSONS.md holds a lesson this Mac
# has not fanned out yet, ask for lib/lesson-fanout.sh to be run on it, which files a "check this
# project for that defect" issue in every repo the repo-digest covers.
#
# Keyed on the STATE reached (a lesson number in the file that the ledger lacks), never on how it got
# there, so a lesson added through the lesson check picker, by plan-council, by hand, or arriving
# from the other Mac through the sync is caught alike (L247). The ledger is written by the fan out
# script, and only once every repo has the issue, so a request that was ignored or a run that
# failed part way is asked again after the cooldown rather than lost (L368).
#
# First run on a Mac, with no ledger yet, records every lesson already present as a baseline and
# says nothing: the request is about lessons from now on, not the ones written before it.
#
# Guards:
#   CLAUDE_DETACHED_RUN set    a headless run has nobody to act on it. Silent.
#   LESSON_FANOUT_OFF=1        the documented override. Silent.
#   Asleep (sleep mode)        nobody is there to run it; it waits for the morning. Silent.
#   Cooldown per Mac           one request per stretch of work, not one per tool call; its length
#                              is a window this hook sets, not measured.
# Fails QUIET: anything it cannot read exits 0 with no output.
#
# Seams: CLAUDE_HOME, LESSON_FANOUT_NOW (the clock).

set -uo pipefail

[ -n "${CLAUDE_DETACHED_RUN:-}" ] && exit 0
[ "${LESSON_FANOUT_OFF:-}" = "1" ] && exit 0
cat >/dev/null 2>&1 || true

CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"
# Asleep (sleep mode, claude-config#841): nobody is there to run it, so it waits, with no cooldown
# spent, and the first tool call after wake asks. Unreadable counts as awake (lib/sleep.sh).
if . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/sleep.sh" 2>/dev/null \
  && sleep_active "$CLAUDE_HOME/state/sleep/current.json"; then
  exit 0
fi
LESSONS="$CLAUDE_HOME/LESSONS.md"
LEDGER="$CLAUDE_HOME/state/lesson-fanout.done"
STAMP="$CLAUDE_HOME/state/lesson-fanout-notice.stamp"
COOLDOWN_SECONDS=600
now="${LESSON_FANOUT_NOW:-$(date +%s)}"

[ -f "$LESSONS" ] || exit 0
present="$(grep -oE '^- \*\*L[0-9]+\.' "$LESSONS" 2>/dev/null | sed -E 's/^- \*\*(L[0-9]+)\./\1/' | sort -u)"
[ -n "$present" ] || exit 0

mkdir -p "$(dirname "$LEDGER")" 2>/dev/null || exit 0
if [ ! -f "$LEDGER" ]; then
  printf '%s\n' "$present" | sed 's/$/ baseline/' >"$LEDGER" 2>/dev/null
  exit 0
fi

pending="$(comm -23 <(printf '%s\n' "$present") <(awk '{print $1}' "$LEDGER" | sort -u) \
  | sed 's/^L//' | sort -n | sed 's/^/L/' | tr '\n' ' ' | sed 's/ *$//')"
[ -n "$pending" ] || exit 0

last="$(cat "$STAMP" 2>/dev/null || echo 0)"
[[ "$last" =~ ^[0-9]+$ ]] || last=0
[ $(( now - last )) -lt "$COOLDOWN_SECONDS" ] && exit 0
printf '%s' "$now" >"$STAMP" 2>/dev/null

cmd="bash $CLAUDE_HOME/hooks/lib/lesson-fanout.sh $pending"
reason="New lesson(s) not yet checked for in Dan's other projects: $pending. Run this now, as its own Bash call, exactly as written: $cmd

It files one issue per repo in the repo-digest lists, asking that project to be checked for the same defect, skipping the repo the lesson came from and any repo that already has one. Report its outcome to Dan in one or two plain lines: how many issues were filed, and every line it marked FAILED or REFUSED with its reason. If it reports anything not filed, say so plainly; rerunning later files only the gaps."
jq -cn --arg r "$reason" '{decision: "block", reason: $r}'
