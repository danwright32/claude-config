#!/usr/bin/env bash
#
# run-all-tests.sh: run every test suite in this repo and report one verdict.
#
# The suites are discovered from disk (`test-*.sh`), never from a list kept here.
# A hand written list would only ever run the suites someone remembered to add,
# so a new suite could sit unrun while this reported everything green
# (LESSONS.md L96).
#
# That was true of the FILES and false of the DIRECTORIES until #120. It read one
# directory, the one it lives in, so `tests/`, `tools/` and
# `payload/skills/milestone/` were outside it. The first three were run only
# because four hand written steps in .github/workflows/tests.yml named them, and
# the fourth was named by nothing at all: 233 checks that had never run anywhere.
# The boundary was the same hand maintained list, drawn one level up.
#
# So with no arguments it asks the REPO which directories hold a suite, and reads
# all of them. A suite added anywhere is found by that on the day it lands.
#
# Run:  bash ~/.claude/hooks/run-all-tests.sh              # every suite in the repo
#       bash ~/.claude/hooks/run-all-tests.sh <dir>...     # only these directories
#
# Exit 0 = every suite passed. Exit 1 = at least one failed, or a directory it was
# told to read held no suites, or nothing was found to run. Finding NO suites is a
# failure, not a pass: an empty run is indistinguishable from a clean one
# otherwise (LESSONS.md L98).
#
# Environment:
#   HOOK_TESTS_ROOT           read this repo instead of the one above this script
#   HOOK_TESTS_LIST_ONLY=1    print the directories it would read, run nothing
#   HOOK_TESTS_FAIL_DETAIL_MAX  lines of a failing suite's output to print

set -uo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
SELF_DIR="${SELF%/*}"

# This script's own directory holds `test-*.sh` files, and one of them tests this
# script, so a bare run discovers that suite and runs it, and it runs this script
# again. Measured the first time the suite existed: it recursed until the run was
# killed by hand. A depth marker rather than a lock, because the legitimate case
# (a suite invoking the runner against a FIXTURE directory) has to keep working,
# and only the bare re-entry is refused.
# HOOK_TESTS_LIST_ONLY is exempt, because it runs nothing at all: it prints the directories and
# exits, so it cannot be the step that recurses, and refusing it makes the one question a suite
# legitimately asks about the real repo unanswerable from inside a run.
if [ "${HOOK_TESTS_RUNNING:-0}" = "1" ] && [ "$#" -eq 0 ] \
   && [ -z "${HOOK_TESTS_ROOT:-}" ] && [ "${HOOK_TESTS_LIST_ONLY:-0}" != "1" ]; then
  echo "run-all-tests: refusing to run the whole repo from inside a run of the whole repo, which recurses without end. Name the directories to read, or set HOOK_TESTS_ROOT." >&2
  exit 1
fi
export HOOK_TESTS_RUNNING=1

# How many lines of a failing suite's own output to print. Enough to act on, bounded so one
# broken suite cannot bury the other verdicts.
FAIL_DETAIL_MAX="${HOOK_TESTS_FAIL_DETAIL_MAX:-40}"

dirs=""     # newline separated, deduplicated in the order found
add_dir(){  # add_dir <path>
  case "
$dirs" in *"
$1
"*) return 0 ;; esac
  dirs="$dirs$1
"
}

if [ "$#" -gt 0 ]; then
  for d in "$@"; do add_dir "$d"; done
  source_of_dirs="named on the command line"
else
  # Asked of git rather than of `find`, so a suite living in an untracked scratch
  # copy of the repo is not picked up and an ignored build directory costs nothing
  # to walk.
  root="${HOOK_TESTS_ROOT:-}"
  [ -n "$root" ] || root="$(git -C "$SELF_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
  if [ -n "$root" ] && [ -d "$root" ]; then
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      base="${f##*/}"
      case "$base" in test-*.sh) ;; *) continue ;; esac
      sub="${f%/*}"
      if [ "$sub" = "$f" ]; then add_dir "$root"; else add_dir "$root/$sub"; fi
    done <<EOF
$(git -C "$root" ls-files 2>/dev/null || true)
EOF
    # A repo that was READ and held no suite is a failure, and specifically NOT a
    # reason to fall back to this script's own directory. That fallback is for the
    # case below, where there is no repo at all; reaching it from here reads the
    # REAL hooks directory while claiming to have read the one it was pointed at,
    # runs this script's own test suite, and recurses without end. Measured the
    # first time the empty-repo check existed: the run had to be killed by hand.
    # A remedy scoped to the symptom that was observed is absent in the
    # neighbouring, worse failure (L173).
    if [ -z "$dirs" ]; then
      echo "run-all-tests: $root holds no test-*.sh at all, so NOTHING would be verified. Refusing to report that as a clean run." >&2
      exit 1
    fi
    source_of_dirs="discovered in $root"
  else
    # No repo above this script, which is what an installed copy under the config
    # directory looks like. Its own directory is still worth reading, and saying
    # that a narrower run happened keeps it from reading as the full one (L11).
    add_dir "$SELF_DIR"
    source_of_dirs="no repo above $SELF_DIR, so only its own directory was read"
  fi
fi

if [ "${HOOK_TESTS_LIST_ONLY:-0}" = "1" ]; then
  printf '%s' "$dirs"
  exit 0
fi

echo "run-all-tests: $(printf '%s' "$dirs" | grep -c .) directory(ies), $source_of_dirs"

ran=0
failed=0
failed_names=""
empty_dirs=""

while IFS= read -r d; do
  [ -n "$d" ] || continue
  if [ ! -d "$d" ]; then
    empty_dirs="$empty_dirs  $d (no such directory)
"
    continue
  fi
  here=0
  for suite in "$d"/test-*.sh; do
    [ -e "$suite" ] || continue
    # The runner's own test suite is a suite like any other and is run as one. It
    # never invokes this script bare, and the guard at the top is what makes that
    # true rather than a convention anybody has to remember.
    [ "$suite" = "$SELF" ] && continue
    name="$(basename "$suite")"
    here=$((here + 1))
    ran=$((ran + 1))
    out="$(bash "$suite" 2>&1)"
    code=$?
    # The suite's own TALLY line, which has to carry a pass count and a fail count on the same
    # line. Matching any line holding the word "passed" picked up a per-check line instead: the
    # sync suite reported `ok: #105 even though every check inside it passed` in the column where
    # its score belongs, which is a line about something else standing where the verdict goes
    # (L11). Every suite here writes its total differently, so the shapes are matched rather than
    # a single spelling demanded.
    summary="$(printf '%s\n' "$out" | grep -EI '[Pp][Aa][Ss][Ss][A-Za-z]*[^0-9]{0,4}[0-9]+|[0-9]+[^0-9]{0,4}[Pp][Aa][Ss][Ss]' \
                 | grep -EI '[Ff][Aa][Ii][Ll][A-Za-z]*[^0-9]{0,4}[0-9]+|[0-9]+[^0-9]{0,4}[Ff][Aa][Ii][Ll]' | tail -1)"
    # Trust the exit code, and fall back to the printed tally only when a suite
    # exits 0 while its own count says otherwise. Read from that same line.
    #
    # The count AFTER the word is tried first and the count before it only if
    # that finds nothing, because the two forms are not exclusive: read as one
    # alternation, `PASS=805 FAIL=0` matches "805 FAIL" and the whole suite is
    # reported as having 805 failures. Two suites here write "0 failed" and the
    # rest write "failed: 0", so both forms are needed and the order between them
    # is what makes them safe.
    tally="$(printf '%s' "$summary" | grep -Eio 'fail(ed|ure)?[^0-9A-Za-z]{0,3}[0-9]+' | tail -1 | grep -Eo '[0-9]+' || true)"
    if [ -z "$tally" ]; then
      tally="$(printf '%s' "$summary" | grep -Eio '[0-9]+ +fail(ed|ure)?' | tail -1 | grep -Eo '[0-9]+' || true)"
    fi
    if [ "$code" -ne 0 ] || { [ -n "$tally" ] && [ "$tally" -gt 0 ]; }; then
      failed=$((failed + 1))
      failed_names="$failed_names $name"
      printf '  FAIL  %-38s %s\n' "$name" "$summary"
      # And WHY. A one line verdict is enough on a machine where you can just run the suite
      # again; it is useless where you cannot, which is the whole point of running these
      # somewhere else (claude-config#101). The failing lines are printed, and the count is
      # said out loud when there are more than fit, so a truncated report cannot read as a
      # complete one.
      detail="$(printf '%s\n' "$out" | grep -E '^ *(FAIL|not ok)' || true)"
      [ -n "$detail" ] || detail="$(printf '%s\n' "$out" | tail -n "$FAIL_DETAIL_MAX")"
      shown="$(printf '%s\n' "$detail" | grep -c . || true)"
      printf '%s\n' "$detail" | head -n "$FAIL_DETAIL_MAX" | sed 's/^/          /'
      if [ "${shown:-0}" -gt "$FAIL_DETAIL_MAX" ]; then
        printf '          ...and %s more line(s) not shown\n' "$(( shown - FAIL_DETAIL_MAX ))"
      fi
    else
      printf '  ok    %-38s %s\n' "$name" "$summary"
    fi
  done
  # A directory that was named and held nothing is its own outcome. With several
  # directories in play, one of them going empty (renamed, moved, a path typed
  # wrong in CI) loses a whole block of coverage while every remaining suite still
  # reports green, which is the exact shape this file exists to refuse (L98).
  if [ "$here" -eq 0 ]; then
    empty_dirs="$empty_dirs  $d
"
  fi
done <<EOF
$dirs
EOF

echo
if [ -n "$empty_dirs" ]; then
  echo "NO TEST SUITES FOUND in these directories, so whatever lives in them was NOT verified:"
  printf '%s' "$empty_dirs"
fi
if [ "$ran" -eq 0 ]; then
  echo "NOTHING WAS RUN. Treat this as a failure."
  exit 1
fi
if [ "$failed" -eq 0 ] && [ -z "$empty_dirs" ]; then
  echo "ALL $ran SUITES PASSED"
  exit 0
fi
[ "$failed" -eq 0 ] || echo "$failed of $ran SUITES FAILED:$failed_names"
exit 1
