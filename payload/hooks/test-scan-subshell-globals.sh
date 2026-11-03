#!/usr/bin/env bash
# Tests for the scan that finds a function answering into a global nobody can read
# (claude-config#372).
#
# lesson_index_entry_cap recorded "this hook exists but carries no cap" in a shared variable, while
# every call site read the function through a command substitution. That is a subshell, so the
# assignment was discarded on return and the warning it fed could never fire, with the code setting
# it reading as entirely correct. The tests caught it; inspection would not have.
#
# Driven against fixtures FIRST, so every outcome is produced rather than merely reachable (L151),
# and against the real tree at the end, because a scan proven only over files this suite wrote says
# nothing about the one anybody runs (L52).
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCAN="$DIR/scan-subshell-globals.py"
# WHERE THIS IS RUNNING. Two copies of these hooks exist: the repo's payload/hooks, which sits
# beside a claude-sync and a payload/, and the INSTALLED copy under the config root, which does
# not. `$DIR/../..` is the repo in the first and the HOME DIRECTORY in the second, so a suite that
# assumes the first walks all of $HOME in the second. Measured 2026-09-11: that is what made
# `claude-sync recheck` exceed its 30 minute ceiling and report the whole config unverified.
#
# Said in the one agreed shape the runner reads, so it is reported as NOT RUN rather than as broken
# code, and never as a pass: this suite is about the repo, and the installed copy is not one.
# The checkout is found by the one shared test, lib/checkout-root.sh (claude-config#1567, #1663),
# which prints nothing for an installed copy or a copy inside some other repository.
REPO="$(bash "$DIR/lib/checkout-root.sh" "$DIR/.." 2>/dev/null || true)"
if [ -z "$REPO" ]; then
  echo "test-scan-subshell-globals: $DIR/.. is not the payload of a claude-config checkout, so there was nothing here to scan." >&2
  printf 'SUITE-NOT-RUN %s\n' "needs the repository above it, and $DIR/.. is not the payload of one"
  echo "passed: 0, failed: 0"
  printf 'SUITE-RESULT passed=0 failed=0\n'
  exit 2
fi

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }
says(){ case "$2" in *"$3"*) check "$1" ok ;; *) check "$1" "did not say '$3'" ;; esac; }

[ -f "$SCAN" ] || { echo "FAIL: no scan at $SCAN"; echo "passed: 0, failed: 1"; printf 'SUITE-RESULT passed=0 failed=1\n'; exit 1; }

FIX="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/scan-subshell.XXXXXXXX")" && pwd -P)"
trap 'rm -rf "$FIX"' EXIT
printf '# empty\n' > "$FIX/baseline.txt"

RC=0; OUT=""
run(){ OUT="$(python3 "$SCAN" --root "$FIX" --baseline "$FIX/baseline.txt" 2>&1)"; RC=$?; }

echo "scan subshell globals: the fault it was written for"

# The incident, in miniature: the answer is recorded in a global, and the one caller reads the
# function through a command substitution, so the assignment is gone by the time it returns.
cat > "$FIX/a.sh" <<'EOF'
ANSWER=""
read_cap(){
  ANSWER="hook present but carrying no cap"
  printf '%s' "160"
}
cap="$(read_cap)"
[ -n "$ANSWER" ] && echo "$ANSWER"
EOF
run
check "a function whose global every caller reads in a subshell is reported" "$([ "$RC" -ne 0 ] && echo ok || echo "exit $RC")"
says "and the finding names the function" "$OUT" "read_cap"
says "and the name it sets" "$OUT" "ANSWER"

echo "scan subshell globals: and nothing it should leave alone"

# Called plainly SOMEWHERE is not condemned: answering into a global is a legitimate design when
# the caller is in the same shell, and this repo has such functions on purpose.
cat > "$FIX/a.sh" <<'EOF'
ANSWER=""
read_cap(){
  ANSWER="something"
  printf '%s' "160"
}
read_cap
cap="$(read_cap)"
EOF
run
check "a function also called plainly is not condemned" "$([ "$RC" -eq 0 ] && echo ok || echo "exit $RC: $OUT")"

# An env PREFIX assigns nothing in this shell. It is the commonest line shape in these suites, and
# counting it made the first measurement of this scan four times too large.
cat > "$FIX/a.sh" <<'EOF'
run_it(){
  CLAUDE_HOME="$fix" SYNC_REPO="$repo" bash "$prog" status
}
out="$(run_it)"
EOF
run
check "an env prefix on a command is not an assignment" "$([ "$RC" -eq 0 ] && echo ok || echo "exit $RC: $OUT")"

# A local is not a global, which is the whole remedy.
cat > "$FIX/a.sh" <<'EOF'
read_cap(){
  local answer
  answer="something"
  printf '%s' "$answer"
}
cap="$(read_cap)"
EOF
run
check "a variable declared local is not a global" "$([ "$RC" -eq 0 ] && echo ok || echo "exit $RC: $OUT")"

# A declaration ENDS where its command does (claude-config#1045). The names used to be read by
# splitting the whole line on spaces, so `local a b skip; shift` declared `skip;` and `shift`, and
# the later `skip=...` was reported as a global. It flagged path_without in test-pr-review.sh on
# PR #1039, whose fix moved `shift` onto its own line: working around the scan, not fixing it. Each
# way a command can end is here, and so are values holding the same characters inside quotes or a
# command substitution, which do NOT end it, so a fix that cut at the first `;` anywhere loses the
# names after it and fails here too.
cat > "$FIX/a.sh" <<'EOF'
semi(){
  local a b skip; shift
  skip="$1"
  printf '%s' "$skip"
}
both(){
  local first && shift
  first="$1"
  printf '%s' "$first"
}
either(){
  local second || return 1
  second="$1"
  printf '%s' "$second"
}
valued(){
  local msg="one; two && three" out="$(date; date)" count=0 tail
  tail="$msg"; count=1
  printf '%s%s%s' "$tail" "$count" "$out"
}
x="$(semi 1 2)"; y="$(both 1)"; z="$(either 1)"; v="$(valued)"
EOF
run
check "#1045 a declaration ends at ; && and ||, and a value holding them does not end it" "$([ "$RC" -eq 0 ] && echo ok || echo "exit $RC: $OUT")"

# A declaration ends at `|` too, and there it declares nothing at all: every member of a pipeline
# runs in a subshell of its own, so `local third | cat` makes third local to a shell that ends at
# once, and the `third=` after it sets this shell's global (claude-config#2076). This fixture sat in
# the clean one above until #2076 read pipelines as the shell runs them; what #1045 decided, that
# `cat` is never read as a declared name, still holds, since nothing in the pipeline is declared.
cat > "$FIX/a.sh" <<'EOF'
piped(){
  local third | cat
  third="$1"
  printf '%s' "$third"
}
w="$(piped 1)"
EOF
run
check "#2076 a local in a pipeline declares nothing in this shell" "$([ "$RC" -ne 0 ] && echo ok || echo "exit $RC: it was taken as declared")"
says "#2076 and the name it then sets is the finding" "$OUT" "piped sets third"

# And what FOLLOWS the end is a command of its own, so an assignment there is judged as one: in
# `local a; leak=1` the name leak is a global, and must not be counted as declared because it
# shares a line with a declaration.
cat > "$FIX/a.sh" <<'EOF'
ANSWER=""
after(){
  local a; ANSWER="leaked"
  printf '%s' "$a"
}
x="$(after)"
EOF
run
check "#1045 an assignment after a declaration's end is still judged" "$([ "$RC" -ne 0 ] && echo ok || echo "exit $RC: it was taken as declared")"
says "#1045 and the finding names it" "$OUT" "ANSWER"

# The words INSIDE an array initializer or an unquoted substitution are values, not names: in
# `local list=(two LEAKED) when=$(date +%s)` only list and when are declared, so a later global
# that happens to share a word with the value is still a global (lessons review of #1103).
cat > "$FIX/a.sh" <<'EOF'
LEAKED=""
inside(){
  local list=(two LEAKED) when=$(date +%s)
  LEAKED="set"
  printf '%s %s' "${list[0]}" "$when"
}
x="$(inside)"
EOF
run
check "#1045 a word inside an array initializer is not declared" "$([ "$RC" -ne 0 ] && echo ok || echo "exit $RC: it was taken as declared")"
says "#1045 and the global sharing it is named" "$OUT" "LEAKED"

# A heredoc body is another language's code, not this shell's.
cat > "$FIX/a.sh" <<'OUTER'
convert(){
  python3 - <<'PY'
tzinfo = 1
print(tzinfo)
PY
}
x="$(convert)"
OUTER
run
check "an assignment inside a heredoc is not this shell's" "$([ "$RC" -eq 0 ] && echo ok || echo "exit $RC: $OUT")"

echo "scan subshell globals: a brace inside quoted text is not where a function ends (claude-config#2063)"

# The real case, in miniature. ps_payload_text in lib/push-scope.sh carries Python in a single
# quoted `python3 -c` string, and one literal opening brace in it made this scan read the function
# as running to the end of the file: it reported 23 globals the function never touches, every
# assignment below it in the file. #2061 worked around it by spelling the brace chr(123).
cat > "$FIX/a.sh" <<'OUTER'
payload_text(){
  local p="${1-}" more=""
  more="$(printf '%s' "$p" | python3 -c '
import json, sys
s = sys.stdin.read().strip()
if s[:1] in ("{", "["):
    print(json.loads(s))
' 2>/dev/null)" || more=""
  printf '%s\n%s' "$p" "$more"
}
payload="$(payload_text "$1")"
FOLLOWING=1
OUTER
run
check "#2063 a brace in a quoted python3 -c string does not carry the function to the end of the file" "$([ "$RC" -eq 0 ] && echo ok || echo "exit $RC: $OUT")"

# And the same for a closing brace, in the other direction: read as structure it ENDS the function
# early, so a global set below it is never seen. Double quotes, and a heredoc body, likewise.
cat > "$FIX/a.sh" <<'OUTER'
ANSWER=""
early(){
  echo "a closing } inside double quotes"
  echo 'and one } inside single quotes'
  cat <<EOF
and one } in a heredoc body
EOF
  ANSWER="leaked"
}
x="$(early)"
OUTER
run
check "#2063 a closing brace in quoted text or a heredoc body does not end the function early" "$([ "$RC" -ne 0 ] && echo ok || echo "exit $RC: the global below the brace was never seen")"
says "#2063 and the global below it is named" "$OUT" "early sets ANSWER"

# The control: real function bounds are still found. A function holding quoted braces ends at its
# own closing brace, so the next function's global is reported against the next function and
# nothing after either is drawn in; a brace group and a parameter expansion are still structure.
cat > "$FIX/a.sh" <<'OUTER'
quoted(){
  local p="$1"
  printf '%s' "{ $p" | python3 -c 'print("{")'
}
ANSWER=""
real(){
  if [ -n "${1:-}" ]; then { echo grouped; }; fi
  ANSWER="x"
}
cap="$(real)"
q="$(quoted)"
AFTER=1
OUTER
run
check "#2063 control: a real function's global is still reported" "$([ "$RC" -ne 0 ] && echo ok || echo "exit $RC: $OUT")"
says "#2063 control: against the right function" "$OUT" "a.sh:6  real sets ANSWER"
case "$OUT" in
  *quoted*|*AFTER*|*", cap"*|*", q"*) check "#2063 control: and nothing outside a function is drawn into one" "$OUT" ;;
  *) check "#2063 control: and nothing outside a function is drawn into one" ok ;;
esac

echo "scan subshell globals: a brace in a bracket expression, and a line inside a string, are not code (claude-config#2068)"

# The real case: mt_is_interpreter in lib/merge-target.sh matches `'$'[A-Za-z_{]*` in a case
# pattern, and the `{` there is a character the pattern matches, not a brace group. Counted as one,
# it left the function open to the end of the file (1890 lines, measured 2026-11-02), so every function below it was
# never found, and a global one of them sets was never reported. The `[{]` in a [[ =~ ]] regex
# (test-suite-scratch-isolation.sh) and a ${v//[{]/} replacement are the same shape.
cat > "$FIX/a.sh" <<'OUTER'
is_interp() {
  local tok="$1"
  case "$tok" in
    '"$'*|'$'[A-Za-z_{]*) return 0 ;;
  esac
  [[ "$tok" =~ \$[{]?(PY)$ ]] && return 0
  tok="${tok//[{]/}"
  return 1
}
ANSWER=""
real(){
  ANSWER="x"
}
cap="$(real)"
if is_interp "$1"; then :; fi
OUTER
run
check "#2068 a brace in a bracket expression does not carry the function past its end" "$([ "$RC" -ne 0 ] && echo ok || echo "exit $RC: the next function was never found: $OUT")"
says "#2068 and the next function's global is reported against it" "$OUT" "a.sh:11  real sets ANSWER"

# The real case: the suite deadline watchdog in tests/test-claude-sync.sh runs a program through
# `sh -c '...'`, whose lines read `ceiling="$2"; mark="$3"` and `start="$(date +%s)"`. Those are
# assignments in ANOTHER shell, the one sh starts, and a Python program in a `python3 -c` string
# (`stdout=subprocess.PIPE` in lib/project-rules-behind.sh) is not shell at all. The body is read
# whole by shell-words (#2076), so the program is one quoted word of one command, never a command.
cat > "$FIX/a.sh" <<'OUTER'
watch(){
  local out
  out="$(sh -c '
    ceiling="$2"; mark="$3"
    start="$(date +%s)"
  ' sh 1 2 3)"
  python3 -c '
import subprocess
r = subprocess.run(["true"],
    stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
'
  printf '%s' "$out"
}
v="$(watch)"
OUTER
run
check "#2068 an assignment inside a quoted string is not this shell's global" "$([ "$RC" -eq 0 ] && echo ok || echo "exit $RC: $OUT")"

# The control: what follows a string's close on the same line is still this shell's code, so an
# assignment there is judged, and an ordinary assignment on its own line still counts.
cat > "$FIX/a.sh" <<'OUTER'
after(){
  printf '%s' "
two lines"; CLOSED=1
  SAID="$(date)"
}
v="$(after)"
OUTER
run
check "#2068 control: an assignment after a string closes is still judged" "$([ "$RC" -ne 0 ] && echo ok || echo "exit $RC: $OUT")"
says "#2068 control: and names both globals" "$OUT" "after sets CLOSED, SAID"

# But a word after the close with no separator before it is still an argument to the command the
# string belongs to, so `two" ARG=1` hands printf the word ARG=1 and assigns nothing.
cat > "$FIX/a.sh" <<'OUTER'
arg(){
  printf '%s %s' "
two" ARG=1
}
v="$(arg)"
OUTER
run
check "#2068 a word after a string's close is an argument, not an assignment" "$([ "$RC" -eq 0 ] && echo ok || echo "exit $RC: $OUT")"

echo "scan subshell globals: assignments read as the shell reads its commands (#2076)"

# Each shape below was never judged while assignments were read by shlex, a line at a time. The
# lines are the real ones, with the function's `local` taken away so the name is a global.
#
# A comment after the assignment: shlex yields `#` as a word, which is no assignment, so the whole
# line was dropped. From mt_merge_invocation_bounds in lib/merge-target.sh.
cat > "$FIX/a.sh" <<'OUTER'
bounds(){
  c="${cmd:$i:1}"   # empty at i == n, so the end of the command closes the last invocation
}
v="$(bounds)"
OUTER
run
check "#2076 an assignment followed by a comment is judged" "$([ "$RC" -ne 0 ] && echo ok || echo "exit $RC: $OUT")"
says "#2076 and names it" "$OUT" "bounds sets c"

# Quotes nested inside a `$( )` inside double quotes: shlex reads the inner quotes as closing the
# outer ones and splits the value into words. From leave_out_proven in lib/pr-review.sh.
cat > "$FIX/a.sh" <<'OUTER'
leave_out(){
  rows="$(printf '%s' "$rows" | sort -t "$(printf '\t')" -k1,1n)"
}
v="$(leave_out)"
OUTER
run
check "#2076 an assignment with quotes nested inside its substitution is judged" "$([ "$RC" -ne 0 ] && echo ok || echo "exit $RC: $OUT")"
says "#2076 and names it" "$OUT" "leave_out sets rows"

# The first line of a multi line assignment: an unclosed quote, which shlex refuses. And the awk
# program's own `b = ""` lines are still never this shell's. From carry_review in lib/pr-review.sh.
cat > "$FIX/a.sh" <<'OUTER'
carry(){
  rows="$(awk -v br="$branch" '
    FNR == 1 { b = ""; s = ""; st = ""; bs = "" }
    /^branch=/ { b = substr($0, 8) } /^sha=/ { s = substr($0, 5) }
    /^status=/ { st = substr($0, 8) } /^base=/ { bs = substr($0, 6) }
    /^$/ { if (b == br && st == "ok" && bs != "") printf "%s\t%s\t%s\n", s, bs, FILENAME; nextfile }' "${files[@]}" 2>/dev/null)"
}
v="$(carry)"
OUTER
run
check "#2076 the first line of a multi line assignment is judged" "$([ "$RC" -ne 0 ] && echo ok || echo "exit $RC: $OUT")"
says "#2076 and names it alone" "$OUT" "carry sets rows"$'\n'

# Mid line: after `&&`, and after `then` with a command after it. shlex read the whole line, and a
# first word that was no assignment dropped all of it. From mt_merge_invocation_bounds.
cat > "$FIX/a.sh" <<'OUTER'
bounds(){
  if [ "$c" = "\\" ] && [ "$quote" = '"' ]; then i=$((i + 2)); continue; fi
  [ "$c" = "$quote" ] && quote=""
}
v="$(bounds)"
OUTER
run
check "#2076 an assignment mid line is judged" "$([ "$RC" -ne 0 ] && echo ok || echo "exit $RC: $OUT")"
says "#2076 and names both" "$OUT" "bounds sets i, quote"

# Mid line on the line that defines the function, its body running on to the next: the body was
# read from the line after, which begins inside the string, so nothing of it was judged. From
# remember in sync-stuck-notice.sh.
cat > "$FIX/a.sh" <<'OUTER'
remember(){ in_list "$keep" "$1" || keep="${keep:+$keep
}$1"; }
v="$(remember x)"
OUTER
run
check "#2076 an assignment on the line defining the function is judged" "$([ "$RC" -ne 0 ] && echo ok || echo "exit $RC: $OUT")"
says "#2076 and names it" "$OUT" "remember sets keep"

# The controls: what runs in a subshell, a `( )` group or a `$( )`, sets nothing in this shell, and
# a word after a value is still an env prefix on the command it precedes.
cat > "$FIX/a.sh" <<'OUTER'
sub(){
  local out
  out="$(inner=1; printf '%s' "$inner")"
  ( cd /tmp && grouped=1 )
  PREFIX=1 env | wc -l
  printf '%s' "$out"
}
v="$(sub)"
OUTER
run
check "#2076 control: an assignment in a subshell or a substitution, or an env prefix, is not a global" "$([ "$RC" -eq 0 ] && echo ok || echo "exit $RC: $OUT")"

# The reader is lib/shell-words.py, loaded by its path, and the scan keeps no reading of its own to
# fall back on. Without it nothing can be judged, which is said, and never reported as a clean tree.
NOREADER="$FIX/noreader"
mkdir -p "$NOREADER/lib" "$NOREADER/tree"
cp "$SCAN" "$NOREADER/scan-subshell-globals.py"
cp "$DIR/lib/ratchet.py" "$DIR/lib/shell_code_lines.py" "$NOREADER/lib/"
printf 'f(){\n  x=1\n}\nv="$(f)"\n' > "$NOREADER/tree/a.sh"
OUT="$(python3 "$NOREADER/scan-subshell-globals.py" --root "$NOREADER/tree" --baseline "$FIX/baseline.txt" 2>&1)"; RC=$?
check "#2076 without the shared reader the scan refuses" "$([ "$RC" -eq 2 ] && echo ok || echo "exit $RC: $OUT")"
says "#2076 and names the reader it could not load" "$OUT" "lib/shell-words.py could not be loaded"
printf 'raise RuntimeError("broken on purpose")\n' > "$NOREADER/lib/shell-words.py"
OUT="$(python3 "$NOREADER/scan-subshell-globals.py" --root "$NOREADER/tree" --baseline "$FIX/baseline.txt" 2>&1)"; RC=$?
check "#2076 a reader that fails to load is refused the same way" "$([ "$RC" -eq 2 ] && echo ok || echo "exit $RC: $OUT")"
says "#2076 and says why" "$OUT" "broken on purpose"
# Its tree sits under the fixture root the tests below scan, so it goes before they run.
rm -rf "$NOREADER"

# Loading the reader leaves no bytecode beside it (claude-config#2076). Python caches what it loads
# by path in lib/__pycache__ unless told not to, and test-push-scope.sh asserts lib/ holds no
# shell-words bytecode (#1017), so one run of this scan failed that suite on every later run.
# Measured in a copy of the hooks, never the real lib/, so a sibling run cannot race the count.
PYC="$FIX/pyc"
mkdir -p "$PYC/lib" "$PYC/tree"
cp "$SCAN" "$PYC/scan-subshell-globals.py"
cp "$DIR/lib/ratchet.py" "$DIR/lib/shell_code_lines.py" "$DIR/lib/shell-words.py" "$PYC/lib/"
printf 'f(){\n  local x=1\n}\nv="$(f)"\n' > "$PYC/tree/a.sh"
OUT="$(python3 "$PYC/scan-subshell-globals.py" --root "$PYC/tree" --baseline "$FIX/baseline.txt" 2>&1)"; RC=$?
check "#2076 control: the copied scan ran and judged its tree" "$([ "$RC" -eq 0 ] && echo ok || echo "exit $RC: $OUT")"
_pyc="$(ls "$PYC/lib/__pycache__" 2>/dev/null | grep -c '^shell-words' || true)"
check "#2076 the scan leaves no shell-words bytecode in lib/" "$([ "$_pyc" = 0 ] && echo ok || echo "$_pyc shell-words bytecode file(s) left in lib/__pycache__")"
rm -rf "$PYC"

# A body the reader cannot read is never skipped in silence (claude-config#2076). Before, such a
# function came back with no names and was counted with the clean ones, so a tree the reader had
# stopped understanding read as a tree with nothing wrong in it (L10, L11). Each is listed with its
# file, line and what the reader could not close, and the count is said on every run, zero too. It
# does not fail the scan on its own: the limit is the reader's, not the code's, and the shell may
# well run it (a quote the shell closes further down than the function's own closing brace).
cat > "$FIX/a.sh" <<'EOF'
ok(){
  local x=1
  printf '%s' "$x"
}
open_subst(){
  x=$(echo a
}
v="$(ok)"; w="$(open_subst)"; z="$(open_quote)"
open_quote(){
  y="abc
}
EOF
run
check "#2076 a body the reader cannot read does not fail the scan on its own" "$([ "$RC" -eq 0 ] && echo ok || echo "exit $RC: $OUT")"
says "#2076 and the count of them is said" "$OUT" "the command reader could not read 2 function bodies"
says "#2076 and one left open by a substitution is named" "$OUT" "a.sh:5  open_subst: a substitution, group or heredoc opened in it never closes"
says "#2076 and one left open by a quote is named, with the quote's line" "$OUT" "a.sh:9  open_quote: the quote opened on line 10 never closes"
printf 'f(){\n  local x=1\n}\nv="$(f)"\n' > "$FIX/a.sh"
run
says "#2076 and a tree with none says so" "$OUT" "the command reader could not read 0 function bodies"

echo "scan subshell globals: the baseline is a ratchet in both directions"

cat > "$FIX/a.sh" <<'EOF'
ANSWER=""
read_cap(){
  ANSWER="x"
  printf 'y'
}
cap="$(read_cap)"
EOF
printf 'a.sh: 1\n' > "$FIX/baseline.txt"
run
check "a finding the baseline already records does not fail the scan" "$([ "$RC" -eq 0 ] && echo ok || echo "exit $RC: $OUT")"
printf 'a.sh: 2\n' > "$FIX/baseline.txt"
run
check "a baseline claiming more than the file has is refused" "$([ "$RC" -ne 0 ] && echo ok || echo "exit $RC")"
says "and says the number is stale" "$OUT" "stale"

# A file this cannot OPEN is not a file with nothing in it. Returning "nothing judged, no
# findings" would make an unreadable file indistinguishable from a clean one, and the count it
# feeds is the whole verdict (L10, L11, L215).
UNREAD="$FIX/unreadable"; mkdir -p "$UNREAD"
printf 'echo hi\n' > "$UNREAD/x.sh"
chmod 000 "$UNREAD/x.sh"
printf '# empty\n' > "$UNREAD/baseline.txt"
OUT="$(python3 "$SCAN" --root "$UNREAD" --baseline "$UNREAD/baseline.txt" 2>&1)"; RC=$?
chmod 644 "$UNREAD"/*.sh 2>/dev/null || true
check "a file it cannot read is a finding, not a clean result" "$([ "$RC" -ne 0 ] && echo ok || echo "exit $RC: $OUT")"
says "and it says the file could not be read" "$OUT" "could not be read"

EMPTY="$FIX/empty"; mkdir -p "$EMPTY"
OUT="$(python3 "$SCAN" --root "$EMPTY" --baseline "$FIX/baseline.txt" 2>&1)"; RC=$?
check "a run that found no sources refuses rather than passing" "$([ "$RC" -eq 2 ] && echo ok || echo "exit $RC")"
OUT="$(python3 "$SCAN" --root "$FIX" --baseline "$FIX/no-such-baseline.txt" 2>&1)"; RC=$?
check "a missing baseline refuses rather than treating every finding as new" "$([ "$RC" -eq 2 ] && echo ok || echo "exit $RC")"

echo "scan subshell globals: one verdict whatever --root names (claude-config#443)"

# #443 was reported as this scan being red on one Mac and green in CI. It was not the Mac: the
# report ran it with `--root payload`, the suite runs it with `--root .`, and the findings were
# keyed relative to whatever --root named while the baseline is written relative to the checkout.
# So the SAME tree gave two verdicts: every recorded file read as newly grown under one spelling
# of its path and as stale under the other. Reproduced identically on python 3.9, 3.11 and 3.14.
# A mini checkout, marked by `.git` the way a real one is, with a finding in each of two folders.
MINI="$FIX/mini"; mkdir -p "$MINI/.git" "$MINI/sub" "$MINI/other"
cat > "$MINI/sub/a.sh" <<'EOF'
ANSWER=""
read_cap(){
  ANSWER="x"
  printf 'y'
}
cap="$(read_cap)"
EOF
cp "$MINI/sub/a.sh" "$MINI/other/b.sh"
printf 'sub/a.sh: 1\nother/b.sh: 1\n' > "$MINI/baseline.txt"
OUT="$(python3 "$SCAN" --root "$MINI" --baseline "$MINI/baseline.txt" 2>&1)"; RC=$?
check "the whole checkout agrees with its baseline" "$([ "$RC" -eq 0 ] && echo ok || echo "exit $RC: $OUT")"
OUT="$(python3 "$SCAN" --root "$MINI/sub" --baseline "$MINI/baseline.txt" 2>&1)"; RC=$?
check "and so does one folder of it, scanned alone" "$([ "$RC" -eq 0 ] && echo ok || echo "exit $RC: $OUT")"
says "and it names the finding by its path in the checkout" "$OUT" "sub/a.sh:2"
# The entry for the folder it did NOT read was not measured, so it may be neither passed nor
# called stale; it is said out loud as not judged (L11).
says "and says which baseline entry it did not judge" "$OUT" "not judged: other/b.sh"
# Scoping must not swallow the finding it exists for: the folder scanned alone still fails when
# its own file grows past the baseline.
printf 'sub/a.sh: 0\nother/b.sh: 1\n' > "$MINI/baseline.txt"
OUT="$(python3 "$SCAN" --root "$MINI/sub" --baseline "$MINI/baseline.txt" 2>&1)"; RC=$?
check "a folder scanned alone still fails on its own growth" "$([ "$RC" -eq 1 ] && echo ok || echo "exit $RC: $OUT")"

echo "scan subshell globals: and the real tree it ships to guard"

# The exact command #443 reported, against the real tree.
OUT="$(cd "$REPO" && python3 "$SCAN" --root payload --baseline payload/hooks/subshell-globals.txt 2>&1)"; RC=$?
check "the real tree scanned as payload/ alone agrees with the baseline" "$([ "$RC" -eq 0 ] && echo ok || echo "exit $RC: $OUT")"

OUT="$(cd "$REPO" && python3 "$SCAN" --root . 2>&1)"; RC=$?
check "the real tree agrees with its own baseline" "$([ "$RC" -eq 0 ] && echo ok || echo "exit $RC: $OUT")"
_considered="$(printf '%s\n' "$OUT" | sed -n 's/^scan-subshell-globals: \([0-9]*\) function.*/\1/p')"
check "and it really considered the repo's functions, rather than none" "$([ "${_considered:-0}" -gt 20 ] && echo ok || echo "considered ${_considered:-0}")"
# The defect this scan found on the day it shipped must stay fixed: tip_payload_dir recorded its
# answer in a global its only caller read through a command substitution, so the cleanup that reads
# that variable could never fire and every comparison left a copy of the whole shared payload
# behind. Asserted here rather than only in the sync suite, because this is the scan that found it.
# Matched with `case` over a variable, never piped into `grep -q`: under pipefail a short
# circuiting consumer kills its producer and the pipeline reports a failure that never happened
# (L183), and this repo ratchets the count of such pipelines down rather than up.
case "$OUT" in
  *"claude-sync:"*) check "and claude-sync no longer holds the finding it found there" "claude-sync is flagged again" ;;
  *) check "and claude-sync no longer holds the finding it found there" ok ;;
esac

echo
# A NESTED CHECKOUT IS A SECOND COPY OF THE SAME TREE (claude-config#504, L234). This walk prunes
# .git, node_modules and __pycache__ and nothing else, so a worktree under .claude/worktrees is
# counted as though its files were the repository's own. Measured 2026-09-19 with two worktrees
# open: 166 shell files became 498, every tree wide count roughly tripled, and both ratchets went
# red on a tree nobody had changed. That is what made `claude-sync recheck` record this Mac as
# broken from one checkout and healthy from another, because only one of them had worktrees in it.
NEST="$FIX/nested"
mkdir -p "$NEST/payload/hooks" "$NEST/.claude/worktrees/copy/payload/hooks"
cat > "$NEST/payload/hooks/test-outer.sh" <<'NESTEOF'
#!/usr/bin/env bash
out="$(some_command)"
! grep -q 'a needle that is present here' <<< "$out" && echo ok
echo 'a needle that is present here'
NESTEOF
cp "$NEST/payload/hooks/test-outer.sh" "$NEST/.claude/worktrees/copy/payload/hooks/test-outer.sh"
nest_out="$(python3 "$SCAN" --root "$NEST" --baseline /dev/null 2>&1 || true)"
# Parameter expansion, not a pipeline: a short circuiting consumer like `head -1` kills the
# producer feeding it under pipefail, and the pipeline then reports a failure that never happened
# (L183). test-pipefail-shortcircuit.sh caught this exact line, and it is the second time today.
nest_n="${nest_out#*across }"
nest_n="${nest_n%% *}"
case "$nest_n" in ''|*[!0-9]*) nest_n=0 ;; esac
[ "$nest_n" = "1" ] \
  && check "a nested checkout is not scanned as part of the tree above it" ok \
  || check "a nested checkout is not scanned as part of the tree above it" "it counted $nest_n file(s), so the copy under .claude/worktrees was counted too: $nest_out"

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
