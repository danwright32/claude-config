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
# What the old search refused by accident is let through (claude-config#3855). Taking every
# occurrence of a script name out could make the word payload/ appear where the name sat against it
# inside a longer word. Neither path below is a payload path, and the gate on main lets both
# through. The pull request of #3775 kept the two refusals until Dan chose; on 2026-11-27 he chose
# "Keep now, drop in #3855", so the old search is gone and both are let through, as on main.
# shellcheck disable=SC2016
runbash 'bash x; bash $Y xpayload/hooks/x.sh' "$FIX/elsewhere"
allowed "#3855 dropped: a script named x beside xpayload/ and a script named by a value names no payload path"
# shellcheck disable=SC2016
runbash 'bash s; bash $Y /api/payloads' "$FIX/elsewhere"
allowed "#3855 dropped: a script named s beside /payloads and a script named by a value names no payload path"
# The refusals the old search shared with the new one stay: a real payload path beside each.
# shellcheck disable=SC2016
runbash 'bash x; bash $Y payload/hooks/x.sh' "$FIX/elsewhere"
refused "#3855 control: the first with a real payload path given to the script is still refused"
# shellcheck disable=SC2016
runbash 'bash s; bash $Y /api/payload/hooks' "$FIX/elsewhere"
refused "#3855 control: the second with a real payload folder given to the script is still refused"

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

echo "a command is judged in the folder the shell really runs it in (claude-config#3855)"

# A CHANGE OF FOLDER THE SHELL UNDOES (claude-config#3855, found in the review of 2026-11-27). The
# gate followed every cd and pushd it met, so after a cd in brackets, or a pushd and its popd, it
# judged the commands after it in the other folder while the shell ran them where the session was:
# a write under payload/ from the primary checkout went through with no words. Each command below
# is only ever handed to the gate. None is run.
runbash "(cd $FIX/elsewhere); echo x > payload/hooks/x.sh" "$FIX/dev"
refused "#3855 a redirect after a cd in brackets is refused where the session is"
says "#3855 and the refusal names the file in the checkout the command runs in" "$FIX/dev/payload/hooks/x.sh"
runbash "(cd $FIX/elsewhere); python3 -c 'open(\"payload/hooks/x.sh\",\"w\").write(\"x\")'" "$FIX/dev"
refused "#3855 an inline script opening a payload file on one line, after a cd in brackets"
runbash "(cd $FIX/elsewhere); rm payload/hooks/x.sh" "$FIX/dev"
refused "#3855 a remove after a cd in brackets"
runbash "(cd $FIX/elsewhere && true); cp $FIX/elsewhere/a.txt payload/hooks/new.sh" "$FIX/dev"
refused "#3855 a copy after brackets holding a cd and another command"
runbash "(cd $FIX/elsewhere); (rm payload/hooks/x.sh)" "$FIX/dev"
refused "#3855 a remove in brackets of its own, after a cd in brackets"
runbash "(cd $FIX/elsewhere) && rm payload/hooks/x.sh" "$FIX/dev"
refused "#3855 a remove joined to the brackets by &&"
runbash "(cd $FIX/elsewhere)
rm payload/hooks/x.sh" "$FIX/dev"
refused "#3855 a remove on the line after the brackets"
runbash "(cd $FIX/elsewhere); python3 - <<'EOF'
open(\"payload/hooks/x.sh\",\"w\").write(\"x\")
EOF" "$FIX/dev"
refused "#3855 a script fed from a heredoc, after a cd in brackets"
runbash "pushd $FIX/elsewhere; popd; echo x > payload/hooks/x.sh" "$FIX/dev"
refused "#3855 a redirect after a pushd and its popd is refused where the session is"
runbash "pushd $FIX/elsewhere; popd; python3 -c 'open(\"payload/hooks/x.sh\",\"w\").write(\"x\")'" "$FIX/dev"
refused "#3855 an inline script opening a payload file on one line, after a pushd and its popd"
runbash "pushd $FIX/elsewhere && popd && rm payload/hooks/x.sh" "$FIX/dev"
refused "#3855 a remove after a pushd and its popd joined by &&"
runbash "pushd $FIX/elsewhere >/dev/null; popd >/dev/null; rm payload/hooks/x.sh" "$FIX/dev"
refused "#3855 a remove after a pushd and a popd whose output is sent away"
runbash "pushd $FIX/dev; pushd $FIX/elsewhere; popd; rm payload/hooks/x.sh" "$FIX/elsewhere"
refused "#3855 after two pushd and one popd a remove is judged in the folder the first pushd went to"
runbash "cd $FIX/elsewhere; popd; rm payload/hooks/x.sh" "$FIX/dev"
refused "#3855 a cd and a popd: a shell set to keep every cd on its list goes back, so it is judged there too"
runbash "cd $FIX/elsewhere | cat; rm payload/hooks/x.sh" "$FIX/dev"
refused "#3855 a cd in a pipeline moves a shell of its own, so the remove after it is judged where the session is"
runbash "cd $FIX/elsewhere & rm payload/hooks/x.sh" "$FIX/dev"
refused "#3855 so is a cd sent to the background"
runbash "true & rm payload/hooks/x.sh" "$FIX/dev"
refused "#3855 a command after a single & is a command of its own, and is judged"
# A command the shared reader cannot vouch for, here one with a quote left open: which folder each
# part runs in cannot be read, so each is judged in every folder a cd in the command names, the
# session's among them, and cut at a single & too.
runbash "(cd $FIX/elsewhere); rm payload/hooks/x.sh \"left open" "$FIX/dev"
refused "#3855 a command the reader cannot read is judged where the session is too, after a cd in brackets"
runbash "true & rm payload/hooks/x.sh \"left open" "$FIX/dev"
refused "#3855 and after a single &"
runbash "sleep 1& rm payload/hooks/x.sh \"left open" "$FIX/dev"
refused "#3855 and after a single & that follows a digit"
runbash "cd $FIX/elsewhere && rm payload/hooks/x.sh \"left open" "$FIX/dev"
refused "#3855 and after a cd the shell would keep, since which folder it runs in cannot be read"
# Judged in each folder, never refused outright: the path below names a payload folder, so a gate
# that refused every command it cannot read that names one would refuse it.
runbash "(cd $FIX/elsewhere); rm $FIX/elsewhere/payload/a.txt \"left open" "$FIX/dev"
allowed "#3855 control: a command the reader cannot read that names a payload folder outside any checkout is let through"
# The same when the part that cannot be read is a string handed to a shell: the command around it
# reads well, and the string is still judged every way (found by the lessons review of this change).
runbash "bash -c 'true & rm payload/hooks/x.sh \"left open'" "$FIX/dev"
refused "#3855 a string handed to a shell that the reader cannot read is judged after a single & too"
runbash "bash -c '(cd $FIX/elsewhere); rm $FIX/elsewhere/payload/a.txt \"left open'" "$FIX/dev"
allowed "#3855 control: such a string that names a payload folder outside any checkout is let through"
runbash "sleep 1& rm payload/hooks/x.sh" "$FIX/dev"
refused "#3855 a command after a single & that follows a digit is judged, in a command the reader can read"
# What really moved is still judged where it moved to, and what was refused before still is.
runbash "( cd $FIX/elsewhere; echo x > payload/hooks/x.sh )" "$FIX/dev"
allowed "#3855 control: a write inside the brackets, after the cd there, lands elsewhere and is let through"
runbash "cd $FIX/elsewhere; echo x > payload/hooks/x.sh" "$FIX/dev"
allowed "#3855 control: a write after a cd the shell keeps lands elsewhere and is let through"
runbash "cd $FIX/elsewhere && rm payload/hooks/x.sh" "$FIX/dev"
allowed "#3855 control: so is a remove joined to that cd by &&"
runbash "pushd $FIX/elsewhere; echo x > payload/hooks/x.sh; popd" "$FIX/dev"
allowed "#3855 control: a write between a pushd and its popd lands elsewhere and is let through"
runbash "pushd $FIX/elsewhere; rm payload/hooks/x.sh" "$FIX/dev"
allowed "#3855 control: a remove after a pushd with no popd lands elsewhere and is let through"
runbash "true & rm $FIX/elsewhere/a.txt" "$FIX/dev"
allowed "#3855 control: a remove outside any checkout after a single & is let through"
runbash "(cd $FIX/dev); echo x > payload/hooks/x.sh" "$FIX/elsewhere"
allowed "#3855 control: a write after a cd in brackets into the checkout stays where the session is, elsewhere"
runbash "cd $FIX/dev; (cd $FIX/elsewhere); rm payload/hooks/x.sh" "$FIX/elsewhere"
refused "#3855 a remove after a kept cd into the checkout and an undone one out of it is judged in the checkout"
runbash "python3 -c \"import os; os.system('(cd $FIX/elsewhere); rm payload/hooks/x.sh')\"" "$FIX/dev"
refused "#3855 control: the same inside a command string an inline script runs was refused before, and is"
runbash "bash -c 'pushd $FIX/dev; pushd $FIX/elsewhere; popd; rm payload/hooks/x.sh'" "$FIX/elsewhere"
refused "#3855 two pushd and one popd inside a command string handed to a shell are judged where the first pushd went"
# A COMMAND IS REFUSED WHEN ANY READING OF IT REFUSES. The reading that was there follows the
# pushd into the checkout and knows no popd, so it judges the remove in the checkout. The new
# reading goes back with the popd and judges it elsewhere. The first still refuses, so the gate does.
runbash "pushd $FIX/dev; popd; rm payload/hooks/x.sh" "$FIX/elsewhere"
refused "#3855 what the reading that was there refused is still refused: a remove after a pushd into the checkout and its popd"
runbash "pushd $FIX/dev >/dev/null; popd >/dev/null; python3 -c 'open(\"payload/hooks/x.sh\",\"w\").write(\"x\")'" "$FIX/elsewhere"
refused "#3855 and an inline script opening a payload file after that pushd and its popd"

echo "a remove or an edit fed its paths by the command before it (claude-config#3855)"

# xargs runs its command on the words it is fed. The gate read xargs rm as a remove of nothing.
# Now the words the commands before it in the pipeline name are judged as what it writes.
runbash "echo payload/hooks/x.sh | xargs rm" "$FIX/dev"
refused "#3855 xargs rm fed a payload path is refused"
says "#3855 and the refusal names the file" "$FIX/dev/payload/hooks/x.sh"
runbash "printf '%s\\n' payload/hooks/x.sh | xargs rm -f" "$FIX/dev"
refused "#3855 the same fed by printf"
runbash "echo 'payload/hooks/x.sh' | xargs rm" "$FIX/dev"
refused "#3855 the same with the path in single quotes"
runbash "grep -l foo payload/hooks/x.sh | xargs sed -i -e s/a/b/" "$FIX/dev"
refused "#3855 an in place sed fed the files a search of payload names"
runbash "find payload/hooks -name x.sh | xargs rm" "$FIX/dev"
refused "#3855 a remove fed by a find under payload"
runbash "echo x.sh | xargs rm" "$FIX/dev/payload/hooks"
refused "#3855 a remove fed a bare name, run inside the payload folder"
runbash "echo payload/hooks/x.sh | xargs -n1 rm" "$FIX/dev"
refused "#3855 xargs with an option of its own before the remove"
runbash "echo payload/hooks/x.sh | xargs git rm" "$FIX/dev"
refused "#3855 a git rm fed a payload path"
runbash "echo payload/hooks/x.sh | sort | xargs rm" "$FIX/dev"
refused "#3855 a path fed through another command on the way"
runbash "echo payload/hooks/x.sh | sudo xargs rm" "$FIX/dev"
refused "#3855 xargs run behind sudo"
runbash "bash -c 'echo payload/hooks/x.sh | xargs rm'" "$FIX/dev"
refused "#3855 xargs rm fed a payload path inside a command string handed to a shell"
runbash "python3 -c \"import os; os.system('echo payload/hooks/x.sh | xargs rm')\"" "$FIX/dev"
refused "#3855 and inside a command string an inline script runs"
runbash "echo $FIX/elsewhere/a.txt | xargs rm" "$FIX/dev"
allowed "#3855 control: xargs rm fed a path outside any checkout is let through"
runbash "echo payload/hooks/x.sh | xargs cat" "$FIX/dev"
allowed "#3855 control: xargs running a command that only reads is let through"
runbash "echo payload/hooks/x.sh | xargs wc -l; rm $FIX/elsewhere/a.txt" "$FIX/dev"
allowed "#3855 control: a remove after the pipeline has ended is not fed by it"

echo "a symbolic link's target is read from the link's own folder (claude-config#3855)"

# The system reads a symbolic link's target from the folder the link is in, never from where the
# command ran. The gate read it from where the command ran, so a link to payload/hooks made from
# the tests folder, beside the checkout, was a second name for the payload folder it never saw.
runbash "ln -s payload/hooks ../l5" "$FIX/dev/tests"
refused "#3855 a link whose target, read from the link's folder, is the payload folder"
says "#3855 and the refusal names the payload folder" "$FIX/dev/payload/hooks"
runbash "ln -sf payload/hooks ../l5" "$FIX/dev/tests"
refused "#3855 the same with -sf"
runbash "ln -s ../dev/payload/hooks $FIX/elsewhere/l6" "$FIX/dev/tests"
refused "#3855 a target that climbs out of the link's folder and into the checkout"
runbash "ln -s payload/hooks $FIX/dev" "$FIX/elsewhere"
refused "#3855 a link made inside a folder named last, its target read from that folder"
runbash "python3 -c 'import os; os.symlink(\"payload/hooks\", \"../l9\")'" "$FIX/dev/tests"
refused "#3855 the same link made by os.symlink"
runbash "node -e 'require(\"fs\").symlinkSync(\"payload/hooks\", \"../l12\")'" "$FIX/dev/tests"
refused "#3855 by node symlinkSync"
runbash "python3 -c 'from pathlib import Path; Path(\"../l13\").symlink_to(\"payload/hooks\")'" "$FIX/dev/tests"
refused "#3855 by a path object's symlink_to"
runbash "python3 -c \"import os; os.system('ln -s payload/hooks ../l10')\"" "$FIX/dev/tests"
refused "#3855 by ln in a command string an inline script runs"
printf '#!/bin/bash\nln -s payload/hooks ../l11\n' > "$FIX/scripts/rel.sh"
runbash "bash $FIX/scripts/rel.sh" "$FIX/dev/tests"
refused "#3855 by ln in a script file the command runs"
printf 'import os\nos.symlink("payload/hooks", "../l14")\n' > "$FIX/scripts/rel.py"
runbash "python3 $FIX/scripts/rel.py" "$FIX/dev/tests"
refused "#3855 by os.symlink in a script file the command runs"
runbash "ln -s a.txt $FIX/elsewhere/l7" "$FIX/dev"
allowed "#3855 control: a link outside any checkout to a file beside it is let through"
runbash "ln -s payload/hooks ../l5" "$FIX/elsewhere"
allowed "#3855 control: the first command run where no checkout is beside the link is let through"
runbash "ln payload/hooks/x.sh ../l8" "$FIX/dev/tests"
allowed "#3855 control: a hard link's source is read from where the command runs, as the system reads it"

echo "a patch file applied by git is caught after the call, by its destination (claude-config#3855)"

# RULED OUT, WITH THE MEASUREMENT (claude-config#3855). The files a patch touches are named in the
# patch FILE and in no word of the command, as with any other write a file makes: before the call
# there is nothing to read, and the check after the call names what changed. Here the patch is
# really applied, to the stand in checkout, between the two halves.
prepost(){ # prepost <event> <command> <cwd> <tool use id>
  OUT="$(python3 -c '
import json, sys
print(json.dumps({"hook_event_name": sys.argv[1], "tool_name": "Bash", "cwd": sys.argv[3],
                  "tool_use_id": sys.argv[4], "session_id": sys.argv[5], "tool_input": {"command": sys.argv[2]}}))
' "$1" "$2" "$3" "$4" "$SID" | env SYNC_WATCH_PID_FILE="$PIDF" SYNC_HOLD_FILE="$HOLD" PAYLOAD_WRITE_STATE_DIR="$FIX/state" PAYLOAD_WRITE_INSTALLED_DIR="$FIX/installed" bash "$HOOK" 2>&1)"; RC=$?
}
mkdir -p "$FIX/installed"
: > "$FIX/dev/payload/hooks/x.sh"
git -C "$FIX/dev" add payload/hooks/x.sh 2>/dev/null
printf 'patched\n' > "$FIX/dev/payload/hooks/x.sh"
git -C "$FIX/dev" diff -- payload/hooks/x.sh > "$FIX/elsewhere/p.patch" 2>/dev/null
: > "$FIX/dev/payload/hooks/x.sh"
if [ -s "$FIX/elsewhere/p.patch" ]; then check "#3855 the fixture holds a patch that touches the stand in payload file" ok
else check "#3855 the fixture holds a patch that touches the stand in payload file" "git made no patch, so the two cases below measure nothing"; fi
prepost PreToolUse "git apply $FIX/elsewhere/p.patch" "$FIX/dev" g1
allowed "#3855 git apply of a patch file is not refused before it runs: no word of the command names what it touches"
git -C "$FIX/dev" apply "$FIX/elsewhere/p.patch" 2>/dev/null
if [ "$(cat "$FIX/dev/payload/hooks/x.sh" 2>/dev/null)" = "patched" ]; then check "#3855 the patch was applied to the stand in checkout" ok
else check "#3855 the patch was applied to the stand in checkout" "the stand in payload file did not change, so the next case measures nothing"; fi
prepost PostToolUse "git apply $FIX/elsewhere/p.patch" "$FIX/dev" g1
if [ "$RC" -eq 2 ]; then check "#3855 and the payload file it changed is reported after the call" ok
else check "#3855 and the payload file it changed is reported after the call" "exit $RC, said: ${OUT:0:160}"; fi
says "#3855 by the name of the file" "$FIX/dev/payload/hooks/x.sh"
: > "$FIX/dev/payload/hooks/x.sh"

case "$(ps -o command= -p "$WPID" 2>/dev/null || true)" in
  *claude-sync*watch*) check "the stand in watcher lived to the end of the suite" ok ;;
  *) check "the stand in watcher lived to the end of the suite" "it had gone, so every answer after that was given with no watcher and proves nothing" ;;
esac

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
