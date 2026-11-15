#!/usr/bin/env bash
# A whole tree scan: a send touching these paths runs this suite (claude-config#809).
# send-gate: scans hooks/ skills/ mods/
# No suite writes what it found at the margin under its FAIL line (claude-config#2916).
#
# Until #2928 the runner printed a failing suite's FAIL line and only the lines indented further
# than it (claude-config#253), so a finding written at the margin was dropped from a full run's
# report. #2854 found this in test-lib-bytecode-importers.sh and #2916 in 22 more suites on
# 2026-11-13, each now indenting what its FAIL helper prints after the first line. Since #2928 the
# runner also keeps margin lines up to the next result line, which it has to infer; a message
# indented by hand needs no inference. Kept by Dan's decision on 2026-11-14 (PR #2985), so this
# still fails the next margin message on the day it lands (L613), with no list of suites excused.
# lib/fail-margin.py says what it reads and what it cannot.
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCAN="$DIR/lib/fail-margin.py"
# The checkout this copy is the payload of, found by the one shared test (lib/checkout-root.sh,
# claude-config#1567): a repository above that is not this one is no checkout.
ROOT="${FAIL_MARGIN_ROOT:-$(bash "$DIR/lib/checkout-root.sh" "$DIR/.." 2>/dev/null || true)}"

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)" | sed '2,$s/^/  /'; fi; }

if [ -z "$ROOT" ] || [ ! -d "$ROOT" ]; then
  echo "test-fail-margin: $DIR/.. is not the payload of a claude-config checkout, so there were no files of this repository to read." >&2
  printf 'SUITE-NOT-RUN %s\n' "needs the repository to read its files, and $DIR/.. is not the payload of a claude-config checkout"
  exit 2
fi

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/fail-margin.XXXXXXXX")" || TMPROOT=""
case "${TMPROOT%/}" in
  ''|/|"${HOME%/}") echo "test-fail-margin: refusing to run: throwaway directory came back as '$TMPROOT'." >&2; exit 2 ;;
esac
trap 'rm -rf "$TMPROOT"' EXIT

# ---------------------------------------------------------------------------
# The runner, measured rather than taken from its comment (L721). Until #2928 a full run dropped a
# FAIL message's lines at the margin, which is what this scan was written against. Since #2928 the
# runner keeps them up to the next result line and sets them under their FAIL, at the same column
# as a message indented by hand. Both halves are measured here: if the runner stops showing the
# margin lines, or shows them anywhere but under their FAIL, the two no longer agree and this says
# so. The same suite is then handed to the scan, which must still name the margin message and not
# the indented one: indenting by hand is the shape #253's rule reads without inferring anything.
# ---------------------------------------------------------------------------
mkdir -p "$TMPROOT/runner"
cat > "$TMPROOT/runner/test-planted.sh" <<'PLANTED'
#!/usr/bin/env bash
pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }
margin="$(printf 'margin-one.sh:3\nmargin-two.sh:4')"
kept="$(printf 'kept-one.sh:3\nkept-two.sh:4')"
check "a list written at the margin" "these do:
$margin"
check "a list indented line by line" "these do:
$(printf '%s\n' "$kept" | sed 's/^/  /')"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
exit 1
PLANTED
shown="$(HOOK_TESTS_TIMINGS= HOOK_TESTS_FLAKY_OUTPUT= HOOK_TESTS_FLAKE_RECHECK=0 HOOK_TESTS_SLOT=0 bash "$DIR/run-all-tests.sh" "$TMPROOT/runner" 2>&1)"
shown_as="a full run showed:
$(printf '%s\n' "$shown" | sed 's/^/    /')"
case "$shown" in
  *"a list written at the margin"*) check "the runner was handed the planted suite's failure" ok ;;
  *) check "the runner was handed the planted suite's failure" "$shown_as" ;;
esac
case "$shown" in
  *margin-one.sh*margin-two.sh*) check "a full run shows every line of a finding written at the margin under its FAIL (#2928)" ok ;;
  *) check "a full run shows every line of a finding written at the margin under its FAIL (#2928)" "it did not, so the runner has gone back to dropping them: $shown_as" ;;
esac
case "$shown" in
  *kept-one.sh*kept-two.sh*) check "and shows every line of one indented under it" ok ;;
  *) check "and shows every line of one indented under it" "$shown_as" ;;
esac
# The column each line starts at in the report, or nothing when it is not there.
shown_col() { printf '%s\n' "$shown" | grep -F "$1" | sed -n '1s/[^ ].*//p' | awk '{ print length($0) }'; }
fail_at="$(shown_col 'FAIL: a list written at the margin')"
margin_at="$(shown_col 'margin-two.sh')"
kept_at="$(shown_col 'kept-two.sh')"
[ -n "$fail_at" ] && [ -n "$margin_at" ] && [ "$margin_at" -gt "$fail_at" ] && [ "$margin_at" = "${kept_at:-}" ] \
  && check "and sets the margin finding under its FAIL, at the column of one indented by hand (#2928)" ok \
  || check "and sets the margin finding under its FAIL, at the column of one indented by hand (#2928)" "FAIL at column ${fail_at:-none}, margin finding at ${margin_at:-none}, indented finding at ${kept_at:-none}: $shown_as"
planted="$(printf 'test-planted.sh\n' | python3 "$SCAN" --root "$TMPROOT/runner")"; planted_rc=$?
planted_lines="$(printf '%s\n' "$planted" | awk -F: 'NF { printf "%s ", $2 }')"
[ "$planted_rc" = 1 ] && [ "$planted_lines" = "8 " ] \
  && check "the scan names the message written at the margin, and not the one indented by hand" ok \
  || check "the scan names the message written at the margin, and not the one indented by hand" "exit $planted_rc, lines '$planted_lines' where 8 was wanted:
$planted"

# ---------------------------------------------------------------------------
# Every shape the scan looks for, and what it must leave alone, before the tree is asked (L1).
# Written through a quoted heredoc, whose body the scan never judges, so this file holds none of
# them itself. TAB stands for a tab, which the runner does not count as indentation.
# ---------------------------------------------------------------------------
mkdir -p "$TMPROOT/payload/hooks"
cat > "$TMPROOT/probe.txt" <<'PROBE'
#!/usr/bin/env bash
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }
bad() { echo "FAIL: $1"; }
check_eq() { if [ "$2" = "$3" ]; then check "$1" ok; else check "$1" "wanted '$2', got '$3'"; fi; }
check "a list at the margin" "these do:
$found"
bad "a sentence at the margin:
see the log"
check "a list on a line of its own" "these do:
  $found"
echo "FAIL: written straight out:
$hits"
check_eq "an expected value of two lines" "one
two" "$out"
check_eq "a list in the word of a parameter" "0" "$rc${found:+
$found}"
check "a blank line" "these:

  more"
bad "a tab:
TABsee the log"
echo "  FAIL: an indented FAIL line
  under it at the same depth"
raw="$(cmd)"
check "a list the source cannot vouch for" "these do:
$raw  Fix them."
check "indented by sed" "these do:
$(printf '%s\n' "$found" | sed 's/^/  /')"
check "an indented sentence" "these do:
  see the log"
check "a third argument is not printed" ok "line one
line two"
run_it "a command that prints no FAIL" "gh pr comment --body \"one
two\""
cat > f <<EOF
echo "FAIL: in a heredoc
$found"
EOF
# check "in a comment" "these:
listed=""
listed="$listed  $rel
"
check "a list built indented" "these do:
$listed  Fix them."
indenting() { echo "FAIL: $1" | sed '2,$s/^/  /'; }
indenting "a helper that indents what it prints:
$found"
handing_on() { indenting "$1"; }
handing_on "a helper handing everything to one that indents:
$found"
PROBE
sed "s/TAB/$(printf '\t')/" "$TMPROOT/probe.txt" > "$TMPROOT/payload/hooks/test-probe.sh"
# The same text in a file that is not a suite is not judged.
cp "$TMPROOT/payload/hooks/test-probe.sh" "$TMPROOT/payload/hooks/probe-helper.sh"
probe="$(printf 'payload/hooks/test-probe.sh\npayload/hooks/probe-helper.sh\n' | python3 "$SCAN" --root "$TMPROOT")"; probe_rc=$?
probe_lines="$(printf '%s\n' "$probe" | awk -F: 'NF { printf "%s ", $2 }')"
want="6 8 10 12 14 16 18 21 23 26 "
[ "$probe_rc" = 1 ] && [ "$probe_lines" = "$want" ] \
  && check "the scan sees every shape of a FAIL message going on at the margin, and none of what is not one" ok \
  || check "the scan sees every shape of a FAIL message going on at the margin, and none of what is not one" "exit $probe_rc, lines '$probe_lines' where $want were wanted:
$probe"
# Each finding says which kind it is, so the next author knows what to change.
case "$probe" in
  *":6: a FAIL message goes on at the margin"*":10: a value expanded on a line of its own"*":18: a blank line"*) check "and each finding names its kind" ok ;;
  *) check "and each finding names its kind" "it said: $probe" ;;
esac
clean="$(printf 'payload/hooks/probe-helper.sh\n' | python3 "$SCAN" --root "$TMPROOT")"; clean_rc=$?
[ "$clean_rc" = 0 ] && [ -z "$clean" ] \
  && check "and finding nothing, it says nothing and exits 0" ok \
  || check "and finding nothing, it says nothing and exits 0" "exit $clean_rc: $clean"
# A suite it was told to read and could not is said, never passed over as clean (L98).
gone="$(printf 'payload/hooks/test-gone.sh\n' | python3 "$SCAN" --root "$TMPROOT" 2>&1)"; gone_rc=$?
[ "$gone_rc" = 1 ] && case "$gone" in *"could not read payload/hooks/test-gone.sh"*) true ;; *) false ;; esac \
  && check "a suite it could not read fails the scan, named" ok \
  || check "a suite it could not read fails the scan, named" "exit $gone_rc: $gone"

# ---------------------------------------------------------------------------
# The real tree: none at all, anywhere.
# ---------------------------------------------------------------------------
FILES="$(bash "$DIR/lib/repo-files.sh" "$ROOT" 2>/dev/null || true)"
# A listing that came back short read the wrong tree, and the check below would pass over it (L98):
# 313 suites on 2026-11-13.
suites_n="$(printf '%s\n' "$FILES" | grep -c -E '(^|/)test-[^/]*\.sh$')"
[ "$suites_n" -ge 200 ] \
  && check "the suites to judge were listed" ok \
  || check "the suites to judge were listed" "lib/repo-files.sh gave $suites_n suites for $ROOT, where 313 were listed on 2026-11-13, so the tree below was not the repository's"
found="$(printf '%s\n' "$FILES" | python3 "$SCAN" --root "$ROOT" 2>&1)"; found_rc=$?
[ "$found_rc" = 0 ] && [ -z "$found" ] \
  && check "no suite writes what it found at the margin under its FAIL line" ok \
  || check "no suite writes what it found at the margin under its FAIL line" "exit $found_rc; these go on at the margin from that line on, which a full run has to infer is part of the message:
$found
Indent each line after the first: pipe the FAIL helper's echo through sed '2,\$s/^/  /', or put a
list in the message as \$(printf '%s\n' \"\$found\" | sed 's/^/  /')."

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
