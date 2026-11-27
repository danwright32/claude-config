#!/usr/bin/env bash
# Tests for a file the Slack drafts gate reads through a variable inside a shell function
# (claude-config#3497).
#
# A script that set a variable to the name of a script that posts and ran it through that variable
# was refused where the two commands stood at its top level, and allowed where they stood in a
# function the script then called. Measured 2026-11-22 at 8b4e006b0f and again 2026-11-26 on main at
# 6c4cee7247, through this wrapper: `bash case.sh`, with posts.sh beside it, exit 0.
#
# The gate works out the value in both places (sh_locals has followed a NAME=value in a function
# body since #2683). What differed was the directory: a function runs wherever it is called from,
# so the walk does not vouch for the directory inside one, and a value that is a relative path was
# then left as the word the script wrote, which names no file, so nothing was read. The same path
# written out in the same function was read all along, against the directory the reader follows.
# A value worked out is now read there too, in a third reading, made after the two before it found
# nothing, that can only refuse more.
#
# Kept apart from test-slack-drafts-only-gate-scripts.sh, which covers a script that posts, so that
# suite does not grow (the precedent is test-slack-drafts-comment-start.sh); the helpers below are
# copied from it as they are, so a case here is driven the same way: a hook payload piped into
# slack-drafts-only-gate.sh, exit 0 allowed and 2 refused, the reason on stderr. Nothing a case names
# is ever run, and no file here holds a token, a webhook address or a channel.
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/slack-drafts-only-gate.sh"
unset SLACK_GATE_UNWORKED_PATHS

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }

if [ ! -f "$HOOK" ]; then
  echo "FAIL: there is no slack-drafts-only-gate.sh beside this suite at $DIR, so no Slack send is refused."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
fi
# The reading this suite holds is lib/function-values.py's, which the gate loads at its start.
if [ ! -f "$DIR/lib/function-values.py" ]; then
  echo "FAIL: there is no lib/function-values.py beside this suite at $DIR, so the gate cannot read a function's values."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
fi

T="$(mktemp -d "${TMPDIR:-/tmp}/slack-gate.XXXXXXXX")" || exit 1
case "${T%/}" in ''|/|"${HOME%/}") echo "refusing to run: throwaway directory came back as '$T'" >&2; exit 2 ;; esac
trap 'rm -rf "$T"' EXIT
# Every case runs with a judgement cache of its own, never this Mac's (claude-config#2918).
export SLACK_GATE_CACHE_DIR="$T/gate-cache"
unset SLACK_GATE_CACHE_TRACE

# payload <tool name> <tool_input JSON> [cwd]: one PreToolUse payload in the measured shape.
payload() {
  python3 -c '
import json, sys
tool, inp, cwd = sys.argv[1], json.loads(sys.argv[2]), sys.argv[3]
print(json.dumps({"session_id": "f6017250-8f33-47ac-bbb2-b82a7c319d0d",
                  "transcript_path": "/tmp/transcript.jsonl", "cwd": cwd,
                  "permission_mode": "auto", "hook_event_name": "PreToolUse", "tool_name": tool,
                  "tool_input": inp, "tool_use_id": "toolu_01X4Qw7JnfYswF7UVX94Z4Sy"}))
' "$1" "$2" "${3:-$T}"
}
bash_input() { python3 -c 'import json, sys; print(json.dumps({"command": sys.argv[1], "description": "d"}))' "$1"; }

RC=0; OUT=""; ERR=""
run_raw() { # run_raw <stdin text>
  local errf; errf="$(mktemp "${TMPDIR:-/tmp}/slack-gate-err.XXXXXXXX")"
  OUT="$(printf '%s' "$1" | bash "$HOOK" 2>"$errf")"; RC=$?
  ERR="$(cat "$errf")"; rm -f "$errf"
}
run_bash() { run_raw "$(payload Bash "$(bash_input "$1")" "${2:-$T}")"; }

refused() { if [ "$RC" -eq 2 ]; then check "$1" ok; else check "$1" "exit $RC, stdout: ${OUT:0:200}, stderr: ${ERR:0:300}"; fi; }
allowed() { if [ "$RC" -eq 0 ] && [ -z "$(printf '%s%s' "$OUT" "$ERR" | tr -d '[:space:]')" ]; then check "$1" ok
            else check "$1" "exit $RC, stdout: ${OUT:0:200}, stderr: ${ERR:0:300}"; fi; }
says() { case "$ERR" in *"$2"*) check "$1" ok ;; *) check "$1" "stderr did not say '$2': ${ERR:0:400}" ;; esac; }

NL=$'\n'
shown() { printf '%s' "${1//$NL/ (line break) }"; }
POSTS="REFUSED: this command posts to Slack"

# The folder every case runs in: a script that posts and one that does not, each as a shell script
# and a Python one, and the same four a folder down.
FV="$T/fv"
mkdir -p "$FV/lib"
for at in "$FV" "$FV/lib"; do
  printf '%s\n' 'curl -s -X POST -d text=hi https://slack.com/api/chat.postMessage' > "$at/posts.sh"
  printf '%s\n' 'echo hi' > "$at/quiet.sh"
  printf '%s\n' 'import urllib.request' "urllib.request.urlopen('https://slack.com/api/chat.postMessage', b'text=hi')" > "$at/posts.py"
  printf '%s\n' 'print("hi")' > "$at/quiet.py"
done
chmod +x "$FV/posts.sh" "$FV/quiet.sh"
# script <line>...: the script the next case judges, case.sh, one line for each word.
script() { printf '%s\n' "$@" > "$FV/case.sh"; }
judge_script() { run_bash "bash case.sh" "$FV"; }

echo "slack drafts only: a file run through a variable is read inside a function as at the top level (claude-config#3497)"

# The controls, refused before this change: the two commands at the top level, the path written out
# in the function, and a value that is a whole path, which needs no directory.
script 'kept=posts.sh' 'bash "$kept"'
judge_script
refused "the control: set and run at the top level, a script that posts is refused"
says "the control: as the post it is" "$POSTS"
script 'run() {' '  bash posts.sh' '}' 'run'
judge_script
refused "the control: written out in a function, a script that posts is refused"
script 'run() {' "  kept=$FV/posts.sh" '  bash "$kept"' '}' 'run'
judge_script
refused "the control: through a variable holding a whole path, in a function, a script that posts is refused"

# The measured shape, and the ways a function body sets and runs it.
while IFS= read -r body; do
  [ -n "$body" ] || continue
  body="${body//@NL@/$NL}"
  for file in posts quiet; do
    printf '%s\n' "${body//@F@/$file}" > "$FV/case.sh"
    judge_script
    if [ "$file" = posts ]; then
      refused "a script that posts, run through a variable in a function, is refused: $(shown "$body")"
      says "as the post it is, the answer the top level gets: $(shown "$body")" "$POSTS"
    else
      allowed "the same function running a script that does not post passes: $(shown "$body")"
    fi
  done
done <<'SHAPES'
run() {@NL@  kept=@F@.sh@NL@  bash "$kept"@NL@}@NL@run
run() {@NL@  local kept=@F@.sh@NL@  bash "$kept"@NL@}@NL@run
run() { kept=@F@.sh; bash "$kept"; }@NL@run
function run {@NL@  kept=@F@.sh@NL@  bash "$kept"@NL@}@NL@run
run() {@NL@  kept=@F@.sh@NL@  sh "$kept"@NL@}@NL@run
run() {@NL@  kept=@F@.py@NL@  python3 "$kept"@NL@}@NL@run
run() {@NL@  kept=lib/@F@.sh@NL@  bash "$kept"@NL@}@NL@run
run() {@NL@  kept=./@F@.sh@NL@  "$kept"@NL@}@NL@run
run() {@NL@  kept=@F@.sh@NL@  echo start@NL@  bash "$kept" --flag@NL@}@NL@echo first@NL@run
kept=@F@.sh@NL@run() {@NL@  bash "$kept"@NL@}@NL@run
SHAPES

# Typed as the command itself, not a script on disk.
run_bash 'run() { kept=posts.sh; bash "$kept"; }; run' "$FV"
refused "typed as a command, a script that posts run through a variable in a function is refused"
says "typed as a command: as the post it is" "$POSTS"
run_bash 'run() { kept=quiet.sh; bash "$kept"; }; run' "$FV"
allowed "typed as a command, the same function running a script that does not post passes"

# Set in a function and run outside it, after the call or in another function. The walk holds no
# value there (a call leaves every name its body binds unknown), so the file is read with the one
# value a function body gives the name. The function may not have run by then, so this is no
# finding of a post: the gate says it could not check, and what it read. The same for a value
# built from another the body sets, which the walk does not follow inside a body (the last shape).
while IFS= read -r body; do
  [ -n "$body" ] || continue
  body="${body//@NL@/$NL}"
  for file in posts quiet; do
    printf '%s\n' "${body//@F@/$file}" > "$FV/case.sh"
    judge_script
    if [ "$file" = posts ]; then
      refused "a script that posts, run through a variable only a function sets, is refused: $(shown "$body")"
      says "as a check it could not make: $(shown "$body")" "REFUSED: the gate could not check whether this command posts to Slack"
      says "naming the variable and what was read: $(shown "$body")" "runs a file through \$kept, whose value the gate cannot follow to that command: only a function of the same text sets it"
    else
      allowed "the same script running a file that does not post passes: $(shown "$body")"
    fi
  done
done <<'SHAPES'
run() {@NL@  kept=@F@.sh@NL@}@NL@run@NL@bash "$kept"
set_it() { kept=@F@.sh; }@NL@run_it() { bash "$kept"; }@NL@set_it@NL@run_it
set_it() {@NL@  kept=@F@.py@NL@}@NL@set_it@NL@python3 "$kept" --flag
run() {@NL@  dir=lib@NL@  kept="$dir/@F@.sh"@NL@  bash "$kept"@NL@}@NL@run
SHAPES

# A file sourced that way was refused before, as a path the gate cannot work out (#2538), and is.
script 'run() {' '  kept=posts.sh' '  . "$kept"' '}' 'run'
judge_script
refused "the control: a script that posts, sourced through a variable in a function, is refused as before"

# A value the function does not hold for certain is not read as though it did: where another
# command of the script binds the name too, the walk gives no value, and the answer is the one it
# was (a file run by a path the gate cannot work out is let through until #2683's switch is on).
script 'run() {' '  kept=posts.sh' '  read -r kept' '  bash "$kept"' '}' 'run'
judge_script
allowed "a name the function reads in after setting it is not followed, as before"

# A name declared with a bare `local` and set on a line after it, the ordinary way to write a
# function. The declaration counted as something else that binds the name, so the name got no
# value and the script it ran was read by nobody: allowed on main at 969bb0fce0 and at 5019457df1,
# the first build of this change (the review's probe b02, 2026-11-27). A bare local gives the
# name no value, so it is no second one. The walk holds none for it at the command, so the answer
# is the one a value only a function sets gets: a check the gate could not make.
while IFS= read -r body; do
  [ -n "$body" ] || continue
  body="${body//@NL@/$NL}"
  for file in posts quiet; do
    printf '%s\n' "${body//@F@/$file}" > "$FV/case.sh"
    judge_script
    if [ "$file" = posts ]; then
      refused "a script that posts, run through a variable a bare local declares and the next line sets, is refused: $(shown "$body")"
      says "as a check it could not make: $(shown "$body")" "REFUSED: the gate could not check whether this command posts to Slack"
      says "naming the variable: $(shown "$body")" "runs a file through \$kept, whose value the gate cannot follow to that command"
    else
      allowed "the same function running a script that does not post passes: $(shown "$body")"
    fi
  done
done <<'SHAPES'
run() { local kept; kept=@F@.sh; bash "$kept"; }; run
run() {@NL@  local kept@NL@  kept=@F@.sh@NL@  bash "$kept"@NL@}@NL@run
run() {@NL@  local other kept@NL@  kept=lib/@F@.sh@NL@  bash "$kept"@NL@}@NL@run
set_it() {@NL@  local kept@NL@  kept=@F@.py@NL@  python3 "$kept"@NL@}@NL@set_it
SHAPES
# The same declaration in its other ordinary spellings: `local kept=""`, `local kept=''` and
# `local kept=`, which give the name an empty value, and `declare kept` and `typeset kept`, which
# in a function declare it as local does. The empty value counted as a second value that differs
# from the one set on the next line, and declare and typeset as something else that binds the
# name, so the name got no value and the script it ran was read by nobody: allowed on main and at
# 010c05a1b0 (the second review's probes d4b, d4, d3 and d3b, 2026-11-27). An empty value names no
# file, so it is no second one, and a bare declare or typeset is read as a bare local is.
while IFS= read -r body; do
  [ -n "$body" ] || continue
  body="${body//@NL@/$NL}"
  for file in posts quiet; do
    printf '%s\n' "${body//@F@/$file}" > "$FV/case.sh"
    judge_script
    if [ "$file" = posts ]; then
      refused "a script that posts, run through a variable declared empty or by declare or typeset and set on the next line, is refused: $(shown "$body")"
      says "as a check it could not make: $(shown "$body")" "REFUSED: the gate could not check whether this command posts to Slack"
      says "naming the variable: $(shown "$body")" "runs a file through \$kept, whose value the gate cannot follow to that command"
    else
      allowed "the same function running a script that does not post passes: $(shown "$body")"
    fi
  done
done <<'SHAPES'
run() {@NL@  local kept=""@NL@  kept=@F@.sh@NL@  bash "$kept"@NL@}@NL@run
run() {@NL@  local kept=''@NL@  kept=@F@.sh@NL@  bash "$kept"@NL@}@NL@run
run() {@NL@  local kept=@NL@  kept=@F@.sh@NL@  bash "$kept"@NL@}@NL@run
run() {@NL@  declare kept@NL@  kept=@F@.sh@NL@  bash "$kept"@NL@}@NL@run
run() {@NL@  typeset kept@NL@  kept=@F@.sh@NL@  bash "$kept"@NL@}@NL@run
run() { local kept=""; kept=@F@.sh; bash "$kept"; }; run
set_it() {@NL@  typeset kept other@NL@  kept=@F@.py@NL@  python3 "$kept"@NL@}@NL@set_it
SHAPES
# What those spellings do not excuse: a name the body goes on to read in.
script 'run() {' '  declare kept' '  kept=posts.sh' '  read -r kept' '  bash "$kept"' '}' 'run'
judge_script
allowed "a name declared with a bare declare, set, and then read in is not followed, as before"
# What a bare local does not excuse: a name the body goes on to read in is still one the gate
# holds no value for, and the answer is the one it was.
script 'run() {' '  local kept' '  kept=posts.sh' '  read -r kept' '  bash "$kept"' '}' 'run'
judge_script
allowed "a name declared with a bare local, set, and then read in is not followed, as before"
# Not covered, and so not asserted either way: a name a function sets that the top level sets as
# well (`kept=""` or `kept=quiet.sh` above the function; the review's probes b08 and b01), and a
# name a local declares with an option (`local -a kept`).

echo "slack drafts only: a script that runs itself in a function is not read a second time, and anything else is read as before (claude-config#3497)"

# test-pipefail-shortcircuit.sh runs itself inside a function (`sc_run(){ ... bash
# "${BASH_SOURCE[0]}" 2>&1; }`). Once a function's values were written out, the gate read that
# suite a second time, as a file it runs, and that reading is made with the directory unknown (a
# function runs wherever it is called from), so the path on the suite's own first source line,
# built from `cd ... && pwd` on its BASH_SOURCE, could not be worked out there: refused as a check
# the gate could not make, four times in the 61,284 commands this Mac had recorded, where main
# passed all four (measured 2026-11-26 at 47094abfaa). The file is the one being read, handed
# nothing, by the same shell, in the same folder: a second reading of it can find nothing the first
# does not. So that one command is left out of the wider reading, and only that one. Each control
# below is a neighbour that is still read, and was seen to fail with the leaving out made too wide
# (red-3.txt in the builder's notes).
IDIOM='. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/quiet.sh" || exit 1'
ONCE='if [ -z "${NESTED:-}" ]; then'
COULD_NOT="REFUSED: the gate could not check whether this command posts to Slack"
mkdir -p "$FV/other"
ln -s ../case.sh "$FV/other/alias.sh"
printf '%s\n' 'echo hi' > "$FV/step.sh"
cp "$FV/posts.sh" "$FV/lib/step.sh"
cp "$FV/posts.py" "$FV/lib/json.py"

script "$IDIOM" 'again() { NESTED=1 SEEN="$PWD" bash "${BASH_SOURCE[0]}" 2>&1; }' "$ONCE" '  again' 'fi' 'echo done'
judge_script
allowed "a script that runs itself in a function, by its own BASH_SOURCE, passes"
script "$IDIOM" 'again() {' '  self=./case.sh' '  NESTED=1 bash "$self"' '}' "$ONCE" '  again' 'fi'
judge_script
allowed "a script that runs itself in a function, by another spelling of the same path, passes"

# What main reads, it reads still: the script run again at its top level, where the directory is
# known and the second reading works line 1 out, and the script named by a literal path in a
# function, which main refuses and this change does not touch (it is the first reading's).
script "$IDIOM" "$ONCE" '  NESTED=1 bash "${BASH_SOURCE[0]}"' 'fi'
judge_script
allowed "the control: a script that runs itself at its top level passes, as on main"
script "$IDIOM" 'again() { NESTED=1 bash case.sh; }' "$ONCE" '  again' 'fi'
judge_script
refused "the control: a script that runs itself in a function by a literal path is refused, as on main"
says "the control: as a check it could not make, as on main" "$COULD_NOT"

# A different file is followed, beside the same first line.
script "$IDIOM" 'run() {' '  kept=posts.sh' '  bash "$kept"' '}' 'run'
judge_script
refused "a script whose function runs a different file that posts is refused"
says "a different file: as the post it is" "$POSTS"

# Itself reached through another file: that file is followed, and what it runs.
printf '%s\n' "$ONCE" '  NESTED=1 bash case.sh' 'fi' 'bash posts.sh' > "$FV/back.sh"
script 'run() {' '  other=back.sh' '  bash "$other"' '}' 'run'
judge_script
refused "a script that reaches itself through another file, which also posts, is refused"
says "through another file: that file is the one read" "the script back.sh runs a command that posts"
says "through another file: as the post it is" "$POSTS"
printf '%s\n' "$ONCE" '  NESTED=1 bash case.sh' 'fi' 'echo back' > "$FV/back.sh"
script "$IDIOM" 'run() {' '  other=back.sh' '  bash "$other"' '}' 'run'
judge_script
refused "a script that reaches itself through another file is followed through that file, as before"
says "through another file: the script is read again from there" "the script back.sh runs a command that posts: the script case.sh"
rm -f "$FV/back.sh"

# The same file by a name the gate cannot prove is the same: a symlink in another folder, beside
# which `dirname` finds another lib. Read as before.
script "$IDIOM" 'again() {' '  self=other/alias.sh' '  NESTED=1 bash "$self"' '}' "$ONCE" '  again' 'fi'
judge_script
refused "a script that runs itself in a function through a symlink in another folder is read as before"
says "through a symlink: read by that name" "the script other/alias.sh"

# Handed a word, it is not the reading already made: the word is a file it runs.
script 'again() {' '  arg=posts.sh' '  bash "${BASH_SOURCE[0]}" "$arg"' '}' 'if [ -n "${1:-}" ]; then' '  bash "$1"' 'else' '  again' 'fi'
judge_script
refused "a script that hands itself a file that posts, in a function, is refused"

# By another shell, or with its input given: as before.
script "$IDIOM" 'again() { NESTED=1 zsh "${BASH_SOURCE[0]}"; }' "$ONCE" '  again' 'fi'
judge_script
refused "a script a function hands to another shell is read as before"
script "$IDIOM" 'again() { NESTED=1 bash "${BASH_SOURCE[0]}" < lib/quiet.sh; }' "$ONCE" '  again' 'fi'
judge_script
refused "a script a function runs with its input given is read as before"

# After the script wrote a file, changed folder or exported where Python looks, a second run of it
# is not the reading already made: each of these posts only the second time round.
script 'bash gen.sh' 'cp posts.sh gen.sh' 'again() { NESTED=1 bash "${BASH_SOURCE[0]}"; }' "$ONCE" '  again' 'fi'
judge_script
refused "a script that writes a file that posts, then runs itself in a function, is refused"
says "after a write: the file written is the one named" "gen.sh"
script 'bash step.sh' "set_it() { self=$FV/case.sh; }" "$ONCE" '  set_it' '  cd lib' '  NESTED=1 bash "$self"' 'fi'
judge_script
refused "a script that changes folder, then runs itself through a name a function sets, is refused"
says "after a cd: the file found in the new folder is the one named" "step.sh"
script "python3 -c 'import json'" 'export PYTHONPATH=lib' 'again() { NESTED=1 bash "${BASH_SOURCE[0]}"; }' "$ONCE" '  again' 'fi'
judge_script
refused "a script that exports where Python looks, then runs itself in a function, is refused"
says "after an export: the module found there is the one named" "which imports json"

echo "slack drafts only: the values a function's bodies set are worked out once for a script (claude-config#3497)"

# The work, counted, which no load can move (L290). The first build of this change worked each
# name out afresh, over every command of the text, for every command that used it: one
# claude-sync lesson, judged in 2.7 seconds of processor time on main, ran out of the gate's 11
# seconds and was refused (measured 2026-11-26 at 90a4992cba, through the gate's wrapper). With
# that mended it still asked what else in the text binds a name whose value it had not worked out,
# the dearer question, whose answer changes nothing there: 0.45 seconds more for the same lesson.
# The script below has 200 functions, each running a file through a name its body sets from $1,
# which no reading can work out, and two commands the wider reading does change. Counted beneath
# the gate: how often a command is read as an assignment, and how often what else binds one of
# those 200 names is asked.
cat > "$T/counted.py" <<'PY'
import importlib.util, os, sys

gate_path, folder = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location("gate", gate_path)
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)
spec = importlib.util.spec_from_file_location("shell_words", os.path.join(os.path.dirname(gate_path), "lib", "shell-words.py"))
sw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sw)
gate.remember_readings(sw)

N = 200
lines = []
for i in range(N):
    lines += ["f%d() {" % i, '  local dir%d="$1"' % i, "  local n%d=quiet.sh" % i, "  echo start",
              '  bash "$dir%d/quiet.sh"' % i, "}"]
lines += ["g() {", "  kept=quiet.sh", '  bash "$kept"', "}", "h() { later=quiet.sh; }", "h", 'bash "$later"']
text = "\n".join(lines) + "\n"
counts = {"assignment": 0, "binds": 0}
plain_assignment, plain_binds = gate.Judge.sh_assignment, gate.Judge.sh_binds
def sh_assignment(self, head):
    counts["assignment"] += 1
    return plain_assignment(self, head)
def sh_binds(name, text, allowed=0):
    counts["binds"] += name.startswith("dir")
    return plain_binds(name, text, allowed)
gate.Judge.sh_assignment, gate.Judge.sh_binds = sh_assignment, staticmethod(sh_binds)
judge = gate.Judge(sw)
wrong = []
try:
    got = judge.line(text, folder, 0, text)
except BaseException as e:  # the gate's own time running out among them, which is the finding
    got = None
    wrong.append("judging it ended in %s: %s" % (type(e).__name__, str(e)[:200]))
if got is not None:
    wrong.append("a script that runs only quiet files was refused: %s" % got[:200])
# 1,008 readings as an assignment with the fix, about five for each function, and no asking what
# else binds one of the 200 names; at 90a4992cba it was 241,806 readings, every command of every
# body once more for each name, and 200 askings (both measured 2026-11-26).
if counts["assignment"] > 10 * N:
    wrong.append("a command was read as an assignment %d times for %d functions, more than %d"
                 % (counts["assignment"], N, 10 * N))
if counts["binds"]:
    wrong.append("what else binds a name was asked %d times of the %d names whose value is not worked out"
                 % (counts["binds"], N))
print("; ".join(wrong) or "ok")
print("counted assignment=%d binds=%d" % (counts["assignment"], counts["binds"]))
PY
counted="$(python3 -B "$T/counted.py" "$DIR/slack_drafts_only_gate.py" "$FV" 2>&1)"
check "reading a function's values does not grow with the square of a script's functions" "$(printf '%s\n' "$counted" | head -n 1)"
echo "  $(printf '%s\n' "$counted" | grep '^counted ' || echo 'no count was printed')"

echo

echo "passed: $pass, failed: $fail"

printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"

[ "$fail" -eq 0 ]
