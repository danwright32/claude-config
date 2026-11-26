#!/usr/bin/env bash
# Tests for how the Slack drafts gate reads a file an interpreter loads as it starts because the
# command sets a variable that names it (claude-config#3675): sitecustomize.py and usercustomize.py
# in a folder PYTHONPATH names, the user site folder PYTHONUSERBASE or HOME places, the libraries
# RUBYOPT and PERL5OPT name (found through RUBYLIB, PERL5LIB or -I), the rubygems.rb RUBYLIB puts in
# front of ruby's own, the debugger PERL5LIB puts in front of perl's own, BASH_ENV, ENV, the start
# up files in the folder ZDOTDIR or HOME names, BUN_OPTIONS and NODE_REPL_EXTERNAL_MODULE. And for
# where node looks for a main file whose name starts with a dash, handed after --.
#
# Every route was measured first with stand in scripts that only wrote a marker file (2026-11-25,
# one run of each shape; python 3.14.4 and 3.9.6, ruby 2.6.10, perl 5.34.1, bash 3.2.57, zsh 5.9,
# dash, ksh, node 22.22.2, bun), and each case below was seen to pass the gate before the change.
# Each has two quiet twins, which must stay allowed, so a fix that refused every command setting
# one of these variables would fail here too: the same command with the variable naming a file
# that does not post, and the same command without the variable.
#
# The world they run in (the gate under test, the throwaway folder and its judgement cache, POST)
# is lib/slack-drafts-gate-harness.sh. The helper functions are copied as they are from the other
# suites, because the gate reads functions only where they are called;
# test-slack-drafts-gate-helper-copies.sh holds the copies equal. A case is driven the same way in
# all of them: a hook payload piped into slack-drafts-only-gate.sh, exit 0 allowed and 2 refused,
# the reason on stderr. Nothing a case names is ever run.
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/lib/slack-drafts-gate-harness.sh" || {
  echo "FAIL: $(basename "$0"): lib/slack-drafts-gate-harness.sh is missing, so there is no gate to run and no world to run it in. Refusing to run."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}

# The helpers every case is driven through, copied as they are into each of the suites: the gate
# knows a shell function only where the text calling it defines it (lib/unknown-program.py,
# #3304), so with these in a sourced file it would read `run_bash "<a command that posts>"` as an
# unknown program running that command, and refuse a plain run of this suite.
pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }

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
run_tool() { run_raw "$(payload "$1" "$2")"; }
run_bash() { run_raw "$(payload Bash "$(bash_input "$1")")"; }

refused() { if [ "$RC" -eq 2 ]; then check "$1" ok; else check "$1" "exit $RC, stdout: ${OUT:0:200}, stderr: ${ERR:0:300}"; fi; }
allowed() { if [ "$RC" -eq 0 ] && [ -z "$(printf '%s%s' "$OUT" "$ERR" | tr -d '[:space:]')" ]; then check "$1" ok
            else check "$1" "exit $RC, stdout: ${OUT:0:200}, stderr: ${ERR:0:300}"; fi; }
says() { case "$ERR" in *"$2"*) check "$1" ok ;; *) check "$1" "stderr did not say '$2': ${ERR:0:400}" ;; esac; }
read_refused() {
  refused "$1"
  case "$ERR" in
    *"could not judge"*|*Traceback*) check "$1 (judged, not a crash)" "the gate crashed: ${ERR:0:300}" ;;
    *) check "$1 (judged, not a crash)" ok ;;
  esac
}

# The fixtures: every file a case names, in one folder the commands are judged in. PYPOST, RBPOST
# and PLPOST are a Python, a ruby and a perl file that post; POST is the harness's curl line.
G="$T/g3675"
mkdir -p "$G"
run_g() { run_raw "$(payload Bash "$(bash_input "$1")" "$G")"; }
# trio <what> <the variable> <a command that loads a file that posts> <the same naming a quiet file> <the same without the variable>
trio() {
  run_g "$3"
  read_refused "#3675 $1 is refused: $3"
  says "#3675 and the refusal names $2: $3" "$2"
  run_g "$4"
  allowed "#3675 $1, naming a file that does not post, passes: $4"
  run_g "$5"
  allowed "#3675 $1, without $2, passes: $5"
}
# pair <what> <the variable> <a command that loads a file that posts> <the same naming a quiet file>
pair() {
  run_g "$3"
  read_refused "#3675 $1 is refused: $3"
  says "#3675 and the refusal names $2: $3" "$2"
  run_g "$4"
  allowed "#3675 $1, naming a file that does not post, passes: $4"
}
pypost() { printf '%s\n' 'import urllib.request' 'urllib.request.urlopen("https://slack.com/api/chat.postMessage", data=b"x")' > "$1"; }
rbpost() { printf '%s\n' 'require "net/http"' 'Net::HTTP.post(URI("https://slack.com/api/chat.postMessage"), "text=hi")' > "$1"; }
plpost() { printf '%s\n' "package $2;" 'system("curl -s -X POST -d text=hi https://slack.com/api/chat.postMessage");' '1;' > "$1"; }
jspost() { printf '%s\n' 'fetch("https://slack.com/api/chat.postMessage", {method: "POST", body: "text=hi"})' > "$1"; }

printf '%s\n' 'print(1)' > "$G/quiet.py"
printf '%s\n' 'puts 1' > "$G/quiet.rb"
printf '%s\n' 'print 1;' > "$G/quiet.pl"
printf '%s\n' 'echo hi' > "$G/quiet.sh"
printf '%s\n' 'console.log(1)' > "$G/quiet.js"

echo "slack drafts only: the yardsticks, each file that posts refused run by name (claude-config#3675)"
pypost "$G/posts.py"
rbpost "$G/posts.rb"
plpost "$G/posts.pl" main
printf '%s\n' "$POST" > "$G/posts.sh"
jspost "$G/posts.js"
for runs in "python3 posts.py" "ruby posts.rb" "perl posts.pl" "bash posts.sh" "zsh posts.sh" "sh posts.sh" "node posts.js" "bun posts.js"; do
  run_g "$runs"
  read_refused "#3675 the yardstick: $runs"
done
for runs in "python3 quiet.py" "ruby quiet.rb" "perl quiet.pl" "bash quiet.sh" "zsh quiet.sh" "sh -i quiet.sh" "node quiet.js" "bun quiet.js"; do
  run_g "$runs"
  allowed "#3675 the yardstick: $runs"
done

echo "slack drafts only: sitecustomize and usercustomize in a folder PYTHONPATH names (claude-config#3675)"
# Measured: `PYTHONPATH=dir python3 quiet.py` ran dir/sitecustomize.py and dir/usercustomize.py
# before quiet.py, as a module or as a package folder, from any entry of the value, with -c too;
# not with -S, -E or -I, and never one in the folder the script is in.
mkdir -p "$G/custom" "$G/usercustom" "$G/pkgcustom/sitecustomize" "$G/pkgcalm/sitecustomize" "$G/calm" "$G/empty"
pypost "$G/custom/sitecustomize.py"
pypost "$G/usercustom/usercustomize.py"
pypost "$G/pkgcustom/sitecustomize/__init__.py"
printf '%s\n' 'x = 1' > "$G/pkgcalm/sitecustomize/__init__.py"
printf '%s\n' 'x = 1' > "$G/calm/sitecustomize.py"
printf '%s\n' 'x = 1' > "$G/calm/usercustomize.py"
printf '%s\n' 'python3 quiet.py' > "$G/runs-py.sh"
trio "sitecustomize.py in a PYTHONPATH folder" PYTHONPATH "PYTHONPATH=custom python3 quiet.py" "PYTHONPATH=calm python3 quiet.py" "python3 quiet.py"
trio "usercustomize.py in a PYTHONPATH folder" PYTHONPATH "PYTHONPATH=usercustom python3 quiet.py" "PYTHONPATH=calm python3 quiet.py" "python3 quiet.py"
pair "a sitecustomize package in a PYTHONPATH folder" PYTHONPATH "PYTHONPATH=pkgcustom python3 quiet.py" "PYTHONPATH=pkgcalm python3 quiet.py"
pair "sitecustomize.py in a later entry of PYTHONPATH" PYTHONPATH "PYTHONPATH=calm:custom python3 quiet.py" "PYTHONPATH=calm:empty python3 quiet.py"
pair "sitecustomize.py with code given by -c" PYTHONPATH "PYTHONPATH=custom python3 -c 'pass'" "PYTHONPATH=calm python3 -c 'pass'"
pair "sitecustomize.py with PYTHONPATH set through env" PYTHONPATH "env PYTHONPATH=custom python3 quiet.py" "env PYTHONPATH=calm python3 quiet.py"
pair "sitecustomize.py with PYTHONPATH exported first" PYTHONPATH "export PYTHONPATH=custom; python3 quiet.py" "export PYTHONPATH=calm; python3 quiet.py"
pair "sitecustomize.py under a script that starts python3" PYTHONPATH "PYTHONPATH=custom bash runs-py.sh" "PYTHONPATH=calm bash runs-py.sh"
run_g 'PYTHONPATH="$UNSET_3675/lib" python3 quiet.py'
read_refused "#3675 a PYTHONPATH the gate cannot work out, in front of python3 itself, is refused"
says "#3675 and the refusal names PYTHONPATH" "PYTHONPATH"
run_g 'PYTHONPATH="calm:$PYTHONPATH" python3 quiet.py'
allowed "#3675 a PYTHONPATH that adds a quiet folder to the session's own passes"

echo "slack drafts only: the user site folder PYTHONUSERBASE or HOME places (claude-config#3675)"
# Measured: `PYTHONUSERBASE=dir python3 quiet.py` ran dir/lib/python/site-packages/usercustomize.py
# and the import lines of each .pth file there (python 3.14.4 and 3.9.6; not with -s), and
# `HOME=dir python3 quiet.py` ran dir/Library/Python/3.14/lib/python/site-packages/usercustomize.py
# (3.14.4).
mkdir -p "$G/userbase/lib/python/site-packages" "$G/calmbase/lib/python/site-packages" "$G/pthbase/lib/python/site-packages" \
  "$G/pyhome/Library/Python/3.14/lib/python/site-packages" "$G/calmpyhome/Library/Python/3.14/lib/python/site-packages"
pypost "$G/userbase/lib/python/site-packages/usercustomize.py"
printf '%s\n' 'x = 1' > "$G/calmbase/lib/python/site-packages/usercustomize.py"
printf '%s\n' 'import pthposts' > "$G/pthbase/lib/python/site-packages/x.pth"
pypost "$G/pthbase/lib/python/site-packages/pthposts.py"
printf '%s\n' 'import pthcalm' > "$G/calmbase/lib/python/site-packages/x.pth"
printf '%s\n' 'x = 1' > "$G/calmbase/lib/python/site-packages/pthcalm.py"
pypost "$G/pyhome/Library/Python/3.14/lib/python/site-packages/usercustomize.py"
printf '%s\n' 'x = 1' > "$G/calmpyhome/Library/Python/3.14/lib/python/site-packages/usercustomize.py"
trio "usercustomize.py in the folder PYTHONUSERBASE places" PYTHONUSERBASE "PYTHONUSERBASE=userbase python3 quiet.py" "PYTHONUSERBASE=calmbase python3 quiet.py" "python3 quiet.py"
pair "a .pth file's import in the folder PYTHONUSERBASE places" PYTHONUSERBASE "PYTHONUSERBASE=pthbase python3 quiet.py" "PYTHONUSERBASE=calmbase python3 quiet.py"
pair "usercustomize.py in the user site folder under HOME" HOME "HOME=pyhome python3 quiet.py" "HOME=calmpyhome python3 quiet.py"

echo "slack drafts only: a library RUBYOPT names, and the rubygems.rb RUBYLIB puts first (claude-config#3675)"
# Measured: `RUBYOPT=-r./mod ruby quiet.rb` ran mod.rb first; `RUBYOPT=-rmod` ran it where RUBYLIB,
# an -I inside RUBYOPT or an -I on ruby's own command line named its folder, with a space after -r
# and with .rb written out too. `RUBYLIB=dir ruby quiet.rb` ran dir/rubygems.rb in place of ruby's
# own (not with --disable-gems).
mkdir -p "$G/rlib" "$G/rcalm" "$G/rgems" "$G/rgemscalm"
rbpost "$G/optposts.rb"
printf '%s\n' 'X = 1' > "$G/optcalm.rb"
rbpost "$G/rlib/libmod.rb"
printf '%s\n' 'X = 1' > "$G/rcalm/libmod.rb"
rbpost "$G/rgems/rubygems.rb"
printf '%s\n' 'X = 1' > "$G/rgemscalm/rubygems.rb"
trio "a library RUBYOPT names by its path" RUBYOPT "RUBYOPT=-r./optposts ruby quiet.rb" "RUBYOPT=-r./optcalm ruby quiet.rb" "ruby quiet.rb"
trio "a library RUBYOPT names, found through RUBYLIB" RUBYOPT "RUBYLIB=rlib RUBYOPT=-rlibmod ruby quiet.rb" "RUBYLIB=rcalm RUBYOPT=-rlibmod ruby quiet.rb" "RUBYLIB=rlib ruby quiet.rb"
pair "a library RUBYOPT names, found through -I on ruby's command line" RUBYOPT "RUBYOPT=-rlibmod ruby -Irlib quiet.rb" "RUBYOPT=-rlibmod ruby -Ircalm quiet.rb"
pair "a library RUBYOPT names, found through -I and its folder as two words" RUBYOPT "RUBYOPT=-rlibmod ruby -I rlib quiet.rb" "RUBYOPT=-rlibmod ruby -I rcalm quiet.rb"
pair "a library RUBYOPT names, found through an -I inside RUBYOPT" RUBYOPT "RUBYOPT='-Irlib -rlibmod' ruby quiet.rb" "RUBYOPT='-Ircalm -rlibmod' ruby quiet.rb"
pair "a library RUBYOPT names after a space" RUBYOPT "RUBYOPT='-r libmod' RUBYLIB=rlib ruby quiet.rb" "RUBYOPT='-r libmod' RUBYLIB=rcalm ruby quiet.rb"
pair "a library RUBYOPT names with .rb written out" RUBYOPT "RUBYLIB=rlib RUBYOPT=-rlibmod.rb ruby quiet.rb" "RUBYLIB=rcalm RUBYOPT=-rlibmod.rb ruby quiet.rb"
pair "a library RUBYOPT names, with RUBYLIB exported first" RUBYOPT "export RUBYLIB=rlib; RUBYOPT=-rlibmod ruby quiet.rb" "export RUBYLIB=rcalm; RUBYOPT=-rlibmod ruby quiet.rb"
pair "a library an exported RUBYOPT names, found by a later RUBYLIB" RUBYOPT "export RUBYOPT=-rlibmod; RUBYLIB=rlib ruby quiet.rb" "export RUBYOPT=-rlibmod; RUBYLIB=rcalm ruby quiet.rb"
pair "the rubygems.rb in a RUBYLIB folder" RUBYLIB "RUBYLIB=rgems ruby quiet.rb" "RUBYLIB=rgemscalm ruby quiet.rb"
for runs in "RUBYOPT=-W0 ruby quiet.rb" "RUBYOPT=-rjson ruby quiet.rb" "RUBYOPT='-w -rset' ruby quiet.rb"; do
  run_g "$runs"
  allowed "#3675 a RUBYOPT that names no file of the command's own passes: $runs"
done
run_g 'RUBYOPT="-r$UNSET_3675/mod" ruby quiet.rb'
read_refused "#3675 a RUBYOPT the gate cannot work out is refused"
says "#3675 and the refusal names RUBYOPT" "RUBYOPT"

echo "slack drafts only: a module PERL5OPT names, and the debugger PERL5LIB puts first (claude-config#3675)"
# Measured: `PERL5OPT=-MMod perl quiet.pl` ran Mod.pm first where PERL5LIB, an -I inside PERL5OPT
# or an -I on perl's own command line named its folder (never from the folder it runs in), with
# -m, with =arguments after the name, and Deep::Mod as Deep/Mod.pm. `PERL5OPT=-d` and `perl -d`
# ran the perl5db.pl of a PERL5LIB folder in place of perl's own, and `PERL5OPT=-d:Mod` ran
# Devel/Mod.pm.
mkdir -p "$G/plib/Deep" "$G/pcalm/Deep" "$G/pdb/Devel" "$G/pdbcalm/Devel"
plpost "$G/plib/Optmod.pm" Optmod
printf '%s\n' 'package Optmod;' '1;' > "$G/pcalm/Optmod.pm"
plpost "$G/plib/Deep/Mod.pm" Deep::Mod
printf '%s\n' 'package Deep::Mod;' '1;' > "$G/pcalm/Deep/Mod.pm"
plpost "$G/pdb/perl5db.pl" DB
printf '%s\n' 'package DB;' 'sub DB {}' '1;' > "$G/pdbcalm/perl5db.pl"
plpost "$G/pdb/Devel/Mark.pm" Devel::Mark
printf '%s\n' 'package Devel::Mark;' 'sub DB::DB {}' '1;' > "$G/pdbcalm/Devel/Mark.pm"
trio "a module PERL5OPT names, found through PERL5LIB" PERL5OPT "PERL5OPT=-MOptmod PERL5LIB=plib perl quiet.pl" "PERL5OPT=-MOptmod PERL5LIB=pcalm perl quiet.pl" "PERL5LIB=plib perl quiet.pl"
pair "a module PERL5OPT names, found through -I on perl's command line" PERL5OPT "PERL5OPT=-MOptmod perl -Iplib quiet.pl" "PERL5OPT=-MOptmod perl -Ipcalm quiet.pl"
pair "a module PERL5OPT names, found through an -I inside PERL5OPT" PERL5OPT "PERL5OPT='-Iplib -MOptmod' perl quiet.pl" "PERL5OPT='-Ipcalm -MOptmod' perl quiet.pl"
pair "a module PERL5OPT names with -m" PERL5OPT "PERL5OPT=-mOptmod PERL5LIB=plib perl quiet.pl" "PERL5OPT=-mOptmod PERL5LIB=pcalm perl quiet.pl"
pair "a module PERL5OPT names with arguments" PERL5OPT "PERL5OPT=-MOptmod=a,b PERL5LIB=plib perl quiet.pl" "PERL5OPT=-MOptmod=a,b PERL5LIB=pcalm perl quiet.pl"
pair "a module PERL5OPT names in a package folder" PERL5OPT "PERL5OPT=-MDeep::Mod PERL5LIB=plib perl quiet.pl" "PERL5OPT=-MDeep::Mod PERL5LIB=pcalm perl quiet.pl"
pair "a module PERL5OPT names, with PERL5LIB exported first" PERL5OPT "export PERL5LIB=plib; PERL5OPT=-MOptmod perl quiet.pl" "export PERL5LIB=pcalm; PERL5OPT=-MOptmod perl quiet.pl"
pair "the debugger module PERL5OPT names with -d:" PERL5OPT "PERL5OPT=-d:Mark PERL5LIB=pdb perl quiet.pl" "PERL5OPT=-d:Mark PERL5LIB=pdbcalm perl quiet.pl"
pair "the perl5db.pl in a PERL5LIB folder, with -d in PERL5OPT" PERL5LIB "PERL5OPT=-d PERL5LIB=pdb perl quiet.pl" "PERL5OPT=-d PERL5LIB=pdbcalm perl quiet.pl"
pair "the perl5db.pl in a PERL5LIB folder, with -d on perl's command line" PERL5LIB "PERL5LIB=pdb perl -d quiet.pl" "PERL5LIB=pdbcalm perl -d quiet.pl"
for runs in "PERL5OPT=-MCarp perl quiet.pl" "PERL5OPT=-w perl quiet.pl" "PERL5OPT='-Mstrict -Mwarnings' perl quiet.pl"; do
  run_g "$runs"
  allowed "#3675 a PERL5OPT that names no file of the command's own passes: $runs"
done
run_g 'PERL5OPT="-M$UNSET_3675" perl quiet.pl'
read_refused "#3675 a PERL5OPT the gate cannot work out is refused"
says "#3675 and the refusal names PERL5OPT" "PERL5OPT"

echo "slack drafts only: the file BASH_ENV names (claude-config#3675)"
# Measured: `BASH_ENV=file bash quiet.sh` ran file first, with -c and for a script run by its path
# whose first line names bash too; not sh, bash --posix or bash -p.
printf '%s\n' "$POST" > "$G/envposts.sh"
printf '%s\n' "$POST" > "$G/envposts"
printf '%s\n' 'echo env' > "$G/envcalm.sh"
printf '%s\n' 'echo env' > "$G/envcalm"
printf '%s\n' '#!/bin/bash' 'echo hi' > "$G/bang.sh"
printf '%s\n' 'BASH_ENV=envposts.sh bash quiet.sh' > "$G/runs-env.sh"
printf '%s\n' 'BASH_ENV=envcalm.sh bash quiet.sh' > "$G/runs-envcalm.sh"
trio "the file BASH_ENV names" BASH_ENV "BASH_ENV=envposts.sh bash quiet.sh" "BASH_ENV=envcalm.sh bash quiet.sh" "bash quiet.sh"
pair "the file BASH_ENV names, with no extension, in front of bash -c" BASH_ENV "BASH_ENV=envposts bash -c ':'" "BASH_ENV=envcalm bash -c ':'"
pair "the file BASH_ENV names, in front of a script run by its path" BASH_ENV "BASH_ENV=envposts.sh ./bang.sh" "BASH_ENV=envcalm.sh ./bang.sh"
pair "the file BASH_ENV names, set through env" BASH_ENV "env BASH_ENV=envposts.sh bash quiet.sh" "env BASH_ENV=envcalm.sh bash quiet.sh"
pair "the file an exported BASH_ENV names" BASH_ENV "export BASH_ENV=envposts.sh; bash quiet.sh" "export BASH_ENV=envcalm.sh; bash quiet.sh"
pair "the file BASH_ENV names, by a path with a variable the gate works out" BASH_ENV 'BASH_ENV="$PWD/envposts.sh" bash quiet.sh' 'BASH_ENV="$PWD/envcalm.sh" bash quiet.sh'
pair "the file BASH_ENV names inside a script the command runs" BASH_ENV "bash runs-env.sh" "bash runs-envcalm.sh"
run_g 'BASH_ENV="$UNSET_3675" bash quiet.sh'
read_refused "#3675 a BASH_ENV the gate cannot work out is refused"
says "#3675 and the refusal names BASH_ENV" "BASH_ENV"
run_g 'BASH_ENV="$(cat where.txt)" bash quiet.sh'
read_refused "#3675 a BASH_ENV made by a substitution is refused"
run_g 'BASH_ENV=nosuchfile.sh bash quiet.sh'
allowed "#3675 a BASH_ENV naming no file there passes: nothing loads"

echo "slack drafts only: the file ENV names (claude-config#3675)"
# Measured: `ENV=file sh -i quiet.sh`, `dash -i` and `ksh -i` ran file first, with -c too; without
# -i none did. ENV is a name programs use for other things, so a value that names no file passes.
trio "the file ENV names, in front of sh -i" ENV "ENV=envposts.sh sh -i quiet.sh" "ENV=envcalm.sh sh -i quiet.sh" "sh -i quiet.sh"
pair "the file ENV names, in front of dash -i -c" ENV "ENV=envposts.sh dash -i -c ':'" "ENV=envcalm.sh dash -i -c ':'"
pair "the file ENV names, in front of ksh -i" ENV "ENV=envposts.sh ksh -i quiet.sh" "ENV=envcalm.sh ksh -i quiet.sh"
pair "the file an exported ENV names" ENV "export ENV=envposts.sh; sh -i quiet.sh" "export ENV=envcalm.sh; sh -i quiet.sh"
for runs in "ENV=production sh -i quiet.sh" "ENV=production node quiet.js" "ENV=staging bash quiet.sh"; do
  run_g "$runs"
  allowed "#3675 an ENV that names no file passes: $runs"
done
run_g 'ENV="$UNSET_3675" sh -i quiet.sh'
read_refused "#3675 an ENV the gate cannot work out, in front of a shell, is refused"
says "#3675 and the refusal names ENV" "ENV"
run_g 'ENV="$UNSET_3675" node quiet.js'
allowed "#3675 an ENV the gate cannot work out, in front of a program that is no shell, passes"

echo "slack drafts only: the start up files in the folder ZDOTDIR or HOME names (claude-config#3675)"
# Measured: `ZDOTDIR=dir zsh quiet.sh` ran dir/.zshenv first, with -c too (not with -f); with -i
# also dir/.zshrc, with -l dir/.zprofile and dir/.zlogin. `HOME=dir zsh quiet.sh` ran dir/.zshenv,
# `HOME=dir bash -i` dir/.bashrc, `bash -l` dir/.bash_profile, `sh -l`, `dash -l` and `ksh -l`
# dir/.profile, `ksh -i` dir/.kshrc.
mkdir -p "$G/zposts" "$G/zcalm" "$G/zrc" "$G/zlogin" "$G/home" "$G/calmhome" "$G/bashhome" "$G/profhome"
printf '%s\n' "$POST" > "$G/zposts/.zshenv"
printf '%s\n' 'echo z' > "$G/zcalm/.zshenv"
printf '%s\n' "$POST" > "$G/zrc/.zshrc"
printf '%s\n' "$POST" > "$G/zlogin/.zlogin"
printf '%s\n' 'echo z' > "$G/zcalm/.zshrc"
printf '%s\n' 'echo z' > "$G/zcalm/.zlogin"
printf '%s\n' "$POST" > "$G/home/.zshenv"
printf '%s\n' 'echo z' > "$G/calmhome/.zshenv"
printf '%s\n' "$POST" > "$G/bashhome/.bashrc"
printf '%s\n' 'echo z' > "$G/calmhome/.bashrc"
printf '%s\n' "$POST" > "$G/profhome/.profile"
printf '%s\n' 'echo z' > "$G/calmhome/.profile"
trio "the .zshenv in the folder ZDOTDIR names" ZDOTDIR "ZDOTDIR=zposts zsh quiet.sh" "ZDOTDIR=zcalm zsh quiet.sh" "zsh quiet.sh"
pair "the .zshenv in the folder ZDOTDIR names, in front of zsh -c" ZDOTDIR "ZDOTDIR=zposts zsh -c ':'" "ZDOTDIR=zcalm zsh -c ':'"
pair "the .zshrc in the folder ZDOTDIR names" ZDOTDIR "ZDOTDIR=zrc zsh -i -c ':'" "ZDOTDIR=zcalm zsh -i -c ':'"
pair "the .zlogin in the folder ZDOTDIR names" ZDOTDIR "ZDOTDIR=zlogin zsh -l -c ':'" "ZDOTDIR=zcalm zsh -l -c ':'"
pair "the .zshenv in the folder an exported ZDOTDIR names" ZDOTDIR "export ZDOTDIR=zposts; zsh quiet.sh" "export ZDOTDIR=zcalm; zsh quiet.sh"
run_g 'ZDOTDIR="$UNSET_3675" zsh quiet.sh'
read_refused "#3675 a ZDOTDIR the gate cannot work out is refused"
says "#3675 and the refusal names ZDOTDIR" "ZDOTDIR"
pair "the .zshenv in the folder HOME names" HOME "HOME=home zsh quiet.sh" "HOME=calmhome zsh quiet.sh"
pair "the .bashrc in the folder HOME names" HOME "HOME=bashhome bash -i -c ':'" "HOME=calmhome bash -i -c ':'"
pair "the .profile in the folder HOME names" HOME "HOME=profhome sh -l -c ':'" "HOME=calmhome sh -l -c ':'"
run_g 'HOME="$UNSET_3675" bash quiet.sh'
allowed "#3675 a HOME the gate cannot work out passes, as before: it is set for many other reasons"

echo "slack drafts only: the files BUN_OPTIONS and NODE_REPL_EXTERNAL_MODULE name (claude-config#3675)"
# Measured: `BUN_OPTIONS='--preload ./pre.js' bun quiet.js` ran pre.js first, with -r too (bun as
# installed); `NODE_REPL_EXTERNAL_MODULE=./mod.js node -i` ran mod.js (node 22.22.2).
jspost "$G/pre.js"
printf '%s\n' 'console.log(0)' > "$G/calmpre.js"
trio "the file BUN_OPTIONS has bun preload" BUN_OPTIONS "BUN_OPTIONS='--preload ./pre.js' bun quiet.js" "BUN_OPTIONS='--preload ./calmpre.js' bun quiet.js" "bun quiet.js"
pair "the file BUN_OPTIONS names with -r" BUN_OPTIONS "BUN_OPTIONS='-r ./pre.js' bun quiet.js" "BUN_OPTIONS='-r ./calmpre.js' bun quiet.js"
pair "the file BUN_OPTIONS names glued to its option" BUN_OPTIONS "BUN_OPTIONS=--preload=./pre.js bun quiet.js" "BUN_OPTIONS=--preload=./calmpre.js bun quiet.js"
trio "the file NODE_REPL_EXTERNAL_MODULE names" NODE_REPL_EXTERNAL_MODULE "NODE_REPL_EXTERNAL_MODULE=./pre.js node -i" "NODE_REPL_EXTERNAL_MODULE=./calmpre.js node -i" "node -i quiet.js"
run_g 'BUN_OPTIONS="--preload $UNSET_3675/x.js" bun quiet.js'
read_refused "#3675 a BUN_OPTIONS the gate cannot work out is refused"

echo "slack drafts only: where node looks for a main file named with a leading dash (claude-config#3675)"
# Measured with node 22.22.2: `node -- -x.js` did not run -x.js in the folder it ran in, nor one
# under node_modules there or above ("Cannot find module '-x.js'"). It ran the one in a folder
# NODE_PATH names (a relative entry too, and a later one), in ~/.node_modules, in
# ~/.node_libraries, and it looks in lib/node beside the folder its own program is in; as a file,
# with .js added, as a folder's index.js or the main its package.json names.
mkdir -p "$G/npath" "$G/ncalm" "$G/npkg/-pk" "$G/npkgcalm/-pk" "$G/nhome/.node_modules" "$G/ncalmhome/.node_modules" \
  "$G/nlibs/.node_libraries" "$G/nprefix/bin" "$G/nprefix/lib/node" "$G/nprefixcalm/bin" "$G/nprefixcalm/lib/node" "$G/ndir"
jspost "$G/npath/-viapath.js"
printf '%s\n' 'console.log(1)' > "$G/ncalm/-viapath.js"
jspost "$G/npkg/-pk/lib.js"
printf '%s\n' '{"main": "lib.js"}' > "$G/npkg/-pk/package.json"
printf '%s\n' 'console.log(1)' > "$G/npkgcalm/-pk/lib.js"
printf '%s\n' '{"main": "lib.js"}' > "$G/npkgcalm/-pk/package.json"
jspost "$G/nhome/.node_modules/-inhome.js"
printf '%s\n' 'console.log(1)' > "$G/ncalmhome/.node_modules/-inhome.js"
jspost "$G/nlibs/.node_libraries/-inhome.js"
jspost "$G/nprefix/lib/node/-inprefix.js"
printf '%s\n' 'console.log(1)' > "$G/nprefixcalm/lib/node/-inprefix.js"
# A stand in for the node program, never run: the gate only asks where a program named node is.
printf '%s\n' '#!/bin/sh' 'exit 1' > "$G/nprefix/bin/node"
chmod +x "$G/nprefix/bin/node"
cp "$G/nprefix/bin/node" "$G/nprefixcalm/bin/node"
chmod +x "$G/nprefixcalm/bin/node"
trio "a dash named main file node finds in a NODE_PATH folder" NODE_PATH "NODE_PATH=npath node -- -viapath.js" "NODE_PATH=ncalm node -- -viapath.js" "node -- -viapath.js"
pair "a dash named main file with .js left off" NODE_PATH "NODE_PATH=npath node -- -viapath" "NODE_PATH=ncalm node -- -viapath"
pair "a dash named main file in a later NODE_PATH entry" NODE_PATH "NODE_PATH=ndir:npath node -- -viapath.js" "NODE_PATH=ndir:ncalm node -- -viapath.js"
pair "a dash named package node finds in a NODE_PATH folder" NODE_PATH "NODE_PATH=npkg node -- -pk" "NODE_PATH=npkgcalm node -- -pk"
pair "a dash named main file with NODE_PATH exported first" NODE_PATH "export NODE_PATH=npath; node -- -viapath.js" "export NODE_PATH=ncalm; node -- -viapath.js"
pair "a dash named main file in .node_modules under HOME" ".node_modules" "HOME=nhome node -- -inhome.js" "HOME=ncalmhome node -- -inhome.js"
run_g "HOME=nlibs node -- -inhome.js"
read_refused "#3675 a dash named main file in .node_libraries under HOME is refused"
PATH="$G/nprefix/bin:$PATH" run_g "node -- -inprefix.js"
read_refused "#3675 a dash named main file in lib/node beside node's own folder is refused"
says "#3675 and the refusal names lib/node" "lib/node"
PATH="$G/nprefixcalm/bin:$PATH" run_g "node -- -inprefix.js"
allowed "#3675 a dash named main file in lib/node that does not post passes"
# What #3600 reads stays read: a file of that name in the folder, which node does not run, is still
# refused, since nothing this change touches may pass more than before.
jspost "$G/-infolder.js"
run_g "node -- -infolder.js"
read_refused "#3675 a dash named file in the folder is still refused after --, as #3600 left it"

echo
sdg_harness_result
