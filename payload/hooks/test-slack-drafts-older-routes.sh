#!/bin/bash
# Tests for the older routes past slack-drafts-only-gate.sh that the reviews of pull requests 3782
# and 3835 found on main (claude-config#3837). Each was a command that the gate allowed and that
# runs something the gate had not read:
#
#   route 1  a function named for a program the gate reads by its name, defined in a file the
#            command sources, or after another command on its line
#   route 2  a program run from a folder the gate takes for the system's, written into that folder
#            by an earlier command of the same call
#   route 3  a program whose word the gate cannot work out, handed the file that is run next
#   route 5  a function of the name defined through eval
#   route 6  a curl config written by a program the gate cannot read
#   route 7  a shell script, a heredoc or piped text one step deeper than the gate reads as commands
#   route 8  a write that is only quoted words, in a text the reader gave up on, replacing what the
#            gate noted a file to hold
#
# Routes 4 and 9 of the issue are not closed here; the two cases under "left as they are" hold what
# the gate answers for them today, so a change to either is seen.
#
# Every case goes through the hook, as a session's call does. None of the commands is ever run: the
# gate reads them.
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
# Every case runs with a judgement cache of its own, never this Mac's (claude-config#2918).
export SLACK_GATE_CACHE_DIR="$T/gate-cache"
unset SLACK_GATE_CACHE_TRACE

payload() {
  python3 -c '
import json, sys
print(json.dumps({"session_id": "f6017250-8f33-47ac-bbb2-b82a7c319d0d",
                  "transcript_path": "/tmp/transcript.jsonl", "cwd": sys.argv[2],
                  "permission_mode": "auto", "hook_event_name": "PreToolUse", "tool_name": "Bash",
                  "tool_input": {"command": sys.argv[1], "description": "d"},
                  "tool_use_id": "toolu_01X4Qw7JnfYswF7UVX94Z4Sy"}))
' "$1" "$2"
}

P="$T/proj"
H="$T/home"
mkdir -p "$P/recs" "$P/calmrecs" "$H"

RC=0; OUT=""; ERR=""
# run_here <command>: the gate's answer for the command as a call made in the project folder, with
# a home folder of the suite's own, so the curl config it reads and writes is never this Mac's.
run_here() {
  local errf; errf="$(mktemp "${TMPDIR:-/tmp}/slack-gate-err.XXXXXXXX")"
  OUT="$(payload "$1" "$P" | HOME="$H" bash "$HOOK" 2>"$errf")"; RC=$?
  ERR="$(cat "$errf")"; rm -f "$errf"
}

judged() {
  case "$ERR" in
    *"could not judge"*|*Traceback*) check "$1 (judged, not a crash)" "the gate crashed: ${ERR:0:300}" ;;
    *) check "$1 (judged, not a crash)" ok ;;
  esac
}
refused() {
  if [ "$RC" -eq 2 ]; then check "$1" ok; else check "$1" "exit $RC, stdout: ${OUT:0:200}, stderr: ${ERR:0:300}"; fi
  judged "$1"
}
allowed() {
  if [ "$RC" -eq 0 ] && [ -z "$(printf '%s%s' "$OUT" "$ERR" | tr -d '[:space:]')" ]; then check "$1" ok
  else check "$1" "exit $RC, stdout: ${OUT:0:200}, stderr: ${ERR:0:300}"; fi
  judged "$1"
}
says() { case "$ERR" in *"$2"*) check "$1" ok ;; *) check "$1" "stderr did not say '$2': ${ERR:0:500}" ;; esac; }
says_not() { case "$ERR" in *"$2"*) check "$1" "stderr said '$2': ${ERR:0:500}" ;; *) check "$1" ok ;; esac; }

POST="curl -s -X POST -d text=hi https://slack.com/api/chat.postMessage"

printf '%s\n' 'echo ok' > "$P/calm.sh"
printf '%s\n' 'echo ok' > "$P/run.sh"
printf '%s\n' "$POST" > "$P/post.sh"
printf '%s\n' '#!/bin/sh' 'echo frob' > "$P/frob"
chmod +x "$P/frob"
printf '%s\n' 'silent' > "$H/.curlrc"
printf '%s\n' 'url = "https://slack.com/api/chat.postMessage"' > "$P/endpoint.txt"

echo "== route 1: a function of the name in a sourced file, or after another command on its line =="

printf '%s\n' 'cat() { ./frob "$@"; }' > "$P/defs.sh"
printf '%s\n' 'helper() { echo "$@"; }' > "$P/defs-calm.sh"
printf '%s\n' '. ./defs.sh' > "$P/defs-outer.sh"
printf '%s\n' 'alias cat=./frob' > "$P/defs-alias.sh"

run_here '. ./defs.sh; cat calm.sh > run.sh; bash run.sh'
refused "#3837 route 1: cat after a sourced file defines a function called cat is refused"
says "#3837 route 1: and the refusal says cat is not certain to be the system's" "not certain to be the system's own cat"
run_here 'source defs.sh && cat calm.sh > run.sh && bash run.sh'
refused "#3837 route 1: the same with the word source is refused"
run_here '. ./defs-outer.sh; cat calm.sh > run.sh; bash run.sh'
refused "#3837 route 1: a function called cat in a file that a sourced file sources is refused"
run_here '. ./defs-alias.sh; cat calm.sh > run.sh; bash run.sh'
refused "#3837 route 1: an alias called cat in a sourced file is refused"
run_here 'true; cat() { ./frob "$@"; }; cat calm.sh > run.sh; bash run.sh'
refused "#3837 route 1: a function called cat defined after another command on its line is refused"
run_here 'true; function cat { ./frob "$@"; }; cat calm.sh > run.sh; bash run.sh'
refused "#3837 route 1: the same written with the word function is refused, as before"
printf '%s\n' 'echo ok' > "$P/locked.sh"
chmod 000 "$P/locked.sh"
run_here '. ./locked.sh; cat calm.sh > run.sh; bash run.sh'
if [ -r "$P/locked.sh" ]; then
  echo "SUITE-PART-UNMEASURED #3837 route 1: a sourced file the gate cannot open leaves cat doubted: this user can read a file with no permissions, so the case cannot be made here"
else
  refused "#3837 route 1: a sourced file the gate cannot open leaves cat doubted"
fi
run_here 'cp locked.sh made-locked.sh; . ./made-locked.sh; cat calm.sh > run.sh; bash run.sh'
if [ -r "$P/locked.sh" ]; then
  echo "SUITE-PART-UNMEASURED #3837 route 1: a sourced file this call copied from a file the gate cannot open leaves cat doubted: this user can read a file with no permissions, so the case cannot be made here"
else
  refused "#3837 route 1: a sourced file this call copied from a file the gate cannot open leaves cat doubted"
fi
chmod 644 "$P/locked.sh"
run_here "printf '' > made-empty.sh; . ./made-empty.sh; cat calm.sh > run.sh; bash run.sh"
allowed "#3837 route 1: a sourced file this call wrote empty, which the gate read whole, leaves cat believed"
run_here "printf '%s\\n' 'cat() { ./frob; }' > made-defs.sh; . ./made-defs.sh; cat calm.sh > run.sh; bash run.sh"
refused "#3837 route 1: a function called cat in a sourced file this call wrote is refused"
run_here "printf '%s\\n' 'helper() { :; }' > made-calm.sh; . ./made-calm.sh; cat calm.sh > run.sh; bash run.sh"
allowed "#3837 route 1: a sourced file this call wrote that defines another function leaves cat believed"
# What a sourced file defines is asked once for the files sourced so far and what this call wrote
# them from (sourced_shadow), so each of these changes one of the two after the first asking.
run_here "cp calm.sh kept.txt; . ./defs-calm.sh; cat calm.sh > first.txt; . ./defs.sh; cat calm.sh > run.sh; bash run.sh"
refused "#3837 route 1: a file sourced after cat was first asked about is still read"
run_here "printf '%s\\n' 'helper() { :; }' > made-twice.sh; . ./made-twice.sh; cat calm.sh > first.txt; printf '%s\\n' 'cat() { ./frob; }' > made-twice.sh; . ./made-twice.sh; cat calm.sh > run.sh; bash run.sh"
refused "#3837 route 1: a sourced file written again after cat was first asked about is read as written the second time"
run_here '. ./not-there.sh 2>/dev/null; cat calm.sh > run.sh; bash run.sh'
allowed "#3837 route 1: a sourced file that is not there leaves cat believed"
run_here '. ./defs.sh; cp calm.sh run.sh; bash run.sh'
allowed "#3837 route 1: cp after a sourced file that defines only cat still passes"
run_here '. ./defs-calm.sh; cat calm.sh > run.sh; bash run.sh'
allowed "#3837 route 1: cat after a sourced file that defines another function still passes"
run_here 'cat calm.sh > run.sh; bash run.sh'
allowed "#3837 route 1: cat with nothing sourced still passes"
run_here 'bash defs.sh; cat calm.sh > run.sh; bash run.sh'
allowed "#3837 route 1: a file run by bash, whose functions end with it, leaves cat believed"
run_here '. ./defs.sh; cat post.sh > run.sh; bash run.sh'
refused "#3837 route 1: a post in what the system's cat would have written is still refused"

echo "== route 5: a function of the name defined through eval =="

run_here "eval 'cat() { ./frob; }'; cat calm.sh > run.sh; bash run.sh"
refused "#3837 route 5: cat after eval defines a function called cat in single quotes is refused"
run_here 'eval "cat() { ./frob; }"; cat calm.sh > run.sh; bash run.sh'
refused "#3837 route 5: the same in double quotes is refused"
run_here "eval 'cat () { ./frob; }'; cat calm.sh > run.sh; bash run.sh"
refused "#3837 route 5: the same with a space before the brackets is refused"
run_here "eval 'concat() { ./frob; }'; cat calm.sh > run.sh; bash run.sh"
allowed "#3837 route 5: a function whose name only ends in cat leaves cat believed"
run_here "echo 'call cat ( ) here'; cat calm.sh > run.sh; bash run.sh"
refused "#3837 route 5: a name, a space and empty brackets in quoted words count as a function of the name"

echo "== route 2: a program written into a system folder earlier in the same call =="

run_here 'cp ./frob /opt/homebrew/bin/cat; /opt/homebrew/bin/cat calm.sh > run.sh; bash run.sh'
refused "#3837 route 2: cat by its path in Homebrew's folder, copied there by this call, is refused"
says "#3837 route 2: and the refusal says cat is not certain to be the system's" "not certain to be the system's own cat"
run_here 'cp ./frob /usr/local/bin/cat; /usr/local/bin/cat calm.sh > run.sh; bash run.sh'
refused "#3837 route 2: the same in /usr/local/bin is refused"
run_here 'cp ./frob /usr/local/bin/cat; cat calm.sh > run.sh; bash run.sh'
refused "#3837 route 2: cat by its bare name, after this call copied a file called cat into a system folder, is refused"
run_here 'mv ./frob /usr/local/bin/cp; /usr/local/bin/cp post.sh run.sh; bash calm.sh'
allowed "#3837 route 2: a copier written by this call, whose target is not run, still passes"
run_here 'mv ./frob /usr/local/bin/cp; /usr/local/bin/cp calm.sh run.sh; bash run.sh'
refused "#3837 route 2: a copier by its path, moved there by this call, is refused where its target is run"
run_here 'cp ./frob /usr/local/bin/frob; /usr/local/bin/cat calm.sh > run.sh; bash run.sh'
allowed "#3837 route 2: another file written into the folder leaves cat believed"
run_here 'cp ./frob ./cat2; /bin/cat calm.sh > run.sh; bash run.sh'
allowed "#3837 route 2: a write elsewhere leaves cat by its path believed"
run_here '/bin/cat calm.sh > run.sh; bash run.sh'
allowed "#3837 route 2: cat by its path with nothing written still passes"

# Whether this call wrote the program is asked once for each name while the gate's record of what
# the call wrote stays as it was (written_program), so here the record changes after the first asking.
run_here 'cp calm.sh kept.txt; cat calm.sh > first.txt; cp frob /usr/local/bin/cat; cat calm.sh > run.sh; bash run.sh'
refused "#3837 route 2: a file called cat copied into a system folder after cat was first asked about is still seen"
run_here 'cp calm.sh kept.txt; cat calm.sh > first.txt; cp frob elsewhere/cat; cat calm.sh > run.sh; bash run.sh'
allowed "#3837 route 2: a file called cat copied into a folder the shell does not search leaves cat believed"

echo "== route 3: a program whose word cannot be worked out, handed the file that is run next =="

run_here '"$TOOL" +x run.sh; bash run.sh'
refused "#3837 route 3: a program held in a variable, handed the script that is run next, is refused"
says "#3837 route 3: and the refusal says the program could not be worked out" "a program whose name this gate cannot work out"
says "#3837 route 3: and that the check could not be made" "could not check"
run_here '$TOOL run.sh; bash run.sh'
refused "#3837 route 3: the same with the variable unquoted is refused"
run_here '"$TOOL" out=run.sh; bash run.sh'
refused "#3837 route 3: the file named after an equals sign is refused"
run_here '"$TOOL" calm.sh; bash run.sh'
allowed "#3837 route 3: a program held in a variable that names another file still passes"
run_here '"$TOOL" +x run.sh'
allowed "#3837 route 3: a program held in a variable, with nothing run after it, still passes"
run_here '"$TOOL" +x run.sh; cat run.sh'
allowed "#3837 route 3: the file only read afterwards still passes"
run_here '[ -x run.sh ] || echo missing; bash run.sh'
allowed "#3837 route 3: a test in square brackets that names the file run next still passes"
run_here '[[ -f run.sh ]] && bash run.sh'
allowed "#3837 route 3: and so does one in double square brackets"
printf '%s\n' '"$TOOL" +x run.sh' 'bash run.sh' > "$P/inside3.sh"
run_here 'bash inside3.sh'
allowed "#3837 route 3: the same two commands in a script on disk pass, as for a program the gate does not know"

echo "== route 6: a curl config written by a program the gate cannot read =="

run_here './frob > ~/.curlrc'
refused "#3837 route 6: a program the gate does not know, writing the curl config, is refused"
says "#3837 route 6: and the refusal names the config" "a config file curl reads by default"
says "#3837 route 6: and says the check could not be made" "could not check"
says_not "#3837 route 6: and does not say a post was found" "REFUSED: this command posts to Slack"
run_here './frob ~/.curlrc'
refused "#3837 route 6: a program the gate does not know, handed the curl config, is refused"
run_here '"$TOOL" > ~/.curlrc'
refused "#3837 route 6: a program held in a variable, writing the curl config, is refused"
run_here 'curl -s https://example.invalid/x -o ~/.curlrc'
refused "#3837 route 6: a download into the curl config is refused"
run_here "./frob > $H/.config/curlrc"
refused "#3837 route 6: the same for the config under .config is refused"
run_here "printf 'silent\\n' > ~/.curlrc"
allowed "#3837 route 6: a curl config written with text the gate reads, naming no endpoint, still passes"
run_here 'cat endpoint.txt > ~/.curlrc'
refused "#3837 route 6: a curl config written with an endpoint is still refused"
says "#3837 route 6: and that refusal still says what it found" "naming chat.postMessage"
run_here './frob > notes.txt'
allowed "#3837 route 6: a program the gate does not know, writing another file, still passes"
run_here 'cat ~/.curlrc'
allowed "#3837 route 6: reading the curl config still passes"
run_here 'chmod 600 ~/.curlrc'
allowed "#3837 route 6: chmod of the curl config still passes"

echo "== route 7: a script one step deeper than the gate used to read as commands =="

# chain <name> <how many scripts> <the last script's text> [how each runs the next]: name0.sh runs
# name1.sh and so on, and the last holds the text given. A script run by the command is 0 deep, the
# one it runs 1 deep. The gate read commands 0 to 2 deep and now reads them 0 to 7 deep.
chain() {
  local name="$1" n="$2" last="$3" by="${4:-bash }" i=0
  while [ "$i" -lt $((n - 1)) ]; do
    printf '%s\n' "$by$name$((i + 1)).sh" > "$P/$name$i.sh"
    i=$((i + 1))
  done
  printf '%s\n' "$last" > "$P/$name$i.sh"
}
chain h 4 'bash post.sh'
chain s 4 '. ./post.sh' '. ./'
chain g 4 'bash calm.sh'
chain k 8 'echo ok'
chain m 8 'bash post.sh'
chain n 9 'bash post.sh'
chain o 9 'echo ok'
chain e 3 "bash <<'EOF'"$'\n''bash post.sh'$'\n''EOF'
chain c 3 "bash <<'EOF'"$'\n''echo ok'$'\n''EOF'
chain t 8 "bash <<'EOF'"$'\n''echo ok'$'\n''EOF'
chain p 3 "printf 'bash post.sh\\n' | bash"
chain u 8 "printf 'echo ok\\n' | bash"
printf '%s\n' 'if [ -z "${AGAIN:-}" ]; then AGAIN=1; . ./again.sh; fi' 'echo ok' > "$P/again.sh"
printf '%s\n' 'if [ -z "${AGAIN:-}" ]; then AGAIN=1; . ./again-post.sh; fi' 'bash h1.sh' > "$P/again-post.sh"

run_here 'bash h0.sh'
refused "#3837 route 7: a script that posts, behind four other scripts, is refused"
says "#3837 route 7: and the refusal says what it found" "posts to Slack (it names chat.postMessage)"
run_here 'bash s0.sh'
refused "#3837 route 7: the same chain by source is refused"
run_here 'bash h1.sh'
refused "#3837 route 7: a script that posts, behind three, is still refused"
says "#3837 route 7: and that refusal still says what it found" "posts to Slack (it names chat.postMessage)"
run_here 'bash e0.sh'
refused "#3837 route 7: a heredoc fed to a shell, three deep, that runs a script that posts is refused"
run_here 'bash p0.sh'
refused "#3837 route 7: text piped to a shell, three deep, that runs a script that posts is refused"
run_here 'bash m0.sh'
refused "#3837 route 7: a script that posts, eight deep, is refused by the name in it"
run_here 'bash n0.sh'
refused "#3837 route 7: a script that posts, behind nine others, is refused"
says "#3837 route 7: and the refusal says how deep the gate reads" "is 8 steps deep in what this command runs, which is as deep as this gate reads a script as commands"
says "#3837 route 7: and says the check could not be made" "could not check"
says_not "#3837 route 7: and does not say a post was found" "REFUSED: this command posts to Slack"
says "#3837 route 7: and names the no network wrapper" "no network wrapper"
run_here 'bash o0.sh'
refused "#3837 route 7: a calm script eight deep is refused as one the gate could not check"
run_here 'bash t0.sh'
refused "#3837 route 7: a calm heredoc fed to a shell eight deep is refused as one it could not check"
run_here 'bash u0.sh'
refused "#3837 route 7: calm text piped to a shell eight deep is refused as one it could not check"
run_here 'bash again-post.sh'
refused "#3837 route 7: a script that sources itself and runs a chain that posts is refused"
run_here 'bash g0.sh'
allowed "#3837 route 7: a calm script behind four others still passes"
run_here 'bash k0.sh'
allowed "#3837 route 7: a calm chain whose last script is seven deep still passes"
run_here 'bash c0.sh'
allowed "#3837 route 7: a calm heredoc fed to a shell three deep still passes"
run_here 'bash again.sh'
allowed "#3837 route 7: a calm script that sources itself still passes"
printf '%s\n' '# the cases below name https://slack.com/api/chat.postMessage' 'echo ok' > "$P/named.sh"
chain w 3 'bash named.sh'
run_here 'bash w0.sh'
refused "#3837 route 7: a script three deep that only names an endpoint is still refused by that name, never read past it"
says "#3837 route 7: and that refusal still names the no network wrapper" "no network wrapper"
# Three deep or deeper, a script is read as commands only up to the gate's DEEP_FILE_MAX, 256 KB:
# reading tests/test-claude-sync.sh (1.9 MB) where the gate's own suite reaches it that deep took
# the judgement of that suite's run from 5.8 to 13.2 s of processor, past the gate's 11 s. A longer
# one is judged by the names in it, as before the issue, which is left open and put to Dan; the
# last case holds what the gate answers for it today, so a change is seen.
pad() { python3 -c 'import sys; sys.stdout.write(("# " + "x" * 97 + "\n") * int(sys.argv[1]))' "$1" >> "$2"; }
chain lit 4 'bash post.sh'
pad 2000 "$P/lit3.sh"
chain big 4 'bash post.sh'
pad 2700 "$P/big3.sh"
run_here 'bash lit0.sh'
refused "#3837 route 7: a script that posts, behind four others of which the last is 200 KB, is refused"
run_here 'bash big3.sh'
refused "#3837 route 7: a script of 270 KB that runs a script that posts, run by the command itself, is refused as before"
run_here 'bash big0.sh'
allowed "#3837 route 7, left as it is: a script that posts behind four others, of which the last is 270 KB, is judged by the names in it and passes"

echo "== route 8: a write that is only quoted words, in a text the reader gave up on =="

printf '%s\n' 'cp post.sh made.sh' "echo 'a \$(printf true > made.sh) b'" 'echo "never closed' > "$P/body8.sh"
printf '%s\n' "echo 'a \$(printf true > kept.sh) b'" 'echo "never closed' > "$P/body8b.sh"
printf '%s\n' "$POST" > "$P/kept.sh"
printf '%s\n' 'cp post.sh made.sh' 'printf true > made.sh' > "$P/body8c.sh"
printf '%s\n' "echo 'a \$(printf true > other.sh) b'" 'echo "never closed' > "$P/body8d.sh"

run_here 'bash body8.sh ; bash made.sh'
refused "#3837 route 8: a quoted write in a script the reader gave up on does not replace what a file was copied from"
run_here 'bash body8b.sh ; bash kept.sh'
refused "#3837 route 8: and what a file holds on disk is still read"
run_here "bash -c 'cp post.sh made.sh
echo \"a (printf true > made.sh) b\"
echo \"never closed'; bash made.sh"
refused "#3837 route 8: the same inside a string handed to bash -c that the reader gave up on is refused"
run_here "eval 'cp post.sh made.sh
echo \"a (printf true > made.sh) b\"
echo \"never closed'; bash made.sh"
refused "#3837 route 8: and inside a string handed to eval"
run_here "bash -c 'cp post.sh made.sh; printf true > made.sh'; bash made.sh"
allowed "#3837 route 8: a real write in a string the reader can read still replaces what was noted"
run_here 'bash body8c.sh ; bash made.sh'
allowed "#3837 route 8: a real write in a script the reader can read still replaces what was noted"
run_here 'cp post.sh made.sh; printf true > made.sh; bash made.sh'
allowed "#3837 route 8: and so does one on the line that was typed"
run_here 'bash body8d.sh ; bash calm.sh'
allowed "#3837 route 8: a script the reader gave up on, whose quoted write names another file, still passes"

echo "== left as they are: routes 4 and 9 =="

printf '%s\n' 'export PATH="/opt/homebrew/bin:$PATH"' 'cat calm.sh > run2.sh' 'bash run2.sh' > "$P/inside4.sh"
run_here 'bash inside4.sh'
allowed "#3837 route 4, not closed: PATH named inside a script on disk leaves cat believed there"
printf '%s\n' 'import pathlib, sys' 'out = open("copy-out.txt", "w")' \
  'for f in sorted(pathlib.Path(sys.argv[1]).glob("*.jsonl")):' '    out.write(f.read_text())' > "$P/copy.py"
printf '%s\n' '{"text": "names https://slack.com/api/chat.postMessage"}' > "$P/recs/s.jsonl"
run_here 'python3 copy.py recs'
allowed "#3837 route 9, not closed: a script that can write, handed a folder holding a file that names an endpoint, passes"
run_here 'python3 copy.py recs/s.jsonl'
refused "#3837 route 9: the same script handed that file is refused, as before"

echo

echo "passed: $pass, failed: $fail"

printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"

[ "$fail" -eq 0 ]
