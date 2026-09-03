#!/usr/bin/env bash
# Global Stop hook: after a turn that involved REAL work (any tool use other
# than AskUserQuestion), re-prompt Claude to reflect before it actually stops —
# (1) what it is least sure about, and (2) the biggest thing the user probably
# does not realize about what was just done.
#
# Skips:
#   - trivial chat turns (no tools used since the last genuine user message)
#   - turns whose only tool was AskUserQuestion (Claude was asking the user)
#   - its own continuation (stop_hook_active guard) so it cannot loop
#
# Fails SAFE: any parse/transcript error -> skip (do not fire), to avoid noise.
# No time throttle by design: it fires once per substantive turn. To disable,
# remove its hooks.Stop entry in ~/.claude/settings.json.

set -uo pipefail

input=$(cat)

# Detached-run guard: a headless `claude -p` launched by an app has nobody to reflect TO, and its
# stdout is a file some program parses rather than a person reads. Firing here does real damage: the
# re-prompt is spent on ceremony instead of the run's actual job. Overture's scout-extract run burned
# itself writing this banner into its own log and never wrote the results file the app was waiting
# for, losing every extracted show (2026-07-16). Any runner that sets this is telling us the same
# thing: there is no reader on the other end.
[ -n "${CLAUDE_DETACHED_RUN:-}" ] && exit 0

# Loop guard: don't re-fire on our own (or another Stop hook's) continuation.
stop_active=$(printf '%s' "$input" | jq -r '.stop_hook_active // false' 2>/dev/null)
[ "$stop_active" = "true" ] && exit 0

transcript=$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null)
[ -n "$transcript" ] || exit 0
[ -f "$transcript" ] || exit 0

# Per-conversation kill switch: `touch <transcript>.skip-stop-hooks` silences
# this hook for that one conversation only; delete the file to re-enable.
[ -f "${transcript}.skip-stop-hooks" ] && exit 0

# Did the latest turn (since the last genuine user message) use a MUTATING tool
# (Edit/Write/Bash/Agent/...)? Chat-only and read-only Q&A turns -> skip, so the
# reflection doesn't crowd out short question turns (shared helper, also used by
# feature-issue-review.sh).
worked=$(python3 "$(dirname "${BASH_SOURCE[0]}")/turn-worked.py" "$transcript" 2>/dev/null)

[ "$worked" = "yes" ] || exit 0

# decision:block feeds `reason` back to Claude as a continuation instruction, and
# Claude Code prints that reason to Dan verbatim. So the instruction does NOT live
# in this file any more: it lives in review/session-reflection.md and what follows
# emits a short pointer to it.
#
# The path is RESOLVED FROM THIS FILE'S OWN LOCATION, never written down and never
# read from the environment. This config is synced between two Macs whose paths
# differ, so a pointer that resolves itself is correct on both with nothing to
# configure. test-review-instructions.sh proves that by running a relocated copy of
# the tree and requiring the reason to name the copy.
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

payload="$(python3 "$SELF_DIR/lib/review-reason.py" \
  --instruction "$SELF_DIR/review/session-reflection.md" \
  --label "SESSION REFLECTION" 2>/dev/null)" || payload=""

if [ -n "$payload" ]; then
  printf '%s' "$payload"
else
  # The pointer could not be built. Losing its detail is a nuisance; losing the
  # reflection is not, so a static payload still sends Claude to the instruction.
  # It names the file relatively, because the one thing this branch cannot do is
  # work out an absolute path.
  cat <<'JSON'
{"decision":"block","reason":"SESSION REFLECTION. Read review/session-reflection.md next to the Stop hooks in your Claude config directory (normally ~/.claude/hooks) and follow it exactly. The pointer that normally names its exact path could not be built, so find the file yourself rather than inventing a reflection from this line."}
JSON
fi
