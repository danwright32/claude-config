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
  printf '%s\t%s\t%s\n' "$rc" "$2" "$(printf '%s' "$words" | tr '\n' ' ')" > "$3"
}
# judge <cwd> <list file> <out file>: each path in the list judged, four at a time, the lines
# gathered in the list's order.
judge(){
  local i=0 p
  : > "$3"
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    i=$((i + 1))
    judge_one "$1" "$p" "$W/one.$i" &
    [ $((i % 4)) -eq 0 ] && wait
  done < "$2"
  wait
  local k=1
  while [ "$k" -le "$i" ]; do cat "$W/one.$k" >> "$3"; rm -f "$W/one.$k"; k=$((k + 1)); done
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
judged="$(grep -c . "$W/real.out")"
[ "$judged" -eq "$n" ] && check "every one listed was judged ($judged)" ok || check "every one listed was judged" "$judged of $n"
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

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
