#!/usr/bin/env bash
#
# design-score-reopen.sh: SessionStart hook. Starts, at most once a day on this Mac, the check that
# reopens a "Match the settled design" issue or its milestone closed below 100% where the close gate
# could not see it, and says what the last run did (claude-config#1386).
#
# WHY HERE, and not a launch agent or a GitHub workflow. A workflow would be one file in every repo
# with a design milestone, set up again for each new one, and billed minutes in the private ones. A
# launch agent is a copy each Mac must install by hand and goes on running the old definition after
# a change (L423). This hook arrives with the config sync on both Macs, needs nothing installed, runs
# under Dan's own gh sign ins (every account, as the gate reads them), and costs nothing. What it
# trades away: a close is caught the next day Dan opens a session, not the next hour, and a close
# made while no session is opened for days waits that long. For a close that is undone by reopening,
# a day late loses nothing.
#
# IT NEVER RUNS THE CHECK INSIDE THE HOOK. The check reads GitHub for every repo in the digest, which
# can take a minute, and a hook has five seconds, so it starts design-score-reopen.py --scheduled
# detached and not waited for (the shape of stale-worktree-nudge.sh, #1247). The start is recorded
# BEFORE the run starts, so a start that fails cannot be retried on every session (L514).
#
# IT SAYS WHAT HAPPENED, ONCE. The run leaves a result file only when it reopened something or could
# not check something; the next session start claims it by a rename, so of two sessions starting at
# once exactly one says it, and keeps it as result.shown. A run that started a day ago and never
# recorded finishing is said too (L13): a check that died is not a check that found nothing.
#
# Never blocks: every path exits 0. stdout on exit 0 is added to the session's context.
#
# Env (seams for the tests):
#   DESIGN_REOPEN_STATE_DIR  where the run's records live (default ~/.claude/state/design-score-reopen)
#   DESIGN_REOPEN_PY         the check to start (default design-score-reopen.py beside this file)
#   DESIGN_REOPEN_EVERY      seconds between runs (default 72000, 20 hours, so a daily habit is not
#                            skipped for starting a little earlier than yesterday)
#   DESIGN_REOPEN_NOW        the clock, as an epoch (L290)
set -uo pipefail
cat >/dev/null 2>&1 || true
[ -n "${CLAUDE_DETACHED_RUN:-}" ] && exit 0

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="${DESIGN_REOPEN_PY:-$DIR/design-score-reopen.py}"
STATE="${DESIGN_REOPEN_STATE_DIR:-${CLAUDE_HOME:-$HOME/.claude}/state/design-score-reopen}"
EVERY="${DESIGN_REOPEN_EVERY:-72000}"
NOW="${DESIGN_REOPEN_NOW:-$(date +%s)}"

if ! mkdir -p "$STATE" 2>/dev/null; then
  echo "design-score-reopen: could not make $STATE, so the daily check for Match the settled design issues closed below 100% was not started. Tell Dan."
  exit 0
fi

# --- say what a finished run left ---------------------------------------------
said=""
shopt -s nullglob
for f in "$STATE"/result.*; do
  case "$f" in *.tmp.*|*.shown|*.claimed.*) continue ;; esac
  claimed="$f.claimed.$$"
  mv "$f" "$claimed" 2>/dev/null || continue
  said="$said$(cat "$claimed" 2>/dev/null)"$'\n'
  mv -f "$claimed" "$STATE/result.shown" 2>/dev/null || true
done
shopt -u nullglob
if [ -n "$said" ]; then
  printf 'The daily check for Match the settled design issues closed below 100%% (claude-config#1386) reported the following. Tell Dan, in plain words:\n%s' "$said"
fi

# --- start today's run --------------------------------------------------------
last="$(tr -dc '0-9' <"$STATE/last-start" 2>/dev/null)"
finished="$(tr -dc '0-9' <"$STATE/last-finish" 2>/dev/null)"
if [ -n "$last" ] && [ $((NOW - last)) -lt "$EVERY" ]; then
  exit 0
fi
if [ -n "$last" ] && { [ -z "$finished" ] || [ "$finished" -lt "$last" ]; }; then
  echo "The daily check for Match the settled design issues closed below 100% (claude-config#1386), started $(( (NOW - last) / 3600 )) hours ago and never finished (it recorded no end), so nothing is known about closes since then. Its log is $STATE/log. A new run is starting now. Tell Dan."
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "design-score-reopen: python3 is not on PATH, and the daily check for Match the settled design issues closed below 100% runs on it, so it was not started. Tell Dan."
  exit 0
fi
printf '%s\n' "$NOW" >"$STATE/last-start" 2>/dev/null || true
nohup python3 "$RUNNER" --scheduled --state-dir "$STATE" </dev/null >/dev/null 2>&1 &
disown "$!" 2>/dev/null || true
exit 0
