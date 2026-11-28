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
# It sleeps longer than this suite is allowed to run (SUITE_WALL_DEFAULT is 1200 seconds). At 300
# it died partway through a run that took six minutes on a loaded Mac (2026-11-26, load about
# 250), and every refusal expected after that came back allowed, 53 failures with one cause
# (claude-config#3775). The last check of the suite says so if it ever goes again.
( bash -c 'exec -a "'"$FIX"'/src/claude-sync watch" sleep 1500' </dev/null >/dev/null 2>&1 &
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
# A list of words is a command (claude-config#3775): the list route named its own commands, so
# patch, an in place sed, perl or ruby, and a dd writing to of= went through.
runbash "python3 -c \"import subprocess; subprocess.run(['patch', 'payload/hooks/x.sh', '$FIX/elsewhere/a.txt'])\"" "$FIX/dev"
refused "#3775 a patch given as a list of words"
runbash "python3 -c \"import subprocess; subprocess.run(['/usr/bin/patch', 'payload/hooks/x.sh', '$FIX/elsewhere/a.txt'])\"" "$FIX/dev"
refused "#3775 the same with patch named by its path"
runbash "python3 -c \"import subprocess; subprocess.run(['sed', '-i', '', 's/a/b/', 'payload/hooks/x.sh'])\"" "$FIX/dev"
refused "#3775 an in place sed given as a list of words"
runbash "python3 -c \"import subprocess; subprocess.run(['sed', '-e', 's/(a)/[b]/', '-i.bak', 'payload/hooks/x.sh'])\"" "$FIX/dev"
refused "#3775 an in place sed whose flag follows an expression holding brackets"
runbash "python3 -c \"import subprocess; subprocess.run(['perl', '-pi', '-e', 's/a/b/', 'payload/hooks/x.sh'])\"" "$FIX/dev"
refused "#3775 an in place perl given as a list of words"
runbash "python3 -c \"import subprocess; subprocess.run(['ruby', '-i', '-pe', 'next', 'payload/hooks/x.sh'])\"" "$FIX/dev"
refused "#3775 an in place ruby given as a list of words"
runbash "python3 -c \"import subprocess; subprocess.run(['dd', 'if=/dev/null', 'of=payload/hooks/x.sh'])\"" "$FIX/dev"
refused "#3775 a dd given as a list of words, writing to a payload file"
runbash "python3 -c \"import subprocess; subprocess.run(['sed', '-n', '1p', 'payload/hooks/x.sh'])\"" "$FIX/dev"
allowed "#3775 control: a sed in a list of words that only prints is let through"
runbash "python3 -c \"import subprocess; subprocess.run(['perl', '-ne', 'print', 'payload/hooks/x.sh'])\"" "$FIX/dev"
allowed "#3775 control: so is a perl that only prints"
runbash "python3 -c \"import subprocess; subprocess.run(['dd', 'if=payload/hooks/x.sh', 'of=$FIX/elsewhere/out.bin'])\"" "$FIX/dev"
allowed "#3775 control: so is a dd that reads a payload file and writes outside any checkout"
# A list of words is read by the reading a typed command gets (claude-config#3775): git writing,
# and a command behind a launcher word, were let through from a list where the same words typed
# are refused.
runbash "python3 -c \"import subprocess; subprocess.run(['git', 'checkout', '--', 'payload/hooks/x.sh'])\"" "$FIX/dev"
refused "#3775 a list of words running git checkout on a payload file"
runbash "python3 -c \"import subprocess; subprocess.run(['git', 'restore', 'payload/hooks/x.sh'])\"" "$FIX/dev"
refused "#3775 a list of words running git restore on a payload file"
runbash "python3 -c \"import subprocess; subprocess.run(['git', 'rm', 'payload/hooks/x.sh'])\"" "$FIX/dev"
refused "#3775 a list of words running git rm on a payload file"
runbash "python3 -c \"import subprocess; subprocess.run(['git', 'mv', 'payload/hooks/x.sh', 'payload/hooks/y.sh'])\"" "$FIX/dev"
refused "#3775 a list of words running git mv on a payload file"
runbash "python3 -c \"import subprocess; subprocess.run(['git', '-C', 'payload', 'checkout', '--', 'hooks/x.sh'])\"" "$FIX/dev"
refused "#3775 a list of words running git checkout from the payload folder, by -C"
runbash "python3 -c \"import subprocess; p = 'payload/hooks/x.sh'; subprocess.run(['git', 'checkout', '--', p])\"" "$FIX/dev"
refused "#3775 a list of words running git checkout on a payload path held in a value"
runbash "node -e \"require('child_process').spawnSync('git', ['checkout', '--', 'payload/hooks/x.sh'])\"" "$FIX/dev"
refused "#3775 node spawnSync given git and a list of words"
runbash "python3 -c \"import subprocess; subprocess.run(['sudo', 'rm', 'payload/hooks/x.sh'])\"" "$FIX/dev"
refused "#3775 a list of words whose remove follows sudo"
runbash "python3 -c \"import subprocess; subprocess.run(['env', 'LANG=C', 'rm', 'payload/hooks/x.sh'])\"" "$FIX/dev"
refused "#3775 a list of words whose remove follows env and a setting"
runbash "python3 -c \"import subprocess; subprocess.run(['nohup', 'mv', '$FIX/elsewhere/a.txt', 'payload/hooks/x.sh'])\"" "$FIX/dev"
refused "#3775 a list of words whose move follows nohup"
runbash "python3 -c \"import subprocess; subprocess.run(['timeout', '5', 'rm', 'payload/hooks/x.sh'])\"" "$FIX/dev"
refused "#3775 a list of words whose remove follows timeout"
runbash "python3 -c \"import subprocess; subprocess.run(['sudo', 'git', 'checkout', '--', 'payload/hooks/x.sh'])\"" "$FIX/dev"
refused "#3775 a list of words whose git checkout follows sudo"
runbash "python3 -c \"import subprocess; subprocess.run(['git', 'status', 'payload/hooks'])\"" "$FIX/dev"
allowed "#3775 control: a list of words running git status on a payload folder is let through"
runbash "python3 -c \"import subprocess; subprocess.run(['git', 'log', '--', 'payload/hooks/x.sh'])\"" "$FIX/dev"
allowed "#3775 control: so is git log on a payload file"
runbash "python3 -c \"import subprocess; subprocess.run(['git', 'checkout', 'main']); print(open('payload/hooks/x.sh').read())\"" "$FIX/dev"
allowed "#3775 control: so is a git checkout of a branch beside a read of a payload file"
runbash "python3 -c \"import subprocess; subprocess.run(['sudo', 'cat', 'payload/hooks/x.sh'])\"" "$FIX/dev"
allowed "#3775 control: so is a read that follows sudo"
runbash "python3 -c \"import subprocess; subprocess.run(['env', 'LANG=C', 'ls', 'payload/hooks'])\"" "$FIX/dev"
allowed "#3775 control: so is a listing that follows env and a setting"
runbash "python3 -c \"import subprocess, sys; subprocess.run(['cp', sys.argv[1], sys.argv[2]])\" a.txt b.txt" "$FIX/elsewhere"
allowed "#3775 control: so is a copy between two values in a call that names no payload path"
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
# string that goes on past that without its quote closing is one this gate could not read, and is
# refused as untold in a call naming payload, never let through unread. Exactly the count is read.
# A quote with 4000 characters or fewer after it that never closes is not refused: it is no string
# a script runs, and is most often the closing quote of a search, as the last two controls show.
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
runbash "grep -n \"system\" payload/hooks/x.sh" "$FIX/dev"
allowed "#3689 control: a search for the word system, whose closing quote follows it, is not taken for a string"
runbash "grep -n \"os.system(\" payload/hooks/x.sh" "$FIX/dev"
allowed "#3689 control: nor is a search for a call with its bracket"

# And the loop over the script files of one command.
for k in 1 2 3 4 5 6 7 8 9; do printf 'print(%s)\n' "$k" > "$FIX/scripts/n$k.py"; done
many_files(){ local k out=""; for k in $(seq 1 "$1"); do out="$out python3 $FIX/scripts/n$k.py;"; done; printf '%s : payload/' "$out"; }
runbash "$(many_files 8)" "$FIX/dev"
allowed "#3689 a command running 8 script files has each read"
runbash "$(many_files 9)" "$FIX/dev"
refused "#3689 one running 9 is refused, so the loop stops at its count"
says "#3689 in words that name the count" "more than 8 script files"

echo "what counts toward the 8 script files"

# WHAT THE COUNT COUNTS (claude-config#3775). The case above types 9 different files that are all
# there, directly in the command, and that was the only shape tested. The count went up for every
# OCCURRENCE of a script being run, before the gate knew whether there was a file it could open: a
# name holding a value, which it never opens, and the same file again. So a plain run of a test
# suite was refused at its ninth `bash "$HOOK"`, having opened nothing: 84 of this repository's 410
# suites and the whole run, measured on 2026-11-26. Only a file the gate goes on to open counts
# now, once for each directory it is run in, and the limit is still 8.
same_file(){ local k out=""; for k in $(seq 1 "$1"); do out="$out python3 $FIX/scripts/n1.py;"; done; printf '%s : payload/' "$out"; }
runbash "$(same_file 9)" "$FIX/dev"
allowed "#3775 the same script file run 9 times is one file read"
lines(){ local k; for k in $(seq 1 "$1"); do printf '%s\n' "$2"; done; }
# shellcheck disable=SC2016  # the names are meant to reach the file with their values unfilled
{ lines 9 'bash "$HOOK" x'; lines 9 'python3 "$LIB" x'; lines 9 '. "$DIR/lib/x.sh"'
  lines 9 '"$DIR/hook.sh" x'; lines 9 'out="$(printf x | bash "$HOOK" 2>&1)"'; } > "$FIX/scripts/values.sh"
runbash "bash $FIX/scripts/values.sh; : payload/" "$FIX/dev"
allowed "#3775 a script file running names that hold a value, 45 times, opens no file and is let through"
lines 9 "python3 $FIX/scripts/gone.py" > "$FIX/scripts/gone9.sh"
runbash "bash $FIX/scripts/gone9.sh; : payload/" "$FIX/dev"
allowed "#3775 nor does a file that is not there count, run 9 times from inside a script file"
for k in 1 2 3 4 5 6 7 8; do printf 'python3 %s/n%s.py\npython3 %s/n1.py\n' "$FIX/scripts" "$k" "$FIX/scripts"; done > "$FIX/scripts/inner8.sh"
runbash "bash $FIX/scripts/inner8.sh; : payload/" "$FIX/dev"
allowed "#3775 a script file running 8 different files, each more than once, has each read"
# What is read on past the old stopping point is judged: a link after the ninth occurrence.
{ lines 9 "python3 $FIX/scripts/n1.py"; printf 'ln -s %s %s\n' "$FIX/dev/payload/hooks" "$FIX/elsewhere/l9"; } > "$FIX/scripts/same9link.sh"
runbash "bash $FIX/scripts/same9link.sh" "$FIX/elsewhere"
refused "#3775 a link into payload after the same file run 9 times is refused"
says "#3775 as the write it is, naming the folder" "a write to $FIX/dev/payload/hooks"
# shellcheck disable=SC2016
{ lines 9 'bash "$HOOK" x'; printf 'ln -s %s %s\n' "$FIX/dev/payload/hooks" "$FIX/elsewhere/l10"; } > "$FIX/scripts/values9link.sh"
runbash "bash $FIX/scripts/values9link.sh" "$FIX/elsewhere"
refused "#3775 a link into payload after 9 names holding a value is refused"
says "#3775 as the write it is, naming the folder" "a write to $FIX/dev/payload/hooks"
# The limit, a number the gate sets and not a measurement, is still 8 files opened, wherever the
# ninth is run from.
for k in 1 2 3 4 5 6 7 8 9; do printf 'python3 %s/n%s.py\n' "$FIX/scripts" "$k"; done > "$FIX/scripts/inner9.sh"
runbash "bash $FIX/scripts/inner9.sh; : payload/" "$FIX/dev"
refused "#3775 a script file running 9 different files that can be opened is still refused"
says "#3775 in the same words" "claude-sync: REFUSED a command that runs more than 8 script files."
printf 'bash %s\n' "$FIX/scripts/inner9.sh" > "$FIX/scripts/outer9.sh"
runbash "bash $FIX/scripts/outer9.sh; : payload/" "$FIX/dev"
refused "#3775 and so is one that runs that script file"
says "#3775 in the same words" "more than 8 script files"
{ lines 30 "python3 $FIX/scripts/n1.py"; for k in 2 3 4 5 6 7 8 9; do printf 'python3 %s/n%s.py\n' "$FIX/scripts" "$k"; done; } > "$FIX/scripts/late9.sh"
runbash "bash $FIX/scripts/late9.sh; : payload/" "$FIX/dev"
refused "#3775 a ninth different file after 30 runs of the first is still refused"
says "#3775 in the same words" "more than 8 script files"
runbash "bash $FIX/scripts/inner9.sh" "$FIX/elsewhere"
allowed "#3775 control: 9 different files in a call naming no payload path is let through, as before"
# The same file run in another directory is read again there, since a relative path in it lands
# somewhere else, and that reading counts.
printf 'import os\nos.symlink("payload/hooks/x.sh", "%s")\n' "$FIX/elsewhere/l11" > "$FIX/scripts/rel.py"
runbash "cd $FIX/elsewhere && python3 $FIX/scripts/rel.py; cd $FIX/dev && python3 $FIX/scripts/rel.py" "$FIX/elsewhere"
refused "#3775 a file read once is read again where it is run from another directory"
says "#3775 and its relative link is judged there" "a write to $FIX/dev/payload/hooks/x.sh"
mkdir -p "$FIX/elsewhere/d1" "$FIX/elsewhere/d2" "$FIX/elsewhere/d3" "$FIX/elsewhere/d4" "$FIX/elsewhere/d5" "$FIX/elsewhere/d6" "$FIX/elsewhere/d7" "$FIX/elsewhere/d8" "$FIX/elsewhere/d9"
many_dirs(){ local k out=""; for k in $(seq 1 "$1"); do out="$out cd $FIX/elsewhere/d$k && python3 $FIX/scripts/n1.py;"; done; printf '%s : payload/' "$out"; }
runbash "$(many_dirs 8)" "$FIX/dev"
allowed "#3775 one file run from 8 directories is 8 readings"
runbash "$(many_dirs 9)" "$FIX/dev"
refused "#3775 and from 9 it is refused for the count"
says "#3775 in the same words" "more than 8 script files"
# The run that was refused on 2026-11-26: the Slack drafts gate's own suite, as it is beside this
# one, run plainly from a checkout at risk and in the form a builder is told to use.
if [ -f "$DIR/test-slack-drafts-only-gate.sh" ]; then
  cp "$DIR/test-slack-drafts-only-gate.sh" "$FIX/dev/payload/hooks/test-slack-drafts-only-gate.sh"
  runbash "bash payload/hooks/test-slack-drafts-only-gate.sh" "$FIX/dev"
  allowed "#3775 a plain run of the Slack drafts gate's suite is let through"
  runbash "bash $FIX/dev/payload/hooks/test-slack-drafts-only-gate.sh > $FIX/elsewhere/out.txt 2>&1" "$FIX/elsewhere"
  allowed "#3775 and so is its run by its full path with the output kept in a file"
else
  check "#3775 a plain run of the Slack drafts gate's suite is let through" "test-slack-drafts-only-gate.sh is not beside this suite, so the run was not asked about"
fi

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

# ANOTHER SCRIPT'S NAME INSIDE THE PAYLOAD PATH (claude-config#3775, found in review 2026-11-27).
# The payload path the command names "besides the script itself" was looked for in the command
# with every occurrence of every script path it runs taken out as plain text. So a script named a
# took every letter a out of payload/, and a script run by its payload path took out the same path
# given to the script that cannot be read. Only the word where a script is run is taken out now.
# shellcheck disable=SC2016  # the names are meant to reach the gate with their values unfilled
runbash 'bash a; bash $X payload/hooks/x.sh' "$FIX/elsewhere"
refused "#3775 a script named by a value and given a payload path is refused beside a script named a"
says "#3775 in words that say it could not read the script" "could not read the script file"
runbash "bash load; bash $FIX/scripts/gone.sh payload/hooks/x.sh" "$FIX/elsewhere"
refused "#3775 a script that is not there and given a payload path is refused beside a script named load"
# shellcheck disable=SC2016
runbash "bash $FIX/dev/payload/hooks/x.sh; python3 \"\$TOOL\" $FIX/dev/payload/hooks/x.sh" "$FIX/elsewhere"
refused "#3775 a script named by a value is refused when given the path of a payload script the command also runs"
runbash "bash $FIX/dev/payload/hooks/gone.sh $FIX/dev/payload/hooks/gone.sh" "$FIX/elsewhere"
refused "#3775 a script that is not there is refused when given its own payload path as a word besides"
# shellcheck disable=SC2016
runbash 'bash $X payload/hooks/x.sh' "$FIX/elsewhere"
refused "#3775 control: the first of those without the other script was refused before, and is"
# shellcheck disable=SC2016
runbash "python3 \"\$TOOL\" $FIX/dev/payload/hooks/x.sh" "$FIX/elsewhere"
refused "#3775 control: the third without the other script was refused before, and is"
# shellcheck disable=SC2016
runbash "bash $FIX/dev/payload/hooks/x.sh; python3 \"\$TOOL\"" "$FIX/elsewhere"
allowed "#3775 control: a payload script run beside one named by a value, no payload path besides, is let through"
runbash "bash \"$FIX/dev/payload/hooks/gone.sh\"" "$FIX/elsewhere"
allowed "#3775 control: a script that is not there, its own quoted name the only payload path, is let through"
runbash "bash $FIX/dev/payload/hooks/gone.sh; bash $FIX/dev/payload/hooks/gone.sh" "$FIX/elsewhere"
allowed "#3775 control: the same script that is not there run twice, no payload path besides, is let through"
runbash "(bash $FIX/dev/payload/hooks/gone.sh)>$FIX/elsewhere/a.txt" "$FIX/elsewhere"
allowed "#3775 control: and run inside brackets with its output sent elsewhere"
# What the old search refused by accident is still refused. Taking every occurrence of a script
# name out could make the word payload/ appear where the name sat against it inside a longer word.
# Neither path below is a payload path, but dropping a refusal is left to Dan (the pull request of
# #3775), so the gate asks the old search as well as the new one until he answers.
# shellcheck disable=SC2016
runbash 'bash x; bash $Y xpayload/hooks/x.sh' "$FIX/elsewhere"
refused "#3775 kept until decided: a script named x beside xpayload/ and a script named by a value"
# shellcheck disable=SC2016
runbash 'bash s; bash $Y /api/payloads' "$FIX/elsewhere"
refused "#3775 kept until decided: a script named s beside /payloads and a script named by a value"

echo "a redirection of a script file's link command is no file the link command is given"

# A REDIRECTION IS NO WORD OF THE PROGRAM (claude-config#3775). Every word of a link command of a
# script file that was no option was placed as a file it writes, a redirection among them, and a
# relative one lands in the folder the command runs in. So a suite run from inside a payload folder
# was refused for a write to a file named 2>/dev/null, which no command makes. The redirections are
# taken out before the words are read now, and what an output redirection writes is still judged.
# Every script here is made up and none is run: only the gate reads them.
HOOKS_DIR="$FIX/dev/payload/hooks"
mkscript(){ # mkscript <name> <line>...
  local f="$FIX/scripts/$1"; shift
  { printf '#!/bin/bash\n'; printf '%s\n' "$@"; } > "$f"
}
mklarge(){ # mklarge <name> <line>: larger than the shared reader takes, so read as text
  { python3 -c 'print("# pad\n" * 60000)'; printf '%s\n' "$2"; } > "$FIX/scripts/$1"
}
mkscript r1.sh "ln -s \"\$A\" \"\$B/t\" 2>/dev/null"
runbash "bash $FIX/scripts/r1.sh 2>&1 | tail -3" "$HOOKS_DIR"
allowed "#3775 a link command with its errors sent to /dev/null, in a script run inside a payload folder, is let through"
mkscript r2.sh "ln -s \"\$A\" \"\$B/t\" >/dev/null 2>&1"
runbash "bash $FIX/scripts/r2.sh" "$HOOKS_DIR"
allowed "#3775 so is one with its output sent there and its errors after it"
mkscript r3.sh "ln -s \"\$A\" \"\$B/t\" > /dev/null"
runbash "bash $FIX/scripts/r3.sh" "$HOOKS_DIR"
allowed "#3775 and with the operator a word of its own"
mkscript r4.sh "ln -s \"\$A\" \"\$B/t\" < in.txt"
runbash "bash $FIX/scripts/r4.sh" "$HOOKS_DIR"
allowed "#3775 a link command reading its input from a file writes nothing there"
mklarge r6.sh "ln -s \"\$A\" \"\$B/t\" 2>/dev/null"
runbash "bash $FIX/scripts/r6.sh" "$HOOKS_DIR"
allowed "#3775 a script larger than the shared reader takes, its link command's errors sent to /dev/null"
mklarge r7.sh "ln -s \"\$A\" \"\$B/t\" 2>&1"
runbash "bash $FIX/scripts/r7.sh" "$HOOKS_DIR"
allowed "#3775 and with its errors sent after its output"
# shellcheck disable=SC2016  # the names reach the made up script with their values unfilled
printf 'import os\nos.system("ln -s $A $B/t 2>/dev/null")\n' > "$FIX/scripts/r8.py"
runbash "python3 $FIX/scripts/r8.py" "$HOOKS_DIR"
allowed "#3775 a python script file that runs such a link command as one string"
runbash "bash $FIX/scripts/r1.sh" "$FIX/dev"
allowed "#3775 control: the first of those run from the root was let through before, and is"

# What a redirection WRITES is a write. Each of these was refused before, for a file named after
# the redirection or the operator, and is refused now, most for the file itself.
mkscript w1.sh "ln -s \"\$A\" \"\$B/t\" > log.txt"
runbash "bash $FIX/scripts/w1.sh" "$HOOKS_DIR"
refused "#3775 control: a link command's output sent to a file in the payload folder it runs in"
says "#3775 and the refusal names the file the output is sent to" "a write to $HOOKS_DIR/log.txt."
mkscript w2.sh "ln -s \"\$A\" \"\$B/t\" >log.txt"
runbash "bash $FIX/scripts/w2.sh" "$HOOKS_DIR"
refused "#3775 control: the same with the name against the operator"
says "#3775 naming the file" "a write to $HOOKS_DIR/log.txt."
mkscript w3.sh "ln -s \"\$A\" \"\$B/t\" 2>>err.log"
runbash "bash $FIX/scripts/w3.sh" "$HOOKS_DIR"
refused "#3775 control: errors added to a file there"
mkscript w4.sh "ln -s \"\$A\" \"\$B/t\" > payload/hooks/log.txt"
runbash "bash $FIX/scripts/w4.sh" "$FIX/dev"
refused "#3775 control: output sent to a payload file, run from the root"
# With its name against the operator the same write was let through: read as one word,
# >payload/hooks/log.txt names a folder called >payload, which is no payload folder.
mkscript w4glued.sh "ln -s \"\$A\" \"\$B/t\" >payload/hooks/log.txt"
runbash "bash $FIX/scripts/w4glued.sh" "$FIX/dev"
refused "#3775 output sent to a payload file with its name against the operator, run from the root, is refused"
says "#3775 naming the file" "a write to $FIX/dev/payload/hooks/log.txt."
mkscript w5.sh "ln -s \"\$A\" \"\$B/t\" &> all.log"
runbash "bash $FIX/scripts/w5.sh" "$HOOKS_DIR"
refused "#3775 control: both outputs sent to a file there"
mkscript w6.sh "ln -s \"\$A\" \"\$B/t\" >& both.log"
runbash "bash $FIX/scripts/w6.sh" "$HOOKS_DIR"
refused "#3775 control: and with the other spelling of that"
mkscript w7.sh "ln -s \"\$A\" \"\$B/t\" <> both.txt"
runbash "bash $FIX/scripts/w7.sh" "$HOOKS_DIR"
refused "#3775 control: a file there opened for reading and writing"
mkscript w8.sh "ln -s \"\$A\" \"\$B/t\" >| log.txt"
runbash "bash $FIX/scripts/w8.sh" "$HOOKS_DIR"
refused "#3775 control: output forced over a file there"
mkscript w9.sh "ln -s \"\$A\" b>out.txt"
runbash "bash $FIX/scripts/w9.sh" "$HOOKS_DIR"
refused "#3775 control: a redirection against the name of a link made there"
mkscript w10.sh "ln -s \"\$A\" \"\$B/t\" > -x.log"
runbash "bash $FIX/scripts/w10.sh" "$HOOKS_DIR"
refused "#3775 control: output sent to a file there whose name starts with a dash"
mkscript w11.sh "ln -s \"\$A\" \"\$B/t\" > pay\\load/hooks/x.sh"
runbash "bash $FIX/scripts/w11.sh" "$FIX/dev"
refused "#3775 control: output sent to a payload file written with a backslash in its name, from the root"
mkscript w12.sh "ln -s \"\$A\" \"\$B/t\" {fd}>named.txt"
runbash "bash $FIX/scripts/w12.sh" "$HOOKS_DIR"
refused "#3775 control: output sent to a file there through a named descriptor"
mklarge w13.sh "ln -s \"\$A\" \"\$B/t\" > log.txt"
runbash "bash $FIX/scripts/w13.sh" "$HOOKS_DIR"
refused "#3775 control: a large script whose link command sends its output to a file there"
# shellcheck disable=SC2016
printf 'import os\nos.system("ln -s $A $B/t > log.txt")\n' > "$FIX/scripts/w14.py"
runbash "python3 $FIX/scripts/w14.py" "$HOOKS_DIR"
refused "#3775 control: a python script file whose link command sends its output to a file there"
# Where a redirection writes cannot be told from its words when they hold a value or run a
# command. Those are placed as they were before, so nothing that was refused is let through.
mkscript w15.sh "ln -s \"\$A\" \"\$B/t\" > \"\$V/log\""
runbash "bash $FIX/scripts/w15.sh" "$HOOKS_DIR"
refused "#3775 kept as it was: output sent to a file named through a value, the operator a word of its own"
mkscript w16.sh "ln -s \"\$A\" \"\$B/t\" 2> >(tee e.log)"
runbash "bash $FIX/scripts/w16.sh" "$HOOKS_DIR"
refused "#3775 kept as it was: errors sent to a command that writes a file there"
mkscript w17.sh "ln -s \"\$A\" \"\$B/t\" < <(echo x > made.txt)"
runbash "bash $FIX/scripts/w17.sh" "$HOOKS_DIR"
refused "#3775 kept as it was: input read from a command that writes a file there"
# The shared reader cuts a command at the | of >|, so the link command reaches this gate ending
# in an operator with nothing after it, and what that writes cannot be told.
mkscript w18.sh "ln -s \"\$A\" \"\$B/t\" >| /dev/null"
runbash "bash $FIX/scripts/w18.sh" "$HOOKS_DIR"
refused "#3775 kept as it was: output forced over /dev/null with >|, which is cut at its |"

# The links themselves, with a redirection beside them, and every kind of link the reading of a
# script file refuses: each run inside a payload folder and from the root.
mkscript k1.sh "ln -s x.sh l 2>/dev/null"
runbash "bash $FIX/scripts/k1.sh" "$HOOKS_DIR"
refused "#3775 control: a link made in the payload folder, its errors sent to /dev/null"
says "#3775 naming a file there" "a write to $HOOKS_DIR/"
mkscript k2.sh "ln -s $FIX/dev/payload/hooks $FIX/elsewhere/k2 2>/dev/null"
runbash "bash $FIX/scripts/k2.sh" "$FIX/elsewhere"
refused "#3775 control: a link to the payload folder, its errors sent to /dev/null"
mkscript k3.sh "ln -s \"\$A\" \">x\""
runbash "bash $FIX/scripts/k3.sh" "$HOOKS_DIR"
refused "#3775 control: a link there whose quoted name starts like a redirection"
mkscript k4in.sh "ln x.sh \"\$B/h\" 2>/dev/null"
runbash "bash $FIX/scripts/k4in.sh" "$HOOKS_DIR"
refused "#3775 control: a hard link of a payload file by a relative name, inside the payload folder"
mkscript k4root.sh "ln payload/LESSONS.md \"\$B/h\" 2>/dev/null"
runbash "bash $FIX/scripts/k4root.sh" "$FIX/dev"
refused "#3775 control: and from the root"
mkscript k5in.sh "link x.sh \"\$B/h\""
runbash "bash $FIX/scripts/k5in.sh" "$HOOKS_DIR"
refused "#3775 control: the link command, inside the payload folder"
mkscript k5root.sh "link payload/LESSONS.md \"\$B/h\""
runbash "bash $FIX/scripts/k5root.sh" "$FIX/dev"
refused "#3775 control: and from the root"
mkscript k6in.sh "bash $FIX/scripts/k4in.sh"
runbash "bash $FIX/scripts/k6in.sh" "$HOOKS_DIR"
refused "#3775 control: a script file that runs the script file that links, inside the payload folder"
mkscript k6root.sh "bash $FIX/scripts/k4root.sh"
runbash "bash $FIX/scripts/k6root.sh" "$FIX/dev"
refused "#3775 control: and from the root"
printf 'import os\nos.link("./x.sh", "%s")\n' "$FIX/elsewhere/k7in" > "$FIX/scripts/k7in.py"
runbash "python3 $FIX/scripts/k7in.py" "$HOOKS_DIR"
refused "#3775 control: a python script file linking a file by a relative path, inside the payload folder"
printf 'import os\nos.link("payload/LESSONS.md", "%s")\n' "$FIX/elsewhere/k7root" > "$FIX/scripts/k7root.py"
runbash "python3 $FIX/scripts/k7root.py" "$FIX/dev"
refused "#3775 control: and from the root"
printf 'import os\nos.system("ln -s x.sh l 2>/dev/null")\n' > "$FIX/scripts/k8in.py"
runbash "python3 $FIX/scripts/k8in.py" "$HOOKS_DIR"
refused "#3775 control: a python script file running ln as one string, inside the payload folder"
printf 'import os\nos.system("ln -s payload/hooks %s 2>/dev/null")\n' "$FIX/elsewhere/k8root" > "$FIX/scripts/k8root.py"
runbash "python3 $FIX/scripts/k8root.py" "$FIX/dev"
refused "#3775 control: and from the root"
printf 'symlink "./x.sh", "%s";\n' "$FIX/elsewhere/k9in" > "$FIX/scripts/k9in.pl"
runbash "perl $FIX/scripts/k9in.pl" "$HOOKS_DIR"
refused "#3775 control: a perl script file linking a file by a relative path, inside the payload folder"
printf 'symlink "payload/hooks/x.sh", "%s";\n' "$FIX/elsewhere/k9root" > "$FIX/scripts/k9root.pl"
runbash "perl $FIX/scripts/k9root.pl" "$FIX/dev"
refused "#3775 control: and from the root"
printf 'require("fs").symlinkSync("./x.sh", "%s");\n' "$FIX/elsewhere/k10in" > "$FIX/scripts/k10in.js"
runbash "node $FIX/scripts/k10in.js" "$HOOKS_DIR"
refused "#3775 control: a node script file linking a file by a relative path, inside the payload folder"
printf 'require("fs").symlinkSync("payload/hooks/x.sh", "%s");\n' "$FIX/elsewhere/k10root" > "$FIX/scripts/k10root.js"
runbash "node $FIX/scripts/k10root.js" "$FIX/dev"
refused "#3775 control: and from the root"
mklarge k11in.sh "ln -s x.sh l 2>/dev/null"
runbash "bash $FIX/scripts/k11in.sh" "$HOOKS_DIR"
refused "#3775 control: a large script that makes a link, inside the payload folder"
mklarge k11root.sh "ln payload/LESSONS.md \"\$B/h\" 2>/dev/null"
runbash "bash $FIX/scripts/k11root.sh" "$FIX/dev"
refused "#3775 control: and from the root"
runbash "bash \"\$S\"" "$HOOKS_DIR"
refused "#3775 control: a script file named by a value, run inside the payload folder"
says "#3775 in words that say it could not read the script" "could not read the script file"

# The same word typed directly is judged by the reading of a typed command, which main has too
# and which refuses it. Taking it out there lets through commands main refuses, so it is left.
runbash "ln -s \"\$A\" \"\$B/t\" 2>/dev/null" "$HOOKS_DIR"
refused "#3775 kept until decided: a link command typed directly with its errors sent to /dev/null, inside a payload folder"
runbash "python3 -c 'import os; os.system(\"ln -s \$A \$B/t 2>/dev/null\")'" "$HOOKS_DIR"
refused "#3775 kept until decided: and an inline script typed directly that runs it as one string"

# KEPT UNTIL DECIDED (claude-config#3775). Two more words of a script are taken for a write that
# may be none, and for neither is there a reading that is right for every script, so both are
# refused as they were and the choice is Dan's (the pull request that added these lines).
# The text a symbolic link holds is read from the folder the LINK is in. Here that folder is a
# value, so it may be the payload folder the script runs in, and the text is placed there.
mkscript b1.sh "ln -s 999999 \"\$STATE/remove.lock\""
runbash "bash $FIX/scripts/b1.sh" "$HOOKS_DIR"
refused "#3775 kept until decided: a symbolic link holding a plain word, in a folder named by a value, run inside a payload folder"
says "#3775 the word is named as the write" "a write to $HOOKS_DIR/999999."
runbash "bash $FIX/scripts/b1.sh" "$FIX/dev"
allowed "#3775 control: the same script run from the root is let through"
# A command a script hands to a function of its own as a quoted string, as the suites of this gate
# hand theirs to a helper, is read as an inline script that makes a link: the function may run it.
mkscript d1.sh "helper(){ :; }" "helper \"a label\" \"python3 -c \\\"import os; os.link('payload/LESSONS.md', '\$T/h1')\\\"\""
runbash "bash $FIX/scripts/d1.sh" "$FIX/dev"
refused "#3775 kept until decided: a made up link command handed to a function as a string, run from the root of a checkout"
says "#3775 the payload file it names is named as the write" "a write to $FIX/dev/payload/LESSONS.md."
runbash "bash $FIX/scripts/d1.sh" "$FIX/elsewhere"
allowed "#3775 control: the same script run from a folder that is no checkout is let through"
# And an inline script that holds a call that makes a link, with a quoted word that may be a path.
mkscript e1.sh "python3 -c 'import os, re" "re.search(r\"(^|/)payload(/|\$)\", \"x\")" "# os.symlink(a, b) is read elsewhere" "'"
runbash "bash $FIX/scripts/e1.sh" "$HOOKS_DIR"
refused "#3775 kept until decided: an inline script in a script file, holding a link call and a quoted pattern with a slash, run inside a payload folder"

echo "what the redirection word was hiding inside a payload folder is refused for itself"

# WHAT A REFUSAL FOR THE WORD ALSO COVERED (claude-config#3775). A script refused for a redirection
# word is refused whatever else it does. With the word no longer placed, each write such a script
# really makes inside a payload folder has to be read for what it is. Every script here is made
# up and none is run.
#
# A link command given ONE name makes the link in the folder it runs in, under that name's last part.
mkscript o1.sh "ln -s $FIX/elsewhere/a.txt 2>/dev/null"
runbash "bash $FIX/scripts/o1.sh" "$HOOKS_DIR"
refused "#3775 a link command given one name, its errors sent to /dev/null, run inside a payload folder: the link lands there"
says "#3775 naming the link it makes there" "a write to $HOOKS_DIR/a.txt."
mkscript o2.sh "ln -s $FIX/elsewhere/a.txt"
runbash "bash $FIX/scripts/o2.sh" "$HOOKS_DIR"
refused "#3775 the same with no redirection"
mkscript o3.sh "ln -s \"\$p\" 2>/dev/null"
runbash "bash $FIX/scripts/o3.sh" "$HOOKS_DIR"
refused "#3775 one name that is a value: what the link is called cannot be told, the folder it lands in can"
says "#3775 naming the folder" "a write to $HOOKS_DIR"
mkscript o3b.sh "ln -s \"\$T/a.txt\" >/dev/null 2>&1"
runbash "bash $FIX/scripts/o3b.sh" "$HOOKS_DIR"
refused "#3775 one name under a value: its last part is what the link is called"
says "#3775 naming the link" "a write to $HOOKS_DIR/a.txt."
printf 'import os\nos.system("ln -s %s/elsewhere/a.txt 2>/dev/null")\n' "$FIX" > "$FIX/scripts/o4.py"
runbash "python3 $FIX/scripts/o4.py" "$HOOKS_DIR"
refused "#3775 a python script file running a link command given one name as one string"
mklarge o5.sh "ln -s $FIX/elsewhere/a.txt 2>&1"
runbash "bash $FIX/scripts/o5.sh" "$HOOKS_DIR"
refused "#3775 a large script whose link command is given one name"
mkscript o6.sh "cd $HOOKS_DIR" "ln -s $FIX/elsewhere/a.txt 2>/dev/null"
runbash "bash $FIX/scripts/o6.sh" "$FIX/elsewhere"
refused "#3775 a link command given one name after the script moves into a payload folder"
runbash "bash $FIX/scripts/o1.sh" "$FIX/elsewhere"
allowed "#3775 control: a link command given one name, run outside any checkout, is let through"
runbash "bash $FIX/scripts/o1.sh" "$FIX/dev"
allowed "#3775 control: so is one run at the root of the checkout, where the link is no payload file"
mkscript o8.sh "cd \"\$T\"" "ln -s $FIX/elsewhere/a.txt 2>/dev/null"
runbash "bash $FIX/scripts/o8.sh" "$HOOKS_DIR"
allowed "#3775 control: and one run after the script moves to a folder named by a value"

# A redirection written against the target of the one before it is a redirection of its own.
# shellcheck disable=SC2016
printf 'import os\nos.system("ln -s $A $B/t </dev/null>out.txt")\n' > "$FIX/scripts/g1.py"
runbash "python3 $FIX/scripts/g1.py" "$HOOKS_DIR"
refused "#3775 a python string whose link command writes a file there, the redirection written against the one before it"
says "#3775 naming the file" "a write to $HOOKS_DIR/out.txt."
mklarge g2.sh "ln -s \"\$A\" \"\$B/t\" </dev/null>out.txt"
runbash "bash $FIX/scripts/g2.sh" "$HOOKS_DIR"
refused "#3775 a large script whose link command does the same"
says "#3775 naming the file" "a write to $HOOKS_DIR/out.txt."
# shellcheck disable=SC2016
printf 'import os\nos.system("ln -s $A $B/t 2>/dev/null;echo>c")\n' > "$FIX/scripts/g3.py"
runbash "python3 $FIX/scripts/g3.py" "$HOOKS_DIR"
refused "#3775 a python string whose second command writes a file there, written against the first"
# shellcheck disable=SC2016
printf 'import os\nos.system("ln -s $A $B/t </dev/null;tee>out.txt")\n' > "$FIX/scripts/g4.py"
runbash "python3 $FIX/scripts/g4.py" "$HOOKS_DIR"
refused "#3775 and with a tee whose output is sent to a file there"
# shellcheck disable=SC2016
printf 'import os\nos.system("ln -s $A $B/t </dev/null>payload/hooks/out.txt")\n' > "$FIX/scripts/g5.py"
runbash "python3 $FIX/scripts/g5.py" "$FIX/dev"
refused "#3775 the same write to a payload file, from the root"
# shellcheck disable=SC2016
printf 'import os\nos.system("ln -s $A $B/t >/dev/null</dev/null")\n' > "$FIX/scripts/g6.py"
runbash "python3 $FIX/scripts/g6.py" "$HOOKS_DIR"
allowed "#3775 control: two redirections written together that write nothing there are let through"
mklarge g7.sh "ln -s \"\$A\" \"\$B/t\" 2>/dev/null</dev/null"
runbash "bash $FIX/scripts/g7.sh" "$HOOKS_DIR"
allowed "#3775 control: and in a large script"

# A string cut into words by the script itself is run with no shell, so nothing is a redirection:
# each of its words is a word of the link command, as written.
printf 'import subprocess\nsubprocess.run("ln -s %s/elsewhere/a.txt <b".split())\n' "$FIX" > "$FIX/scripts/x1.py"
runbash "python3 $FIX/scripts/x1.py" "$HOOKS_DIR"
refused "#3775 a python script file running a split string: no shell reads it, so <b is the link's name"
says "#3775 naming that link" "a write to $HOOKS_DIR/<b."
printf 'import subprocess\nsubprocess.run("ln -s %s/elsewhere/a.txt 2>&1".split())\n' "$FIX" > "$FIX/scripts/x2.py"
runbash "python3 $FIX/scripts/x2.py" "$HOOKS_DIR"
refused "#3775 and with 2>&1 for the link's name"
printf 'import subprocess\nsubprocess.run("ln -s %s/elsewhere/a.txt %s/elsewhere/b.txt <b".split())\n' "$FIX" "$FIX" > "$FIX/scripts/x3.py"
runbash "python3 $FIX/scripts/x3.py" "$HOOKS_DIR"
refused "#3775 a split string naming two files and <b, which is then the folder the links are made in"
printf 'import subprocess\nsubprocess.check_call("ln -s %s/elsewhere/a.txt %s/elsewhere/b.txt 2>&1".split(" "))\n' "$FIX" "$FIX" > "$FIX/scripts/x4.py"
runbash "python3 $FIX/scripts/x4.py" "$HOOKS_DIR"
refused "#3775 and split at a blank it is given"
printf 'exec("ln -s %s/elsewhere/a.txt %s/elsewhere/b.txt <b".split)\n' "$FIX" "$FIX" > "$FIX/scripts/x5.rb"
runbash "ruby $FIX/scripts/x5.rb" "$HOOKS_DIR"
refused "#3775 and split with no brackets, as ruby writes it"
printf 'import subprocess\nsubprocess.run("ln -s %s/elsewhere/a.txt %s/elsewhere/l 2>/dev/null", shell=True)\n' "$FIX" "$FIX" > "$FIX/scripts/x6.py"
runbash "python3 $FIX/scripts/x6.py" "$HOOKS_DIR"
allowed "#3775 control: the same words run by a shell, which takes the redirection out, are let through"
# A string is read up to the first quote mark of either kind. One that stops at a mark unlike the
# one it opened with is not read to its end, so its words are placed as they were before: nothing
# says how many names the link command is given, or that what follows the mark is no name.
printf 'import os\nos.system("ln -s %s/elsewhere/a.txt 2>/dev/null \x27b\x27")\n' "$FIX" > "$FIX/scripts/c1.py"
runbash "python3 $FIX/scripts/c1.py" "$HOOKS_DIR"
refused "#3775 a python string whose link command names the link in quotes after a redirection, which is not read that far"
printf 'import os\nos.system("ln -s %s/elsewhere/a.txt \x27%s/elsewhere/my link\x27")\n' "$FIX" "$FIX" > "$FIX/scripts/c2.py"
runbash "python3 $FIX/scripts/c2.py" "$HOOKS_DIR"
allowed "#3775 control: a string stopped at a quote mark before the name of a link made elsewhere is not taken for a link command given one name"

# What an output redirection of ANY command of a shell script file writes is a write, read by the
# same reading. Every other write a script file makes is named after the call, as before.
mkscript l1.sh "ln -s \"\$A\" \"\$B/t\" 2>/dev/null" "echo hi > out.txt"
runbash "bash $FIX/scripts/l1.sh" "$HOOKS_DIR"
refused "#3775 a script whose link command has a redirection and whose next line writes a file there"
says "#3775 naming the file that line writes" "a write to $HOOKS_DIR/out.txt."
mkscript l2.sh "echo hi > out.txt"
runbash "bash $FIX/scripts/l2.sh" "$HOOKS_DIR"
refused "#3775 the line that writes there with no link command beside it"
mkscript l3.sh "echo hi >> payload/hooks/out.txt"
runbash "bash $FIX/scripts/l3.sh" "$FIX/dev"
refused "#3775 a line of a script file adding to a payload file, run from the root"
mkscript l4.sh "echo hi > \"\$T/out.txt\"" "echo hi > /dev/null 2>&1" "echo hi >&2" "cat < in.txt"
runbash "bash $FIX/scripts/l4.sh" "$HOOKS_DIR"
allowed "#3775 control: lines writing under a value, to /dev/null and to a descriptor, and one reading a file there"
mkscript l5.sh "if [[ \"\$a\" > b ]]; then :; fi" "if (( n > 5 )); then :; fi" "x=\$(( n > 5 ))" "echo \"a > b\" 'c > d'"
runbash "bash $FIX/scripts/l5.sh" "$HOOKS_DIR"
allowed "#3775 control: a > in a test, in an arithmetic and in quotes is no redirection"
mkscript l5b.sh "if [[ \$x > 3 || \$y > 4 ]]; then :; fi"
runbash "bash $FIX/scripts/l5b.sh" "$HOOKS_DIR"
allowed "#3775 control: nor is one in the second half of a test, which the reader cuts at its ||"
mkscript l5c.sh ">lead.txt echo hi"
runbash "bash $FIX/scripts/l5c.sh" "$HOOKS_DIR"
refused "#3775 a line whose redirection is written before its command name"
says "#3775 naming the file" "a write to $HOOKS_DIR/lead.txt."
mkscript l6.sh "cd \"\$T\"" "echo hi > out.txt"
runbash "bash $FIX/scripts/l6.sh" "$HOOKS_DIR"
allowed "#3775 control: a line writing a relative file after the script moves to a folder named by a value"
runbash "bash $FIX/scripts/l2.sh" "$FIX/elsewhere"
allowed "#3775 control: the line that writes a relative file, run outside any checkout"

# Two forms of bash and zsh in which a > writes nothing: the old square bracket arithmetic, and a
# test whose first half holds its closing brackets only inside quotes. Both are read so only in a
# script file bash or zsh is named to run. A shell with neither form runs the same line as a
# command with a redirection, so there it stays refused, and so does every line where a real
# redirection stands beside the form.
# shellcheck disable=SC2016  # the made up lines reach the script as written
mkscript l7.sh 'echo $[ 1 > 0 ]'
runbash "bash $FIX/scripts/l7.sh" "$HOOKS_DIR"
allowed "#3775 a > inside the old square bracket arithmetic, in a script bash is named to run, is no redirection"
runbash "dash $FIX/scripts/l7.sh" "$HOOKS_DIR"
refused "#3775 the same line in a script a shell with no such arithmetic is named to run"
# shellcheck disable=SC2016
mkscript l7b.sh 'echo $[ 1 > 0 ] > out.txt'
runbash "bash $FIX/scripts/l7b.sh" "$HOOKS_DIR"
refused "#3775 an old arithmetic and then a redirection that writes a file there"
# shellcheck disable=SC2016
mkscript l7c.sh 'echo hi > out$[ 1 > 0 ]'
runbash "bash $FIX/scripts/l7c.sh" "$HOOKS_DIR"
refused "#3775 a redirection whose target holds an old arithmetic"
# shellcheck disable=SC2016
mkscript l7d.sh 'echo $$[ 1 > 0 ]'
runbash "bash $FIX/scripts/l7d.sh" "$HOOKS_DIR"
refused "#3775 a bracket after the process number opens no arithmetic, so the > is a redirection"
# shellcheck disable=SC2016
mkscript l7e.sh 'echo \$[ 1 > 0 ]'
runbash "bash $FIX/scripts/l7e.sh" "$HOOKS_DIR"
refused "#3775 nor does one after an escaped dollar sign"
# shellcheck disable=SC2016
mkscript l7f.sh "echo '\$[' 1 > out.txt ']'"
runbash "bash $FIX/scripts/l7f.sh" "$HOOKS_DIR"
refused "#3775 nor do the two characters inside quotes, where the > after them is a redirection"
# shellcheck disable=SC2016
mkscript l8.sh '[[ $a == "]]" || $b > c ]] && echo y'
runbash "bash $FIX/scripts/l8.sh" "$HOOKS_DIR"
allowed "#3775 a test whose first half holds its closing brackets only in quotes is still open in its second half"
runbash "dash $FIX/scripts/l8.sh" "$HOOKS_DIR"
refused "#3775 the same line in a script a shell with no such test is named to run"
# shellcheck disable=SC2016
mkscript l8b.sh '[[ $a == "]]" || $b > c ]] > out.txt'
runbash "bash $FIX/scripts/l8b.sh" "$HOOKS_DIR"
refused "#3775 such a test with a redirection after its closing brackets"
# shellcheck disable=SC2016
mkscript l8c.sh '[[x "]]" || echo hi > c ]]'
runbash "bash $FIX/scripts/l8c.sh" "$HOOKS_DIR"
refused "#3775 a command whose name only starts with two brackets opens no test"
# shellcheck disable=SC2016
mkscript l8d.sh '[[ $a == "]]"'
mkscript l8e.sh 'echo hi > out.txt ]]'
runbash "bash $FIX/scripts/l8d.sh; bash $FIX/scripts/l8e.sh" "$HOOKS_DIR"
refused "#3775 a test left open at the end of one script file covers no line of the next"
mkscript l8f.sh "bash $FIX/scripts/l8d.sh" 'echo hi > out.txt ]]'
runbash "bash $FIX/scripts/l8f.sh" "$HOOKS_DIR"
refused "#3775 nor a line of the script file that ran it"
# Quotes that nest are not read flat: read so, every ]] of the first line stands inside quotes,
# and the test it closes would be taken to cover the line after it.
cat > "$FIX/scripts/l8g.sh" <<'L8G'
#!/bin/bash
[[ "$(echo '"')" == x ]] > "$(echo '"').txt"
echo hi > out2.txt ]]
L8G
runbash "bash $FIX/scripts/l8g.sh" "$HOOKS_DIR"
refused "#3775 a closed test whose quotes nest leaves the line after it read"

# LET THROUGH UNTIL DECIDED (claude-config#3775). 3808's head refused each of these inside a
# payload folder, only for the redirection word of the link command beside it; main lets each
# through, and so does this gate with no link command in the script. What a program writes by its
# own arguments is not read from a script file, and a link whose name is a value is not judged
# (the pull request of #3689): both are named after the call. Refusing them before it is Dan's
# choice (the pull request that added these lines).
mkscript u1.sh "ln -s \"\$A\" \"\$B/t\" 2>/dev/null" "touch out.txt"
runbash "bash $FIX/scripts/u1.sh" "$HOOKS_DIR"
allowed "#3775 let through until decided: a link command with a redirection, then a touch of a file there"
mkscript u2.sh "ln -s \"\$A\" \"\$B/t\" 2>&1 | tee log.txt"
runbash "bash $FIX/scripts/u2.sh" "$HOOKS_DIR"
allowed "#3775 let through until decided: a link command whose output is piped to a tee writing a file there"
mklarge u3.sh "echo hi > out.txt"
runbash "bash $FIX/scripts/u3.sh" "$HOOKS_DIR"
allowed "#3775 let through until decided: a large script, read as text for its links alone, whose line writes a file there"
# shellcheck disable=SC2016
printf 'import os\nos.system("ln -s $A $B/t 2>/dev/null")\nopen("out.txt", "w").write("x")\n' > "$FIX/scripts/u4.py"
runbash "python3 $FIX/scripts/u4.py" "$HOOKS_DIR"
allowed "#3775 let through until decided: a python script file with such a link command that also opens a file there for writing"
mkscript u5.sh "ln -s $FIX/elsewhere/a.txt \"\$N\" 2>/dev/null"
runbash "bash $FIX/scripts/u5.sh" "$HOOKS_DIR"
allowed "#3775 let through until decided: a link whose name is a value, with a redirection, run inside a payload folder"
mkscript u6.sh "ln -s $FIX/elsewhere/a.txt \"\$N\""
runbash "bash $FIX/scripts/u6.sh" "$HOOKS_DIR"
allowed "#3775 control: the same link with no redirection is let through, as it was"

# LET THROUGH UNTIL DECIDED, SEVEN MORE KINDS (claude-config#3775). Each of these makes a link or
# writes a file in the payload folder it is run in. 3808's head refused each only for the
# redirection word of the link command it holds; main lets each through, and so does this gate.
# Each case asserts the answer given today and no intended one: refusing any of them before the
# call is Dan's choice (the pull request that added these lines).
# 1. One name in a string, with a second command written against the redirection: the target is
#    read to the next blank, so what follows is counted as a second name.
printf 'import os\nos.system("ln -s %s/elsewhere/a.txt 2>/dev/null;true %s/elsewhere/b")\n' "$FIX" "$FIX" > "$FIX/scripts/v1.py"
runbash "python3 $FIX/scripts/v1.py" "$HOOKS_DIR"
allowed "#3775 let through until decided: one name in a python string, a second command written against its redirection"
# 2. One name beside a value that holds the options: the value is counted as a name.
# shellcheck disable=SC2016  # the name reaches the made up script with its value unfilled
mkscript v2.sh 'ln $LN_FLAGS '"$FIX"'/elsewhere/a.txt 2>/dev/null'
runbash "bash $FIX/scripts/v2.sh" "$HOOKS_DIR"
allowed "#3775 let through until decided: one name beside a value that holds the options, with a redirection"
# 3. A name that starts with a dash after --: every word starting with a dash is dropped as an option.
mkscript v3.sh "ln -s -- -a 2>/dev/null"
runbash "bash $FIX/scripts/v3.sh" "$HOOKS_DIR"
allowed "#3775 let through until decided: a link named by a word starting with a dash after --, with a redirection"
# 4. An output redirection whose target holds a value and still lands in the folder: the link
#    command's own, and another line's.
# shellcheck disable=SC2016
mkscript v4.sh "ln -s $FIX/elsewhere/a.txt $FIX/elsewhere/b 2>/dev/null >out."'$$'
runbash "bash $FIX/scripts/v4.sh" "$HOOKS_DIR"
allowed "#3775 let through until decided: a link command whose second redirection names a relative file ending in a value"
# shellcheck disable=SC2016
mkscript v4b.sh "ln -s $FIX/elsewhere/a.txt $FIX/elsewhere/b 2>/dev/null" 'echo hi > out.$$'
runbash "bash $FIX/scripts/v4b.sh" "$HOOKS_DIR"
allowed "#3775 let through until decided: a link command with a redirection, then a line writing a relative file ending in a value"
# 5. >| on another line: the shared reader cuts the line at the | of the operator.
mkscript v5.sh "ln -s $FIX/elsewhere/a.txt $FIX/elsewhere/b 2>/dev/null" "echo hi >| out.txt"
runbash "bash $FIX/scripts/v5.sh" "$HOOKS_DIR"
allowed "#3775 let through until decided: a link command with a redirection, then a line writing a file there with >|"
# 6. An output redirection of a test: a line that opens with a test is not read for redirections.
mkscript v6.sh "ln -s $FIX/elsewhere/a.txt $FIX/elsewhere/b 2>/dev/null" "[[ -d x ]] > out.txt"
runbash "bash $FIX/scripts/v6.sh" "$HOOKS_DIR"
allowed "#3775 let through until decided: a link command with a redirection, then a test whose output is sent to a file there"
# 7. A write after a move this gate follows and the shell does not make.
mkscript v7.sh "ln -s $FIX/elsewhere/a.txt $FIX/elsewhere/b 2>/dev/null" "cd $FIX/elsewhere/no-such-folder 2>/dev/null || true" "echo hi > out.txt"
runbash "bash $FIX/scripts/v7.sh" "$HOOKS_DIR"
allowed "#3775 let through until decided: a link command with a redirection, a move to a folder that is not there, then a line writing a file"

# Three readings no case above holds: a quoted name is one word, &> in a large script is read to
# its end, and an input copied from a descriptor or closed is a read.
mkdir -p "$FIX/elsewhere/my dir"
mkscript q1.sh "ln -s $FIX/elsewhere/a.txt \"$FIX/elsewhere/my dir/l\" 2>/dev/null"
runbash "bash $FIX/scripts/q1.sh" "$HOOKS_DIR"
allowed "#3775 a link elsewhere whose quoted name holds a blank is one word, and is let through"
mklarge q2.sh "ln -s \"\$A\" \"\$B/t\" &>out.txt"
runbash "bash $FIX/scripts/q2.sh" "$HOOKS_DIR"
refused "#3775 a large script whose link command sends both outputs to a file there with &>"
says "#3775 naming the file" "a write to $HOOKS_DIR/out.txt."
mklarge q2root.sh "ln -s \"\$A\" \"\$B/t\" &>payload/hooks/out.txt"
runbash "bash $FIX/scripts/q2root.sh" "$FIX/dev"
refused "#3775 and to a payload file, from the root"
mkscript q3.sh "ln -s \"\$A\" \"\$B/t\" <&3"
runbash "bash $FIX/scripts/q3.sh" "$HOOKS_DIR"
allowed "#3775 a link command whose input is copied from a descriptor writes nothing there"
mkscript q4.sh "ln -s \"\$A\" \"\$B/t\" <&-"
runbash "bash $FIX/scripts/q4.sh" "$HOOKS_DIR"
allowed "#3775 nor does one whose input is closed"

# A named descriptor is a descriptor: what follows its operator is read as after a number.
mkscript n1.sh "ln -s \"\$A\" \"\$B/t\" {fd}>/dev/null"
runbash "bash $FIX/scripts/n1.sh" "$HOOKS_DIR"
allowed "#3775 output sent to /dev/null through a named descriptor writes nothing there"
runbash "bash $FIX/scripts/w12.sh" "$HOOKS_DIR"
says "#3775 and the file one writes there is named by its own name" "a write to $HOOKS_DIR/named.txt."
# KEPT UNTIL DECIDED (claude-config#3775): a target that is a value, its operator a word of its
# own. Written against its operator the same target is let through by main, by 3808's head and
# here, as any value is. Letting the spaced spelling through lets a write to a value through that
# 3808's head refuses, so it is refused as it was and the choice is Dan's.
mkscript n2.sh "ln -s \"\$A\" \"\$B/t\" 2> \"\$T/err\""
runbash "bash $FIX/scripts/n2.sh" "$HOOKS_DIR"
refused "#3775 kept until decided: errors sent to a file named through a value, the operator a word of its own"
mkscript n3.sh "ln -s \"\$A\" \"\$B/t\" 2> \$T/err"
runbash "bash $FIX/scripts/n3.sh" "$HOOKS_DIR"
refused "#3775 kept until decided: the same with the value unquoted"
mkscript n4.sh "ln -s \"\$A\" \"\$B/t\" 2> \$(mktemp)"
runbash "bash $FIX/scripts/n4.sh" "$HOOKS_DIR"
refused "#3775 kept until decided: errors sent to a file a command names"
mkscript n5.sh "ln -s \"\$A\" \"\$B/t\" 2>\$T/err"
runbash "bash $FIX/scripts/n5.sh" "$HOOKS_DIR"
allowed "#3775 control: the value written against its operator is let through, as it was"

echo "a path in a command string takes nothing from the read of the whole command"

# WHAT A STRING'S SEGMENTS PLACE (claude-config#3775, found in review 2026-11-27). An open( call
# written over two lines is in no one segment, so only the read of the whole command sees it, and
# that read leaves out a path a segment already placed. The segments of a command string filled
# the same set: a string naming the same path in an open( call, after a cd this gate follows and
# the shell does not (one in brackets, or a pushd and a popd), placed it elsewhere, and the write
# to the checkout the command really runs in was let through. The gate on main refused all three.
# Each command is written as one $'...' word, its line breaks as \n: a heredoc holding a quote
# inside a command substitution is refused by bash 3.2 on macOS (claude-config#1690).
TWO_LINE_OPEN=$'python3 -c \'import os\nopen("payload/hooks/x.sh",\n"w").write("x")\''
STRING_NAMES_IT=$'python3 -c \'import os\nos.system("echo open(\\"payload/hooks/x.sh\\", \\"w\\")")\nopen("payload/hooks/x.sh",\n"w").write("x")\''
STRING_NAMES_IT_WITH=$'python3 -c \'import os\nos.system("echo open(\\"payload/hooks/x.sh\\", \\"w\\")")\nwith open(\n"payload/hooks/x.sh", "w") as f: f.write("x")\''
runbash "(cd $FIX/elsewhere); $TWO_LINE_OPEN" "$FIX/dev"
refused "#3775 control: an open over two lines, after a cd in brackets, is refused where the session is"
runbash "pushd $FIX/elsewhere; popd; $TWO_LINE_OPEN" "$FIX/dev"
refused "#3775 control: and after a pushd and a popd"
runbash "$STRING_NAMES_IT" "$FIX/dev"
refused "#3775 control: and with a command string naming the same path, with no cd at all"
runbash "(cd $FIX/elsewhere); $STRING_NAMES_IT" "$FIX/dev"
refused "#3775 a command string naming the same path does not let it through after a cd in brackets"
says "#3775 and the refusal names the file in the checkout the command runs in" "$FIX/dev/payload/hooks/x.sh"
runbash "pushd $FIX/elsewhere; popd; $STRING_NAMES_IT" "$FIX/dev"
refused "#3775 nor after a pushd and a popd"
runbash "pushd $FIX/elsewhere; popd; $STRING_NAMES_IT_WITH" "$FIX/dev"
refused "#3775 nor written as a with open( whose path is on the next line"
runbash "cd $FIX/elsewhere; $STRING_NAMES_IT" "$FIX/dev"
refused "#3775 and after a cd the shell does follow it is refused as the gate on main refuses it"

case "$(ps -o command= -p "$WPID" 2>/dev/null || true)" in
  *claude-sync*watch*) check "the stand in watcher lived to the end of the suite" ok ;;
  *) check "the stand in watcher lived to the end of the suite" "it had gone, so every answer after that was given with no watcher and proves nothing" ;;
esac

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
