#!/usr/bin/env bash
# The checks of test-run-all-tests.sh that read THIS repository's own files rather than a fixture
# tree it builds (claude-config#1997).
# send-gate: scans hooks/ skills/ mods/
#
# The line above is what has a claude-sync send run this suite (README "send-gate", #809): it reads
# every test-*.sh and *_tests.py in the repository and the runner beside it, and under payload/ those
# live in hooks/, skills/ and mods/. Without it a send never ran these scans (claude-config#2020).
#
# The scanners gate before a push runs, whole, every suite that lists the repository's files, on
# the premise that running a whole suite costs a few seconds. test-run-all-tests.sh lists them for
# the checks below, so it qualified, and it is the slowest suite there is: it starts the runner on
# dozens of fixture trees. The gate recorded 510 seconds for it, and 457 and 673 in two runs on
# 2026-10-31, against its budget of 150, so every push in this repository was refused once and
# waited for it. Every other check in that suite builds a tree of its own, so nothing a change adds
# elsewhere in the repository can turn it red, and it has no business in the gate's path.
#
# So the checks that DO read the repository live here, in a suite the gate selects by the same
# rule as any other scanner, and they still run before every push. They are three:
#
#   1. the runner, asked only which directories of the real repository it would read;
#   2. every suite in the repository read for a print of an unmeasured part in a shape the runner
#      does not read (#1444);
#   3. every suite in the repository read for a check that declares itself unmeasured and counts
#      as a pass (#1452).
#
# The two source scans are tested against fixtures here too, beside the scan of the real tree, so
# the scan and its proof stay in one file (L1). The runner's own handling of those prints, which
# needs fixture runs, stays in test-run-all-tests.sh.
#
# Do not add a check here that builds fixture trees and runs the runner on them: that is the cost
# this file was split out to keep off every push. And do not add one that lists the repository to
# test-run-all-tests.sh, which would make the gate run that whole suite again;
# test-scanners-before-push.sh fails if it does.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="$DIR/run-all-tests.sh"

# Its own wall clock, however it was started (claude-config#444, #465).
. "$DIR/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

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

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/run-all-tests-real-tree.XXXXXXXX")" || TMPROOT=""
case "${TMPROOT%/}" in
  ''|/|"${HOME%/}") echo "test-run-all-tests-real-tree: refusing to run: throwaway directory came back as '$TMPROOT'." >&2; exit 2 ;;
esac
trap 'rm -rf "$TMPROOT"' EXIT

# The runner's agreed line for a part that was not measured, and the word it judges, each assembled
# from pieces so this file's own source holds neither in a shape the scans below would flag.
PART_MARK="SUITE""-PART-UNMEASURED"
STRAY_WORD="UNMEAS""URED"

# ---------------------------------------------------------------------------
# 1. The real repo this file lives in. test-run-all-tests.sh watches the runner fail six ways on
# fixtures before anyone relies on this answer. It is asked only WHICH directories it would read,
# never run, because running it from here would run this suite from inside itself.
# ---------------------------------------------------------------------------
REAL="$(git -C "$DIR" rev-parse --show-toplevel 2>/dev/null || true)"
if [ -n "$REAL" ]; then
  out_list="$(HOOK_TESTS_LIST_ONLY=1 bash "$RUNNER" 2>/dev/null)"
  for d in payload/hooks tests tools payload/skills/milestone; do
    # An anchored whole-line match against the absolute path, not a substring search. `tests`
    # appears inside the runner's own name, so a substring check is answered by the refusal
    # message ABOUT the runner just as readily as by a directory it listed, and it passed that
    # way while its three neighbours failed (L156).
    grep -qx "$REAL/$d" <<< "$out_list" \
      && check "the real repo's $d is one of the directories it would read" ok \
      || check "the real repo's $d is one of the directories it would read" "out=$out_list"
  done
  # And it must be listing, not refusing. A refusal prints nothing on stdout, which every check
  # above would report as a missing directory rather than as the runner declining to answer.
  [ "$(printf '%s\n' "$out_list" | grep -c .)" -ge 4 ] \
    && check "the listing answered rather than refusing" ok \
    || check "the listing answered rather than refusing" "it printed $(printf '%s\n' "$out_list" | grep -c .) line(s)"
else
  # No repository above this file, which is what a deployed copy under the config directory looks
  # like. The four checks above cannot be asked here, and this branch used to REFUSE, which is one
  # of the three failures that made the documented command report red on a tree where nothing was
  # wrong (claude-config#155). What is true here is asserted instead, so the branch still checks
  # something rather than only explaining why it cannot (L98).
  out_list="$(HOOK_TESTS_LIST_ONLY=1 bash "$RUNNER" 2>/dev/null)"
  n_list="$(printf '%s\n' "$out_list" | grep -c . || true)"
  [ "${n_list:-0}" = 1 ] && [ "$out_list" = "$DIR" ] \
    && check "with no repo above it, the runner reads only its own directory" ok \
    || check "with no repo above it, the runner reads only its own directory" "it would read: $out_list"
fi

# ---------------------------------------------------------------------------
# 2. THE GUARD, in the source (#1444): a branch that never runs on this machine (as root, on Linux,
# with no zsh) prints nothing there, so the run time guard in test-run-all-tests.sh cannot see it.
# So every suite in the repository is also read for a print whose text starts with the word, or a
# note carrying it, in a shell suite or a python one. Found from the files the repository holds,
# through lib/repo-files.sh, never from a list (L96), so a suite not yet committed is read too
# (claude-config#522).
stray_unmeasured_prints(){   # stray_unmeasured_prints <file>.. -> file:line for each such print
  grep -n -E "(echo|printf)[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*[\"'](\\\\n|[[:space:]])*((SUITE-NOTE|note:)[^\"']*)?${STRAY_WORD}([^A-Za-z]|\$)|print\\([[:space:]]*[fr]?[\"'][[:space:]]*((SUITE-NOTE|note:)[^\"']*)?${STRAY_WORD}([^A-Za-z]|\$)|(echo|printf|print\\()[[:space:]]*[fr]?[\"'][[:space:]]+${PART_MARK}" "$@" 2>/dev/null || true
}
PUF="$TMPROOT/dir-part-source"; mkdir -p "$PUF"
printf 'echo "%s: no zsh here, so its reading was not measured"\n' "$STRAY_WORD" > "$PUF/test-a.sh"
printf '    print("%s: no Chrome at %%s" %% X)\n' "$STRAY_WORD" > "$PUF/b_tests.py"
printf 'echo "note: this copy is reported %s rather than passed."\n' "$STRAY_WORD" > "$PUF/test-c.sh"
printf 'printf %s\\n "the parts"\ncheck "it is said as %s" ok\n' "'$PART_MARK %s'" "$STRAY_WORD" > "$PUF/test-d.sh"
printf '  echo "  %s indented, so it is not read"\n' "$PART_MARK" > "$PUF/test-e.sh"
pu_found="$(stray_unmeasured_prints "$PUF/test-a.sh" "$PUF/b_tests.py" "$PUF/test-c.sh" "$PUF/test-d.sh" "$PUF/test-e.sh")"
case "$pu_found" in
  *test-a.sh:1:*b_tests.py:1:*test-c.sh:1:*test-e.sh:1:*) case "$pu_found" in *test-d.sh*) check "#1444 the source scan finds each stray print and nothing else" "it flagged the agreed line: $pu_found" ;; *) check "#1444 the source scan finds each stray print and nothing else" ok ;; esac ;;
  *) check "#1444 the source scan finds each stray print and nothing else" "found: $pu_found" ;;
esac
pu_root="$(git -C "$DIR" rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$pu_root" ] && [ -f "$pu_root/payload/hooks/run-all-tests.sh" ] || pu_root="${RUN_ALL_TESTS_CHECKOUT:-}"
if [ -n "$pu_root" ] && [ -f "$pu_root/payload/hooks/run-all-tests.sh" ]; then
  pu_files=()
  # Read into a variable first, never through process substitution, whose child bash 3.2 never waits
  # for and whose exit can cut short what this suite prints next (L1035, #1989).
  pu_list="$(bash "$DIR/lib/repo-files.sh" "$pu_root" | grep -E '(^|/)(test-[^/]*\.sh|[^/]*_tests\.py)$')"
  while IFS= read -r pu_f; do [ -n "$pu_f" ] && pu_files+=("$pu_root/$pu_f"); done <<PU_LIST
$pu_list
PU_LIST
  if [ "${#pu_files[@]}" -lt 50 ]; then
    check "#1444 the source scan read the repository's suites" "it found only ${#pu_files[@]} suite files in $pu_root, so it read almost nothing"
  else
    pu_stray="$(stray_unmeasured_prints "${pu_files[@]}")"
    [ -z "$pu_stray" ] \
      && check "#1444 no suite in the repository prints an unmeasured part in a shape the runner does not read" ok \
      || check "#1444 no suite in the repository prints an unmeasured part in a shape the runner does not read" "print each as $PART_MARK <what, and why> instead: $(printf '%s\n' "$pu_stray" | sed "s|^$pu_root/||" | cut -c1-200 | tr '\n' ';')"
  fi
else
  printf '%s %s\n' "$PART_MARK" "the source scan for unmeasured parts the runner cannot read, because this copy is not in a checkout and none was handed in RUN_ALL_TESTS_CHECKOUT"
fi

# ---------------------------------------------------------------------------
# 3. A CHECK THAT DECLARES ITSELF UNMEASURED AND COUNTS AS A PASS (claude-config#1452).
#
# After #1444 three suites printed the agreed line and then went on to `check "<the part> could not
# be measured here" ok`, so the part that never ran was ALSO counted among the passes, and the
# runner's "26 passed" included checks that measured nothing (L98). One more had no agreed line at
# all, only the check, so the word lived inside a check's name and nothing read it: the runner sees
# a check's name only when it fails, and the scan above reads prints, not checks.
#
# The rule, decided precisely so it can be tested from both sides: a check is a DECLARED pass when
# it is a statement of its own (`check "<name>" ok` alone on its line, or straight after then, else,
# do or {, in python `check("<name>", True)`), so nothing was tested to reach it. It is not one when
# it continues a test (the line before ends in a backslash, && or ||, or it follows one on its line),
# ends a case arm (;;), or computes its result. A declared pass whose NAME says the thing was not
# measured (the word, in any case, or "could not / cannot / was not ... measured") is the defect:
# say it once with the agreed line and count nothing. A name that MENTIONS the word on a check that
# tests something (a suite asserting another tool reports unmeasured) is a check like any other.
# The two quote characters are handed in as variables and the patterns built from them, and the
# opening brace is written as its octal escape, so the program text holds no unpaired quote or
# brace: either one unbalances the shell readers of this file, scan-subshell-globals.py among them,
# which counts braces to find where a function ends.
declared_unmeasured_passes(){   # declared_unmeasured_passes <file>.. -> file:line for each
  awk -v dq=$'\x22' -v sq=$'\x27' '
    BEGIN {
      quoted = "(" dq "[^" dq "]*" dq "|" sq "[^" sq "]*" sq ")"
      shell_pass = "^[[:space:]]*((then|else|do|[\173])[[:space:]]+)?check[[:space:]]+" quoted "[[:space:]]+ok[[:space:]]*;?[[:space:]]*$"
      py_pass = "^[[:space:]]*check[(][[:space:]]*" quoted "[[:space:]]*,[[:space:]]*True[[:space:]]*[)][[:space:]]*$"
      opening = "^[^" dq sq "]*[" dq sq "]"; closing = "[" dq sq "].*$"
    }
    FNR == 1 { prev = "" }
    {
      line = $0
      if (prev !~ /([\\]|&&|[|][|])[[:space:]]*$/ && line !~ /;;[[:space:]]*$/ && (line ~ shell_pass || line ~ py_pass)) {
        name = line
        sub(opening, "", name); sub(closing, "", name)
        if (tolower(name) ~ /unmeasured|(could not|cannot|can.t|was not|were not|not) (be )?measured/) print FILENAME ":" FNR ":" line
      }
      prev = line
    }
  ' "$@" 2>/dev/null || true
}
DPF="$TMPROOT/dir-declared-pass"; mkdir -p "$DPF"
# The defect, four ways: the old phrasing, the word only inside the check's name, the check alone in
# an else branch on the line after it, and python.
printf 'check "the real tree could not be measured from this copy" ok\n' > "$DPF/test-dp1.sh"
printf '  check "the keyboard wiring is %s here" ok\n' "$STRAY_WORD" > "$DPF/test-dp2.sh"
printf 'else\n  check "the apostrophe case could not be measured on this bash" ok\nfi\n' > "$DPF/test-dp3.sh"
printf 'check("the frames were not measured in a browser", True)\n' > "$DPF/dp4_tests.py"
# Ordinary checks that mention the word: each tests something, so none is flagged.
printf '[ "$c" -eq 3 ] && check "no claude means exit 3, %s" ok\n' "$STRAY_WORD" > "$DPF/test-dn1.sh"
printf 'grep -q x f \\\n  && check "and it says %s rather than a pass" ok \\\n  || check "and it says %s rather than a pass" "$out"\n' "$STRAY_WORD" "$STRAY_WORD" > "$DPF/test-dn2.sh"
printf 'case "$o" in\n  *x*)\n    check "an unreadable record is counted as %s" ok ;;\nesac\n' "$STRAY_WORD" > "$DPF/test-dn3.sh"
printf 'check "a thin window is %s, not a pass" "%s" "$out"\n' "$STRAY_WORD" "$STRAY_WORD" > "$DPF/test-dn4.sh"
printf 'check "every mod passes its checks" ok\n' > "$DPF/test-dn5.sh"
printf 'check("its picture half is said to be %s", "x" in out, out)\n' "$STRAY_WORD" > "$DPF/dn6_tests.py"
dp_found="$(cd "$DPF" && declared_unmeasured_passes test-dp1.sh test-dp2.sh test-dp3.sh dp4_tests.py test-dn1.sh test-dn2.sh test-dn3.sh test-dn4.sh test-dn5.sh dn6_tests.py | cut -d: -f1,2 | tr '\n' ' ')"
[ "$dp_found" = "test-dp1.sh:1 test-dp2.sh:1 test-dp3.sh:2 dp4_tests.py:1 " ] \
  && check "#1452 a check declaring itself unmeasured is found four ways, and checks that test an unmeasured report are not" ok \
  || check "#1452 a check declaring itself unmeasured is found four ways, and checks that test an unmeasured report are not" "found: $dp_found"
if [ -n "$pu_root" ] && [ -f "$pu_root/payload/hooks/run-all-tests.sh" ] && [ "${#pu_files[@]}" -ge 50 ]; then
  dp_stray="$(declared_unmeasured_passes "${pu_files[@]}")"
  [ -z "$dp_stray" ] \
    && check "#1452 no suite in the repository counts a part it could not measure as a passing check" ok \
    || check "#1452 no suite in the repository counts a part it could not measure as a passing check" "print $PART_MARK <what, and why> and count nothing: $(printf '%s\n' "$dp_stray" | sed "s|^$pu_root/||" | cut -c1-200 | tr '\n' ';')"
else
  printf '%s %s\n' "$PART_MARK" "the source scan for checks that declare themselves unmeasured, because this copy is not in a checkout and none was handed in RUN_ALL_TESTS_CHECKOUT"
fi

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
