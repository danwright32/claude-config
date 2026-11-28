#!/usr/bin/env bash
# Tests for what the Slack drafts gate keeps noted when a text the shared reader gave up on names a
# write (claude-config#3878). The gate notes what each file was last written with, what a folder was
# copied from and what PYTHONPATH was exported, and judges a later run by the note. A text the reader
# cannot read is cut crudely, into anything that may be a command, words inside quotes included. A
# write among those may be words a shell only prints, so it must never stand in the place of what
# was noted before: the file, the folder or the path is from then on also something the gate could
# not read. Kept apart from the other suites so none grows past its wall clock; the helpers below
# are copied from test-slack-drafts-made-lines.sh as they are, so a case here is driven the same
# way: a hook payload piped into slack-drafts-only-gate.sh, exit 0 allowed and 2 refused, the reason
# on stderr. Nothing a case names is ever run.
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
unset PYTHONPATH

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

refused() { if [ "$RC" -eq 2 ]; then check "$1" ok; else check "$1" "exit $RC, stdout: ${OUT:0:200}, stderr: ${ERR:0:300}"; fi; }
allowed() { if [ "$RC" -eq 0 ] && [ -z "$(printf '%s%s' "$OUT" "$ERR" | tr -d '[:space:]')" ]; then check "$1" ok
            else check "$1" "exit $RC, stdout: ${OUT:0:200}, stderr: ${ERR:0:300}"; fi; }
says() { case "$ERR" in *"$2"*) check "$1" ok ;; *) check "$1" "stderr did not say '$2': ${ERR:0:900}" ;; esac; }
lacks() { case "$ERR" in *"$2"*) check "$1" "stderr said '$2': ${ERR:0:900}" ;; *) check "$1" ok ;; esac; }

# The folder every case is judged in: a script that posts and one that does not, a folder of each, a
# Python module of each under a folder of its own, and scripts that import one.
S="$(cd "$T" && pwd -P)/src"  # by its real path, as a checkout is: on macOS the temp folder is behind a link
mkdir -p "$S/postdir" "$S/calmdir" "$S/postlib" "$S/cleanlib"
POST='curl -s -X POST -d text=hi https://slack.com/api/chat.postMessage'
printf '%s\n' "$POST" > "$S/post.sh"
printf '%s\n' 'echo ok' > "$S/calm.sh"
printf '%s\n' "$POST" > "$S/postdir/run.sh"
printf '%s\n' 'echo ok' > "$S/calmdir/run.sh"
printf '%s\n' 'import urllib.request' "urllib.request.urlopen('https://slack.com/api/chat.postMessage', b'text=hi')" > "$S/postlib/helper.py"
printf '%s\n' "print('ok')" > "$S/cleanlib/helper.py"
printf '%s\n' 'import helper' > "$S/run.py"
printf '%s\n' 'import beside' > "$S/own.py"
printf '%s\n' "print('ok')" > "$S/beside.py"
# Scripts the reader reads whole: one writes the file a case copies the post to, one exports.
printf '%s\n' 'printf true > made.sh' > "$S/writer.sh"
printf '%s\n' 'export PYTHONPATH=cleanlib' > "$S/env-clean.sh"
printf '%s\n' 'F=env-clean.sh' '. "./$F"' > "$S/via.sh"
run_s() { run_raw "$(payload Bash "$(bash_input "$1")" "$S")"; }

# The line that makes the reader give a text up, and words a shell only prints that the crude cut
# lists as commands: it cuts at every semicolon, quotes and all.
OPEN='echo "never closed'
quoted() { printf "echo 'a; %s; b'" "$1"; }
# lines <line>...: one text of those lines.
lines() { printf '%s\n' "$@"; }
# fed <what follows the shell> <line>...: a heredoc of the lines fed to bash, then what follows.
fed() {
  local after="$1"; shift
  printf "bash <<'EOF' ; %s\n" "$after"
  printf '%s\n' "$@"
  printf 'EOF'
}
ROUGH="a command in text this gate could not read as commands for certain"
PYDOUBT="a PYTHONPATH exported in text this gate could not read as commands for certain"

echo "slack drafts unread write notes: a write in text the reader gave up on never replaces a note (claude-config#3878)"

# Each seen first, alone: what is refused and what is allowed with every text read whole.
run_s "bash post.sh"
refused "#3878 a script that posts, run alone"
run_s "bash calm.sh"
allowed "#3878 a script that does not post, run alone"
run_s "cp post.sh made.sh; bash made.sh"
refused "#3878 a copy of the script that posts, run"
says "#3878 and it is judged by what it was copied from" "made.sh is made from post.sh earlier in this command"

echo "  a file: the note of what it was written with"

# The issue's own text. A shell copies the post, prints the echo, fails on the open quote, and
# the command after the heredoc then runs the copy.
run_s "$(fed 'bash made.sh' 'cp post.sh made.sh' 'echo "a $(printf true > made.sh) b"' "$OPEN")"
refused "#3878 shape 1: a heredoc fed to bash whose quoted words name a write of the copied post, then the copy run"
says "#3878 and the refusal says the file may hold what the gate could not read" "made.sh is written earlier in this command by $ROUGH"
run_s "$(fed 'bash made.sh' 'cp post.sh made.sh' "$(quoted 'printf true > made.sh')" "$OPEN")"
refused "#3878 shape 1: the same with the write inside single quotes, cut at a semicolon"
run_s "$(fed 'bash made.sh' 'cp post.sh made.sh' "$(quoted 'cp calm.sh made.sh')" "$OPEN")"
refused "#3878 shape 1: the same with quoted words that name a copy of a calm script over it"
lines 'cp post.sh made.sh' "$(quoted 'printf true > made.sh')" "$OPEN" > "$S/body.sh"
run_s "bash body.sh ; bash made.sh"
refused "#3878 shape 1: the same text as a script file on disk, run before the copy"
run_s "bash -c '$(lines 'cp post.sh made.sh' 'echo "a; printf true > made.sh; b"' "$OPEN")' ; bash made.sh"
refused "#3878 shape 1: the same text as a string handed to bash -c"
run_s "eval '$(lines 'cp post.sh made.sh' 'echo "a; printf true > made.sh; b"' "$OPEN")' ; bash made.sh"
refused "#3878 shape 1: the same text as a string handed to eval"
run_s "bash <<< '$(lines 'cp post.sh made.sh' 'echo "a; printf true > made.sh; b"' "$OPEN")' ; bash made.sh"
refused "#3878 shape 1: the same text as a here-string fed to bash"
run_s "$(lines 'cp post.sh made.sh' "$(quoted 'printf true > made.sh')" 'bash made.sh' "$OPEN")"
refused "#3878 shape 1: the whole command given up on, the copy run inside it"
# What the file was noted to hold is still read where a reading asks for its text: the copy
# printed into a shell is judged by the script it was copied from.
run_s "$(fed 'cat made.sh | bash' 'cp post.sh made.sh' "$(quoted 'printf true > made.sh')" "$OPEN")"
refused "#3878 shape 1: the copy printed into a shell after quoted words that name a write of it"
says "#3878 and it is judged by the script it was copied from" "the script post.sh runs a command that posts"
run_s "$(fed 'bash made.sh' 'cp post.sh made.sh' "$(quoted 'bash writer.sh')" "$OPEN")"
refused "#3878 shape 1: quoted words that name a run of a script on disk, read whole, which writes over the copy"
run_s "$(fed 'bash made.sh' 'cp post.sh made.sh' "$(quoted 'bash -c "printf true > made.sh"')" "$OPEN")"
refused "#3878 shape 1: quoted words that name a string handed to bash -c which writes over the copy"

echo "  a folder: the note of what it was copied from"

run_s "cp -R postdir made; bash made/run.sh"
refused "#3878 a copy of the folder whose script posts, and that script run"
run_s "$(fed 'bash made/run.sh' 'cp -R postdir made' "$(quoted 'cp -R calmdir/ made')" "$OPEN")"
refused "#3878 shape 2: quoted words that name a copy of a calm folder over the copied folder"
says "#3878 and the refusal says the file under it may hold what the gate could not read" "is written earlier in this command by $ROUGH"
run_s "$(fed 'bash made/run.sh' 'cp -R postdir made' "$(quoted 'printf true > made/run.sh')" "$OPEN")"
refused "#3878 shape 2: quoted words that name a write of one file under the copied folder"
run_s "$(lines 'cp -R postdir made' 'bash made/run.sh' "$OPEN")"
refused "#3878 shape 2: a folder copied in a text given up on, and its script run, is still refused"

echo "  PYTHONPATH: the note of what was exported"

run_s "export PYTHONPATH=postlib; python3 run.py"
refused "#3878 a script whose import is found on the exported PYTHONPATH, in a module that posts"
run_s "export PYTHONPATH=cleanlib; python3 run.py"
allowed "#3878 the same script with a PYTHONPATH whose module does not post"
lines 'export PYTHONPATH=postlib' "$(quoted 'export PYTHONPATH=cleanlib')" "$OPEN" > "$S/env.sh"
run_s ". ./env.sh; python3 run.py"
refused "#3878 shape 3: a sourced file the reader gives up on, whose quoted words name another export"
says "#3878 and the refusal says where Python looks could not be read" "$PYDOUBT"
run_s "$(lines 'export PYTHONPATH=postlib' "$(quoted 'export PYTHONPATH=cleanlib')" 'python3 run.py' "$OPEN")"
refused "#3878 shape 3: the whole command given up on, the script run inside it"
run_s "$(lines 'export PYTHONPATH=postlib' "$(quoted 'PYTHONPATH=cleanlib')" 'python3 run.py' "$OPEN")"
refused "#3878 shape 3: the same with the quoted words a bare assignment"
run_s "$(fed 'true' 'export PYTHONPATH=postlib' "$(quoted 'export PYTHONPATH=cleanlib')" 'python3 run.py' "$OPEN")"
refused "#3878 shape 3: the same text as a heredoc fed to bash"
run_s "source /dev/stdin <<'EOF' ; python3 run.py
$(lines 'export PYTHONPATH=postlib' "$(quoted 'export PYTHONPATH=cleanlib')" "$OPEN")
EOF"
refused "#3878 shape 3: the same text sourced from a heredoc, the script run after it"
run_s "eval '$(lines 'export PYTHONPATH=postlib' 'echo "a; export PYTHONPATH=cleanlib; b"' "$OPEN")' ; python3 run.py"
refused "#3878 shape 3: the same text as a string handed to eval, the script run after it"
run_s "$(lines 'export PYTHONPATH=postlib' "$(quoted '. ./env-clean.sh')" 'python3 run.py' "$OPEN")"
refused "#3878 shape 3: quoted words that source a file on disk, read whole, which exports another path"
# The file via.sh sources is read once already, in a text read whole, before the quoted words.
run_s "export PYTHONPATH=postlib; . ./via.sh; export PYTHONPATH=postlib; eval '$(lines 'echo "a; . ./via.sh; b"' "$OPEN")' ; python3 run.py"
refused "#3878 shape 3: quoted words that source a file read earlier in the command, which sources one by a variable"
run_s "$(lines 'export PYTHONPATH=postlib' "$(quoted 'export PYTHONPATH=cleanlib')" 'python3 -m helper' "$OPEN")"
refused "#3878 shape 3: a module run by -m after it"
says "#3878 and the refusal says where Python looks could not be read, for -m too" "$PYDOUBT"

echo "  a write in such a text with nothing noted before it"

# Every write in such a text is marked, and not only one that stands in the place of an earlier
# note. Here the first line really writes the file, and the cut hides that write (it reads the
# redirection as inside a quote), so the quoted words on the second line make the only note.
run_s "$(fed 'bash made.sh' 'echo "bash post.sh; echo true" > made.sh' "$(quoted 'printf true > made.sh')" "$OPEN")"
refused "#3878 quoted words that name a write of a file nothing noted before, then the file run"

echo "  the known cost: a file written and run in a text given up on"

run_s "$(lines "printf 'echo ok' > made.sh" 'bash made.sh' "$OPEN")"
refused "#3878 a calm file written and then run in a text given up on is refused"
says "#3878 and the refusal is that it could not be checked" "whether it posts cannot be checked"
lacks "#3878 and it is not called a post" "REFUSED: this command posts to Slack"
run_s "$(lines 'export PYTHONPATH=cleanlib' 'python3 run.py' "$OPEN")"
refused "#3878 a calm module on a PYTHONPATH exported in a text given up on is refused"
lacks "#3878 and it is not called a post" "REFUSED: this command posts to Slack"
run_s "$(lines 'bash writer.sh' 'bash made.sh' "$OPEN")"
refused "#3878 a calm file written by a script that a text given up on runs, then run, is refused"

echo "  controls: a text read whole is judged as before, and what such a text does not touch too"

run_s "cp post.sh made.sh; printf true > made.sh; bash made.sh"
allowed "#3878 a write the reader reads whole still replaces what the file was copied from"
run_s "$(fed 'bash made.sh' 'cp post.sh made.sh' 'printf true > made.sh')"
allowed "#3878 and so does one in a heredoc the reader reads whole"
run_s "$(fed 'bash made.sh' 'cp post.sh made.sh' "$(quoted 'printf true > made.sh')")"
refused "#3878 quoted words in a heredoc the reader reads whole replace nothing"
says "#3878 and the copy is judged by what it was copied from" "made.sh is made from post.sh earlier in this command"
run_s "cp post.sh made.sh; bash writer.sh; bash made.sh"
allowed "#3878 and so does one made by a script on disk that a text read whole runs"
run_s "export PYTHONPATH=postlib; . ./env-clean.sh; python3 run.py"
allowed "#3878 and an export in a file on disk that a text read whole sources"
run_s "cp -R postdir made; printf true > made/run.sh; bash made/run.sh"
allowed "#3878 a write the reader reads whole still replaces a file under a copied folder"
run_s "export PYTHONPATH=postlib; export PYTHONPATH=cleanlib; python3 run.py"
allowed "#3878 an export the reader reads whole still replaces the one before it"
run_s "eval '$(lines 'export PYTHONPATH=postlib' "$OPEN")' ; export PYTHONPATH=cleanlib; python3 run.py"
allowed "#3878 and an export read whole after one in a text given up on replaces that too"
run_s "$(lines "printf 'echo ok' > made.sh" "$OPEN")"
allowed "#3878 a text given up on that writes a file and runs nothing"
run_s "$(lines 'bash calm.sh' "$OPEN")"
allowed "#3878 a text given up on that runs a calm script it did not write"
run_s "$(lines "printf 'echo ok' > made.sh" 'bash calm.sh' "$OPEN")"
allowed "#3878 a text given up on that writes one file and runs another"
run_s "$(lines 'export PYTHONPATH=cleanlib' 'python3 own.py' "$OPEN")"
allowed "#3878 an import found beside the script is read as before, whatever was exported"
run_s "$(lines 'export PYTHONPATH=cleanlib' 'bash calm.sh' "$OPEN")"
allowed "#3878 an export in a text given up on, with no Python run after it"
# A string the reader reads whole, and marks for another reason, is no text given up on.
run_s "bash -c '\$TOOL x; printf \"echo ok\" > made.sh; bash made.sh'"
allowed "#3878 a string read whole whose first command is a variable: a file written and run in it"
run_s "eval 'cd calmdir && printf \"echo ok\" > made.sh && bash made.sh'"
allowed "#3878 a string read whole that changes directory under eval: a file written and run in it"

echo

echo "passed: $pass, failed: $fail"

printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"

[ "$fail" -eq 0 ]
