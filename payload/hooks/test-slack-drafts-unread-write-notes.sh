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
mkdir -p "$S/postpkg"
cp "$S/postlib/helper.py" "$S/postpkg/__main__.py"
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
# given_up <form> <what follows it> <line>...: a text the reader gives up on that holds the lines, in
# one of five forms, then what follows it in text read whole. The forms: a heredoc fed to a shell,
# the lines as quoted words in one, a string handed to bash -c, one handed to eval, a sourced file.
given_up() {
  local form="$1" after="$2" l q=(); shift 2
  case "$form" in
    heredoc) fed "$after" "$@" "$OPEN" ;;
    quoted) for l in "$@"; do q+=("$(quoted "$l")"); done; fed "$after" "${q[@]}" "$OPEN" ;;
    bash-c) printf "bash -c '%s' ; %s" "$(lines "$@" "$OPEN")" "$after" ;;
    eval) printf "eval '%s' ; %s" "$(lines "$@" "$OPEN")" "$after" ;;
    sourced) lines "$@" "$OPEN" > "$S/given-up.sh"; printf '. ./given-up.sh; %s' "$after" ;;
  esac
}
ROUGH="a command in text this gate could not read as commands for certain"
PYDOUBT="a PYTHONPATH exported in text this gate could not read as commands for certain"
ONTO="a copy to a path that only text this gate could not read as commands for certain makes a folder"
ALONE="read as one of the things a path may hold after text this gate could not read as commands for certain touched it; each is judged alone"

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
says "#3878 and it is judged by the copy the file held before the quoted words" "made.sh is made from post.sh earlier in this command"
says "#3878 and the refusal says that is one of the things the file may hold" "$ALONE"
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
# Where Python looks is unread from the export on, so an import of the standard library is too.
printf '%s\n' 'import os' > "$S/std.py"
run_s "$(lines 'export PYTHONPATH=cleanlib' 'python3 std.py' "$OPEN")"
refused "#3884 an import of the standard library after an export in a text given up on is refused too"
says "#3884 and the refusal says where Python looks could not be read" "$PYDOUBT"
run_s "$(lines 'python3 std.py' "$OPEN")"
allowed "#3884 the same import in a text given up on that exports nothing"
run_s "$(lines 'bash writer.sh' 'bash made.sh' "$OPEN")"
refused "#3878 a calm file written by a script that a text given up on runs, then run, is refused"

echo "  a note made in a text given up on is still followed by a later copy, move or run"

# The folder: copied in such a text it is still a folder, copied from where it was copied from.
run_s "$(lines 'cp -R postdir a' 'cp -R a b' 'bash b/run.sh' "$OPEN")"
refused "#3884 a folder copied twice in a text given up on, and the second copy's script run"
run_s "$(lines 'cp -R postdir a' 'mv a b' 'bash b/run.sh' "$OPEN")"
refused "#3884 a folder copied and then moved in a text given up on, and its script run"
run_s "$(lines 'cp -R postdir a' 'cp -R a b' 'cp -R b c' 'bash c/run.sh' "$OPEN")"
refused "#3884 a folder copied three times in a text given up on, and the last copy's script run"
run_s "$(fed 'cp -R a b; bash b/run.sh' 'cp -R postdir a' "$OPEN")"
refused "#3884 a folder copied in a heredoc given up on, copied again in text read whole, and its script run"
run_s "$(fed 'cat b/run.sh | bash' 'cp -R postdir a' 'cp -R a b' "$OPEN")"
refused "#3884 a script under a second copy of a folder copied in a heredoc given up on, printed into a shell"
run_s "$(lines 'cp -R postpkg a' 'python3 a' "$OPEN")"
refused "#3884 a package folder copied in a text given up on, run by its folder"
run_s "$(lines 'cp -R calmdir a' 'cp post.sh a' 'bash a/post.sh' "$OPEN")"
refused "#3884 a script copied into a folder copied in a text given up on, and run"
run_s "$(fed 'cp post.sh a; bash a/post.sh' 'cp -R calmdir a' "$OPEN")"
refused "#3884 the same with the script copied in, and run, in text read whole after the heredoc"
run_s "$(fed 'cp post.sh a; cat a/post.sh | bash' 'cp -R calmdir a' "$OPEN")"
refused "#3884 the same with the script printed into a shell"
# What the folder was copied from before, and what such a text copies over it, are both kept.
run_s "$(fed 'cat made/run.sh | bash' 'cp -R postdir made' "$(quoted 'cp -R calmdir/ made')" "$OPEN")"
refused "#3884 a script under a copied folder, printed into a shell after quoted words that name a copy over the folder"
says "#3884 and the refusal says every file under a folder such a text copies is one the gate could not read" "comes from $ROUGH"
run_s "$(fed 'cat made/run.sh | bash' 'cp -R calmdir made' 'cp -R postdir/ made' "$OPEN")"
refused "#3884 a folder copied over a copied folder in a text given up on, and its script printed into a shell"
run_s "$(fed 'cp -R made b; cat b/run.sh | bash' 'cp -R calmdir made' 'cp -R postdir/ made' "$OPEN")"
refused "#3884 the same under a copy of that folder made in text read whole"
# Quoted words that name a folder copied onto a file do not make the file a folder for certain: a
# later copy to that path, or from it, is noted both as one into a folder and as one onto a file.
run_s "cp calm.sh made; $(fed 'cp post.sh made; bash made' "$(quoted 'cp -R calmdir made')" "$OPEN")"
refused "#3884 a script copied onto a file that quoted words name a folder copied onto, and run"
says "#3884 and it is judged by the copy as one onto the file" "made is made from post.sh earlier in this command"
says "#3884 and the refusal says that is one of the things the path may hold" "$ALONE"
run_s "cp calm.sh made; $(fed 'cp calm.sh made; bash made' "$(quoted 'cp -R calmdir made')" "$OPEN")"
refused "#3884 a calm script copied onto such a file is still refused: the copy may have been into a folder"
says "#3884 and the refusal says the copy may have been into a folder" "is written earlier in this command by $ONTO"
run_s "cp post.sh made; $(fed 'cp -R made b; bash b' "$(quoted 'cp -R calmdir made')" "$OPEN")"
refused "#3884 a file that quoted words name a folder copied onto, copied as a folder, and the copy run"
says "#3884 and the copy is judged by what the file was copied from" "b is made from post.sh earlier in this command"
run_s "cp calm.sh made; $(fed 'cp -R made b; cp post.sh b; bash b' "$(quoted 'cp -R calmdir made')" "$OPEN")"
refused "#3884 the same file copied as a folder, a script copied onto the copy, and the copy run"

# The file: copied or written in such a text, then copied, moved or printed.
run_s "$(lines 'cp post.sh a.sh' 'cp a.sh b.sh' 'bash b.sh' "$OPEN")"
refused "#3884 a file copied twice in a text given up on, and the second copy run"
run_s "$(lines 'cp post.sh a.sh' 'mv a.sh b.sh' 'bash b.sh' "$OPEN")"
refused "#3884 a file copied and then moved in a text given up on, and run"
run_s "$(fed 'cp a.sh b.sh; bash b.sh' 'cp post.sh a.sh' "$OPEN")"
refused "#3884 a file copied in a heredoc given up on, copied again in text read whole, and run"
run_s "$(fed 'cp a.sh b.sh; cat b.sh | bash' 'cp post.sh a.sh' "$OPEN")"
refused "#3884 the same with the second copy printed into a shell"
run_s "$(lines "printf 'bash post.sh' > a.sh" 'cp a.sh b.sh' 'bash b.sh' "$OPEN")"
refused "#3884 a file written in a text given up on with a run of the post, copied, and the copy run"
run_s "$(fed 'cp a.sh b.sh; cat b.sh | bash' "printf 'bash post.sh' > a.sh" "$OPEN")"
refused "#3884 the same with the copy made in text read whole and printed into a shell"
run_s "$(lines 'cp post.sh a.sh' '. ./a.sh' "$OPEN")"
refused "#3884 a file copied in a text given up on, and sourced"
run_s "$(lines 'cp calm.sh a.sh' 'bash a.sh' "$OPEN")"
refused "#3884 a calm file copied and then run in a text given up on is refused"
run_s "$(lines 'cp post.sh "$X"' 'bash made.sh' "$OPEN")"
refused "#3884 a file copied in a text given up on to a path the gate cannot work out, then a script run"

# PYTHONPATH: exported in such a text, then read by a later Python.
run_s "$(lines 'export PYTHONPATH=postlib' 'python3 run.py' "$OPEN")"
refused "#3884 a module that posts on a PYTHONPATH exported in a text given up on"
run_s "$(fed 'true' 'export PYTHONPATH=postlib' 'python3 run.py' "$OPEN")"
refused "#3884 the same in a heredoc fed to bash"
run_s "eval '$(lines 'export PYTHONPATH=postlib' "$OPEN")' ; python3 run.py"
refused "#3884 the same exported in a string handed to eval, the script run after it"
run_s "$(lines 'PYTHONPATH=postlib python3 run.py' "$OPEN")"
refused "#3884 a PYTHONPATH set on the Python command itself in a text given up on"
run_s "$(lines 'export PYTHONPATH=cleanlib' 'PYTHONPATH=postlib python3 run.py' "$OPEN")"
refused "#3884 the same after an export in that text"
run_s "$(lines 'export PYTHONPATH=postlib' 'export PYTHONPATH=cleanlib' 'python3 run.py' "$OPEN")"
refused "#3884 two exports in a text given up on, the first of a module that posts"
run_s "$(lines 'cp -R postlib lib2' 'export PYTHONPATH=lib2' 'python3 run.py' "$OPEN")"
refused "#3884 a PYTHONPATH naming a folder copied in a text given up on"

# The memo of a sourced file found clean (script): a reading kept from text read whole is not put
# back in a text given up on. The memo is asked only under a command run through a variable, and
# the two readings are the same only where the folder is not certain in both: in a function body,
# and in a text given up on. So: a script sourced through a variable whose function sources the
# export, then one sourced the same way that the reader gives up on, whose quoted words source it.
printf '%s\n' "export PYTHONPATH=$S/cleanlib" > "$S/env-abs.sh"
printf '%s\n' "export PYTHONPATH=$S/postlib" > "$S/env-post-abs.sh"
printf '%s\n' "f() { . $S/env-abs.sh; }" > "$S/kept.sh"
printf '%s\n' "f() { . $S/env-post-abs.sh; }" > "$S/kept-post.sh"
lines "$(quoted ". $S/env-abs.sh")" "python3 $S/run.py" "$OPEN" > "$S/rough.sh"
lines ". $S/env-post-abs.sh" "python3 $S/run.py" "$OPEN" > "$S/rough-post.sh"
run_s "D=.; export PYTHONPATH=postlib; \$D ./rough.sh"
refused "#3884 quoted words that source a file which exports another path, in a script given up on that is sourced through a variable"
run_s "D=.; export PYTHONPATH=postlib; \$D ./kept.sh; \$D ./rough.sh"
refused "#3884 the same after a script read whole, sourced the same way, has had that file read and found clean"
says "#3884 and the refusal says where Python looks could not be read" "$PYDOUBT"
run_s "D=.; export PYTHONPATH=cleanlib; \$D ./kept-post.sh; \$D ./rough-post.sh"
refused "#3884 a file that exports the path of a module that posts, read the same two ways"
# A file that sources one by a variable, sourced from a string handed to eval both times: the
# folder it runs in is not certain there, so it is refused before the memo is asked.
run_s "export PYTHONPATH=postlib; eval '. ./via.sh'; export PYTHONPATH=postlib; eval '$(lines 'echo "a; . ./via.sh; b"' "$OPEN")' ; python3 run.py"
refused "#3884 quoted words that source a file read earlier in a string handed to eval, which sources one by a variable"

echo "  after such a text, a copy from or onto what it touched only adds to the note"

# A heredoc given up on that removes calm.sh and copies a folder to it: if a shell ran those lines
# calm.sh is a folder, the copy of it onto the file b fails whole, and b still holds the post.
UNSURE_DIR=('rm calm.sh' 'cp -R calmdir calm.sh' "$OPEN")
run_s "cp post.sh b; $(fed 'cp -R calm.sh b; bash b' "${UNSURE_DIR[@]}")"
refused "#3884 a folder that may be a file, copied in text read whole onto a copy of the script that posts, and that run"
says "#3884 and it is judged by what the copy held before, alone" "b is made from post.sh earlier in this command"
lacks "#3884 and never as one text with what was copied over it" "post.sh and calm.sh"
run_s "cp post.sh b; $(fed 'cp -R calm.sh b; bash b' 'cp -R calmdir calm.sh' "$OPEN")"
refused "#3884 the same with nothing removed first"
run_s "cp calm.sh a; cp post.sh b; $(fed 'mv a b; bash b' 'rm a' 'cp -R calmdir a' "$OPEN")"
refused "#3884 the same with the source a copy noted earlier, moved onto it"
run_s "cp -R postdir d; $(fed 'cp -R calm.sh d/run.sh; bash d/run.sh' "${UNSURE_DIR[@]}")"
refused "#3884 the same onto a script under a folder copied from one that posts"
run_s "cp post.sh b; $(fed 'cp -R calm.sh b; . ./b' "${UNSURE_DIR[@]}")"
refused "#3884 the same with the copy sourced"
run_s "cp post.sh b; $(fed 'cp -R calm.sh b; cat b | bash' "${UNSURE_DIR[@]}")"
refused "#3884 the same with the copy printed into a shell"
run_s "cp post.sh b; $(fed 'cp -R calm.sh b; cp -R b c; bash c' "${UNSURE_DIR[@]}")"
refused "#3884 the same through one more copy"
run_s "cp post.sh b; bash -c '$(lines "${UNSURE_DIR[@]}")' ; cp -R calm.sh b; bash b"
refused "#3884 the same with the text given up on a string handed to bash -c"
run_s "cp post.sh b; eval '$(lines "${UNSURE_DIR[@]}")' ; cp -R calm.sh b; bash b"
refused "#3884 the same with the text given up on a string handed to eval"
# Every combination is refused: each form of text given up on, each way it makes calm.sh a folder,
# and each thing that then takes from calm.sh, onto a copy of the script that posts.
for form in heredoc quoted bash-c eval sourced; do
  for made in 'cp -R calmdir calm.sh' 'rm calm.sh|cp -R calmdir calm.sh'; do
    IFS='|' read -r -a made_lines <<< "$made"
    for take in 'cp calm.sh b; bash b' 'cp -R calm.sh b; bash b' 'mv calm.sh b; bash b' \
                'cp -R calm.sh b; . ./b' 'bash -c "cp -R calm.sh b"; bash b' 'eval "cp -R calm.sh b"; bash b' \
                'cp -R calm.sh b; cat b | bash'; do
      run_s "cp post.sh b; $(given_up "$form" "$take" "${made_lines[@]}")"
      refused "#3884 text given up on ($form) holding ${made//|/ and }, then $take"
    done
    run_s "cp -R postdir d; $(given_up "$form" 'cp -R calm.sh d/run.sh; bash d/run.sh' "${made_lines[@]}")"
    refused "#3884 text given up on ($form) holding ${made//|/ and }, then a copy onto a script under a folder copied from one that posts"
  done
done
# What such a text removes, makes a folder or moves away is touched too, though nothing is noted
# of what it holds: a copy from it may fail, and the target is then as it was.
run_s "cp post.sh b; $(fed 'cp calm.sh b; bash b' 'rm calm.sh' "$OPEN")"
refused "#3884 a file such a text removes, copied in text read whole onto a copy of the script that posts, and that run"
run_s "cp post.sh b; $(fed 'cp -R calm.sh b; bash b' 'rm calm.sh' 'mkdir calm.sh' "$OPEN")"
refused "#3884 a file such a text removes and makes a folder of, copied onto it"
run_s "cp post.sh b; $(fed 'cp calm.sh b; bash b' 'mv calm.sh gone.sh' "$OPEN")"
refused "#3884 a file such a text moves away, copied onto it"
run_s "cp post.sh b; $(fed 'cp calm.sh b; bash b' 'rm "$GONE"' "$OPEN")"
refused "#3884 a removal in such a text of a path that cannot be worked out, then a copy onto it"
run_s "cp post.sh b; $(fed 'cp calm.sh b; bash b' 'rm c*.sh' "$OPEN")"
refused "#3884 a removal in such a text by a pattern, then a copy of a file it matches"
run_s "cp post.sh b; $(fed 'cp calmdir/run.sh b; bash b' 'rm -r calmdir' "$OPEN")"
refused "#3884 a folder such a text removes, then a copy of a file under it"
run_s "cp post.sh b; $(fed 'cp calm.sh b; bash b' 'rm b' 'mkdir b' "$OPEN")"
refused "#3884 a copy read whole onto a target such a text removed and made a folder of"
run_s "cp post.sh b; $(fed 'echo true > b; bash b' 'rm b' "$OPEN")"
refused "#3884 a write read whole to a target such a text removed"
run_s "cp -R postdir d; $(fed 'cp -R calmdir/ d; bash d/run.sh' 'rm calmdir/run.sh' "$OPEN")"
refused "#3884 a folder with a file such a text removed, copied in text read whole over a folder copied from one that posts"
says "#3884 and the script is judged by the folder it was copied from before" "postdir/run.sh"
# A folder test on a path such a text copies a folder to is answered yes: the
# copy may be one a shell runs, and then the script the test picks is the one that posts.
run_s "$(fed 'F=calm.sh; [ -d a ] && F=post.sh; bash "$F"' 'cp -R calmdir a' "$OPEN")"
refused "#3884 a folder test on a path such a text copies a folder to still picks the script that posts"
# Printed text empties its target before anything is read, so its source decides nothing.
run_s "cp post.sh b; $(fed 'cat calm.sh > b; bash b' 'rm calm.sh' "$OPEN")"
allowed "#3884 a file such a text removes, printed in text read whole over a copy of the script that posts, replaces it"
# What such a text did not touch is replaced as before.
run_s "cp post.sh b; $(fed 'cp calm.sh b; bash b' 'rm spare.sh' 'cp -R calmdir other' "$OPEN")"
allowed "#3884 a copy read whole between two paths such a text did not touch still replaces the note"
# A folder on disk with a file such a text removed is still a folder: a copy into it notes the file
# under it, and nothing at the folder's own path.
run_s "$(fed 'cp calm.sh calmdir; bash calmdir' 'rm calmdir/run.sh' "$OPEN")"
allowed "#3884 a copy into a folder on disk under which such a text removed a file does not note the folder as a file"
# In text read whole a removal or a move away is not followed, though the copy
# after it fails in a shell: pinned so that following it shows as a change.
run_s "cp post.sh b; rm calm.sh; cp calm.sh b; bash b"
allowed "#3884 STILL UNREAD: a file removed in text read whole, then copied onto a copy of the script that posts"
run_s "cp post.sh b; mv calm.sh gone.sh; cp calm.sh b; bash b"
allowed "#3884 STILL UNREAD: a file moved away in text read whole, then copied onto that copy"
# A removal by a pattern touches the paths the pattern can name and what is under them, and no
# folder above them, where a removal by a plain path touches the folders above it too. A name
# between quotes that holds a pattern character is one name to a shell and is read like a pattern.
run_s "cp -R postdir d; $(fed 'cp -R calmdir/ d; bash d/run.sh' 'rm calmdir/r*.sh' "$OPEN")"
allowed "#3884 STILL UNREAD: a folder with a file such a text removed by a pattern, copied in text read whole over a folder copied from one that posts"
run_s "cp -R postdir d; $(fed 'cp -R calmdir/ d; bash d/run.sh' "rm 'calmdir/r*.sh'" "$OPEN")"
allowed "#3884 a name between quotes that holds a pattern character, removed in such a text, touches no folder above it"

# Each program that removes a path or makes a folder of it touches every path it names.
run_s "cp post.sh b; $(fed 'cp calm.sh b; bash b' 'unlink calm.sh' "$OPEN")"
refused "#3884 a file such a text removes with unlink, then copied in text read whole onto a copy of the script that posts"
run_s "cp post.sh b; $(fed 'cp calm.sh b; bash b' 'mkdir b' "$OPEN")"
refused "#3884 a copy read whole onto a target such a text made a folder of with mkdir alone"
run_s "cp -R postdir d; $(fed 'cp -R calmdir/ d; bash d/run.sh' 'rmdir calmdir' "$OPEN")"
refused "#3884 a folder such a text removes with rmdir, then copied in text read whole over a folder copied from one that posts"
run_s "cp post.sh b; $(fed 'cp calm.sh b; bash b' 'rm spare.sh calm.sh' "$OPEN")"
refused "#3884 the second of two paths such a text removes with one rm, then copied onto a copy of the script that posts"
# A folder on disk that such a text may have removed, by its name, by a pattern or with the folder
# above it, may be a file after it: a copy to that path may be onto it, and what it holds then
# cannot be read.
mkdir -p "$S/sub/calmdir"
run_s "$(fed 'cp post.sh calmdir; bash calmdir' 'rm -r calmdir' "$OPEN")"
refused "#3884 a folder on disk such a text removes by its name, then the script that posts copied to that name and run by it"
run_s "$(fed 'cp post.sh calmdir; bash calmdir' 'rm -r c?lmdir' "$OPEN")"
refused "#3884 the same with the folder removed by a pattern"
run_s "$(fed 'cp post.sh sub/calmdir; bash sub/calmdir' 'rm -r sub' "$OPEN")"
refused "#3884 the same with the folder above it removed"

echo "  each thing a path may hold is judged alone, the write as it is written among them"

# What a path held and what is written over it after such a text touched it are two files, and no
# shell holds one after the other: read as one text, a held file with no newline at its end, a
# backslash there, or more bytes than the gate reads of a file takes the post written after it as
# its own words. The files held, made here and never by a command:
printf 'echo ok' > "$S/nonl.sh"
printf '%s\n' 'echo \' > "$S/bs.sh"
yes '# a comment line and nothing more, to fill the file up' | head -c 2200000 > "$S/big.sh"
mkdir -p "$S/nonldir" "$S/bsdir"
printf 'echo ok' > "$S/nonldir/run.sh"
printf '%s\n' 'echo \' > "$S/bsdir/run.sh"
run_s "$(fed 'cp post.sh nonl.sh; bash nonl.sh' 'rm nonl.sh' "$OPEN")"
refused "#3884 a file on disk with no newline at its end, removed in such a text, then the script that posts copied over it and run"
run_s "cp nonl.sh held.sh; $(fed 'cp post.sh held.sh; bash held.sh' "$(quoted 'rm post.sh')" "$OPEN")"
refused "#3884 a file noted from one with no newline at its end, the script that posts named in quoted words, then copied over it and run"
run_s "$(fed 'cp post.sh bs.sh; bash bs.sh' 'rm bs.sh' "$OPEN")"
refused "#3884 a file on disk whose last line ends with a backslash, removed in such a text, then the script that posts copied over it and run"
run_s "$(fed 'cp post.sh big.sh; bash big.sh' 'rm big.sh' "$OPEN")"
refused "#3884 a file on disk longer than the gate reads, removed in such a text, then the script that posts copied over it and run"
# The other way round: what was held is the post, and the file copied over it is the long one.
run_s "cp post.sh b; $(fed 'cp big.sh b; bash b' 'rm b' "$OPEN")"
refused "#3884 a copy of the script that posts, removed in such a text, then a file longer than the gate reads copied over it and run"
# One text too long to read whole is one the gate could not read: nothing after the cut is judged.
says "#3884 and the refusal says the file may be longer than the gate reads" "longer than this gate reads of one file"
run_s "$(fed 'cat post.sh >> big.sh; bash big.sh' 'rm big.sh' "$OPEN")"
refused "#3884 the script that posts added to the end of a file longer than the gate reads, after such a text removed that file"
says "#3884 and the refusal says the file is longer than the gate reads" "longer than this gate reads of one file"
# A copy leaves its target holding whichever thing its source held.
run_s "cp post.sh a; $(fed 'cp calm.sh a; cp a b; bash b' 'rm a' "$OPEN")"
refused "#3884 a copy of a file that may still hold the script that posts, and the copy run"
run_s "cp calm.sh a; $(fed 'cp calm.sh a; cp a b; bash b' 'rm a' "$OPEN")"
allowed "#3884 a copy of a file every reading of which is calm, and the copy run"
# More things than the gate reads one at a time: the path is one it could not read.
MANY=""
for n in 1 2 3 4 5 6 7 8 9 10 11 12 13 14; do MANY="$MANY printf 'echo $n' > b;"; done
run_s "$(fed "$MANY bash b" 'rm b' "$OPEN")"
refused "#3884 fourteen texts written in turn over a file such a text removed, and the file run"
says "#3884 and the refusal says there are more than the gate reads one at a time" "more writes than this gate reads one at a time"
run_s "$(fed "printf 'echo 1' > b; printf 'echo 2' > b; bash b" 'rm b' "$OPEN")"
allowed "#3884 two calm texts written in turn over such a file, and the file run"
# More readings of the whole command than the gate judges: refused, never cut short.
EACH=""
for n in 1 2 3 4 5 6 7; do EACH="$EACH cp calm.sh f$n; bash f$n;"; done
run_s "$(fed "$EACH true" 'rm f1 f2 f3 f4 f5 f6 f7' "$OPEN")"
refused "#3884 seven files such a text removed, each copied over and run: more readings than the gate judges"
says "#3884 and the refusal says so" "more than the gate judges one at a time"
run_s "$(fed 'cp calm.sh f1; bash f1; cp calm.sh f2; bash f2; cp calm.sh f3; bash f3' 'rm f1 f2 f3' "$OPEN")"
allowed "#3884 three such files, each copied over with a calm script and run"
run_s "cp -R nonldir d; $(fed 'cp -R postdir/ d; bash d/run.sh' "$(quoted 'rm -r postdir')" "$OPEN")"
refused "#3884 a folder noted from one whose script has no newline at its end, then what a folder that posts holds copied over it and its script run"
run_s "cp -R bsdir d; $(fed 'cp -R postdir/ d; . d/run.sh' 'rm d/other.txt' "$OPEN")"
refused "#3884 a folder noted from one whose script ends with a backslash, a file under it removed in such a text, then the same copy and its script sourced"

echo "  what such a text still hides: a folder change and a variable among quoted words"

# Two gaps left open, both allowed: pinned here so that closing either shows as a change.
# The crude cut follows a change of folder it lists whether or not a shell runs it, and it places no
# variable, so a script run through one is not read at all.
run_s "$(lines 'cd postdir' 'bash run.sh' "$OPEN")"
refused "#3884 a change of folder in a text given up on, then a script that posts run by a relative path"
run_s "$(lines 'cd postdir' "$(quoted 'cd ../calmdir')" 'bash run.sh' "$OPEN")"
allowed "#3884 STILL UNREAD: quoted words that name a change of folder, then that script run by a relative path"
run_s "$(lines 'F=post.sh' "$(quoted 'F=calm.sh')" 'bash "$F"' "$OPEN")"
allowed "#3884 STILL UNREAD: quoted words that name an assignment of a variable, then a script run through that variable"
run_s "$(lines 'F=post.sh' 'bash "$F"' "$OPEN")"
allowed "#3884 STILL UNREAD: the same with no quoted words at all"
# The folder test above is judged both ways, once with the folder there and once without it, so
# quoted words that name the copy, which leave no folder in a shell, pick the script that posts too.
run_s "$(fed 'F=calm.sh; [ -d a ] || F=post.sh; bash "$F"' "$(quoted 'cp -R calmdir a')" "$OPEN")"
refused "#3884 a folder test on a path that only quoted words copy a folder to picks the script that posts where no folder is there"
run_s "$(fed 'F=calm.sh; [ -d a ] || F=writer.sh; bash "$F"' "$(quoted 'cp -R calmdir a')" "$OPEN")"
allowed "#3884 and the same test picking between two scripts that do not post is allowed"
run_s "F=calm.sh; somecmd || F=post.sh; bash \"\$F\""
allowed "#3884 STILL UNREAD: in text read whole, a script run through a variable set two ways"

echo "  controls: a text read whole is judged as before, and what such a text does not touch too"

run_s "cp post.sh made.sh; printf true > made.sh; bash made.sh"
allowed "#3878 a write the reader reads whole still replaces what the file was copied from"
run_s "$(fed 'bash made.sh' 'cp post.sh made.sh' 'printf true > made.sh')"
allowed "#3878 and so does one in a heredoc the reader reads whole"
run_s "cp post.sh made.sh; printf true >> made.sh; bash made.sh"
refused "#3884 a write the reader reads whole that adds to the file keeps what it was copied from"
run_s "$(fed 'bash made.sh' 'cp post.sh made.sh' "$(quoted 'printf true > made.sh')")"
refused "#3878 quoted words in a heredoc the reader reads whole replace nothing"
says "#3878 and the copy is judged by what it was copied from" "made.sh is made from post.sh earlier in this command"
run_s "cp post.sh made.sh; bash writer.sh; bash made.sh"
allowed "#3878 and so does one made by a script on disk that a text read whole runs"
run_s "export PYTHONPATH=postlib; . ./env-clean.sh; python3 run.py"
allowed "#3878 and an export in a file on disk that a text read whole sources"
run_s "cp -R postdir made; printf true > made/run.sh; bash made/run.sh"
allowed "#3878 a write the reader reads whole still replaces a file under a copied folder"
run_s "cp -R calmdir a; cp -R a b; bash b/run.sh"
allowed "#3884 a calm folder copied twice in text read whole, and the second copy's script run"
run_s "cp -R postdir a; cp -R calmdir/ a; cp -R a b; bash b/run.sh"
allowed "#3884 a folder copied over a copied folder in text read whole still replaces what it was copied from"
run_s "cp -R calmdir made; cp calm.sh made; bash made/calm.sh; bash made/run.sh"
allowed "#3884 a script copied into a folder copied in text read whole is read as before"
# A copy that a shell can only make into a folder leaves the file of that name as it was.
run_s "cp calm.sh made; $(fed 'cp calm.sh made/; bash made' "$(quoted 'cp -R calmdir made')" "$OPEN")"
allowed "#3884 a copy to the path with a slash after it does not touch a file that quoted words name a folder copied onto"
run_s "cp calm.sh made; $(fed 'cp calm.sh writer.sh made; bash made' "$(quoted 'cp -R calmdir made')" "$OPEN")"
allowed "#3884 nor does a copy of two files to it"
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
