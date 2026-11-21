#!/usr/bin/env bash
# Tests for how the Slack drafts gate reads the import statements of Python text this python3 cannot
# parse as a whole (claude-config#3278). Kept apart from test-slack-drafts-only-gate.sh and
# test-slack-drafts-code-loaders.sh so neither grows past its wall clock; the helpers below are
# copied from test-slack-drafts-unread-shapes.sh as they are, so a case here is driven the same way:
# a hook payload piped into slack-drafts-only-gate.sh, exit 0 allowed and 2 refused, the reason on
# stderr. Nothing a case names is ever run.
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
run_bash() { run_raw "$(payload Bash "$(bash_input "$1")")"; }

refused() { if [ "$RC" -eq 2 ]; then check "$1" ok; else check "$1" "exit $RC, stdout: ${OUT:0:200}, stderr: ${ERR:0:300}"; fi; }
allowed() { if [ "$RC" -eq 0 ] && [ -z "$(printf '%s%s' "$OUT" "$ERR" | tr -d '[:space:]')" ]; then check "$1" ok
            else check "$1" "exit $RC, stdout: ${OUT:0:200}, stderr: ${ERR:0:300}"; fi; }
says() { case "$ERR" in *"$2"*) check "$1" ok ;; *) check "$1" "stderr did not say '$2': ${ERR:0:400}" ;; esac; }
lacks() { case "$ERR" in *"$2"*) check "$1" "stderr said '$2': ${ERR:0:400}" ;; *) check "$1" ok ;; esac; }

# One folder: a helper that only saves a draft, a helper that posts, and the scripts beside them.
I="$T/imp"
mkdir -p "$I/pkg"
printf '%s\n' 'from pathlib import Path' 'def save(text):' '    Path("drafts/out.md").write_text(text)' > "$I/helper_ok.py"
printf '%s\n' 'import json, urllib.request' 'def save(text):' \
  '    urllib.request.urlopen("https://slack.com/api/chat.postMessage", data=json.dumps({"text": text}).encode())' > "$I/helper_posts.py"
: > "$I/pkg/__init__.py"
cp "$I/helper_posts.py" "$I/pkg/poster.py"
run_i() { run_raw "$(payload Bash "$(bash_input "$1")" "$I")"; }
# inline <python text>: the text handed to python3 in double quotes, as a session types it. Every
# text below holds a shell variable ($start), which the shell fills in before python sees it, so the
# text as written is not Python and this python3 cannot parse it as a whole.
inline() { run_i "python3 -c \"$1\""; }
# in_script <name> <python text>: the same call as the one command of a shell script, run by bash.
in_script() { printf '%s\n' '#!/bin/bash' 'start="$1"' "python3 -c \"$2\"" > "$I/$1.sh"; run_i "bash $I/$1.sh"; }
# in_file <name> <python text>: the text as a file of its own, run by python3.
in_file() { printf '%s\n' "$2" > "$I/$1.py"; run_i "python3 $I/$1.py"; }
NOT_FOUND="a module the gate cannot find"
TAIL='sys.stdout.write(str(time.time() - $start))'

echo "slack drafts python imports: a list of modules followed by a semicolon names its modules (claude-config#3278)"

# The command that was refused on 2026-11-18: a one line timing helper in a measurement script. The
# list was cut at its commas and each piece's first word taken, so the last module was `sys;`.
inline "import time,sys; $TAIL"
allowed "#3278 import a,b; in code given inline names a and b"
in_script timing "import time,sys; $TAIL"
allowed "#3278 import a,b; in a script's python3 -c names a and b"
in_file timing "import time,sys; $TAIL"
allowed "#3278 import a,b; in a file run by python3 names a and b"
inline "import time, sys ; $TAIL"
allowed "#3278 import a, b ; in code given inline names a and b"
in_script spaced "import time, sys ; $TAIL"
allowed "#3278 import a, b ; in a script's python3 -c names a and b"
in_file spaced "import time, sys ; $TAIL"
allowed "#3278 import a, b ; in a file run by python3 names a and b"
inline "import time; $TAIL"
allowed "#3278 one module and a semicolon names that module"
inline "from time import time; sys.stdout.write(str(time() - \$start))"
allowed "#3278 from a import b; names a"

# Each module of such a list is followed, so a helper beside the script is judged, never assumed.
for how in inline "in_script helper" "in_file helper"; do
  $how "import helper_ok,sys; helper_ok.save(\$start)"
  allowed "#3278 a list holding a helper that only saves a draft: ${how%% *}"
  $how "import helper_posts,sys; helper_posts.save(\$start)"
  refused "#3278 the same list holding a helper that posts: ${how%% *}"
  says "#3278 and the refusal names the helper: ${how%% *}" "helper_posts.py"
  $how "import sys,helper_posts; helper_posts.save(\$start)"
  refused "#3278 a helper that posts as the last module, before the semicolon: ${how%% *}"
  says "#3278 and the refusal names the helper: ${how%% *}" "helper_posts.py"
done

# The controls: an import that names nothing anywhere is still refused, by its own name.
for how in inline "in_script nowhere" "in_file nowhere"; do
  $how "import time,no_such_module_3278; $TAIL"
  refused "#3278 a list holding a module found nowhere is still refused: ${how%% *}"
  says "#3278 and the refusal names the module as written: ${how%% *}" "imports no_such_module_3278, $NOT_FOUND"
  lacks "#3278 with no semicolon in its name: ${how%% *}" "no_such_module_3278;"
done

echo "slack drafts python imports: every import statement of the line is read (claude-config#3278)"

# The statements after the semicolon are on the same line, so one that imports is read too: reading
# the list as Python does must not stop at the first statement's end.
inline "import sys; import helper_ok; helper_ok.save(\$start)"
allowed "#3278 a second import statement on the line, of a helper that only saves a draft"
inline "import sys; import helper_posts; helper_posts.save(\$start)"
refused "#3278 a second import statement on the line, of a helper that posts"
says "#3278 and the refusal names the helper" "helper_posts.py"
inline "import sys; x = 1; from helper_posts import save; save(\$start)"
refused "#3278 an import statement third on the line, of a helper that posts"
says "#3278 and the refusal names the helper" "helper_posts.py"
inline "import sys;import time;import helper_posts;helper_posts.save(\$start)"
refused "#3278 import statements with no space after each semicolon, the last a helper that posts"
says "#3278 and the refusal names the helper" "helper_posts.py"

echo "slack drafts python imports: the list is read as Python reads it (claude-config#3278)"

inline "import helper_ok as h, sys; h.save(\$start)"
allowed "#3278 import a as b, c; names a and c: a helper that only saves a draft"
inline "import helper_posts as h, sys; h.save(\$start)"
refused "#3278 import a as b, c; names a and c: a helper that posts"
says "#3278 and the refusal names the helper" "helper_posts.py"
inline "import sys, helper_posts as h; h.save(\$start)"
refused "#3278 import c, a as b; names c and a: a helper that posts"
says "#3278 and the refusal names the helper" "helper_posts.py"
inline "from helper_ok import (save, Path); save(\$start)"
allowed "#3278 from x import (a, b); names x: a helper that only saves a draft"
inline "from helper_posts import (save, json); save(\$start)"
refused "#3278 from x import (a, b); names x: a helper that posts"
says "#3278 and the refusal names the helper" "helper_posts.py"
in_file many "from helper_ok import (
    save,
    Path,
); save(\$start)"
allowed "#3278 from x import a list in brackets over several lines: a helper that only saves a draft"
in_file many "from helper_posts import (
    save,
    json,
); save(\$start)"
refused "#3278 from x import a list in brackets over several lines: a helper that posts"
says "#3278 and the refusal names the helper" "helper_posts.py"
# A relative import names its modules only in the list, so a list over several lines must be read
# to its end: the first line alone names nothing.
printf '%s\n' 'from . import (' '    poster,' ')' 'poster.save($start)' > "$I/pkg/run.py"
run_i "python3 $I/pkg/run.py"
refused "#3278 from . import a list in brackets over several lines, holding a module that posts"
says "#3278 and the refusal names the module" "poster.py"
# A package's module named last, before the semicolon, was read as `poster;` and never opened.
inline "from pkg import poster; poster.save(\$start)"
refused "#3278 from a package import a module that posts, then a semicolon"
says "#3278 and the refusal names the module" "poster.py"
printf '%s\n' 'import helper_ok, \' '    sys' 'helper_ok.save($start)' > "$I/continued.py"
run_i "python3 $I/continued.py"
allowed "#3278 a list carried onto a second line by a backslash: a helper that only saves a draft"
printf '%s\n' 'import sys, \' '    helper_posts' 'helper_posts.save($start)' > "$I/continued.py"
run_i "python3 $I/continued.py"
refused "#3278 a list carried onto a second line by a backslash: a helper that posts"
says "#3278 and the refusal names the helper" "helper_posts.py"
in_file commented "import helper_ok, sys  # two modules; no more
helper_ok.save(\$start)"
allowed "#3278 a comment after the list: a helper that only saves a draft"
in_file commented "import sys, helper_posts  # two modules; no more
helper_posts.save(\$start)"
refused "#3278 a comment after the list: a helper that posts"
says "#3278 and the refusal names the helper" "helper_posts.py"

echo "slack drafts python imports: a statement Python cannot read is read as it was (claude-config#3278)"

# Where Python's own tokenizer or parser cannot read the statement, the gate does not guess: the
# line is read as before, and a name it cannot place is refused.
inline "import \$mod, sys; $TAIL"
refused "#3278 a list holding a shell variable where a module belongs"
inline "import time,sys; s = 'never closed"
refused "#3278 a line whose string never closes"
inline "import time,sys; if \$start: import helper_posts"
refused "#3278 a line whose later statement is not one Python allows there and holds an import"
inline "import time,sys,; $TAIL"
refused "#3278 a list ending in a comma"
# A line that starts with import inside a string is still read, as before: the gate cannot tell
# what text Python cannot parse will do with it.
in_file quoted 's = """
import helper_posts
"""
x = $start'
refused "#3278 an import line inside a string of text Python cannot parse is still read"
says "#3278 and the refusal names the helper" "helper_posts.py"

echo "slack drafts python imports: line ends and long files (claude-config#3278)"

# Lines ended as Windows ends them are read the same way.
printf 'import time,sys; x = $start\r\nimport helper_ok,sys; y = $start\r\n' > "$I/crlf.py"
run_i "python3 $I/crlf.py"
allowed "#3278 lines ended by a return and a newline: a helper that only saves a draft"
printf 'import time,sys; x = $start\r\nimport helper_posts,sys; y = $start\r\n' > "$I/crlf.py"
run_i "python3 $I/crlf.py"
refused "#3278 lines ended by a return and a newline: a helper that posts"
says "#3278 and the refusal names the helper" "helper_posts.py"
# A long file is read to its end: 3,000 such lines, the helper named on the last. This is no guard
# on the cost of the reading, which was measured by hand once (2026-11-21, this suite's wall clock
# with 30,000 lines against 3,000, one reading each, under load: 0.8 seconds more, about 30
# millionths of a second a line).
awk 'BEGIN { for (i = 0; i < 3000; i++) print "import time,sys; x" i " = $start  # " i; print "import sys,helper_posts; y = $start" }' > "$I/long.py"
run_i "python3 $I/long.py"
refused "#3278 a file of 3,000 import lines is read to its end: the helper that posts is on the last"
says "#3278 and the refusal names the helper, not the time it ran out of" "helper_posts.py"

echo

echo "passed: $pass, failed: $fail"

printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"

[ "$fail" -eq 0 ]
