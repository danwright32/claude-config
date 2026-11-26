#!/usr/bin/env bash
# Tests for check-grep-file-order.sh and its judge grep_file_order_gate.py (claude-config#3546): a
# Bash command whose grep, as the Bash tool's own shell runs it, drops file names (-h) over more than
# one file is refused before it runs, naming the fix, and every grep that keeps argument order or
# keeps the names passes.
#
# Reproduced 2026-11-26 in the Bash tool on the personal MacBook: grep there is a shell function from
# Claude Code's shell snapshot that runs its built in ugrep, which searches several files at once.
# `grep -h result big small1 small2` (one 300,000 line file first, two one line files after) came out
# of argument order in 10 of 10 runs; `command grep` kept it in 5 of 5, and so did `-J1` in 5 of 5.
# A child shell (bash -c, a script) has no such function and runs the real binary.
#
# The hook never runs grep, so nothing here does either: each case hands the hook a PreToolUse
# payload and reads its exit code and what it said. Every refused case is also run against a LOOSER
# copy of the judge whose predicate never fires, and must pass there (L1): that proves the refusal
# comes from the predicate, not from a reader that failed and refused everything.
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/check-grep-file-order.sh"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

pass=0; fail=0
ok(){ pass=$((pass + 1)); }
bad(){ fail=$((fail + 1)); echo "FAIL: $1"; }
check_eq(){ if [[ "$3" == "$2" ]]; then ok; else bad "$1 (expected '$2', got '$3')"; fi; }
check(){ if [[ "$3" == *"$2"* ]]; then ok; else bad "$1"; echo "  expected to contain: $2"; echo "  actual: ${3:0:1500}"; fi; }

command -v python3 >/dev/null 2>&1 || { echo "test-check-grep-file-order: python3 is not on PATH, so nothing was verified." >&2; exit 2; }
[ -f "$HOOK" ] || { bad "#3546 $HOOK does not exist"; printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"; exit 1; }

# The looser copy: the hook, its judge and its libraries, with the judge's predicate made to never
# fire, checked to have been found, since one that matched nothing would prove nothing (L100).
LOOSE="$WORKDIR/loose"; mkdir -p "$LOOSE/lib"
cp "$HOOK" "$DIR/grep_file_order_gate.py" "$LOOSE/"
python3 "$DIR/lib/install-hook-libs.py" "$DIR/lib" "$LOOSE/lib" push-scope.sh shell-words.py || bad "#3546 the hook helpers could not be installed into $LOOSE/lib"
loosened="$(python3 - "$LOOSE/grep_file_order_gate.py" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
head = "def unordered(words):\n"
if head not in s:
    print("unordered")
else:
    s = s.replace(head, head + "    return False\n\n\ndef _was_unordered(words):\n", 1)
open(p, "w").write(s)
PY
)"
for missing in $loosened; do
  bad "#3546 def $missing(words) was not found in the judge to loosen, so its looser runs prove nothing"
done

payload(){ # payload <command>
  python3 -c 'import json, sys; print(json.dumps({"tool_name": "Bash", "tool_input": {"command": sys.argv[1]}, "cwd": sys.argv[2]}))' "$1" "$WORKDIR"
}
judge(){ # judge <command> [hook]: sets out and rc
  out="$(payload "$1" | bash "${2:-$HOOK}" 2>&1)"; rc=$?
}
refused(){ # refused <name> <command>
  judge "$2"
  check_eq "#3546 refused: $1" "2" "$rc"
  check "#3546 and the refusal names the fix: $1" "command grep" "$out"
  judge "$2" "$LOOSE/check-grep-file-order.sh"
  check_eq "#3546 the looser copy, whose predicate never fires, lets it through: $1" "0|" "$rc|$out"
}
allowed(){ # allowed <name> <command>
  judge "$2"
  check_eq "#3546 allowed: $1" "0|" "$rc|$out"
}

# 1. Several named files with -h, wherever the grep stands in the Bash tool's own shell. Each has a
# control beside it that keeps order or keeps the names.
refused "the measured shape" "grep -h result big.txt small1.txt small2.txt"
allowed "control: one file with -h" "grep -h result small1.txt"
allowed "control: several files without -h, each line names its file" "grep result big.txt small1.txt small2.txt"
allowed "control: several files with -H" "grep -H result big.txt small1.txt"
refused "two files" "grep -h result a.txt b.txt"
refused "-h in a cluster" "grep -hn result a.txt b.txt"
refused "-h after another letter" "grep -ih result a.txt b.txt"
refused "--no-filename" "grep --no-filename result a.txt b.txt"
refused "-c with -h, counts with no names" "grep -ch result a.txt b.txt"
refused "-h after the operands" "grep result a.txt b.txt -h"
refused "the pattern given with -e" "grep -h -e result a.txt b.txt"
allowed "control: -e names the pattern, so one file is one file" "grep -h -e result a.txt"
refused "a glob that names several files" "grep -h result *.txt"
refused "brace expansion" "grep -h result {a,b}.txt"
allowed "control: a value taking flag does not count as a file" "grep -h -m 1 result a.txt"
# --color takes its value only after "=", so the next word stays a word of its own (measured: -h
# after it still dropped the names).
refused "-h after --color, whose value needs =" "grep --color -h result a.txt b.txt"
allowed "control: --context takes the next word as its value (measured)" "grep -h --context 1 result a.txt"
allowed "control: a glued value taking flag does not count as a file" "grep -hA2 result a.txt"

# 2. In a pipeline: the grep's own order reaches the next command (measured in a pipe into tr).
refused "piped on" "grep -h result a.txt b.txt | tr '\n' '|'"
allowed "control: grep reading a pipe has no files to reorder" "cat a.txt b.txt | grep -h result"
refused "after cd and &&" "cd /tmp && grep -h result a.txt b.txt"
refused "in a command substitution" 'x=$(grep -h result a.txt b.txt)'
refused "in a subshell" "(grep -h result a.txt b.txt)"
refused "behind an assignment" "LC_ALL=C grep -h result a.txt b.txt"
refused "behind noglob" "noglob grep -h result a.txt b.txt"
refused "behind exec, measured to still reach the function" "exec grep -h result a.txt b.txt"
refused "quoted, which still runs the function" '"grep" -h result a.txt b.txt'
refused "inside eval, the same shell" "eval 'grep -h result a.txt b.txt'"
refused "inside a loop body" 'for p in x y; do grep -h "$p" a.txt b.txt; done'

# 3. Every spelling that reaches the real binary, which keeps argument order, passes.
allowed "command grep, the fix" "command grep -h result a.txt b.txt"
allowed "the full path" "/usr/bin/grep -h result a.txt b.txt"
allowed "env runs the binary" "env grep -h result a.txt b.txt"
allowed "xargs runs the binary" "xargs grep -h result < list.txt"
allowed "timeout runs the binary" "timeout 5 grep -h result a.txt b.txt"
allowed "bash -c is another shell, with no function" "bash -c 'grep -h result a.txt b.txt'"
allowed "zsh -c is another shell, with no function" "zsh -c 'grep -h result a.txt b.txt'"
allowed "find -exec runs the binary" "find . -exec grep -h result {} +"
allowed "one job keeps the order, measured" "grep -h -J1 result a.txt b.txt"
allowed "one job glued in a cluster" "grep -hJ1 result a.txt b.txt"
allowed "one job, long form" "grep -h --jobs=1 result a.txt b.txt"
refused "two jobs is still several" "grep -h -J2 result a.txt b.txt"

# 4. Mentions are not calls.
allowed "control: a commit message naming it" "git commit -m 'grep -h result a.txt b.txt'"
allowed "control: echo naming it" "echo grep -h result a.txt b.txt"
allowed "control: git grep is git's own" "git grep -h result -- a.txt b.txt"
allowed "control: rg is not grep" "rg -h result a.txt b.txt"
out="$(python3 -c 'import json; print(json.dumps({"tool_name": "Write", "tool_input": {"file_path": "/tmp/x", "content": "grep -h r a b"}}))' | bash "$HOOK" 2>&1)"; rc=$?
check_eq "#3546 a Write naming the shape is not judged" "0|" "$rc|$out"

# 5. The refusal says why, in the terms of the place the reader acts.
judge "grep -h result a.txt b.txt"
check "#3546 the refusal says the order is lost" "order" "$out"
check "#3546 the refusal names dropping -h as the other fix" "drop -h" "$out"

# Built is not wired (L3): registered to see every Bash call before it runs, blocking on failure.
. "$DIR/lib/settings-file.sh"
SETTINGS="$(hook_settings_file "$DIR/..")"
wired="$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
print(sum(1 for m in d["hooks"].get("PreToolUse", []) if m.get("matcher") == "Bash"
          for h in m["hooks"] if h.get("command", "").endswith("/hooks/check-grep-file-order.sh")
          and h.get("onFailure") == "block"))' "${SETTINGS:-/dev/null}")"
check_eq "#3546 registered once as a PreToolUse hook on Bash, blocking on failure" "1" "$wired"

# 6. With the reader missing the command cannot be read word by word. A command whose text starts a
# grep with -h is refused as not judged; one without -h passes.
LONE="$WORKDIR/lone"; mkdir -p "$LONE"
cp "$HOOK" "$DIR/grep_file_order_gate.py" "$LONE/"
judge "grep -h result a.txt b.txt" "$LONE/check-grep-file-order.sh"
check_eq "#3546 with lib/shell-words.py missing, the shape is refused" "2" "$rc"
check "#3546 and says it could not be read word by word" "could not be read" "$out"
check "#3546 and names the missing file" "shell-words.py" "$out"
check "#3546 and still names the fix" "command grep" "$out"
judge "grep result a.txt b.txt" "$LONE/check-grep-file-order.sh"
check_eq "#3546 control: with the reader missing, grep without -h passes in silence" "0|" "$rc|$out"
judge "command grep -h result a.txt b.txt" "$LONE/check-grep-file-order.sh"
check_eq "#3546 control: with the reader missing, command grep passes in silence" "0|" "$rc|$out"

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
