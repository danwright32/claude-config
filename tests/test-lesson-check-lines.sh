#!/usr/bin/env bash
# A lesson entry can name the check that holds it, or say why no check can (claude-config#3245).
#
# Before this, nothing recorded whether a machine enforced any of the 894 lessons or a session had to
# read a sentence and obey it (measured 2026-11-18 and again 2026-11-19: no entry carried a line
# naming its check). An entry may now carry ONE of two indented lines:
#
#   CHECK: <path>[, <path>...] (full)      or (partial)
#   NO CHECK: <why no check can hold it>
#
# A path is relative to the config root (hooks/x.sh), or owner/repo:path for a check that lives in
# another repository. This suite holds four things, each seen to fail before the change:
#   1. a malformed line is a fault that holds the lessons file back, like any other entry fault;
#   2. both well formed lines are accepted, and neither leaks into the generated index line;
#   3. `claude-sync lesson-checks` counts the whole library, lists named checks missing on disk and
#      the core lessons a check holds fully (candidates for Dan to take out of the core, one by one);
#   4. `lesson-checks --warnings` speaks only about entries written after the frozen baseline that
#      carry neither line, and about named checks that are not on disk, and is silent otherwise.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
. "$ROOT/payload/hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

SYNC="$ROOT/claude-sync"
pass=0
fail=0
check() { # check <description> <result>   ("ok" passes, anything else is the failure text)
  if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi
}
says() { # says <description> <text> <substring>
  case "$2" in *"$3"*) check "$1" ok ;; *) check "$1" "did not say '$3' (said: ${2:0:300})" ;; esac
}
never_says() { # never_says <description> <text> <substring>
  case "$2" in *"$3"*) check "$1" "said '$3' (said: ${2:0:300})" ;; *) check "$1" ok ;; esac
}
silent() { # silent <description> <text>
  if [ -z "$(printf '%s' "$2" | tr -d '[:space:]')" ]; then check "$1" ok; else check "$1" "it said: ${2:0:300}"; fi
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/test-lesson-check-lines.XXXXXXXX")" || WORK=""
case "${WORK%/}" in
  ''|/|"${HOME%/}") echo "refusing to run: throwaway directory came back as '$WORK'" >&2; exit 2 ;;
esac
trap 'rm -rf "$WORK"' EXIT

H="$WORK/claude"; mkdir -p "$H/hooks"
printf 'ENTRY_CAP=160\n' > "$H/hooks/test-rule-file-budget.sh"
printf '#!/bin/sh\n' > "$H/hooks/real-guard.sh"
printf '# rules\n@LESSONS-INDEX.md\n' > "$H/CLAUDE.md"
# The baseline: L1 to L4 existed before check lines did. L50 and above are new.
BASE="$WORK/baseline.txt"
printf '# frozen\n1\n2\n3\n4\n' > "$BASE"
printf '# core\n# count 3\nL1\nL2\nL50\n' > "$H/LESSONS-CORE.txt"

run() { # run <claude-sync args...>
  CLAUDE_HOME="$H" SYNC_NO_NOTIFY=1 SYNC_LESSON_CHECK_BASELINE="$BASE" bash "$SYNC" "$@" 2>&1
}
lessons() { printf '# Lessons\n\n## Proof over green\n\n%s\n' "$1" > "$H/LESSONS.md"; }

echo "lesson check lines: well formed lines are accepted"

lessons "- **L1. A rule a guard holds in full.** body
  (claude-config#1, 2026-01-01)
  CHECK: hooks/real-guard.sh (full)
  SHORT: A rule a guard holds in full.
- **L2. A rule a guard holds only in part.** body
  CHECK: hooks/real-guard.sh, danwright32/Ovation:scripts/lint.sh (partial)
- **L3. A rule nothing can check by machine.** body
  NO CHECK: it is a judgement about what a reader needs, and no tool can see the reader.
- **L4. An older rule carrying neither line.** body"
out="$(run lesson-faults)"; rc=$?
check "an entry with a CHECK line, one naming two checks, and one with a NO CHECK line all publish" "$([ "$rc" -eq 0 ] && echo ok || echo "exit $rc: ${out:0:300}")"
silent "and lesson-faults says nothing about them" "$out"

# The index renders the rule, never the check line, so the generated files and the budgets are
# unchanged by any check line (the entries render exactly as they did before).
# L1 carries its SHORT line AFTER its CHECK line, so the pairing must step over the check line to
# find it: the first check proves the pairing read the entry at all, which is what lets the second
# one fail (an empty reading would pass it).
idx="$(CLAUDE_HOME="$H" bash "$SYNC" lesson-short-forms "$H/LESSONS.md" 2>&1)"
says "a SHORT line after a CHECK line is still paired with its lesson" "$idx" "A rule a guard holds in full."
never_says "and the CHECK line is never read as a short form" "$idx" "real-guard"

echo "lesson check lines: a malformed line is refused like any other entry fault"

bad_case() { # bad_case <description> <entry text> <what the refusal must name>
  lessons "- **L1. A rule a guard holds in full.** body
$2"
  local o r
  o="$(run lesson-faults)"; r=$?
  check "$1: refused" "$([ "$r" -ne 0 ] && echo ok || echo "exit 0, said: ${o:0:200}")"
  says "$1: the refusal names the entry" "$o" "L1"
  says "$1: and says what it should be" "$o" "$3"
}
bad_case "a CHECK line with no full or partial" "  CHECK: hooks/real-guard.sh" "(full)"
bad_case "a CHECK line naming no path" "  CHECK: (full)" "(full)"
bad_case "a CHECK line with an absolute path" "  CHECK: /Users/x/.claude/hooks/real-guard.sh (full)" "relative"
bad_case "a NO CHECK line giving no reason" "  NO CHECK:" "NO CHECK: <why"
bad_case "a marker in the wrong case" "  Check: hooks/real-guard.sh (full)" "CHECK:"
bad_case "a marker spelled another way" "  Checked by: hooks/real-guard.sh (full)" "CHECK:"
bad_case "two check lines on one entry" "  CHECK: hooks/real-guard.sh (full)
  NO CHECK: it is a judgement no tool can see." "one"

# A check line inside the bold rule sentence would be joined into the rule the index renders.
lessons "- **L1. A rule that wraps
  CHECK: hooks/real-guard.sh (full)
  onto a third line.** body"
out="$(run lesson-faults)"; rc=$?
check "a check line inside the wrapped rule sentence is refused" "$([ "$rc" -ne 0 ] && echo ok || echo "exit 0")"
says "and the refusal says it is inside the rule" "$out" "inside the rule"

echo "lesson check lines: the count over the whole library"

lessons "- **L1. A rule a guard holds in full.** body
  CHECK: hooks/real-guard.sh (full)
- **L2. A rule a guard holds only in part.** body
  CHECK: hooks/real-guard.sh, danwright32/Ovation:scripts/lint.sh (partial)
- **L3. A rule nothing can check by machine.** body
  NO CHECK: it is a judgement about what a reader needs, and no tool can see the reader.
- **L4. An older rule carrying neither line.** body
- **L50. A newer rule naming a guard that is not there.** body
  CHECK: hooks/gone-guard.sh (full)
- **L51. A newer rule carrying neither line.** body"
out="$(run lesson-checks)"; rc=$?
check "the count runs" "$([ "$rc" -eq 0 ] && echo ok || echo "exit $rc: ${out:0:300}")"
says "it counts every entry" "$out" "6 lessons"
says "it counts the entries naming a check" "$out" "3 name the check that holds them (2 fully, 1 partly)"
says "it counts the entries no check can hold" "$out" "1 say no check can hold them"
says "it counts the entries with neither, and how many predate check lines" "$out" "2 carry neither line (1 written before check lines existed)"
says "it names a named check missing on disk" "$out" "L50 hooks/gone-guard.sh"
says "it lists a check in another repository as not looked for" "$out" "L2 danwright32/Ovation:scripts/lint.sh"
says "it lists the core lessons a present check holds fully" "$out" "Candidates to leave the core"
says "and L1 is one" "$out" "L1"
cand="${out#*Candidates to leave the core}"
cand="${cand%%$'\n'*}"
never_says "a core lesson whose named check is missing is no candidate" "$cand" "L50"
never_says "nor one held only in part" "$cand" "L2"
says "it names the new entry with neither line" "$out" "L51"

echo "lesson check lines: the warnings the write time check speaks"

out="$(run lesson-checks --warnings)"; rc=$?
check "the warnings run" "$([ "$rc" -eq 0 ] && echo ok || echo "exit $rc")"
says "a new entry with neither line is warned about" "$out" "L51"
says "with what to add" "$out" "NO CHECK:"
says "a named check missing on disk is warned about" "$out" "hooks/gone-guard.sh"
never_says "an entry that predates check lines is not" "$out" "L4 "
never_says "nor one carrying a well formed line" "$out" "L3 "

lessons "- **L1. A rule a guard holds in full.** body
  CHECK: hooks/real-guard.sh (full)
- **L4. An older rule carrying neither line.** body"
out="$(run lesson-checks --warnings)"
silent "a library with nothing to warn about is not spoken about" "$out"

# The baseline is read, never assumed: with it unreadable, nothing can tell old from new, and that
# is said rather than every entry being called new or none (L11).
out="$(CLAUDE_HOME="$H" SYNC_LESSON_CHECK_BASELINE="$WORK/missing.txt" bash "$SYNC" lesson-checks --warnings 2>&1)"
says "an unreadable baseline is said" "$out" "missing.txt"

echo "lesson check lines: the real library"

# The count runs over the real library with the real baseline beside the tool. Its figures move
# as lessons are written, so only that it runs and reads every entry is held here.
out="$(CLAUDE_HOME="$ROOT/payload" SYNC_NO_NOTIFY=1 bash "$SYNC" lesson-checks 2>&1)"; rc=$?
check "the count runs over the real library" "$([ "$rc" -eq 0 ] && echo ok || echo "exit $rc: ${out:0:300}")"
real_n="$(grep -c '^- \*\*L[0-9][0-9]*\.' "$ROOT/payload/LESSONS.md")"
says "and counts every one of its entries" "$out" "$real_n lessons"

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
