#!/usr/bin/env bash
# Tests for the rest of claude-config#3440: what the Slack drafts gate reads a program as writing
# by its name (lib/program-writes.py note_program) is believed only where the program the shell
# would run is for certain the system's own, by the one judgement lib/exact-output.py already
# makes for sed, git, cat, cp and tee (system_program). Kept apart from
# test-slack-drafts-reads-more.sh, which holds that judgement's first readings, so neither suite
# grows past its wall clock; the helpers below are copied from that one as they are, so a case
# here is driven the same way: a hook payload piped into slack-drafts-only-gate.sh, exit 0 allowed
# and 2 refused, the reason on stderr.
#
# Nothing a case names is ever run by a shell: the gate only reads. The programs this suite runs
# itself are this Mac's own tar, zip and git, by their bare names, to make the fixtures. The
# fixtures name Slack's public API address and hold no token, webhook address or channel.
#
# Every command below marked NEW was ALLOWED on this change's base (6c4cee7247, 2026-11-26): the
# folder holds a script named for the program, which writes a line that posts over every script
# beside it, and the gate read the file that is then run as what the system's program of that
# name would have left there. Each is refused now as a check that could not be made, as the same
# command is with a program the gate does not know (the first two cases, which were refused on
# that base too). What is held, one program at a time:
#   * by its bare name, or by a path in one of the system's folders, each program is read as
#     before: a file it leaves quiet passes, and a post in what it writes is a post found;
#   * by any other path, behind a word that runs it for the shell, as a function or an alias of
#     its name, with PATH named in the command, or where the session's PATH holds the folder
#     itself, every file it names, unpacks, edits, checks out or builds may hold anything;
#   * the shell's own words and builtins are not looked for on PATH, so PATH named in the command
#     leaves them as they were;
#   * a post in what the system's program would have written is still refused.
#
# Not held here, and seen ALLOWED on that base and on this change: each of these programs behind
# a word that runs it for the shell (`command dd if=calm.sh of=run.sh; bash run.sh`, and the same
# for tar, sed -i, a git checkout and chmod; `env true run.sh; bash run.sh` and `env PATH=. test -f
# run.sh; bash run.sh`, where env runs a program named for a builtin). The words note_program is
# handed begin at the program, and the gate's note_writes does not hand over the command as
# written, so the judgement cannot see the word in front. Handing it over is one argument at that
# call in slack_drafts_only_gate.py (`self.note_program(name, args, vals, d, stdin, text)`), which
# this change does not make; named_certain already refuses the form once it can see it.
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
# Started from a git hook or a rebase's exec line, the suite inherits git's own variables, and a
# GIT_DIR there outranks the -C its fixture repository is made with: the init, commit and checkout
# below would land in the repository the hook belongs to. So none of them is carried.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX GIT_COMMON_DIR GIT_OBJECT_DIRECTORY

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)" | sed '2,$s/^/  /'; fi; }

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
run() { run_raw "$(payload Bash "$(bash_input "$1")" "${2:-$M}")"; } # run <command> [the folder it runs in]

refused() { if [ "$RC" -eq 2 ]; then check "$1" ok; else check "$1" "exit $RC, stdout: ${OUT:0:200}, stderr: ${ERR:0:300}"; fi; }
allowed() { if [ "$RC" -eq 0 ] && [ -z "$(printf '%s%s' "$OUT" "$ERR" | tr -d '[:space:]')" ]; then check "$1" ok
            else check "$1" "exit $RC, stdout: ${OUT:0:200}, stderr: ${ERR:0:300}"; fi; }
says() { case "$ERR" in *"$2"*) check "$1" ok ;; *) check "$1" "stderr did not say '$2': ${ERR:0:400}" ;; esac; }
POST="curl -s -X POST -d text=hi https://slack.com/api/chat.postMessage"
FOUND="REFUSED: this command posts to Slack"
UNREAD="the gate could not check whether this command posts to Slack"
found() { refused "#3440 $1 is refused"; says "#3440 $1: as a post found" "$FOUND"; }
unsure() { refused "#3440 NEW $1 is refused"; says "#3440 NEW $1: as a check that could not be made" "REFUSED: $UNREAD"; }
kept() { refused "#3440 $1 is still refused"; }
still() { allowed "#3440 $1 still passes"; }
run_path() { local keep="$PATH"; export PATH="$1"; run "$2" "${3:-$M}"; export PATH="$keep"; }

# The folder every case runs in. Each program named here is a script that writes a line that
# posts over every script beside it, through a name the gate cannot work out, so the gate's own
# reading of the script (which it makes of any script on disk) notes no file.
M="$T/m"
mkdir -p "$M/into" "$M/src"
printf '%s\n' '#!/bin/sh' 'for f in ./*.sh; do' "  echo '$POST' > \"\$f\"" 'done' > "$M/frob"
for n in dd tar unzip sed awk git python3 node perl esbuild tsc cc chmod touch grep; do cp "$M/frob" "$M/$n"; done
chmod +x "$M/frob" "$M/dd" "$M/tar" "$M/unzip" "$M/sed" "$M/awk" "$M/git" "$M/python3" "$M/node" "$M/perl" \
  "$M/esbuild" "$M/tsc" "$M/cc" "$M/chmod" "$M/touch" "$M/grep"
printf '%s\n' "fetch('https://slack.com/api/chat.postMessage', {method: 'POST', body: 'text=hi'})" > "$M/src/p.ts"
printf '%s\n' 'int main(void) { return 0; }' > "$M/tool.c"
printf '%s\n' 'echo ok' > "$M/calm.sh"
printf '%s\n' 'echo ok' > "$M/run.sh"
printf '%s\n' "$POST" > "$M/posts.sh"
printf '%s\n' 'import sys' 'print(len(open(sys.argv[1]).read()))' > "$M/reads.py"
printf '%s\n' 'console.log(1)' > "$M/src/a.ts"
PM="export PATH=$M:\$PATH;"

echo "slack drafts only: a program the gate does not know, naming the file that is then run (claude-config#3440)"
# Refused on the base too: what every NEW case below is held to.
run "./frob if=calm.sh of=run.sh; bash run.sh";     kept "a program the gate does not know, handed of=,"
run "./frob run.sh; bash run.sh";                   kept "a program the gate does not know, handed the script,"

echo "slack drafts only: what dd copies is believed only of the system's own dd (claude-config#3440)"
run "dd if=calm.sh of=run.sh; bash run.sh";         still "dd by its bare name"
run "/bin/dd if=calm.sh of=run.sh; bash run.sh";    still "dd by its path in a system folder"
run "dd if=posts.sh of=run.sh; bash run.sh";        found "dd by its bare name, of a file that posts,"
run "dd if=calm.sh of=other.sh; bash calm.sh";      still "the system's dd, for the file it copied from,"
run "./dd if=calm.sh of=run.sh; bash run.sh";       unsure "a script named dd, run by its path in the folder,"
run "$M/dd if=calm.sh of=run.sh; bash run.sh";      unsure "a script named dd, run by a whole path outside the system's folders,"
run "$PM dd if=calm.sh of=run.sh; bash run.sh";     unsure "dd after PATH is exported"
run "./dd if=calm.sh of=other.sh; bash calm.sh";    unsure "a script named dd, for the file it was handed to copy from,"
run "dd() { ./frob; }; dd if=calm.sh of=run.sh; bash run.sh"; refused "#3440 NEW a function named dd, whose output file is run, is refused"
run_path ".:$PATH" "dd if=calm.sh of=run.sh; bash run.sh"; unsure "dd where the session's PATH holds the folder itself"
run "./dd if=posts.sh of=run.sh; bash run.sh";      kept "a script named dd, of a file that posts,"

echo "slack drafts only: what tar and unzip unpack is believed only of the system's own (claude-config#3440)"
if (cd "$M" && cp calm.sh a.sh && cp posts.sh p.sh && tar -cf a.tar a.sh && tar -cf p.tar p.sh && zip -q a.zip a.sh && rm a.sh p.sh) 2>/dev/null; then
  run "tar -xf a.tar; bash a.sh";                   still "tar by its bare name"
  run "/usr/bin/tar -xf a.tar; bash a.sh";          still "tar by its path in a system folder"
  run "tar -xf p.tar; bash p.sh";                   found "tar by its bare name, of an archive holding a file that posts,"
  run "unzip -o a.zip; bash a.sh";                  still "unzip by its bare name"
  run "./tar -xf a.tar; bash a.sh";                 unsure "a script named tar, run by its path in the folder,"
  run "$PM tar -xf a.tar; bash a.sh";               unsure "tar after PATH is exported"
  run "./tar -xf a.tar -C into; bash into/a.sh";    unsure "a script named tar, unpacking into a folder,"
  run "./unzip -o a.zip; bash a.sh";                unsure "a script named unzip"
  run "$PM unzip -o a.zip; bash a.sh";              unsure "unzip after PATH is exported"
  run_path ".:$PATH" "tar -xf a.tar; bash a.sh";    unsure "tar where the session's PATH holds the folder itself"
  run "./tar -xf p.tar; bash p.sh";                 kept "a script named tar, of an archive holding a file that posts,"
else
  # tar or zip could not make an archive here, a state this suite cannot set (L411).
  echo "SUITE-PART-UNMEASURED #3440: what tar and unzip unpack: tar or zip could not make an archive under $T"
fi

echo "slack drafts only: what sed and awk write is believed only of the system's own (claude-config#3440)"
run "sed -i '' 's/ok/fine/' run.sh; bash run.sh";   still "sed -i by its bare name"
run "/usr/bin/sed -i '' 's/ok/fine/' run.sh; bash run.sh"; still "sed -i by its path in a system folder"
run "sed -i '' 's|ok|$POST|' run.sh; bash run.sh";  kept "sed -i by its bare name, putting in a line that posts,"
run "sed -n p calm.sh; bash calm.sh";               still "the system's sed, for a file it only reads,"
run "awk '{print > \"run.sh\"}' calm.sh; bash run.sh"; still "awk by its bare name, printing into a file,"
run "./sed -i '' 's/ok/fine/' run.sh; bash run.sh"; unsure "a script named sed, handed -i,"
run "$PM sed -i '' 's/ok/fine/' run.sh; bash run.sh"; unsure "sed -i after PATH is exported"
run "./sed 's/ok/fine/w run.sh' calm.sh; bash run.sh"; unsure "a script named sed, whose program names a file to write,"
run "./sed -n p calm.sh; bash calm.sh";             unsure "a script named sed, for the file it was handed to read,"
run "./awk '{print > \"run.sh\"}' calm.sh; bash run.sh"; unsure "a script named awk, printing into a file,"
run "$PM awk '{print > \"run.sh\"}' calm.sh; bash run.sh"; unsure "awk after PATH is exported"
run "./awk '{print}' calm.sh; bash calm.sh";        unsure "a script named awk, for the file it was handed to read,"
run_path ".:$PATH" "sed -i '' 's/ok/fine/' run.sh; bash run.sh"; unsure "sed -i where the session's PATH holds the folder itself"
run "./sed -i '' 's|ok|$POST|' run.sh; bash run.sh"; kept "a script named sed, putting in a line that posts,"

echo "slack drafts only: the code an interpreter is given is followed only for the system's own (claude-config#3440)"
PY="-c \"open('run.sh','w').write('echo ok')\""
run "python3 $PY; bash run.sh";                     still "python3 by its bare name, writing a quiet file,"
run "python3 reads.py run.sh; bash run.sh";         still "python3 by its bare name, running a script on disk handed the file,"
run "./python3 $PY; bash run.sh";                   unsure "a script named python3, given code that names the file,"
run "$PM python3 $PY; bash run.sh";                 unsure "python3 given code, after PATH is exported,"
run "./python3 reads.py run.sh; bash run.sh";       unsure "a script named python3, handed the file,"
run "./node -e \"require('fs').writeFileSync('run.sh','echo ok')\"; bash run.sh"; unsure "a script named node, given code that names the file,"
run "./perl -pi -e 's/ok/fine/' run.sh; bash run.sh"; unsure "a script named perl, editing the file in place,"

echo "slack drafts only: a curl config written by code a doubted program is given is still searched (claude-config#3440)"
# The one route the first version of this change newly ALLOWED (an independent read of pull request
# 3782, 2026-11-27, then seen on a run: refused on main, allowed at 7928694089). A file named only
# in the code a program is given (sed's w, awk's print >, an open() in python3 -c) is read as that
# code and the files it reads. Where the program was not certain to be the system's own, that
# reading was REPLACED by a piece the gate could not read, and the check of a curl config a
# command leaves (curlrc_written, #2893) refuses only an endpoint it finds, so the endpoint went
# unseen. The reading is now kept beside the unreadable piece, as it is for dd, tar and git.
# HOME is a throwaway folder: no real ~/.curlrc is read or named. The endpoint is the method's
# name alone, or behind a made up host.
CH="$T/curl"
mkdir -p "$CH"
RC="$CH/.curlrc"
printf '%s\n' 'silent' > "$RC"
printf '%s\n' 'url = "https://hooks.example.invalid/api/chat.postMessage"' > "$M/rc.txt"
curl_run() { CURL_HOME="$CH" HOME="$CH" run "$1"; }
rc_found() { refused "#3440 $1 is still refused"; says "#3440 $1: for the config it leaves" "a config file curl reads by default"; }
SED_RC="sed -n 's/^.*\$/url = chat.postMessage/w $RC' calm.sh"
AWK_RC="awk 'BEGIN { print \"url = chat.postMessage\" > \"$RC\" }'"
COPY_RC="sed -n 'w $RC' rc.txt"
QUIET_RC="sed -n 's/^.*\$/silent/w $RC' calm.sh"
curl_run "$QUIET_RC";                               still "sed by its bare name, writing a curl config that names no endpoint,"
curl_run "$PM $QUIET_RC";                           still "sed after PATH is exported, writing a curl config that names no endpoint,"
curl_run "$SED_RC";                                 rc_found "sed by its bare name, writing a curl config that names an endpoint,"
curl_run "$PM $SED_RC";                             rc_found "sed after PATH is exported, writing a curl config that names an endpoint,"
curl_run "$AWK_RC";                                 rc_found "awk by its bare name, printing an endpoint into a curl config,"
curl_run "$PM $AWK_RC";                             rc_found "awk after PATH is exported, printing an endpoint into a curl config,"
curl_run "$COPY_RC";                                rc_found "sed by its bare name, copying a file that names an endpoint into a curl config,"
curl_run "$PM $COPY_RC";                            rc_found "sed after PATH is exported, copying a file that names an endpoint into a curl config,"
curl_run "./$SED_RC";                               kept "a script named sed, writing a curl config that names an endpoint,"

echo "slack drafts only: what git checks out is believed only of the system's own git (claude-config#3440)"
R="$T/repo"
mkdir -p "$R"
gitq() { git -C "$R" -c user.name=suite -c user.email=suite@example.invalid "$@" >/dev/null 2>&1; }
if gitq init -q && printf '%s\n' 'echo ok' > "$R/calm.sh" && gitq add calm.sh && gitq commit -q -m first \
   && gitq checkout -q -b other && printf '%s\n' 'echo fine' > "$R/calm.sh" && gitq commit -q -a -m second \
   && gitq checkout -q -; then
  cp "$M/git" "$R/git"
  run "git checkout other; bash calm.sh" "$R";      still "a git checkout of a branch whose file is quiet"
  run "./git checkout other; bash calm.sh" "$R";    unsure "a script named git, checking out a branch,"
  run "export PATH=$R:\$PATH; git checkout other; bash calm.sh" "$R"; unsure "a git checkout after PATH is exported"
  run "git status calm.sh; bash calm.sh" "$R";      still "the system's git status, for a file it is handed,"
  run "./git status calm.sh; bash calm.sh" "$R";    unsure "a script named git, handed status and a file,"
else
  echo "SUITE-PART-UNMEASURED #3440: what git checks out: git could not make a repository with two branches under $T"
fi

echo "slack drafts only: what a compiler builds is read as its sources only for the system's own (claude-config#3440)"
run "esbuild src/a.ts --outfile=out.js; node out.js"; still "esbuild by its bare name"
run "./esbuild src/a.ts --outfile=out.js; node out.js"; unsure "a script named esbuild, run by its path in the folder,"
run "$PM esbuild src/a.ts --outfile=out.js; node out.js"; unsure "esbuild after PATH is exported"
run "./esbuild src/a.ts --outdir=dist; node dist/a.js"; unsure "a script named esbuild, building into a folder,"
run "tsc src/a.ts; node src/a.js";                  still "tsc by its bare name"
run "./tsc src/a.ts; node src/a.js";                unsure "a script named tsc"
run "$PM tsc src/a.ts; node src/a.js";              unsure "tsc after PATH is exported"
run "cc tool.c -o tool; ./tool";                    still "cc by its bare name"
run "./cc tool.c -o tool; ./tool";                  unsure "a script named cc, for the tool it builds,"
run "$PM cc tool.c -o tool; ./tool";                unsure "cc after PATH is exported"
# A post in a source is still found, or the build still refused, whoever the compiler is.
run "esbuild src/p.ts --outfile=out.js; node out.js"; kept "esbuild by its bare name, of a source that posts,"
run "./esbuild src/p.ts --outfile=out.js; node out.js"; kept "a script named esbuild, of a source that posts,"
run "tsc src/p.ts; node src/p.js";                  kept "tsc by its bare name, of a source that posts,"
run "./tsc src/p.ts; node src/p.js";                kept "a script named tsc, of a source that posts,"

echo "slack drafts only: a program is taken to write nothing only where it is the system's own (claude-config#3440)"
run "chmod +x run.sh; bash run.sh";                 still "chmod by its bare name"
run "/bin/chmod +x run.sh; bash run.sh";            still "chmod by its path in a system folder"
run "grep -c ok run.sh; bash run.sh";               still "grep by its bare name"
run "./chmod +x run.sh; bash run.sh";               unsure "a script named chmod"
run "./touch run.sh; bash run.sh";                  unsure "a script named touch"
run "$PM chmod +x run.sh; bash run.sh";             unsure "chmod after PATH is exported"
run "$PM grep -c ok run.sh; bash run.sh";           unsure "grep after PATH is exported"
run "chmod() { ./frob; }; chmod +x run.sh; bash run.sh"; refused "#3440 NEW a function named chmod, handed the script that is then run, is refused"
run "$PM bash -c 'chmod +x run.sh; bash run.sh'";   unsure "chmod in a command string, after PATH is exported around it,"
run_path ".:$PATH" "chmod +x run.sh; bash run.sh";  unsure "chmod where the session's PATH holds the folder itself"

echo "slack drafts only: the refusal says why the program is doubted and what is believed instead (claude-config#3440)"
# One sentence served every cause ("chmod, which is not certain to be the system's own chmod"), so a
# session could not tell a path from the word PATH from a function of the name, nor that the full
# path in a system folder passes. Each cause now has its own words, and the form that is believed.
why() { says "#3440 the refusal of $1 says why" "$2"; }
run "./chmod +x run.sh; bash run.sh"
why "a script named chmod" "because it is run by the path ./chmod, which is outside the folders this gate takes for the system's"
says "#3440 the refusal of a script named chmod names the full path that is believed" "or by its full path, /bin/chmod, it is taken for the system's own"
run "$PM chmod +x run.sh; bash run.sh"
why "chmod after PATH is exported" "because the word PATH appears in this command, and PATH decides where the shell finds a bare name"
says "#3440 the refusal of chmod after PATH is exported names the full path that is believed" "written by its full path, /bin/chmod, it is taken for the system's own"
# What that refusal says to write instead does pass.
run "$PM /bin/chmod +x run.sh; bash run.sh";        still "chmod by the full path the refusal names, after PATH is exported,"
run "chmod() { ./frob; }; chmod +x run.sh; bash run.sh"
why "a function named chmod" "because this command defines a function or an alias named chmod"
run_path ".:$PATH" "chmod +x run.sh; bash run.sh"
why "chmod where the session's PATH holds the folder itself" "because the session's PATH holds a folder that is not written as a whole path"
run "env cat calm.sh > run.sh; bash run.sh";        refused "#3440 cat behind env, whose output is then run, is refused"
why "cat behind env" "because a word in front of it runs it for the shell"

echo "slack drafts only: the shell's own words are not doubted because PATH is named (claude-config#3440)"
# The shell's own words and builtins are not looked for on PATH, so these pass as they did. Each
# case hands the word the script that is then run, with PATH named in the command: with the word
# taken out of BUILTINS (lib/exact-output.py) it is a program looked for on PATH, the script is
# one it may have written, and the case fails. Each was seen to fail that way (2026-11-27).
run "$PM test -f run.sh && bash run.sh";            still "the shell's own test after PATH is exported"
run "$PM export SCRIPT=run.sh; bash run.sh";        still "the shell's own export after PATH is exported"
run "$PM echo 'echo ok' > run.sh; bash run.sh";     still "the shell's own echo, writing the script, after PATH is exported"
run "$PM printf 'echo ok\n' > run.sh; bash run.sh"; still "the shell's own printf, writing the script, after PATH is exported"
for own in type hash true false : unset set declare typeset readonly local kill wait read alias umask ulimit let shift getopts; do
  run "$PM $own run.sh; bash run.sh";               still "the shell's own $own, handed the script, after PATH is exported"
done

echo

echo "passed: $pass, failed: $fail"

printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
