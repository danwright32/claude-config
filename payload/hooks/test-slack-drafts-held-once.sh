#!/usr/bin/env bash
# Tests that the Slack drafts gate reads what is written around a program once for each text
# (claude-config#3406). A program that runs its input inside a function's body is fed by whatever
# calls the function, so the gate looks through the text for the function's calls (held_calls in
# lib/sh-walk-shapes.py, claude-config#3229). It did that afresh for every such function: each
# command of the text was cut into its words once for each function, and the text's commands were
# copied once for each look. Judging `bash tests/test-claude-sync.sh` that was 152,000 readings of
# 8,500 commands, a twentieth of the judgement, part of what took the cold cost case past its limit.
#
# A count, never a time: a time measures the Mac's load. The gate's own code runs, with the two
# readings counted by a copy that wraps them, as test-slack-drafts-code-loaders.sh wraps one to make
# it fail. Kept apart from that suite so it does not grow past its wall clock; the helpers are copied
# from test-slack-drafts-made-lines.sh as they are. Nothing a case names is ever run.
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

T="$(mktemp -d "${TMPDIR:-/tmp}/slack-gate.XXXXXXXX")" || exit 1
case "${T%/}" in ''|/|"${HOME%/}") echo "refusing to run: throwaway directory came back as '$T'" >&2; exit 2 ;; esac
trap 'rm -rf "$T"' EXIT
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

refused() { if [ "$RC" -eq 2 ]; then check "$1" ok; else check "$1" "exit $RC, stdout: ${OUT:0:200}, stderr: ${ERR:0:300}"; fi; }
allowed() { if [ "$RC" -eq 0 ] && [ -z "$(printf '%s%s' "$OUT" "$ERR" | tr -d '[:space:]')" ]; then check "$1" ok
            else check "$1" "exit $RC, stdout: ${OUT:0:200}, stderr: ${ERR:0:300}"; fi; }
says() { case "$ERR" in *"$2"*) check "$1" ok ;; *) check "$1" "stderr did not say '$2': ${ERR:0:900}" ;; esac; }

# The folder the cases are judged from, by its real path, as a checkout is.
S="$(cd "$T" && pwd -P)/src"
mkdir -p "$S"
printf '%s\n' '#!/bin/bash' 'echo ok' > "$S/ok.sh"
printf '%s\n' '#!/bin/bash' 'curl -s -X POST -d text=hi https://slack.com/api/chat.postMessage' > "$S/posts.sh"

# The gate's own code with two of its readings counted: how often each command's text is cut into
# its words as written (written_redirs), and how often the commands of a text holding PLAIN are
# asked for (parsed). The counts are written where COUNTS_3406 says once the verdict is printed. A
# text holding UNREADABLE-3406 fails as the shared reader fails on a text it cannot read.
mkdir -p "$T/counting"
cp "$HOOK" "$T/counting/slack-drafts-only-gate.sh"
ln -s "$DIR/lib" "$T/counting/lib"
cat > "$T/counting/slack_drafts_only_gate.py" <<'PY'
import importlib.util, json, os
spec = importlib.util.spec_from_file_location("gate", os.environ["REAL_GATE_3406"])
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)
words, seen = {}, {"parsed": 0, "marked": 0, "names": 0, "shopt": 0}
real_words, real_parsed, real_findall = gate.Judge.written_redirs, gate.Judge.parsed, gate.re.findall
real_search = gate.re.search
def findall(pattern, string, flags=0):
    # A search of the script's whole text for the functions it defines (the Judge's sh_funcs makes
    # two, one for each way a function is written).
    if isinstance(pattern, str) and "function" in pattern and "echo plain-17\n" in string:
        seen["names"] += 1
    return real_findall(pattern, string, flags)
def search(pattern, string, flags=0):
    # A search of the script's whole text for the word shopt.
    if isinstance(pattern, str) and "shopt" in pattern and "echo plain-17\n" in string:
        seen["shopt"] += 1
    return real_search(pattern, string, flags)
gate.re.findall, gate.re.search = findall, search
def written_redirs(self, text):
    words[text] = words.get(text, 0) + 1
    if "UNREADABLE-3406" in text:
        seen["marked"] += 1
        raise self.sw.Unreadable("made to fail by the suite")
    return real_words(self, text)
def parsed(self, s, cwd):
    if "echo plain-17\n" in s:
        seen["parsed"] += 1
    return real_parsed(self, s, cwd)
gate.Judge.written_redirs, gate.Judge.parsed = written_redirs, parsed
try:
    gate.main()
finally:
    with open(os.environ["COUNTS_3406"], "w") as f:
        json.dump(dict(seen, words=words), f)
PY
RC=0; OUT=""; ERR=""
run_counted() { # run_counted <command>: judged from S by the counting copy, from an empty cache of its own
  local errf; errf="$(mktemp "${TMPDIR:-/tmp}/slack-gate-err.XXXXXXXX")"
  rm -f "$T/counts.json"
  OUT="$(payload Bash "$(bash_input "$1")" "$S" | SLACK_GATE_CACHE_DIR="$(mktemp -d "$T/cache.XXXXXX")" \
    REAL_GATE_3406="$DIR/slack_drafts_only_gate.py" COUNTS_3406="$T/counts.json" bash "$T/counting/slack-drafts-only-gate.sh" 2>"$errf")"; RC=$?
  ERR="$(cat "$errf")"; rm -f "$errf"
}
# counted words <a command's text>: how often that text was cut into its words in the last counted
# run; counted parsed: how often the commands of the script's text were asked for; counted marked:
# how often a text holding UNREADABLE-3406 was cut; counted names and counted shopt: how often the
# script's whole text was searched for the functions it defines, and for the word shopt. "none"
# where the run left no counts, so a run that judged nothing is never read as a count of 0.
counted() {
  python3 -c '
import json, sys
try:
    got = json.load(open(sys.argv[1]))
except (OSError, ValueError):
    print("none")
    sys.exit(0)
print(got["words"].get(sys.argv[3], 0) if sys.argv[2] == "words" else got[sys.argv[2]])
' "$T/counts.json" "$@"
}

# script <file> <functions> <the last function's call>: a script of 30 plain commands, then that
# many functions whose body is a shell given no script, pipe or file of its own (so each reads what
# its calls are given), then one call of each, the last as written by the caller.
script() {
  local n
  {
    echo '#!/bin/bash'
    for n in $(seq 1 30); do echo "echo plain-$n"; done
    for n in $(seq 1 "$2"); do echo "reader_$n() { bash; }"; done
    for n in $(seq 1 $(($2 - 1))); do echo "cat ok.sh | reader_$n"; done
    echo "$3"
  } > "$S/$1"
}

echo "slack drafts held once: what is around a program is read once for each text (claude-config#3406)"

# The count's own premise, seen before it is held to anything: the counting copy judges as the gate
# does, the script's commands are cut into words at all, and the counts are of this run.
script two.sh 2 'cat ok.sh | reader_2'
run_counted "bash two.sh"
allowed "#3406 a script of two functions each fed a script that posts nothing passes, judged by the counting copy"
two_words="$(counted words 'echo plain-17')"
two_parsed="$(counted parsed)"
case "$two_words" in ''|none|0) check "#3406 the counting copy counted a plain command of the two function script being cut into words" "it counted '$two_words', so the cases below would hold the gate to nothing" ;;
  *) check "#3406 the counting copy counted a plain command of the two function script being cut into words" ok ;; esac
case "$two_parsed" in ''|none|0) check "#3406 the counting copy counted the two function script's commands being asked for" "it counted '$two_parsed', so the cases below would hold the gate to nothing" ;;
  *) check "#3406 the counting copy counted the two function script's commands being asked for" ok ;; esac

# Six such functions: each plain command is still cut into its words once, where it was once for
# each function, and the script's commands are asked for no more often than with two.
script six.sh 6 'cat ok.sh | reader_6'
run_counted "bash six.sh"
allowed "#3406 a script of six functions each fed a script that posts nothing passes"
six_words="$(counted words 'echo plain-17')"
six_parsed="$(counted parsed)"
if [ "$six_words" = 1 ]; then check "#3406 with six functions whose calls are looked for, a plain command is cut into its words once" ok
else check "#3406 with six functions whose calls are looked for, a plain command is cut into its words once" "it was cut $six_words times (with two functions: $two_words)"; fi
if [ "$six_parsed" != none ] && [ "$six_parsed" = "$two_parsed" ]; then check "#3406 the script's commands are asked for as often with six functions as with two" ok
else check "#3406 the script's commands are asked for as often with six functions as with two" "asked for $six_parsed times with six functions, $two_parsed with two"; fi

# Holding a reading changes no answer. The call of the last function is still found, by its pipe,
# by a file it is given, and past an assignment written before its name.
for call in 'cat posts.sh | reader_6' 'reader_6 < posts.sh' 'V=1 reader_6 < posts.sh'; do
  script fed.sh 6 "$call"
  run_counted "bash fed.sh"
  refused "#3406 the last of six functions handed a script that posts is refused: $call"
  says "#3406 and the refusal is the posting: $call" "chat.postMessage"
done
# A command that only mentions the function's name is no call of it, and one inside the function's
# own body is not looked at (a function calling itself feeds itself nothing new).
for call in 'echo reader_6 < posts.sh' 'cat posts.sh | echo reader_6' 'cat posts.sh | other reader_6'; do
  script quiet.sh 6 "$call"
  run_counted "bash quiet.sh"
  allowed "#3406 a command that only names a function hands it nothing: $call"
done
# A reading that fails. The walk never cut the commands of the function's own body into words, so
# one of them that cannot be read stops nothing: the function handed a script that posts is still
# refused. Held readings that cut every command up front would give up here and let it through.
{
  echo '#!/bin/bash'
  echo 'reader_1() { echo UNREADABLE-3406; bash; }'
  echo 'cat posts.sh | reader_1'
} > "$S/body.sh"
run_counted "bash body.sh"
refused "#3406 a function whose own body holds a command that cannot be cut into words is still refused what its call hands it"
says "#3406 and that refusal is the posting" "chat.postMessage"
if [ "$(counted marked)" = 0 ]; then check "#3406 and that command of the body was never cut into words" ok
else check "#3406 and that command of the body was never cut into words" "it was cut $(counted marked) times"; fi
# Typed, a reading that fails outside the body is an input that cannot be read, as it was.
run_counted "reader_1() { bash; }; echo UNREADABLE-3406; cat ok.sh | reader_1"
refused "#3406 typed, a command that cannot be cut into words beside a function's call is refused"
says "#3406 and that refusal says its input cannot be read" "what that holds cannot be read"

# The functions a text defines are searched for once for each text. Three readings ask for them:
# the walk of the text's variables, the reading of a sed or git command's output (is the name a
# function of the text's own, asked once for each such name) and the reading of the words after a
# program the gate does not know. Each searched the whole text afresh: six searches of the 1.8 MB
# claude-sync suite where one serves. named <file> <more commands>...: 30 plain commands, one
# function, then those commands.
named() {
  local f="$1" n
  shift
  {
    echo '#!/bin/bash'
    for n in $(seq 1 30); do echo "echo plain-$n"; done
    echo 'helper() { echo ok; }'
    printf '%s\n' "$@"
  } > "$S/$f"
}
named walked.sh 'helper'
run_counted "bash walked.sh"
allowed "#3406 a script whose functions only the walk of its variables asks for passes"
walked_names="$(counted names)"
walked_shopt="$(counted shopt)"
case "$walked_names" in ''|none|0) check "#3406 the counting copy counted a search of a script's text for its functions" "it counted '$walked_names', so the case below would hold the gate to nothing" ;;
  *) check "#3406 the counting copy counted a search of a script's text for its functions" ok ;; esac
named asked.sh 'helper' 'git status' 'sed -n 1p ok.sh' 'unknown_tool_3406 bash ok.sh'
run_counted "bash asked.sh"
allowed "#3406 the same script with a git, a sed and an unknown program's command passes"
asked_names="$(counted names)"
if [ "$asked_names" != none ] && [ "$asked_names" = "$walked_names" ]; then check "#3406 a script's text is searched for its functions as often with a git, a sed and an unknown program's command as with none" ok
else check "#3406 a script's text is searched for its functions as often with a git, a sed and an unknown program's command as with none" "searched $asked_names times with them, $walked_names with none"; fi
# Whether a text runs shopt is searched for once for each text too. The walk of its variables asks,
# and the reading of a function's locals asked again where a local is given a value: a second
# search of the whole text, 10 ms of claude-sync's. A case's patterns are read by that answer, so
# the answers below are pinned with and without the word.
case "$walked_shopt" in ''|none|0) check "#3406 the counting copy counted a search of a script's text for shopt" "it counted '$walked_shopt', so the case below would hold the gate to nothing" ;;
  *) check "#3406 the counting copy counted a search of a script's text for shopt" ok ;; esac
named local.sh 'keeper() {' "  local lib=$S/ok.sh" '  . "$lib"' '}' 'keeper'
run_counted "bash local.sh"
allowed "#3406 a script whose function sources a script that posts nothing, named by a local, passes"
local_shopt="$(counted shopt)"
if [ "$local_shopt" != none ] && [ "$local_shopt" = "$walked_shopt" ]; then check "#3406 a script's text is searched for shopt as often with a local given a value as with none" ok
else check "#3406 a script's text is searched for shopt as often with a local given a value as with none" "searched $local_shopt times with one, $walked_shopt with none"; fi
# cased <file> <first command> <the file the local names>: the function's local is then tested by
# a case whose pattern holds upper case letters, which matches nothing unless shopt has changed
# how patterns match.
cased() {
  named "$1" "$2" 'keeper() {' "  local lib=$S/$3" '  case "$lib" in' "    *.SH) lib=$S/ok.sh ;;" '  esac' '  . "$lib"' '}' 'keeper'
}
cased cased.sh 'true' ok.sh
run_counted "bash cased.sh"
allowed "#3406 a local a case cannot change, in a script that never runs shopt, still names the file sourced"
cased cased.sh 'true' posts.sh
run_counted "bash cased.sh"
refused "#3406 and where that file posts the script is refused"
says "#3406 and that refusal is the posting" "chat.postMessage"
cased cased.sh 'shopt -s nocasematch' ok.sh
run_counted "bash cased.sh"
refused "#3406 the same local in a script that runs shopt is not certain past the case, as it was"
says "#3406 and that refusal says the local is not certain" 'is not certain there'
# And the held names change no answer: a function of the text's own that shadows a program is
# still seen to, where the same command with no such function reads as the program.
named shadow.sh 'sed() { curl -s -X POST -d text=hi https://slack.com/api/chat.postMessage; }' 'sed -n 1p ok.sh'
run_counted "bash shadow.sh"
refused "#3406 a script whose own function named sed posts is refused where it calls sed"
says "#3406 and that refusal is the posting" "chat.postMessage"

echo

echo "passed: $pass, failed: $fail"

printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"

[ "$fail" -eq 0 ]
