#!/usr/bin/env bash
# Tests for rank-next-issues.py, the ranking /next-issue offers its picker from (claude-config#1505).
#
# The ranking used to live only in the skill's prose, and nothing in it ever brought structural work
# forward: tech-debt issues sat at p2 and p3 behind a steady stream of new p2 work and were never
# offered. The script makes the structural slot something the ranking DOES rather than something a
# reader is asked to remember (L27), so these tests hold the slot to its rules: it takes the last
# pick for the highest ranked open tech-debt issue, never displaces a p0, a p1 or a lesson sweep,
# never adds a second structural pick, and falls back to the plain ranking when there is none.
#
# Pure: every case pipes a fixture list into the script, so nothing reaches GitHub.
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RANK="$DIR/rank-next-issues.py"
RULES="$DIR/../../mods/area-check/hooks/rules.ts"

pass=0; fail=0
check(){ if [ "$2" = ok ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }
same(){ # same <description> <expected> <actual>
  if [ "$2" = "$3" ]; then check "$1" ok; else check "$1" "expected [$2], got [$3]"; fi
}
has(){ # has <description> <substring> <text>
  case "$3" in *"$2"*) check "$1" ok ;; *) check "$1" "no [$2] in [$3]" ;; esac
}
lacks(){ # lacks <description> <substring> <text>
  case "$3" in *"$2"*) check "$1" "unexpected [$2] in [$3]" ;; *) check "$1" ok ;; esac
}

# One issue as gh prints it: issue <number> <milestone or empty> <label>...
issue(){
  local n="$1" ms="$2"; shift 2
  local labels="" l
  for l in "$@"; do labels="$labels${labels:+,}{\"name\":\"$l\"}"; done
  local m=null
  [ -n "$ms" ] && m="{\"title\":\"$ms\"}"
  printf '{"number":%s,"title":"Issue %s","labels":[%s],"milestone":%s}' "$n" "$n" "$labels" "$m"
}
list(){ local IFS=,; printf '[%s]' "$*"; }
rank(){ printf '%s' "$1" | python3 "$RANK" "${@:2}" 2>&1; }
picks(){ printf '%s\n' "$1" | grep '^PICK ' | awk '{print $3}' | tr '\n' ' ' | sed 's/ $//'; }

# The shape measured on the issue: new p1 and p2 work keeps arriving, and the tech-debt sits at p3.
# Before the slot the three picks were #10 #11 #12 and the tech-debt issue #20 never reached them.
backlog="$(list "$(issue 12 '' enhancement priority-p2)" "$(issue 20 '' tech-debt priority-p3)" \
  "$(issue 11 '' enhancement user-facing priority-p2)" "$(issue 10 '' bug priority-p1)" \
  "$(issue 13 '' enhancement priority-p2)")"
out="$(rank "$backlog")"; code=$?
same "a backlog ranks without error" 0 "$code"
same "the highest ranked tech-debt issue takes the last pick when none of the picks is structural" \
  "#10 #11 #20" "$(picks "$out")"
has "the slot pick says it is the structural slot" "structural slot" "$(printf '%s\n' "$out" | grep '^PICK 3 ')"
has "the slot line names the issue it brought forward" "SLOT filled #20" "$out"

# A refactor label counts the same as tech-debt, matched whole and in any case.
out="$(rank "$(list "$(issue 10 '' bug priority-p1)" "$(issue 11 '' priority-p2 enhancement)" \
  "$(issue 12 '' priority-p2 enhancement)" "$(issue 30 '' Refactor priority-p4)" "$(issue 31 '' tech-debt-ish priority-p2)")")"
same "a refactor label, in any case, fills the slot; a near spelling does not" "#10 #11 #30" "$(picks "$out")"

# Among several structural issues, the slot takes the one the plain ranking puts highest.
out="$(rank "$(list "$(issue 10 '' priority-p1 bug)" "$(issue 11 '' priority-p2 enhancement)" \
  "$(issue 12 '' priority-p2 enhancement)" "$(issue 40 '' tech-debt priority-p4)" \
  "$(issue 41 '' tech-debt priority-p3)" "$(issue 42 '' tech-debt priority-p3 user-facing)")")"
same "the slot takes the highest ranked structural issue, priority then user-facing" "#10 #11 #42" "$(picks "$out")"

# No structural issue open: the plain ranking stands and nothing breaks.
out="$(rank "$(list "$(issue 12 '' enhancement priority-p2)" "$(issue 11 '' enhancement priority-p2)" \
  "$(issue 10 '' bug priority-p1)" "$(issue 13 '' enhancement priority-p2)")")"; code=$?
same "with no tech-debt issue open the ranking still succeeds" 0 "$code"
same "with no tech-debt issue open the plain top three are offered" "#10 #11 #12" "$(picks "$out")"
has "with no tech-debt issue open the slot says so" "SLOT none" "$out"
lacks "with no tech-debt issue open no pick claims the slot" "structural slot" "$(printf '%s\n' "$out" | grep '^PICK ')"

# A structural issue already among the picks: no second one is added.
out="$(rank "$(list "$(issue 10 '' bug priority-p1)" "$(issue 11 '' tech-debt priority-p1)" \
  "$(issue 12 '' enhancement priority-p2)" "$(issue 20 '' tech-debt priority-p3)")")"
same "a tech-debt issue already in the top picks keeps its place and no second is added" "#10 #11 #12" "$(picks "$out")"
has "the slot line says which pick already covers it" "SLOT already #11" "$out"

# Priority stays the primary rule: the slot never displaces a p0, a p1 or a lesson sweep.
out="$(rank "$(list "$(issue 1 '' priority-p0 bug)" "$(issue 2 '' priority-p1 enhancement)" \
  "$(issue 3 '' priority-p1 enhancement)" "$(issue 4 '' priority-p1 enhancement)" "$(issue 20 '' tech-debt priority-p2)")")"
same "with a p0 and p1s filling the picks the tech-debt issue does not displace one" "#1 #2 #3" "$(picks "$out")"
has "the slot line says it was held back" "SLOT held" "$out"
out="$(rank "$(list "$(issue 4 '' priority-p2 enhancement)" "$(issue 9 'Ungrouped' priority-p2 lesson-sweep)" \
  "$(issue 7 'Ungrouped' priority-p2 lesson-sweep)" "$(issue 8 'Ungrouped' priority-p2 lesson-sweep)" \
  "$(issue 20 '' tech-debt priority-p3)")")"
same "a lesson sweep in the last pick is never displaced by the slot" "#7 #8 #9" "$(picks "$out")"
has "a slot held back by lesson sweeps says so" "SLOT held" "$out"

# The slot may displace a p2 for a lower priority structural issue: that is what it is for.
out="$(rank "$(list "$(issue 2 '' priority-p1 enhancement)" "$(issue 3 '' priority-p1 enhancement)" \
  "$(issue 4 '' priority-p2 enhancement)" "$(issue 20 '' tech-debt priority-p4)")")"
same "a p4 tech-debt issue displaces a p2 in the last pick" "#2 #3 #20" "$(picks "$out")"

# The plain ranking the slot works from.
out="$(rank "$(list "$(issue 5 '' priority-p1 enhancement)" "$(issue 9 'Ungrouped' priority-p2 lesson-sweep)" \
  "$(issue 8 'Ungrouped' priority-p2 lesson-sweep)" "$(issue 1 '' priority-p0 bug)")")"
same "p0 first, then lesson sweeps oldest first, then p1" "#1 #8 #9" "$(picks "$out")"
out="$(rank "$(list "$(issue 5 '' priority-p2 enhancement)" "$(issue 6 '' priority-p2 bug)" \
  "$(issue 7 'Saved views' priority-p2 enhancement)" "$(issue 8 '' priority-p2 enhancement user-facing)")" --milestone 'Saved views')"
same "within a level: user-facing, then the milestone just shipped, then bugs, then oldest" "#8 #7 #6" "$(picks "$out")"
out="$(rank "$(list "$(issue 5 '' priority-p3 enhancement)" "$(issue 6 '' priority-p2 enhancement)" "$(issue 4 '' priority-p4 enhancement)")")"
same "a lower level never outranks a higher one" "#6 #5 #4" "$(picks "$out")"
lacks "picks including a p2 are not called low" "LOW" "$out"
out="$(rank "$(list "$(issue 6 '' priority-p3 enhancement)" "$(issue 5 '' priority-p3 enhancement)" "$(issue 4 '' priority-p4 enhancement)")")"
same "within p3, oldest first, and p4 last" "#5 #6 #4" "$(picks "$out")"
has "picks of p3 and below are said plainly" "LOW" "$out"

# An issue with no priority label is named so it gets one, and ranks at the p2 default meanwhile.
out="$(rank "$(list "$(issue 5 '' priority-p3 enhancement)" "$(issue 6 '' enhancement)" "$(issue 7 '' priority-p1 bug)")")"
same "an unlabelled issue ranks at p2 until it is labelled" "#7 #6 #5" "$(picks "$out")"
has "an unlabelled issue is named" "UNLABELLED #6" "$out"

# Fewer issues than picks, and none at all.
out="$(rank "$(list "$(issue 5 '' priority-p2 enhancement)" "$(issue 6 '' priority-p3 tech-debt)")")"
same "fewer issues than picks offers them all once" "#5 #6" "$(picks "$out")"
out="$(rank '[]')"; code=$?
same "no open issues is not an error" 0 "$code"
has "no open issues is said" "NO OPEN ISSUES" "$out"

# A list that cannot be read is refused, never ranked as an empty backlog (L10).
out="$(rank 'not json')"; code=$?
same "a list that cannot be read exits 2" 2 "$code"
out="$(rank '{"number": 1}')"; code=$?
same "a list that is not a list exits 2" 2 "$code"
# A listing as long as its limit was cut off, so ranking it would rank a partial backlog.
out="$(rank "$(list "$(issue 5 '' priority-p2 enhancement)" "$(issue 6 '' priority-p3 enhancement)")" --limit 2)"; code=$?
same "a listing that reached its limit exits 3" 3 "$code"
has "a truncated listing says to raise the limit" "raise" "$out"

# The structural spellings are the area check's own list (mods/area-check, STRUCTURAL_LABELS), so
# the issue a session is told to restructure is the one /next-issue brings forward. Read from the
# mod's file, so a spelling added there fails here first (L370).
if [ ! -f "$RULES" ]; then
  check "the area check's rules are beside this skill" "$RULES is missing"
else
  theirs="$(grep -E '^export const STRUCTURAL_LABELS' "$RULES" | grep -oE "'[a-z0-9-]+'" | tr -d "'" | sort | tr '\n' ' ')"
  ours="$(python3 "$RANK" --structural-labels | sort | tr '\n' ' ')"
  [ -n "$theirs" ] && check "the area check's structural labels are read" ok || check "the area check's structural labels are read" "no STRUCTURAL_LABELS line in $RULES"
  same "the slot's structural labels are the area check's" "$theirs" "$ours"
fi

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
