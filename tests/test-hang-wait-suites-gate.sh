#!/usr/bin/env bash
# Every script of this repository that sources lib/hang-wait.sh, judged through the Slack drafts gate
# as a session runs it, `bash <path>` from the checkout (claude-config#2679).
#
# hang_wait and window_wait evaluate their condition in the suite's own shell, on purpose (#2465). To
# the gate, a wait whose condition is not written out can set any name, so past it the gate is sure
# of no variable, and a module or file reached later through one ("$DIR/lib", "$ROOT/tools") is
# placed nowhere and refused: "a module the gate cannot find", "a path the gate cannot work out".
# Three suites were refused that way and fixed by #2668. Since #2759 and #3012 a wait whose condition
# is written out keeps the suite's variables, so two of those three, rebuilt as they were, are now
# allowed; the third (test-pr-review.sh before #2680) is still refused, because its waits built their
# condition from a value (`hang_wait "[ -e '$f' ]"`), measured through the wrapper on 2026-11-15.
#
# Only judging the real scripts finds the next one, so this does that. A refusal of that kind fails
# here, naming the script and the gate's reason. A refusal for another reason is printed, never
# failed: it is not this class, and it is not this suite's to settle.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/../payload/hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

pass=0; fail=0
check(){ if [ "$2" = ok ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }

# How many scripts this suite judges at once is its share of the runner, HOOK_TESTS_SLOTS, which
# run-all-tests.sh hands every suite (claude-config#3170): a fixed 4 ran here on CI's runners of 4,
# where the share is 2. Read as tests/test-claude-sync.sh reads it: empty is absent, anything not a
# whole number above zero is refused (L50), and 4 when nothing granted a share, a run started by hand.
. "$DIR/../payload/hooks/lib/whole-number.sh" && declare -F whole_above_zero >/dev/null || {
  echo "FAIL: $(basename "$0"): lib/whole-number.sh is missing, so this suite's share of the runner cannot be read. Refusing to guess how many scripts to judge at once."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
HW_WIDTH=4
if [ -n "${HOOK_TESTS_SLOTS:-}" ]; then
  if _wn_got="$(whole_above_zero "$HOOK_TESTS_SLOTS")"; then HW_WIDTH="$_wn_got"; else
    echo "FAIL: $(basename "$0"): HOOK_TESTS_SLOTS='$HOOK_TESTS_SLOTS' is not a positive whole number of scripts this suite may judge at once. Refusing rather than guessing: it arrives from run-all-tests.sh, so a value nobody can read means that is wrong."
    printf 'SUITE-RESULT passed=0 failed=1\n'
    exit 1
  fi
fi
# The most judgements this suite had going at once, counted at every start, so the share is
# measured in what ran rather than read off the number above.
HW_MOST=0
live_now(){ local n=0 p; for p in "$@"; do kill -0 "$p" 2>/dev/null && n=$((n + 1)); done; printf '%s' "$n"; }

HOOKS="$DIR/../payload/hooks"
GATE="$HOOKS/slack-drafts-only-gate.sh"
ROOT="$(bash "$HOOKS/lib/checkout-root.sh" "$HOOKS/.." 2>/dev/null || true)"
if [ -z "$ROOT" ] || [ ! -f "$GATE" ]; then
  echo "SUITE-UNMEASURED $DIR is not in a claude-config checkout with the gate beside it, so no script was judged"
  printf 'SUITE-RESULT passed=0 failed=0\n'
  exit 0
fi
W="$(mktemp -d "${TMPDIR:-/tmp}/hang-wait-gate.XXXXXX")" || exit 1
trap 'rm -rf "$W"' EXIT

# judge_one <cwd> <path> <out file>: `bash <path>` run from cwd, judged with a gate cache of its own,
# so no judgement reads another's or this Mac's. Writes one line: the exit code, a tab, the path, a
# tab, the gate's words on one line.
judge_one(){
  local c rc words
  c="$(mktemp -d "$W/cache.XXXXXX")"
  words="$(python3 -c '
import json, sys
print(json.dumps({"session_id": "f6017250-8f33-47ac-bbb2-b82a7c319d0d", "transcript_path": "/tmp/t.jsonl",
                  "cwd": sys.argv[1], "permission_mode": "auto", "hook_event_name": "PreToolUse", "tool_name": "Bash",
                  "tool_input": {"command": "bash " + sys.argv[2], "description": "d"}, "tool_use_id": "toolu_01X"}))
' "$1" "$2" | SLACK_GATE_CACHE_DIR="$c" bash "$GATE" 2>&1)"; rc=$?
  # Written whole and then moved into place, so a judge ended part way leaves no line rather than
  # half of one, which would count as judged and read as the gate failing (#3656).
  printf '%s\t%s\t%s\n' "$rc" "$2" "$(printf '%s' "$words" | tr '\n' ' ')" > "$3.part" && mv -f "$3.part" "$3"
}
# why_ended <wait status>: what a judge's own exit status says about how it ended.
why_ended(){
  case "$1" in
    127) printf 'was not a child of this suite when waited for (status 127)' ;;
    1[3-9][0-9]|2[0-9][0-9]) printf 'was ended by signal %s' "$(( $1 - 128 ))" ;;
    *) printf 'exited %s' "$1" ;;
  esac
}
# judge <cwd> <list file> <out file> [<judge function>]: each path in the list judged, HW_WIDTH at a
# time (the suite's share, read above), the lines gathered in the list's order. The judge function is
# judge_one; the controls below hand it a stand in that is ended before it writes.
#
# A judge's line is gathered once its own process has been waited for, one wait per judge, so the
# gathering turns on each judge's completion and never on a time (L290). A judge that ended without
# writing its line is judged again once, and one that ends without a line twice is written to
# <out file>.lost (`<status>\t<path>\t<what it printed>`), for the checks to name. On 2026-11-25, at a
# load average of 263 inside the push gate, one line in 49 went missing and the check said only
# "48 of 49" (#3656): nothing said which script, or how its judge ended.
judge(){
  local i=0 p live pids=() idx=() j fn="${4:-judge_one}"
  : > "$3"; : > "$3.lost"; : > "$3.retried"
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    i=$((i + 1))
    printf '%s\n' "$p" > "$W/path.$i"
    rm -f "$W/one.$i"
    "$fn" "$1" "$p" "$W/one.$i" 2> "$W/err.$i" &
    pids+=("$!"); idx+=("$i")
    live="$(live_now "${pids[@]}")"; [ "$live" -le "$HW_MOST" ] || HW_MOST="$live"
    if [ "${#pids[@]}" -ge "$HW_WIDTH" ]; then
      j=0; while [ "$j" -lt "${#pids[@]}" ]; do wait "${pids[$j]}" 2>/dev/null; printf '%s' "$?" > "$W/st.${idx[$j]}"; j=$((j + 1)); done
      pids=(); idx=()
    fi
  done < "$2"
  j=0; while [ "$j" -lt "${#pids[@]}" ]; do wait "${pids[$j]}" 2>/dev/null; printf '%s' "$?" > "$W/st.${idx[$j]}"; j=$((j + 1)); done
  local k=1 st
  while [ "$k" -le "$i" ]; do
    p="$(cat "$W/path.$k")"
    if [ ! -s "$W/one.$k" ]; then
      st="$(cat "$W/st.$k" 2>/dev/null)"
      printf '%s\t%s\t%s\n' "${st:-unknown}" "$p" "$(tr '\n' ' ' < "$W/err.$k" | cut -c1-300)" >> "$3.retried"
      "$fn" "$1" "$p" "$W/one.$k" 2> "$W/err.$k" &
      wait "$!" 2>/dev/null; printf '%s' "$?" > "$W/st.$k"
    fi
    if [ -s "$W/one.$k" ]; then cat "$W/one.$k" >> "$3"; else
      st="$(cat "$W/st.$k" 2>/dev/null)"
      printf '%s\t%s\t%s\n' "${st:-unknown}" "$p" "$(tr '\n' ' ' < "$W/err.$k" | cut -c1-300)" >> "$3.lost"
    fi
    rm -f "$W/one.$k" "$W/one.$k.part" "$W/path.$k" "$W/st.$k" "$W/err.$k"
    k=$((k + 1))
  done
}
# account <list file> <out file>: whether every path listed was judged, as one line on stdout.
# `judged <n>` when all were. `unmeasured <sentence>` when the only ones missing are judges ended
# from outside on both tries (a signal, or a status that is not a clean finish): the gate was never
# asked, so nothing about the gate is measured, and the runner reads that as a part unmeasured
# (L411). `missing <sentence>` for anything else, a judge that exited 0 and wrote nothing included,
# which is a fault of this suite and fails.
account(){
  local n judged lost st path said clean="" ended=""
  n="$(grep -c . "$1")"; judged="$(grep -c . "$2")"; lost="$(grep -c . "$2.lost")"
  if [ "$judged" -eq "$n" ] && [ "$lost" -eq 0 ]; then printf 'judged %s\n' "$judged"; return 0; fi
  while IFS=$'\t' read -r st path said; do
    if [ "$st" = 0 ]; then clean="$clean $path (its judge exited 0 without writing a line: ${said:-it printed nothing});"
    else ended="$ended $path (its judge $(why_ended "$st") before writing its line, on both tries: ${said:-it printed nothing});"; fi
  done < "$2.lost"
  if [ -z "$clean" ] && [ "$lost" -gt 0 ] && [ $((judged + lost)) -eq "$n" ]; then
    printf 'unmeasured of the %s scripts listed, %s not judged, so whether the gate places what it reaches past lib/hang-wait.sh was not measured:%s\n' "$n" "$([ "$lost" -eq 1 ] && echo "1 was" || echo "$lost were")" "$ended"
  else
    local unseen="" q
    while IFS= read -r q; do
      [ -n "$q" ] || continue
      cut -f2 "$2" "$2.lost" | grep -q -x -F -- "$q" || unseen="$unseen $q (no line, and no record of its judge);"
    done < "$1"
    printf 'missing %s of %s judged;%s%s%s\n' "$judged" "$n" "$clean" "$ended" "$unseen"
  fi
}
# placed_nowhere <gate words>: whether a refusal is this class, a module or file the gate could not place.
placed_nowhere(){ case "$1" in *"a module the gate cannot find"*|*"a path the gate cannot work out"*) return 0 ;; esac; return 1; }

# The control (L1): a script shaped like test-pr-review.sh before #2680, in a tree of its own beside
# the real lib/hang-wait.sh, must be refused as this class, and the same with its wait written out
# allowed. So the words this suite matches are the ones the gate prints today, and a gate that stops
# printing them fails here rather than letting every refusal below pass as another kind.
mkdir -p "$W/ctl/tools/lib" "$W/ctl/tests"
printf '%s\n' 'def go():' '    return 1' > "$W/ctl/tools/lib/ctl_helper.py"
top='DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"'
py="python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import ctl_helper' \"\$DIR/../tools/lib\""
printf '%s\n' '#!/bin/bash' "$top" ". \"$HOOKS/lib/hang-wait.sh\"" 'f="$1"' "hang_wait \"[ -e '\$f' ]\"" "$py" > "$W/ctl/tests/built.sh"
printf '%s\n' '#!/bin/bash' "$top" ". \"$HOOKS/lib/hang-wait.sh\"" 'f="$1"' "hang_wait '[ -e \"\$f\" ]'" "$py" > "$W/ctl/tests/written.sh"
printf '%s\n' tests/built.sh tests/written.sh > "$W/ctl.list"
judge "$W/ctl" "$W/ctl.list" "$W/ctl.out"
built="$(grep -F "	tests/built.sh	" "$W/ctl.out")"
written="$(grep -F "	tests/written.sh	" "$W/ctl.out")"
case "$built" in 2*) placed_nowhere "$built" && check "the control: a wait on a condition built from a value, then an import through a variable, is refused as placed nowhere" ok \
  || check "the control: a wait on a condition built from a value, then an import through a variable, is refused as placed nowhere" "refused for another reason: ${built:0:400}" ;;
  *) check "the control: a wait on a condition built from a value, then an import through a variable, is refused as placed nowhere" "not refused: ${built:0:400}" ;; esac
case "$written" in "0	tests/written.sh	") check "the control: the same with the condition written out is allowed" ok ;;
  *) check "the control: the same with the condition written out is allowed" "${written:0:400}" ;; esac

# The controls for gathering (#3656, L1): a stand in judge, in place of judge_one, for three listed
# paths, whose judge of the middle one is ended by SIGKILL before it writes (the loss seen at a load
# of 263), ended only the first time, or finishes cleanly with no line. Staged, never left to load.
# stand_in <cwd> <path> <out file>: writes a line as judge_one does, except for $SI_PATH (SI_MODE).
stand_in(){
  if [ "$2" = "$SI_PATH" ]; then
    case "$SI_MODE" in
      ended) sh -c 'kill -KILL "$PPID"' ;;
      ended_once) [ -e "$W/si.once" ] || { : > "$W/si.once"; sh -c 'kill -KILL "$PPID"'; } ;;
      clean) return 0 ;;
    esac
  fi
  printf '0\t%s\t\n' "$2" > "$3.part" && mv -f "$3.part" "$3"
}
# Each run is in a subshell of its own whose stderr is kept aside, so the shell's own notice of a job
# it saw killed ("Killed: 9") is not printed among this suite's results as though something broke.
printf '%s\n' tests/a.sh tests/b.sh tests/c.sh > "$W/si.list"
SI_PATH=tests/b.sh
SI_MODE=ended_once; ( judge "$W" "$W/si.list" "$W/si.out" stand_in ) 2>> "$W/si.noise"; got="$(account "$W/si.list" "$W/si.out")"
case "$got|$(cat "$W/si.out.retried")" in "judged 3|137	tests/b.sh	"*) check "the control: a judge ended before writing is judged again, and the line it then writes is counted" ok ;;
  *) check "the control: a judge ended before writing is judged again, and the line it then writes is counted" "account said '$got', the retried record '$(cat "$W/si.out.retried")'" ;; esac
SI_MODE=ended; ( judge "$W" "$W/si.list" "$W/si.out" stand_in ) 2>> "$W/si.noise"; got="$(account "$W/si.list" "$W/si.out")"
case "$got" in "unmeasured of the 3 scripts listed, 1 was not judged,"*" tests/b.sh (its judge was ended by signal 9 before writing its line, on both tries"*) check "the control: a judge ended before writing on both tries is named, and is unmeasured rather than failed" ok ;;
  *) check "the control: a judge ended before writing on both tries is named, and is unmeasured rather than failed" "account said '$got'" ;; esac
SI_MODE=clean; ( judge "$W" "$W/si.list" "$W/si.out" stand_in ) 2>> "$W/si.noise"; got="$(account "$W/si.list" "$W/si.out")"
case "$got" in "missing 2 of 3 judged; tests/b.sh (its judge exited 0 without writing a line"*) check "the control: a judge that finished cleanly without a line is named, and fails" ok ;;
  *) check "the control: a judge that finished cleanly without a line is named, and fails" "account said '$got'" ;; esac

# The real scripts: every shell file the repository ships whose code sources lib/hang-wait.sh.
bash "$HOOKS/lib/repo-files.sh" "$ROOT" > "$W/files" 2>"$W/files.err" || { check "the repository's files were listed" "$(cat "$W/files.err")"; }
: > "$W/suites"
while IFS= read -r f; do
  case "$f" in *.sh) ;; *) continue ;; esac
  case "$f" in */lib/hang-wait.sh) continue ;; esac
  [ -f "$ROOT/$f" ] || continue
  grep -q -E '^[^#]*(^|[;&|{( ]|then |do )(\.|source)[[:space:]][^#]*hang-wait\.sh' "$ROOT/$f" 2>/dev/null && printf '%s\n' "$f" >> "$W/suites"
done < "$W/files"
n="$(grep -c . "$W/suites")"
# L98: a sweep that finds nothing to judge must not read as every script passing. These two are the
# suites #2668 changed that still source the helper, so each must be in the list.
grep -q -x -F payload/hooks/test-context-size-notice.sh "$W/suites" && grep -q -x -F payload/hooks/test-pr-review.sh "$W/suites" \
  && check "the scripts sourcing lib/hang-wait.sh were listed ($n), the two #2668 changed among them" ok \
  || check "the scripts sourcing lib/hang-wait.sh were listed ($n), the two #2668 changed among them" "list: $(tr '\n' ' ' < "$W/suites")"
judge "$ROOT" "$W/suites" "$W/real.out"
while IFS=$'\t' read -r st path said; do
  echo "NOTE: $path was judged again: its first judge $(why_ended "$st") before writing its line (${said:-it printed nothing})"
done < "$W/real.out.retried"
got="$(account "$W/suites" "$W/real.out")"
case "$got" in
  "judged "*) check "every one listed was judged (${got#judged })" ok ;;
  "unmeasured "*) echo "SUITE-PART-UNMEASURED ${got#unmeasured }" ;;
  *) check "every one listed was judged" "${got#missing }" ;;
esac
while IFS=$'\t' read -r rc path words; do
  [ "$rc" = 0 ] && continue
  # Only exit 2 is a refusal; any other code is the gate failing to judge, never a note (L11).
  if [ "$rc" != 2 ]; then
    check "$path was judged by the gate" "the gate exited $rc: ${words:0:600}"
  elif placed_nowhere "$words"; then
    check "$path is not refused for a module or path placed nowhere past lib/hang-wait.sh" \
      "the gate said: ${words:0:600}. Write the wait's condition out in single quotes (hang_wait '[ -e \"\$f\" ]'), or spell the path from BASH_SOURCE where it is handed over (lib/hang-wait.sh's header)"
  else
    echo "NOTE: $path is refused for another reason, not this suite's: ${words:0:300}"
  fi
done < "$W/real.out"
[ "$HW_MOST" -le "$HW_WIDTH" ] && check "no more scripts were judged at once than this suite's share of $HW_WIDTH" ok \
  || check "no more scripts were judged at once than this suite's share of $HW_WIDTH" "$HW_MOST went at once (HOOK_TESTS_SLOTS='${HOOK_TESTS_SLOTS:-}', 4 when unset), taking processors run-all-tests.sh gave to the suites beside it"

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
