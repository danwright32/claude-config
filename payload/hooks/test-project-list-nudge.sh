#!/usr/bin/env bash
# Tests for project-list-nudge.sh, which puts check-project-list.sh on a real event
# (claude-config#157).
#
# check-project-list.sh worked and nothing invoked it. It was absent from settings.json and from
# any driver, so the only way it ever fired was somebody typing the command, which is the one case
# where it adds nothing: a person typing it already suspects the list is wrong. The failure it
# exists to catch is silent by nature, since the stale path loads at the start of every session and
# nothing complains. Built is not wired (L3).
#
# So the checks below care about three things: that a missing project is SAID unprompted, that
# saying it does not turn into noise on every prompt, and that a check which could not run says so
# rather than passing for silence (L98).
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NUDGE="$DIR/project-list-nudge.sh"

pass=0
fail=0
check() { # check <description> <result>   ("ok" passes, anything else is the failure text)
  if [[ "$2" == "ok" ]]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL: $1 ($2)"
  fi
}

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/claude-sync-work.projnudge.XXXXXXXX")" || TMPROOT=""
case "${TMPROOT%/}" in
  ''|/|"${HOME%/}") echo "test-project-list-nudge: refusing to run: throwaway directory came back as '$TMPROOT'." >&2; exit 2 ;;
esac
trap 'rm -rf "$TMPROOT"' EXIT

STATE="$TMPROOT/state"
mkdir -p "$STATE" "$TMPROOT/here/AppOne" "$TMPROOT/here/AppTwo"

mklist() { # mklist <name> <body>  -> prints the path
  local f="$TMPROOT/$1"
  printf '%s\n' "$2" > "$f"
  printf '%s' "$f"
}
# The hook payload a real UserPromptSubmit carries. Only the session id matters here.
payload() { printf '{"session_id": "%s", "prompt": "hello"}' "${1:-sess-a}"; }
run() { # run <list file> <host> [session]
  payload "${3:-sess-a}" | PROJECT_LIST_FILE="$1" PROJECT_LIST_HOST="$2" \
    PROJECT_LIST_STATE_DIR="$STATE" bash "$NUDGE" 2>/dev/null
}
run_err() { # same, but stderr instead
  payload "${3:-sess-a}" | PROJECT_LIST_FILE="$1" PROJECT_LIST_HOST="$2" \
    PROJECT_LIST_STATE_DIR="$STATE" bash "$NUDGE" 2>&1 >/dev/null
}

ALL_THERE="$(mklist all.md "## Projects

On Mac-A:
- \`$TMPROOT/here/AppOne\`
- \`$TMPROOT/here/AppTwo\`
")"
ONE_GONE="$(mklist gone.md "## Projects

On Mac-A:
- \`$TMPROOT/here/AppOne\`
- \`$TMPROOT/here/AppMoved\`
")"
TWO_GONE="$(mklist gone2.md "## Projects

On Mac-A:
- \`$TMPROOT/here/AppOne\`
- \`$TMPROOT/here/AppMoved\`
- \`$TMPROOT/here/AppAlsoMoved\`
")"

# ---------------------------------------------------------------------------
# Nothing wrong is nothing said. A hook that speaks on every prompt is the noise this has to
# avoid, and it would be speaking about the case that needs no action at all.
# ---------------------------------------------------------------------------
out_ok="$(run "$ALL_THERE" Mac-A sess-quiet)"; code_ok=$?
[ "$code_ok" -eq 0 ] \
  && check "a list whose projects are all present exits 0" ok \
  || check "a list whose projects are all present exits 0" "exit=$code_ok"
[ -z "$out_ok" ] \
  && check "and says nothing at all" ok \
  || check "and says nothing at all" "it said: $out_ok"

# ---------------------------------------------------------------------------
# A missing project is SAID, unprompted. This is the whole issue.
# ---------------------------------------------------------------------------
out_gone="$(run "$ONE_GONE" Mac-A sess-b)"; code_gone=$?
case "$out_gone" in
  *AppMoved*) check "a project that is not there is reported" ok ;;
  *) check "a project that is not there is reported" "it said: $out_gone" ;;
esac
# It must NEVER block the prompt. A UserPromptSubmit hook that exits non-zero stops the turn, and
# a moved project is a thing to mention, not a reason to refuse to work (L54).
[ "$code_gone" -eq 0 ] \
  && check "and it still exits 0, so the prompt is not blocked" ok \
  || check "and it still exits 0, so the prompt is not blocked" "exit=$code_gone"
# The one that IS present must not be named, or the reader cannot tell which to act on.
case "$out_gone" in
  *AppOne*) check "and a project that IS present is not named as missing" "it named AppOne: $out_gone" ;;
  *) check "and a project that IS present is not named as missing" ok ;;
esac

# ---------------------------------------------------------------------------
# Once per divergence, not once per prompt.
# ---------------------------------------------------------------------------
out_again="$(run "$ONE_GONE" Mac-A sess-b)"
[ -z "$out_again" ] \
  && check "a second prompt in the same session with the same answer is quiet" ok \
  || check "a second prompt in the same session with the same answer is quiet" "it repeated: $out_again"
# But a CHANGE speaks again, or the first notice silences every later one and a second project
# going missing would never be mentioned (L152).
out_changed="$(run "$TWO_GONE" Mac-A sess-b)"
case "$out_changed" in
  *AppAlsoMoved*) check "and a second project going missing is reported" ok ;;
  *) check "and a second project going missing is reported" "it said: $out_changed" ;;
esac
# A different session is told too, because that session loaded the stale list at ITS startup and
# has never been told anything.
out_other="$(run "$TWO_GONE" Mac-A sess-c)"
case "$out_other" in
  *AppMoved*) check "and a different session is told rather than inheriting the first one's silence" ok ;;
  *) check "and a different session is told rather than inheriting the first one's silence" "it said: $out_other" ;;
esac

# ---------------------------------------------------------------------------
# A check that could not run says so. Reading nothing and finding nothing wrong are
# indistinguishable otherwise, and this hook's silence is what says the list is sound (L98).
# ---------------------------------------------------------------------------
out_nofile="$(run "$TMPROOT/no-such-file.md" Mac-A sess-d)"; code_nofile=$?
case "$out_nofile" in
  *[![:space:]]*) check "a list that cannot be read is reported rather than passed over" ok ;;
  *) check "a list that cannot be read is reported rather than passed over" "it said nothing" ;;
esac
[ "$code_nofile" -eq 0 ] \
  && check "and that does not block the prompt either" ok \
  || check "and that does not block the prompt either" "exit=$code_nofile"

# A machine the list says nothing about is NOT a failure, and must stay quiet: both Macs read one
# list, and the block for the other one is not this machine's business.
NOBLOCK="$(mklist other.md "## Projects

On Some-Other-Mac:
- \`$TMPROOT/here/AppOne\`
")"
out_noblock="$(run "$NOBLOCK" Mac-A sess-e)"
[ -z "$out_noblock" ] \
  && check "a list naming no block for this machine stays quiet" ok \
  || check "a list naming no block for this machine stays quiet" "it said: $out_noblock"

# ---------------------------------------------------------------------------
# No session id in the payload. It cannot deduplicate, so it SPEAKS rather than staying silent: a
# moved project said twice is a smaller failure than one never said (L11), and it says on stderr
# why it could not deduplicate.
# ---------------------------------------------------------------------------
out_nosess="$(printf '{}' | PROJECT_LIST_FILE="$ONE_GONE" PROJECT_LIST_HOST=Mac-A \
  PROJECT_LIST_STATE_DIR="$STATE" bash "$NUDGE" 2>/dev/null)"
case "$out_nosess" in
  *AppMoved*) check "a payload with no session id still reports the missing project" ok ;;
  *) check "a payload with no session id still reports the missing project" "it said: $out_nosess" ;;
esac
err_nosess="$(printf '{}' | PROJECT_LIST_FILE="$ONE_GONE" PROJECT_LIST_HOST=Mac-A \
  PROJECT_LIST_STATE_DIR="$STATE" bash "$NUDGE" 2>&1 >/dev/null)"
case "$err_nosess" in
  *[![:space:]]*) check "and says on stderr that it could not deduplicate" ok ;;
  *) check "and says on stderr that it could not deduplicate" "stderr was empty" ;;
esac

# ---------------------------------------------------------------------------
# Wired, not merely written. The defect this closes is a check nothing invokes, so the hook being
# named in the settings the sync ships is part of the fix and not a separate chore (L3, L27).
# ---------------------------------------------------------------------------
SETTINGS="$DIR/../settings.hooks.json"
if [ -f "$SETTINGS" ]; then
  grep -F 'project-list-nudge.sh' "$SETTINGS" > /dev/null \
    && check "the hook is named in the settings the sync ships" ok \
    || check "the hook is named in the settings the sync ships" "settings.hooks.json does not mention it"
else
  check "the settings the sync ships could be read" "no settings.hooks.json beside $DIR"
fi

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
