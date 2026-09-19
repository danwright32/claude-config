#!/usr/bin/env bash
# Where test-project-list-nudge.sh looks for the settings that register the hook (claude-config#175).
#
# That suite ends with a wiring check, because the defect it closes was a check nothing invoked, so
# being named in the settings is part of the fix rather than a separate chore (L3, L27). It read
# `$DIR/../settings.hooks.json`, which only exists inside the checkout, where the hooks live under
# payload/. On a deployed Mac the hooks sit in ~/.claude/hooks, that file is absent, and the suite
# reported `FAIL: the settings the sync ships could be read` on every run, on both Macs. A suite
# that is permanently red teaches everyone to skim past it, which is how a real failure gets missed
# (L36).
#
# The answer is not to stop asking. A deployed config directory holds the settings that ACTUALLY
# register the hook on that machine, one level above the hooks, so the question is answerable in
# both places and the deployed answer is the more meaningful of the two (L63). Only where neither
# file is present is there nothing to read, and that is the one case that says NOT RUN, in its own
# wording, so an unreadable settings file and a missing one stay distinguishable (L11).
#
# Every case below is driven through the real suite rather than through a copy of its logic, so
# what is measured is what ships.
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUITE="$DIR/test-project-list-nudge.sh"

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

[ -f "$SUITE" ] || {
  echo "test-project-list-nudge-wiring: no test-project-list-nudge.sh beside $DIR, so its settings lookup could not be exercised at all." >&2
  printf 'SUITE-NOT-RUN %s\n' "needs test-project-list-nudge.sh beside it, and there is none in $DIR"
  exit 2
}

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/claude-sync-work.projwire.XXXXXXXX")" || TMPROOT=""
case "${TMPROOT%/}" in
  ''|/|"${HOME%/}") echo "test-project-list-nudge-wiring: refusing to run: throwaway directory came back as '$TMPROOT'." >&2; exit 2 ;;
esac
trap 'rm -rf "$TMPROOT"' EXIT

# A settings directory of each shape. The bodies are the smallest thing that answers the question
# the wiring check asks, which is whether the hook is named at all.
NAMED='{"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"bash ~/.claude/hooks/project-list-nudge.sh"}]}]}}'
UNNAMED='{"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"bash ~/.claude/hooks/rtk-rewrite.sh"}]}]}}'

mkcase() { # mkcase <name> [file=body ...]  -> prints the settings directory
  local d="$TMPROOT/$1" spec
  mkdir -p "$d"
  shift
  for spec in "$@"; do
    printf '%s' "${spec#*=}" > "$d/${spec%%=*}"
  done
  printf '%s' "$d"
}

# run <settings dir>  -> sets OUT to the suite's combined output and RC to its exit status.
#
# It is deliberately NOT a function whose output is captured with $(...), which is how this was
# first written: a command substitution runs in a subshell, so the RC assigned inside it was thrown
# away and every case read as exit 0, including the two that exist to prove a failure can happen.
# The exit status is the thing being measured here (L184), so it is written where the caller can
# see it rather than through a construct that discards it.
RC=0
OUT=""
run() {
  RC=0
  PROJECT_LIST_NUDGE_SETTINGS_DIR="$1" bash "$SUITE" > "$TMPROOT/run.out" 2>&1 || RC=$?
  OUT="$(cat "$TMPROOT/run.out")"
}

# ---------------------------------------------------------------------------
# The checkout. settings.hooks.json is the file the sync ships, and it is the one to read where it
# exists, since inside the checkout it is the only statement of what will be installed.
# ---------------------------------------------------------------------------
CHECKOUT="$(mkcase checkout "settings.hooks.json=$NAMED")"
run "$CHECKOUT"
out_checkout="$OUT"
[ "$RC" -eq 0 ] \
  && check "the checkout shape passes when the shipped settings name the hook" ok \
  || check "the checkout shape passes when the shipped settings name the hook" "it exited $RC saying: $(printf '%s' "$out_checkout" | grep -E '^FAIL|^SUITE-NOT-RUN' | tail -1)"
case "$out_checkout" in
  *SUITE-NOT-RUN*) check "and does not declare itself unrunnable there" "it printed SUITE-NOT-RUN" ;;
  *) check "and does not declare itself unrunnable there" ok ;;
esac

# ---------------------------------------------------------------------------
# The deployed Mac, which is the case in the issue. The hooks sit in ~/.claude/hooks and the file
# one level above them is settings.json, which is what Claude Code actually reads. Before this the
# suite failed here on every run.
# ---------------------------------------------------------------------------
DEPLOYED="$(mkcase deployed "settings.json=$NAMED")"
run "$DEPLOYED"
out_deployed="$OUT"
[ "$RC" -eq 0 ] \
  && check "the deployed shape passes when the installed settings name the hook" ok \
  || check "the deployed shape passes when the installed settings name the hook" "it exited $RC saying: $(printf '%s' "$out_deployed" | grep -E '^FAIL|^SUITE-NOT-RUN' | tail -1)"
case "$out_deployed" in
  *SUITE-NOT-RUN*) check "and reports a real result there rather than declaring itself unrunnable" "it printed SUITE-NOT-RUN" ;;
  *) check "and reports a real result there rather than declaring itself unrunnable" ok ;;
esac

# ---------------------------------------------------------------------------
# The check has to be able to FAIL in both shapes, or passing everywhere would mean only that it
# stopped asking (L1, L159). A settings file that names some other hook is the positive control.
# ---------------------------------------------------------------------------
for shape in "checkout_unnamed settings.hooks.json" "deployed_unnamed settings.json"; do
  set -- $shape
  d="$(mkcase "$1" "$2=$UNNAMED")"
  run "$d"
out_unnamed="$OUT"
  [ "$RC" -ne 0 ] \
    && check "settings holding $2 without the hook fails the suite" ok \
    || check "settings holding $2 without the hook fails the suite" "it exited 0"
  case "$out_unnamed" in
    *project-list-nudge*) check "and the failure names the hook it could not find in $2" ok ;;
    *) check "and the failure names the hook it could not find in $2" "it said: $(printf '%s' "$out_unnamed" | grep '^FAIL' | tail -1)" ;;
  esac
done

# ---------------------------------------------------------------------------
# Both present. The shipped file wins, because inside the checkout a stale installed copy beside it
# would otherwise answer for the version about to be shipped.
# ---------------------------------------------------------------------------
BOTH="$(mkcase both "settings.hooks.json=$NAMED" "settings.json=$UNNAMED")"
run "$BOTH"
out_both="$OUT"
[ "$RC" -eq 0 ] \
  && check "the shipped settings are preferred over an installed copy beside them" ok \
  || check "the shipped settings are preferred over an installed copy beside them" "it exited $RC"

# ---------------------------------------------------------------------------
# Neither present. There is genuinely nothing to read, so the suite says NOT RUN rather than
# failing, and exits 2 the way the runner reads (L98: not run must never be folded into passed).
# ---------------------------------------------------------------------------
EMPTY="$(mkcase empty)"
run "$EMPTY"
out_empty="$OUT"
nr_line="$(printf '%s\n' "$out_empty" | grep -E '^SUITE-NOT-RUN ' | tail -1)"
[ -n "$nr_line" ] \
  && check "with neither settings file present it declares NOT RUN" ok \
  || check "with neither settings file present it declares NOT RUN" "it printed no SUITE-NOT-RUN line"
[ "$RC" -eq 2 ] \
  && check "and exits 2, which is the status the runner reads it by" ok \
  || check "and exits 2, which is the status the runner reads it by" "it exited $RC"
case "$out_empty" in
  *FAIL:*) check "and does not also report a failed check" "it printed a FAIL line as well" ;;
  *) check "and does not also report a failed check" ok ;;
esac

# The reason has to be its OWN. The two sibling suites are ASKED for theirs rather than having
# their wording copied here, so this stays true when either of them is reworded (L41).
nr_reason="${nr_line#SUITE-NOT-RUN }"
case "$nr_reason" in
  *[![:space:]]*) check "and gives a reason rather than an empty one" ok ;;
  *) check "and gives a reason rather than an empty one" "the reason was empty" ;;
esac
sibling_reason() { # sibling_reason <suite> <root var>  -> its SUITE-NOT-RUN reason, or nothing
  local s="$DIR/$1"
  [ -f "$s" ] || return 0
  env "$2=$TMPROOT/no-such-repo" bash "$s" 2>/dev/null \
    | grep -E '^SUITE-NOT-RUN ' | tail -1 | sed 's/^SUITE-NOT-RUN //'
}
siblings_seen=0
for pair in "test-pipefail-shortcircuit.sh SHORTCIRCUIT_ROOT" "test-suite-result-line.sh SUITE_RESULT_ROOT"; do
  set -- $pair
  their="$(sibling_reason "$1" "$2")"
  [ -n "$their" ] || continue
  siblings_seen=$((siblings_seen + 1))
  [ "$nr_reason" != "$their" ] \
    && check "and its reason is not the one $1 gives" ok \
    || check "and its reason is not the one $1 gives" "both say: $nr_reason"
done
# Comparing against nothing would agree with anything, so the absence of a sibling to compare
# against is reported rather than counted as agreement (L98).
[ "$siblings_seen" -gt 0 ] \
  && check "at least one sibling reason was available to compare against" ok \
  || check "at least one sibling reason was available to compare against" "neither sibling suite produced a SUITE-NOT-RUN reason"

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
