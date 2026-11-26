#!/usr/bin/env bash
# Tests for the payload write gate reading three routes it let through (claude-config#3689).
#
# 1. The command string an inline script hands to a shell (os.system, subprocess given one string,
#    perl, ruby, php and awk system, node execSync): its words sit inside a quoted string with
#    spaces in it, which the gate's match for a quoted payload path never read. #3537 read that
#    string for ln only.
# 2. A destination written as a pattern that expands to a payload file (pay*/hooks/x.sh).
# 3. A link made by a script FILE the command runs, where #3537 read only an inline script.
#
# Every file here is a stand in under a temporary folder. The watcher is a real process with a
# real command line, for the reason test-payload-write-gate.sh gives (L52).
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/payload-write-gate.sh"

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }
not_run(){ # not_run <why>
  echo "test-payload-write-gate-script-string: $1" >&2
  printf 'SUITE-NOT-RUN %s\n' "$1"
  echo "passed: $pass, failed: $fail"
  printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
  exit 2
}
[ -f "$HOOK" ] || not_run "needs payload-write-gate.sh beside it"

FIX="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/payload-write-gate-string.XXXXXXXX")" && pwd -P)"
trap 'rm -rf "$FIX"; [ -n "${WPID:-}" ] && kill "$WPID" 2>/dev/null; true' EXIT

# Two clones, as in the sibling suites: the development checkout and the one the daemon runs from.
mkdir -p "$FIX/dev/payload/hooks" "$FIX/dev/tests" "$FIX/src/payload/hooks" "$FIX/elsewhere" "$FIX/links" "$FIX/state" "$FIX/scripts"
: > "$FIX/dev/claude-sync"
: > "$FIX/src/claude-sync"
: > "$FIX/dev/payload/LESSONS.md"
: > "$FIX/dev/payload/hooks/x.sh"
: > "$FIX/src/payload/LESSONS.md"
: > "$FIX/elsewhere/a.txt"
: > "$FIX/elsewhere/b.txt"
: > "$FIX/elsewhere/twice.txt"
git init -q "$FIX/dev" 2>/dev/null
git init -q "$FIX/src" 2>/dev/null
[ -e "$FIX/dev/.git" ] && [ -e "$FIX/src/.git" ] || not_run "the fixture checkouts could not be made git checkouts"

ln -s "$FIX/dev/payload/hooks/x.sh" "$FIX/links/sym.sh"
ln "$FIX/elsewhere/twice.txt" "$FIX/links/twice-again.txt"

HOLD="$FIX/hold"
PIDF="$FIX/watch.pid"
( bash -c 'exec -a "'"$FIX"'/src/claude-sync watch" sleep 300' </dev/null >/dev/null 2>&1 &
  printf '%s\n' "$!" > "$PIDF" ) </dev/null >/dev/null 2>&1
WPID="$(cat "$PIDF" 2>/dev/null)"
for _ in $(seq 1 200); do
  case "$(ps -o command= -p "$WPID" 2>/dev/null || true)" in *claude-sync*watch*) break ;; esac
done
case "$(ps -o command= -p "$WPID" 2>/dev/null || true)" in
  *claude-sync*watch*) ;;
  *) not_run "the fixture watcher process could not be started with a readable command line" ;;
esac

RC=0; OUT=""
unset CLAUDE_CODE_SESSION_ID
SID=""
ME="11111111-aaaa-4bbb-8ccc-000000000001"
edit(){ # edit <file path> <cwd>
  OUT="$(python3 -c '
import json, sys
print(json.dumps({"tool_name": "Edit", "session_id": sys.argv[3], "cwd": sys.argv[2], "tool_input": {"file_path": sys.argv[1]}}))
' "$1" "$2" "$SID" | env SYNC_WATCH_PID_FILE="$PIDF" SYNC_HOLD_FILE="$HOLD" PAYLOAD_WRITE_STATE_DIR="$FIX/state" bash "$HOOK" 2>&1)"; RC=$?
}
runbash(){ # runbash <command> <cwd>
  OUT="$(python3 -c '
import json, sys
print(json.dumps({"tool_name": "Bash", "session_id": sys.argv[3], "cwd": sys.argv[2], "tool_input": {"command": sys.argv[1]}}))
' "$1" "$2" "$SID" | env SYNC_WATCH_PID_FILE="$PIDF" SYNC_HOLD_FILE="$HOLD" PAYLOAD_WRITE_STATE_DIR="$FIX/state" bash "$HOOK" 2>&1)"; RC=$?
}
refused(){ if [ "$RC" -eq 2 ]; then check "$1" ok; else check "$1" "exit $RC, said: ${OUT:0:160}"; fi; }
allowed(){
  if [ "$RC" -eq 0 ] && [ -z "$(printf '%s' "$OUT" | tr -d '[:space:]')" ]; then check "$1" ok
  else check "$1" "exit $RC, said: ${OUT:0:160}"; fi
}
says(){ case "$OUT" in *"$2"*) check "$1" ok ;; *) check "$1" "did not say '$2'" ;; esac; }

# The fixture is only a fixture if the plain write is refused and a plain write elsewhere is not.
edit "$FIX/dev/payload/hooks/x.sh" "$FIX/dev"
refused "control: the stand in payload file is refused by its own name"
runbash "echo x > $FIX/elsewhere/a.txt" "$FIX/elsewhere"
allowed "control: a write outside any checkout is let through"
runbash "cp $FIX/elsewhere/a.txt $FIX/dev/payload/hooks/new.sh" "$FIX/elsewhere"
refused "control: the copy typed directly is refused"

echo "a command string an inline script hands to a shell"

runbash "python3 -c \"import os; os.system('cp $FIX/elsewhere/a.txt $FIX/dev/payload/hooks/new.sh')\"" "$FIX/elsewhere"
refused "#3689 a copy run by os.system is refused"
says "#3689 and the refusal names the file it writes" "$FIX/dev/payload/hooks/new.sh"
runbash "python3 -c \"import os; os.system('cp /etc/hosts payload/hooks/new.sh')\"" "$FIX/dev"
refused "#3689 a copy run by os.system to a relative payload path is refused"
runbash "python3 -c 'import os; os.system(\"cp /etc/hosts payload/hooks/new.sh\")'" "$FIX/dev"
refused "#3689 the same with the string in double quotes"
runbash "python3 -c \"import os; os.system(\\\"cp /etc/hosts payload/hooks/new.sh\\\")\"" "$FIX/dev"
refused "#3689 the same with the quotes of the string escaped"
runbash "python3 -c \"import subprocess; subprocess.run('mv $FIX/elsewhere/a.txt $FIX/dev/payload/hooks/x.sh', shell=True)\"" "$FIX/elsewhere"
refused "#3689 a move run by subprocess given one string is refused"
runbash "python3 -c \"import subprocess; subprocess.call('rm -f payload/hooks/x.sh', shell=True)\"" "$FIX/dev"
refused "#3689 a remove run by subprocess.call is refused"
runbash "python3 -c \"import subprocess; subprocess.check_output('touch payload/hooks/new.sh', shell=True)\"" "$FIX/dev"
refused "#3689 a touch run by subprocess.check_output is refused"
runbash "python3 -c \"import os; os.popen('tee payload/hooks/new.sh')\"" "$FIX/dev"
refused "#3689 a tee run by os.popen is refused"
runbash "python3 -c \"import os; os.system('echo x > $FIX/links/sym.sh')\"" "$FIX/elsewhere"
refused "#3689 a redirect in the string through a link that lives elsewhere is refused"
says "#3689 and the refusal names the file it really is" "$FIX/dev/payload/hooks/x.sh"
runbash "python3 -c \"import os; os.system('cp $FIX/elsewhere/a.txt $FIX/links/sym.sh')\"" "$FIX/elsewhere"
refused "#3689 a copy in the string through that link is refused"
runbash "python3 -c \"import os; os.system('sed -i -e s/a/b/ payload/hooks/x.sh')\"" "$FIX/dev"
refused "#3689 an in place sed in the string is refused"
runbash "python3 -c \"import os; os.system('true && cp /etc/hosts payload/hooks/new.sh')\"" "$FIX/dev"
refused "#3689 the second command of the string is read"
runbash "python3 -c \"import os; os.system('cd payload/hooks; rm x.sh')\"" "$FIX/dev"
refused "#3689 a cd inside the string moves the commands after it"
runbash "python3 -c \"import os; os.system('cd $FIX/dev/payload/hooks && touch new.sh')\"" "$FIX/elsewhere"
refused "#3689 so does a cd to a full path"
runbash "python3 -c \"import os; os.system('bash -c \\\"cp /etc/hosts payload/hooks/new.sh\\\"')\"" "$FIX/dev"
refused "#3689 a shell the string runs has its own string read"
runbash "cd $FIX/dev && python3 -c \"import os; os.system('rm payload/hooks/x.sh')\"" "$FIX/elsewhere"
refused "#3689 the string runs where a cd before the script left it"
runbash "python3 - <<'EOF'
import os
os.system('cp /etc/hosts payload/hooks/new.sh')
EOF" "$FIX/dev"
refused "#3689 a script fed to python as a heredoc"
runbash "perl -e 'system \"cp $FIX/elsewhere/a.txt $FIX/dev/payload/hooks/new.sh\"'" "$FIX/elsewhere"
refused "#3689 perl system with no brackets"
runbash "perl -e 'system(\"rm payload/hooks/x.sh\")'" "$FIX/dev"
refused "#3689 perl system with brackets"
runbash "perl -e 'my \$o = \`cp /etc/hosts payload/hooks/new.sh\`;'" "$FIX/dev"
refused "#3689 a perl command in backquotes"
runbash "perl -e 'exec \"mv $FIX/elsewhere/a.txt $FIX/dev/payload/LESSONS.md\"'" "$FIX/elsewhere"
refused "#3689 perl exec"
runbash "ruby -e 'system(\"cp /etc/hosts payload/hooks/new.sh\")'" "$FIX/dev"
refused "#3689 ruby system"
runbash "ruby -e '%x(rm payload/hooks/x.sh)'" "$FIX/dev"
refused "#3689 ruby %x"
runbash "php -r 'shell_exec(\"rm payload/hooks/x.sh\");'" "$FIX/dev"
refused "#3689 php shell_exec"
runbash "node -e \"require('child_process').execSync('cp /etc/hosts payload/hooks/new.sh')\"" "$FIX/dev"
refused "#3689 node execSync"
runbash "awk 'BEGIN { system(\"cp /etc/hosts payload/hooks/new.sh\") }'" "$FIX/dev"
refused "#3689 awk system"
runbash "python3 -c \"import subprocess; subprocess.run(['cp', '/etc/hosts', 'payload/hooks/new.sh'])\"" "$FIX/dev"
refused "#3689 a copy given to subprocess as a list of words"
runbash "python3 -c \"import subprocess; subprocess.run(['rm', '$FIX/links/sym.sh'])\"" "$FIX/elsewhere"
refused "#3689 a list of words removing a link that leads into payload"
runbash "python3 -c \"import os; n = 'new.sh'; os.system(f'cp /etc/hosts payload/hooks/{n}')\"" "$FIX/dev"
refused "#3689 a string with a value filled in, whose words name payload"
runbash "python3 -c \"import os; n = 'new.sh'; os.system('cp /etc/hosts payload/hooks/' + n)\"" "$FIX/dev"
refused "#3689 a string joined to a value, whose words name payload"

echo "a string it cannot tell"

runbash "python3 -c \"import os, sys; os.system(sys.argv[1])\" 'cp /etc/hosts payload/hooks/new.sh'" "$FIX/dev"
refused "#3689 a command held in a value, in a call that names payload, is refused"
says "#3689 in words that say it could not tell" "could not tell what"
says "#3689 and what to do instead" "Run the command directly"
runbash "python3 -c \"import subprocess; c = 'c' + 'p /etc/hosts payload/hooks/new.sh'; subprocess.run(c, shell=True)\"" "$FIX/dev"
refused "#3689 the same for subprocess given a value"
says "#3689 in the same words" "could not tell what"
runbash "python3 -c \"import os; t = 'cp'; os.system(f'{t} /etc/hosts payload/hooks/new.sh')\"" "$FIX/dev"
refused "#3689 a string whose program is a value filled in"
says "#3689 says it could not tell" "could not tell what"
runbash "perl -e 'system(\$ARGV[0])' 'rm payload/hooks/x.sh'" "$FIX/dev"
refused "#3689 perl system given a value"
runbash "cd payload/hooks && python3 -c \"import os, sys; os.system(sys.argv[1])\" 'rm x.sh'" "$FIX/dev"
refused "#3689 a value run from inside payload needs no payload word"
says "#3689 and says it could not tell" "could not tell what"
SID="$ME"
printf '%s %s host session=%s my work\n' "$(( $(date +%s) + 3600 ))" "$(date +%s)" "$ME" > "$HOLD"
runbash "python3 -c \"import os, sys; os.system(sys.argv[1])\" 'cp /etc/hosts payload/hooks/new.sh'" "$FIX/dev"
allowed "#3689 control: this session's own hold lets it through"
rm -f "$HOLD"; SID=""

echo "a string that writes nowhere near payload"

runbash "python3 -c \"import os; os.system('cp $FIX/elsewhere/a.txt $FIX/elsewhere/b.txt')\"" "$FIX/elsewhere"
allowed "#3689 control: a copy between two files outside any checkout is let through"
runbash "python3 -c \"import os; os.system('cat payload/hooks/x.sh')\"" "$FIX/dev"
allowed "#3689 control: a string that only reads a payload file is let through"
runbash "python3 -c \"import os; os.system('grep -n rm payload/hooks/x.sh | head -3')\"" "$FIX/dev"
allowed "#3689 control: so is a search of one for a writer's name"
runbash "python3 -c \"import subprocess; subprocess.run(['git', 'status'])\"" "$FIX/dev"
allowed "#3689 control: a list of words that writes nothing is let through"
runbash "python3 -c \"import subprocess; print(subprocess.run(['ls', 'payload/hooks'], capture_output=True))\"" "$FIX/dev"
allowed "#3689 control: so is a listing of a payload folder"
runbash "python3 -c \"import os, sys; os.system(sys.argv[1])\" 'ls'" "$FIX/dev"
allowed "#3689 control: a command held in a value, in a call naming no payload path, is let through"
runbash "python3 -c \"import asyncio; asyncio.run(main())\"" "$FIX/dev"
allowed "#3689 control: a call named run that runs no command is let through"
runbash "npm run 'build'" "$FIX/dev"
allowed "#3689 control: so is a tool whose own word is run"
# The shapes the count over 30 days of session records found refused for nothing, each rebuilt
# here from its shape alone: none of them hands a shell anything.
runbash "run \"\$REPO\" payload/hooks" "$FIX/dev"
allowed "#3689 control: a shell function named run, given a value, in a call naming a payload path"
runbash "node -e \"const a = \\\`\\\${x}y\\\`; console.log(a, 'payload/')\"" "$FIX/dev"
allowed "#3689 control: a template string in node, which is no command"
runbash "perl -ne 'print if /x/' payload/hooks/x.sh; node -e \"const a = \\\`\\\${x}y\\\`; console.log(a)\"" "$FIX/dev"
allowed "#3689 control: nor is one beside a perl script that reads"
runbash "echo \"os.system(...) is not read, see payload/hooks\" | wc -c" "$FIX/dev"
allowed "#3689 control: prose that writes the call with dots for its value"
runbash "git log --grep \"the call's own 'payload/' text\"" "$FIX/dev"
allowed "#3689 control: prose with the word call before a quote mark"
runbash "grep -c \"a test run\" payload/hooks/x.sh | cut -c1-20; echo \"done\"" "$FIX/dev"
allowed "#3689 control: the word run at the end of a quoted search"

echo "a destination written as a pattern"

runbash "rm pay*/hooks/x.sh" "$FIX/dev"
refused "#3689 a remove by a pattern that expands to a payload file is refused"
says "#3689 and the refusal names the file" "$FIX/dev/payload/hooks/x.sh"
runbash "echo x > $FIX/dev/pay????/LESSONS.md" "$FIX/elsewhere"
refused "#3689 a redirect to a pattern with question marks"
runbash "rm paylo[a]d/hooks/x.sh" "$FIX/dev"
refused "#3689 a pattern with a set of letters"
runbash "rm -rf *" "$FIX/dev"
refused "#3689 a star alone, in a checkout, which takes payload with it"
runbash "cp $FIX/elsewhere/a.txt $FIX/links/sy*.sh" "$FIX/elsewhere"
refused "#3689 a pattern that expands to a link leading into payload"
says "#3689 and the refusal names the file it really is" "$FIX/dev/payload/hooks/x.sh"
runbash "touch {payload,tests}/hooks/new.sh" "$FIX/dev"
refused "#3689 a list in braces, one of which is payload"
runbash "python3 -c \"import os; os.system('rm pay*/hooks/x.sh')\"" "$FIX/dev"
refused "#3689 a pattern inside a string an inline script runs"
runbash "rm $FIX/elsewhere/tw*.txt" "$FIX/elsewhere"
refused "#3689 a pattern that expands to a file with more than one name, as that file typed out is"
runbash "rm -f $FIX/elsewhere/a*.txt" "$FIX/elsewhere"
allowed "#3689 control: a pattern that expands only to files outside any checkout is let through"
runbash "rm -f $FIX/elsewhere/nothing-*.txt" "$FIX/elsewhere"
allowed "#3689 control: so is a pattern that expands to nothing"
runbash "ls pay*/hooks" "$FIX/dev"
allowed "#3689 control: a pattern in a command that only reads is let through"

# The loop over what a pattern expands to is held to a count: one file past it is refused as a
# pattern this gate could not finish reading, and exactly the count is read through.
mkdir -p "$FIX/dev/tests/many" "$FIX/dev/tests/toomany" "$FIX/toomany"
( cd "$FIX/dev/tests/many" && seq 1 512 | sed 's/$/.t/' | xargs touch )
( cd "$FIX/dev/tests/toomany" && seq 1 513 | sed 's/$/.t/' | xargs touch )
( cd "$FIX/toomany" && seq 1 513 | sed 's/$/.t/' | xargs touch )
[ "$(find "$FIX/dev/tests/many" -type f | grep -c .)" -eq 512 ] && [ "$(find "$FIX/dev/tests/toomany" -type f | grep -c .)" -eq 513 ] || not_run "the folders of 512 and 513 files could not be made"
runbash "rm -f $FIX/dev/tests/many/*" "$FIX/elsewhere"
allowed "#3689 a pattern in a checkout that expands to 512 files is read to its end"
runbash "rm -f $FIX/dev/tests/toomany/*" "$FIX/elsewhere"
refused "#3689 one that expands to 513 is refused, so the loop stops at its count"
says "#3689 in words that say it could not tell" "could not tell"
says "#3689 and that name the count" "more than 512"
runbash "rm -f $FIX/dev/tests/**/*.t" "$FIX/elsewhere"
refused "#3689 a pattern in a checkout holding two stars, which may reach any folder below"
says "#3689 says it could not tell" "could not tell"
runbash "rm -f $FIX/toomany/*" "$FIX/elsewhere"
allowed "#3689 control: a pattern outside any checkout that expands to 513 files is let through"

# The loop over the command strings of one command is held to a count the same way.
many_strings(){ python3 -c '
import sys
print("python3 -c \"import os; " + "; ".join("os.system(\x27true %d\x27)" % k for k in range(int(sys.argv[1]))) + "\" # payload/")' "$1"; }
runbash "$(many_strings 256)" "$FIX/dev"
allowed "#3689 a command holding 256 command strings is read to its end"
runbash "$(many_strings 257)" "$FIX/dev"
refused "#3689 one holding 257 is refused, so the loop stops at its count"
says "#3689 in words that name the count" "more than 256 command strings"

# A quote that never closes, after a run of backslashes, is read in a time that does not grow with
# the run. Each backslash could be read alone or with the character after it, so the search for the
# closing quote tried every way of reading the run and never ended. The gate is given a time to
# answer in, and its whole process group is stopped when it does not, so nothing is left running.
runbash_within(){ # runbash_within <seconds> <command> <cwd>: RC is 124 when the gate gave no answer in that time
  OUT="$(env SYNC_WATCH_PID_FILE="$PIDF" SYNC_HOLD_FILE="$HOLD" PAYLOAD_WRITE_STATE_DIR="$FIX/state" python3 -c '
import json, os, signal, subprocess, sys
p = json.dumps({"tool_name": "Bash", "session_id": "", "cwd": sys.argv[3], "tool_input": {"command": sys.argv[2]}})
proc = subprocess.Popen(["bash", sys.argv[4]], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True)
try:
    out, _ = proc.communicate(p.encode(), timeout=float(sys.argv[1]))
    sys.stdout.write(out.decode("utf-8", "replace"))
    sys.exit(proc.returncode)
except subprocess.TimeoutExpired:
    os.killpg(proc.pid, signal.SIGKILL)
    proc.wait()
    sys.exit(124)
' "$1" "$2" "$3" "$HOOK" 2>&1)"; RC=$?
}
UNCLOSED="$(python3 -c 'print("python3 -c \"import os; os.system(\x27" + "\\\\" * 64 + " payload/x\"")')"
runbash_within 60 "$UNCLOSED" "$FIX/dev"
if [ "$RC" -ne 124 ]; then check "#3689 a quote that never closes after 128 backslashes is answered within 60 seconds" ok
else check "#3689 a quote that never closes after 128 backslashes is answered within 60 seconds" "no answer in 60 seconds"; fi

# A string is read up to 4000 characters, so a quote that never closes costs a bounded search. A
# string longer than that, or one that never closes, is one this gate could not read, and is
# refused as untold in a call naming payload, never let through unread. Exactly the count is read.
sized_string(){ python3 -c '
import sys
body = "true " + "x" * (int(sys.argv[1]) - 5)
print("python3 -c \"import os; os.system(\x27" + body + "\x27)\" # payload/")' "$1"; }
runbash "$(sized_string 4000)" "$FIX/dev"
allowed "#3689 a string of 4000 characters that writes nothing is read to its end"
runbash "$(sized_string 4001)" "$FIX/dev"
refused "#3689 one of 4001 characters, in a call naming payload, is refused as one it could not read"
says "#3689 in words that say it could not tell" "could not tell"
LONG_COPY="$(python3 -c 'print("python3 -c \"import os; os.system(\x27cp /etc/hosts" + " " * 4000 + "payload/hooks/new.sh\x27)\"")')"
runbash "$LONG_COPY" "$FIX/dev"
refused "#3689 a copy into payload at the end of a string past the count is refused"
runbash "python3 -c \"import os; os.system('true $(printf 'x%.0s' $(seq 1 4100))')\"" "$FIX/elsewhere"
allowed "#3689 control: a string past the count in a call naming no payload path is let through"
runbash "python3 -c \"import os; os.system('ls payload/hooks; cat payload/hooks/x.sh')\"" "$FIX/dev"
allowed "#3689 control: a string holding a separator, which the cut into commands splits, is not taken for one that never closes"
runbash "echo \"we run 'em all\"; ls payload/hooks" "$FIX/dev"
allowed "#3689 control: the word run before a quote that never closes, in prose, is not taken for a string"

# And the loop over the script files of one command.
for k in 1 2 3 4 5 6 7 8 9; do printf 'print(%s)\n' "$k" > "$FIX/scripts/n$k.py"; done
many_files(){ local k out=""; for k in $(seq 1 "$1"); do out="$out python3 $FIX/scripts/n$k.py;"; done; printf '%s : payload/' "$out"; }
runbash "$(many_files 8)" "$FIX/dev"
allowed "#3689 a command running 8 script files has each read"
runbash "$(many_files 9)" "$FIX/dev"
refused "#3689 one running 9 is refused, so the loop stops at its count"
says "#3689 in words that name the count" "more than 8 script files"

echo "a link made by a script file"

printf '#!/bin/bash\nln -s %s %s\n' "$FIX/dev/payload/hooks" "$FIX/elsewhere/l1" > "$FIX/scripts/mk.sh"
printf '#!/bin/bash\necho nothing to see\nln -s %s %s\n' "$FIX/elsewhere/a.txt" "$FIX/elsewhere/l2" > "$FIX/scripts/plain.sh"
printf '#!/bin/bash\ncd %s\nln payload/LESSONS.md %s\n' "$FIX/dev" "$FIX/elsewhere/l3" > "$FIX/scripts/mkcd.sh"
printf '#!/bin/bash\nbash %s\n' "$FIX/scripts/mk.sh" > "$FIX/scripts/outer.sh"
printf 'import os\nos.symlink("%s", "%s")\n' "$FIX/dev/payload/hooks/x.sh" "$FIX/elsewhere/l4" > "$FIX/scripts/mk.py"
printf 'import os\nos.system("ln -s payload/hooks %s")\n' "$FIX/elsewhere/l5" > "$FIX/scripts/mksys.py"
printf 'import os\nprint(os.path.exists("%s"))\n' "$FIX/dev/payload/hooks/x.sh" > "$FIX/scripts/reads.py"
printf 'symlink "%s", "%s";\n' "$FIX/dev/payload/hooks/x.sh" "$FIX/elsewhere/l6" > "$FIX/scripts/mk.pl"
printf 'const fs = require("fs");\nfs.symlinkSync("%s", "%s");\n' "$FIX/dev/payload/hooks/x.sh" "$FIX/elsewhere/l7" > "$FIX/scripts/mk.js"
chmod +x "$FIX/scripts/mk.sh" "$FIX/scripts/plain.sh"

runbash "bash $FIX/scripts/mk.sh" "$FIX/elsewhere"
refused "#3689 a shell script file that links a payload folder is refused"
says "#3689 and the refusal names the folder" "$FIX/dev/payload/hooks"
runbash "$FIX/scripts/mk.sh" "$FIX/elsewhere"
refused "#3689 the same script run by its path"
runbash "source $FIX/scripts/mk.sh" "$FIX/elsewhere"
refused "#3689 and sourced"
runbash "bash $FIX/scripts/mkcd.sh" "$FIX/elsewhere"
refused "#3689 a script file that changes directory and links a payload file by a relative path"
runbash "bash $FIX/scripts/outer.sh" "$FIX/elsewhere"
refused "#3689 a script file that runs the script file that links"
runbash "python3 $FIX/scripts/mk.py" "$FIX/elsewhere"
refused "#3689 a python script file that links a payload file is refused"
runbash "python3 $FIX/scripts/mksys.py" "$FIX/dev"
refused "#3689 a python script file that runs ln as a string"
runbash "perl $FIX/scripts/mk.pl" "$FIX/elsewhere"
refused "#3689 a perl script file that links a payload file"
runbash "node $FIX/scripts/mk.js" "$FIX/elsewhere"
refused "#3689 a node script file that links a payload file"
# The options before the script file are read as each interpreter reads them: -I takes nothing in
# python, and a value glued to its option (-Werror, -Xdev) holds letters that are options elsewhere.
runbash "python3 -I $FIX/scripts/mk.py" "$FIX/elsewhere"
refused "#3689 a python script file after an option that takes no value in python"
runbash "python3 -Werror $FIX/scripts/mk.py" "$FIX/elsewhere"
refused "#3689 a python script file after an option with its value glued on"
runbash "python3 -Xdev -u $FIX/scripts/mk.py" "$FIX/elsewhere"
refused "#3689 and after another such option"
runbash "python3 -W error -X dev $FIX/scripts/mk.py" "$FIX/elsewhere"
refused "#3689 and after options whose values are words of their own"
runbash "perl -I $FIX/scripts -w $FIX/scripts/mk.pl" "$FIX/elsewhere"
refused "#3689 a perl script file after an option that takes a folder in perl"
runbash "node --require $FIX/scripts/n1.py $FIX/scripts/mk.js" "$FIX/elsewhere"
refused "#3689 a node script file after an option that takes a module"
runbash "python3 -Bc 'print(1)' $FIX/scripts/mk.py" "$FIX/elsewhere"
allowed "#3689 control: a script file named after an inline script is that script's argument, not run"
runbash "perl -lne 'print' $FIX/scripts/mk.pl" "$FIX/elsewhere"
allowed "#3689 control: so is one after a perl inline script"
runbash "bash $FIX/scripts/plain.sh" "$FIX/elsewhere"
allowed "#3689 control: a script file linking two files outside any checkout is let through"
runbash "python3 $FIX/scripts/reads.py" "$FIX/elsewhere"
allowed "#3689 control: a script file that names a payload file and makes no link is let through"

echo "a script file it cannot read"

runbash "python3 $FIX/scripts/gone.py $FIX/dev/payload/hooks/x.sh" "$FIX/elsewhere"
refused "#3689 a script file that is not there, in a call that names a payload path, is refused"
says "#3689 in words that say it could not read the script" "could not read the script file"
says "#3689 and that name it" "$FIX/scripts/gone.py"
runbash "bash \"\$S\" payload/hooks" "$FIX/dev"
refused "#3689 a script file named by a value, in a call that names a payload path"
says "#3689 says it could not read it" "could not read the script file"
python3 -c 'import sys; open(sys.argv[1], "w").write("# pad\n" * 800000)' "$FIX/scripts/big.sh"
runbash "bash $FIX/scripts/big.sh payload/hooks/x.sh" "$FIX/dev"
refused "#3689 a script file too large to read, in a call that names a payload path"
says "#3689 says it could not read it" "could not read the script file"
# Larger than the shared reader takes and small enough to search: its link commands are read as text.
{ python3 -c 'print("# pad\n" * 60000)'; printf 'ln -s %s %s\n' "$FIX/dev/payload/hooks" "$FIX/elsewhere/l8"; } > "$FIX/scripts/large.sh"
runbash "bash $FIX/scripts/large.sh" "$FIX/elsewhere"
refused "#3689 a shell script file larger than the shared reader takes, that links a payload folder"
runbash "bash $FIX/scripts/gone.sh" "$FIX/elsewhere"
allowed "#3689 control: a script file that is not there, in a call naming no payload path, is let through"
runbash "bash $FIX/dev/payload/hooks/gone.sh" "$FIX/elsewhere"
allowed "#3689 control: so is one whose own name is the only payload path in the call"
runbash "cat > $FIX/scripts/made.sh <<'EOF'
echo made
EOF
bash $FIX/scripts/made.sh $FIX/dev/payload/hooks/x.sh" "$FIX/elsewhere"
allowed "#3689 control: a script the command writes from its own text, and then runs, is read from that text"

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
