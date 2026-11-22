#!/usr/bin/env bash
# Tests for inline Python that runs a file it names in its own text (claude-config#3397). The rule
# is in lib/py-file-runs.py. Kept apart from test-slack-drafts-only-gate.sh as
# test-slack-drafts-unknown-program.sh is, so that suite does not grow past its wall clock; the
# helpers below are copied from that one as they are, so a case here is driven the same way: a hook
# payload piped into slack-drafts-only-gate.sh, exit 0 allowed and 2 refused, the reason on stderr.
# Nothing a case names is ever run: the files that name a Slack address are only ever read by the
# gate, and no command here is handed to a shell or to python3.
#
# Measured on main at a3ffbde735 on 2026-11-20, and again on this change's base (603a5d40c8) before
# it was made: `python3 posts.py` was refused, while `python3 -c "import runpy;
# runpy.run_path('./posts.py')"` and `python3 -c "exec(open('./posts.py').read())"` passed, with the
# path written out or through the outer shell's variable. Only the modules that code imports and the
# files in the words after it were read, so a file the code names in its own text never was. What
# is held:
#   * each measured form is refused, and so is every other way code given to python3 has to run a
#     file or a module it names: compile then exec, eval of read text, a with block, a helper shaped
#     like execfile, pathlib, io.open and codecs.open, importlib's loaders, a path joined, added,
#     formatted or behind os.chdir, a program started on the file (subprocess, os.system, os.popen,
#     os.exec*), and a module run by its name (runpy.run_module, importlib.import_module,
#     __import__), given by -c or fed in a heredoc;
#   * each has a twin that differs only in whether the file posts, and the twin passes;
#   * a path the gate cannot work out is refused as unread where it is typed, and left as it was in
#     a script on disk; a file handed in the words after the code is read by those words, as before;
#   * code that only reads a file as data, and can run nothing, is not read as running it; where the
#     code can run code the two cannot be told apart, and the file is read as one it may run;
#   * a judgement kept in the cache does not outlive the file it read.
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
run_at() { run_raw "$(payload Bash "$(bash_input "$1")" "$2")"; } # run_at <command> <cwd>

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
POST="curl -s -X POST -d text=hi https://slack.com/api/chat.postMessage"

# A file that posts beside a twin that does not, in each shape a case runs one by: a Python file, one
# in a folder, a package's __main__.py, a file with no extension, a shell script, a script with no
# extension whose one command runs the shell script, an expression in a text file, and a data file.
IP="$T/g3397"
mkdir -p "$IP/sub" "$IP/pkg" "$IP/qpkg" "$IP/later"
printf '%s\n' 'import urllib.request' 'urllib.request.urlopen("https://slack.com/api/chat.postMessage", data=b"x")' > "$IP/posts.py"
printf '%s\n' 'print(1)' > "$IP/quiet.py"
cp "$IP/posts.py" "$IP/sub/deep.py"
cp "$IP/quiet.py" "$IP/sub/calm.py"
cp "$IP/posts.py" "$IP/pkg/__main__.py"
cp "$IP/quiet.py" "$IP/qpkg/__main__.py"
cp "$IP/posts.py" "$IP/noext"
cp "$IP/quiet.py" "$IP/qnoext"
printf '%s\n' "$POST" > "$IP/post.sh"
printf '%s\n' 'echo hi' > "$IP/calm.sh"
printf '%s\n' 'bash post.sh' > "$IP/shrun"
printf '%s\n' 'bash calm.sh' > "$IP/shcalm"
printf '%s\n' '__import__("urllib.request").request.urlopen("https://slack.com/api/chat.postMessage", data=b"x")' > "$IP/expr.txt"
printf '%s\n' '1 + 1' > "$IP/sum.txt"
printf '%s\n' '{"a": 1}' > "$IP/data.json"
printf '%s\n' '{"url": "https://slack.com/api/chat.postMessage"}' > "$IP/named.json"
ip_code() { run_at "python3 -c \"$1\"" "${2:-$IP}"; } # ip_code <Python quoting with ' only> [the folder it runs in]
ip_pair() { # ip_pair <what> <Python holding FILE> <a file that posts> <its twin that does not>
  ip_code "${2//FILE/$3}"
  read_refused "#3397 $1, of a file that posts, is refused"
  says "#3397 $1: the refusal names the file" "${3##*/}"
  ip_code "${2//FILE/$4}"
  allowed "#3397 $1, of a file that does not post, passes"
}

echo "slack drafts only: the fixture is judged as it was before the rule (claude-config#3397)"

run_at "python3 posts.py" "$IP"
read_refused "#3397 the control: python3 run on the file that posts is refused"
run_at "python3 quiet.py" "$IP"
allowed "#3397 the control: python3 run on its quiet twin passes"

echo "slack drafts only: the two measured forms, by a path written out and through the outer shell's variable (claude-config#3397)"

ip_pair "runpy.run_path" "import runpy; runpy.run_path('FILE')" ./posts.py ./quiet.py
ip_pair "exec of open(...).read()" "exec(open('FILE').read())" ./posts.py ./quiet.py
ip_pair "runpy.run_path by an absolute path" "import runpy; runpy.run_path('FILE')" "$IP/posts.py" "$IP/quiet.py"
run_at "python3 -c 'import runpy; runpy.run_path(\"./posts.py\")'" "$IP"
read_refused "#3397 runpy.run_path in code the shell quotes with ' is refused"
run_at "D=$IP; python3 -c \"import runpy; runpy.run_path('\$D/posts.py')\"" "$T"
read_refused "#3397 runpy.run_path by a path through the outer shell's variable is refused"
says "#3397 and that refusal names the file" "posts.py"
run_at "D=$IP; python3 -c \"exec(open('\$D/posts.py').read())\"" "$T"
read_refused "#3397 exec of open(...).read() by a path through the outer shell's variable is refused"
says "#3397 and that refusal names the file" "posts.py"
run_at "D=$IP; python3 -c \"import runpy; runpy.run_path('\$D/quiet.py')\"" "$T"
allowed "#3397 runpy.run_path of the quiet twin through that variable passes"
run_at "D=$IP; python3 -c \"exec(open('\$D/quiet.py').read())\"" "$T"
allowed "#3397 exec of open(...).read() of the quiet twin through that variable passes"
# A variable the gate cannot work out leaves the file unread, which is refused as unread.
run_at "D=\"\$(mktemp -d)\"; python3 -c \"import runpy; runpy.run_path('\$D/quiet.py')\"" "$IP"
read_refused "#3397 runpy.run_path by a path through a shell variable the gate cannot work out is refused"
says "#3397 and that refusal says the path cannot be worked out" "cannot work out"
run_at "python3 -c 'import runpy; runpy.run_path(\"\$D/quiet.py\")'" "$IP"
allowed "#3397 a \$ the shell leaves alone inside ' is the code's own text, naming no file, and passes"

echo "slack drafts only: the other ways code given to python3 has to run a file it names (claude-config#3397)"

ip_pair "compile then exec" "exec(compile(open('FILE').read(), 'x', 'exec'))" ./posts.py ./quiet.py
ip_pair "exec inside a with block" "with open('FILE') as f:
    exec(f.read())" ./posts.py ./quiet.py
ip_pair "text read into a name, then exec" "src = open('FILE').read(); exec(src)" ./posts.py ./quiet.py
ip_pair "a path kept in a name, then runpy.run_path" "import runpy; p = 'FILE'; runpy.run_path(p)" ./posts.py ./quiet.py
ip_pair "a helper shaped like execfile" "def execfile(p):
    exec(open(p).read())
execfile('FILE')" ./posts.py ./quiet.py
ip_pair "eval of text read from a file" "eval(open('FILE').read())" ./expr.txt ./sum.txt
ip_pair "exec of pathlib's read_text" "import pathlib; exec(pathlib.Path('FILE').read_text())" ./posts.py ./quiet.py
ip_pair "exec of io.open" "import io; exec(io.open('FILE').read())" ./posts.py ./quiet.py
ip_pair "exec of codecs.open" "import codecs; exec(codecs.open('FILE').read())" ./posts.py ./quiet.py
ip_pair "importlib's spec_from_file_location" "import importlib.util; s = importlib.util.spec_from_file_location('m', 'FILE'); m = importlib.util.module_from_spec(s); s.loader.exec_module(m)" ./posts.py ./quiet.py
ip_pair "importlib's SourceFileLoader" "from importlib.machinery import SourceFileLoader; SourceFileLoader('m', 'FILE').load_module()" ./posts.py ./quiet.py
ip_pair "a file with no extension" "import runpy; runpy.run_path('FILE')" noext qnoext
ip_pair "a path joined with os.path.join" "import os, runpy; runpy.run_path(os.path.join('sub', 'FILE'))" deep.py calm.py
ip_pair "a path put together with +" "import runpy; runpy.run_path('sub/' + 'FILE')" deep.py calm.py
ip_pair "a path in an f-string" "import runpy; d = 'sub'; runpy.run_path(f'{d}/FILE')" deep.py calm.py
ip_pair "a path after os.chdir" "import os, runpy; os.chdir('sub'); runpy.run_path('FILE')" deep.py calm.py
ip_pair "subprocess run on sys.executable and the file" "import subprocess, sys; subprocess.run([sys.executable, 'FILE'])" ./posts.py ./quiet.py
ip_pair "subprocess run on python3 and the file" "import subprocess; subprocess.run(['python3', 'FILE'])" posts.py quiet.py
ip_pair "subprocess run on a shell and a script with no extension" "import subprocess; subprocess.run(['bash', 'FILE'])" shrun shcalm
ip_pair "subprocess run on a command line" "import subprocess; subprocess.run('python3 FILE', shell=True)" posts.py quiet.py
ip_pair "os.system" "import os; os.system('python3 FILE')" ./posts.py ./quiet.py
ip_pair "os.popen" "import os; os.popen('python3 FILE').read()" ./posts.py ./quiet.py
ip_pair "os.execv" "import os, sys; os.execv(sys.executable, [sys.executable, 'FILE'])" ./posts.py ./quiet.py
ip_pair "os.execlp" "import os; os.execlp('python3', 'python3', 'FILE')" ./posts.py ./quiet.py
run_at "P=./posts.py python3 -c \"import os, runpy; runpy.run_path(os.environ['P'])\"" "$IP"
read_refused "#3397 runpy.run_path by a path from a variable the command sets for python3 is refused"
run_at "P=./quiet.py python3 -c \"import os, runpy; runpy.run_path(os.environ['P'])\"" "$IP"
allowed "#3397 and of the quiet twin the same way passes"
run_at "python3 -c 'import sys; exec(sys.stdin.read())' < posts.py" "$IP"
read_refused "#3397 code that runs its input, fed the file that posts with <, is refused"
says "#3397 and that refusal names the file" "posts.py"
run_at "python3 -c 'import sys; exec(sys.stdin.read())' < quiet.py" "$IP"
allowed "#3397 and fed the quiet twin passes"
run_at "python3 -c 'import sys; print(len(sys.stdin.read()))' < posts.py" "$IP"
allowed "#3397 code that only counts its input, fed the file that posts, passes"

echo "slack drafts only: a module run by its name is read as an import of it is (claude-config#3397)"

ip_mod() { # ip_mod <what> <Python holding MOD> <a module that posts> <its twin that does not>
  ip_code "${2//MOD/$3}"
  read_refused "#3397 $1, of a module that posts, is refused"
  ip_code "${2//MOD/$4}"
  allowed "#3397 $1, of a module that does not post, passes"
}
ip_mod "runpy.run_module" "import runpy; runpy.run_module('MOD')" posts quiet
ip_mod "runpy.run_module of a package" "import runpy; runpy.run_module('MOD')" pkg qpkg
ip_mod "runpy.run_module behind a sys.path change" "import runpy, sys; sys.path.insert(0, 'sub'); runpy.run_module('MOD')" deep calm
ip_mod "importlib.import_module" "import importlib; importlib.import_module('MOD')" posts quiet
ip_mod "__import__" "__import__('MOD')" posts quiet
ip_code "import runpy; runpy.run_module('json.tool')"
allowed "#3397 runpy.run_module of a standard library module passes, as python3 -m of it does"

echo "slack drafts only: code python3 reads from its input is read the same way (claude-config#3397)"

run_at "python3 - <<'EOF'
import runpy
runpy.run_path('./posts.py')
EOF" "$IP"
read_refused "#3397 runpy.run_path in code fed to python3 - in a heredoc is refused"
run_at "python3 - <<'EOF'
import runpy
runpy.run_path('./quiet.py')
EOF" "$IP"
allowed "#3397 and of the quiet twin passes"
run_at "python3 <<'EOF'
exec(open('./posts.py').read())
EOF" "$IP"
read_refused "#3397 exec of open(...).read() in code fed to python3 in a heredoc is refused"
run_at "python3 <<'EOF'
exec(open('./quiet.py').read())
EOF" "$IP"
allowed "#3397 and of the quiet twin passes"
run_at "python3 - <<EOF
import runpy
runpy.run_path('\$HOME/quiet.py')
EOF" "$IP"
read_refused "#3397 a path the shell fills in inside a heredoc it expands is not worked out, and is refused"
says "#3397 and that refusal says the path cannot be worked out" "cannot work out"

echo "slack drafts only: a path the gate cannot work out is a file it never read, refused as unread (claude-config#3397)"

for code in "import runpy; runpy.run_path(input())" \
  "import glob, runpy; runpy.run_path(glob.glob('q*.py')[0])" \
  "import os; exec(open(os.environ['NOT_SET_HERE']).read())" \
  "import glob
for f in glob.glob('q*.py'):
    exec(open(f).read())" \
  "import importlib.util, json; s = importlib.util.spec_from_file_location('m', json.load(open('data.json'))['a'])"; do
  ip_code "$code"
  read_refused "#3397 a file run by a path the gate cannot work out is refused: ${code:0:60}"
  says "#3397 and the refusal says so: ${code:0:60}" "cannot work out"
done
# A file handed in the words after the code is read as it was before, by those words.
run_at "python3 -c 'import runpy, sys; runpy.run_path(sys.argv[1])' quiet.py" "$IP"
allowed "#3397 runpy.run_path of sys.argv[1], handed a quiet file, passes as before"
run_at "python3 -c 'import runpy, sys; runpy.run_path(sys.argv[1])' posts.py" "$IP"
read_refused "#3397 and handed the file that posts is refused as before"
run_at "python3 -c 'import sys
for f in sys.argv[1:]:
    exec(open(f).read())' quiet.py qnoext" "$IP"
allowed "#3397 exec of each file in sys.argv, handed quiet files, passes as before"
run_at "python3 -c 'import sys; p = sys.argv[1]; exec(open(p).read())' quiet.py" "$IP"
allowed "#3397 exec of a file whose path a name took from sys.argv, handed a quiet file, passes as before"

echo "slack drafts only: code that only reads a file as data is not read as running it (claude-config#3397)"

for code in "print(open('./posts.py').read())" \
  "print(len(open('posts.py').readlines()))" \
  "import json; print(json.load(open('./named.json')))" \
  "import json, sys; d = json.load(open('named.json')); print(sorted(d))" \
  "import pathlib; print(len(pathlib.Path('posts.py').read_text()))" \
  "import re; print(re.findall('url', open('posts.py').read()))" \
  "import os; print(os.path.getsize('posts.py'), os.path.exists('./named.json'))"; do
  ip_code "$code"
  allowed "#3397 code that only reads a file as data passes: ${code:0:60}"
done
run_at "python3 - <<'EOF'
import json
with open('named.json') as f:
    print(json.load(f))
EOF" "$IP"
allowed "#3397 a heredoc that only reads a file as data passes"
ip_code "exec('print(1)')"
allowed "#3397 exec of text written in the code itself, naming no file, passes"
ip_code "import subprocess; print(subprocess.run(['git', 'status'], capture_output=True).stdout)"
allowed "#3397 a program started with words that name no file and no program the gate reads passes"
ip_code "import subprocess, json; print(json.load(open('./data.json')))"
allowed "#3397 code that can run code, naming a data file that names no endpoint, passes"
# Where the code can run code, the gate cannot tell a file it only reads from one it runs, and it
# falls toward refusing: the file is read as one the code may run.
ip_code "import subprocess, json; print(json.load(open('./named.json')))"
read_refused "#3397 code that can run code, naming a data file that names an endpoint, is refused"
ip_code "import subprocess; print(open('./posts.py').read())"
read_refused "#3397 code that can run code, printing a file that posts, is refused: the two cannot be told apart"

echo "slack drafts only: a judgement kept in the cache does not outlive the file it read (claude-config#3397)"

printf '%s\n' 'print(1)' > "$IP/later/job.py"
ip_code "import runpy; runpy.run_path('job.py')" "$IP/later"
allowed "#3397 a file that does not post yet passes"
cp "$IP/posts.py" "$IP/later/job.py"
ip_code "import runpy; runpy.run_path('job.py')" "$IP/later"
read_refused "#3397 and once it posts the same call is refused, not served from the cache"
ip_code "import runpy; runpy.run_path('soon.py')" "$IP/later"
allowed "#3397 a path naming no file yet passes"
cp "$IP/posts.py" "$IP/later/soon.py"
ip_code "import runpy; runpy.run_path('soon.py')" "$IP/later"
read_refused "#3397 and once a file that posts is there the same call is refused, not served from the cache"

echo "slack drafts only: the same code in a script on disk (claude-config#3397)"

# A file that posts is found there too; a path that cannot be worked out is left as it was there,
# as a file a script runs through a variable is (#2683).
printf '%s\n' "python3 -c \"import runpy; runpy.run_path('./posts.py')\"" > "$IP/wrap.sh"
printf '%s\n' "python3 -c \"import runpy; runpy.run_path('./quiet.py')\"" > "$IP/wrapq.sh"
printf '%s\n' "python3 -c \"import runpy; runpy.run_path(input())\"" > "$IP/wrapu.sh"
run_at "bash wrap.sh" "$IP"
read_refused "#3397 a script on disk whose inline Python runs a file that posts is refused"
run_at "bash wrapq.sh" "$IP"
allowed "#3397 and one whose inline Python runs the quiet twin passes"
run_at "bash wrapu.sh" "$IP"
allowed "#3397 and one whose inline Python runs a path that cannot be worked out is left as it was"

echo "slack drafts only: the ways that were read before this rule still are (claude-config#3397)"

for runs in "python3 - < posts.py" "python3 < posts.py" "cat posts.py | python3" "python3 -m posts" \
  "python3 -m pkg" "cd / && PYTHONPATH=$IP python3 -m posts" \
  "python3 -c 'import posts'" "python3 -c 'import sys; sys.path.insert(0, \"sub\"); import deep'"; do
  run_at "$runs" "$IP"
  read_refused "#3397 read before this rule, and still refused: $runs"
done
for runs in "python3 - < quiet.py" "python3 < quiet.py" "cat quiet.py | python3" "python3 -m quiet" \
  "python3 -m qpkg" "python3 -c 'import quiet'"; do
  run_at "$runs" "$IP"
  allowed "#3397 and its quiet twin still passes: $runs"
done

echo

echo "passed: $pass, failed: $fail"

printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"

[ "$fail" -eq 0 ]
