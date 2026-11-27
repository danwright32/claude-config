#!/usr/bin/env bash
# The close this session card's look for a process a command left behind, run against real
# processes (claude-config#3770).
#
# The look is the Python in PROCESS_LOOK (payload/mods/goal-box/hooks/close.ts). The goal box's own
# suite stands in for it, which is how the first version shipped a look that counted the session's
# own connected servers as left behind: they carry the session's id for as long as the session is
# open, and no test held a process that was still attached. This suite starts real processes
# carrying a made up id and runs the look itself:
#
#   attached      a child of this shell, as a connected server is a child of the session's process.
#                 The look is a child of this shell too, so the child's parents lead to a process the
#                 look descends from: not left behind.
#   reparented    a child whose parent has exited, so launchd (pid 1) is its parent: left behind.
#   unreadable    a carrier whose parent's row is taken out of the process list handed to the look:
#                 its parents can be followed neither to the look's own line nor to launchd, so the
#                 look says it could not tell, and never that it is attached.
#   another id    a process carrying a different id is in no list.
#   own line      the look started by a shell younger than the process list still finds the line of
#                 parents it descends from, reading the kernel's record where the list has no row.
#
# Processes are told apart by pid and parent pid as ps reads them, never by a command's text. The
# look reads a process's environment through the kernel as macOS has it, so anywhere else the suite
# says UNMEASURED and why. Every helper process ends by itself within 45 seconds and is stopped by
# its own pid when the suite ends. Seen to fail against the look as first shipped (L1).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
. "$ROOT/payload/hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?
pass=0
fail=0
unmeasured() { echo "SUITE-PART-UNMEASURED $1"; printf 'SUITE-RESULT passed=%d failed=%d\n' "$pass" "$fail"; [ "$fail" -eq 0 ]; exit $?; }

[ "$(uname)" = Darwin ] || unmeasured "the look reads a process's environment through the macOS kernel, so real processes are measured on macOS only"
command -v python3 >/dev/null 2>&1 || unmeasured "the look is run with python3, which this machine lacks"

tmp="$(mktemp -d)"
stop_helpers() {
  local f pid
  for f in "$tmp"/*.pid; do
    [ -f "$f" ] || continue
    for pid in $(cat "$f"); do
      case "$pid" in '' | *[!0-9]*) continue ;; esac
      kill "$pid" 2>/dev/null
    done
  done
  # Reaped here, so the shell does not print a line for each helper it stopped.
  wait 2>/dev/null
  rm -rf "$tmp"
}
trap stop_helpers EXIT

# The look's own text, read out of close.ts as the template literal holds it.
python3 -I - "$ROOT/payload/mods/goal-box/hooks/close.ts" > "$tmp/look.py" <<'PY'
import re, sys
m = re.search(r'^export const PROCESS_LOOK = `\n(.*?)^`$', open(sys.argv[1]).read(), re.M | re.S)
if not m:
    sys.exit('PROCESS_LOOK is not a plain template literal in close.ts, so the look cannot be read')
src = m.group(1)
if '${' in src:
    sys.exit('PROCESS_LOOK interpolates a value, so the look cannot be read as text')
sys.stdout.write(src.replace('\\\\', '\\'))
PY
if [ ! -s "$tmp/look.py" ]; then
  echo "FAIL: the look could not be read out of close.ts"
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
fi

ID="close-look-$$-$RANDOM"
OTHER="$ID-other"
BROKEN="$ID-broken"
CARRIER='import os, sys, time
open(sys.argv[1], "w").write(str(os.getpid()))
time.sleep(45)'
WRAPPER='import os, subprocess, sys, time
child = subprocess.Popen([sys.executable, "-I", "-c", "import time; time.sleep(45)"])
open(sys.argv[1], "w").write("%d %d" % (os.getpid(), child.pid))
time.sleep(45)'

# $1 = the file a helper writes its pid to -> waits, bounded, until it is written.
written() {
  local n=0
  while [ ! -s "$1" ] && [ "$n" -lt 100 ]; do sleep 0.1; n=$((n + 1)); done
  [ -s "$1" ]
}
# $1 = pid -> its parent's pid as ps reads it now.
parent_of() { ps -o ppid= -p "$1" 2>/dev/null | tr -d ' '; }

CLAUDE_CODE_SESSION_ID="$ID" python3 -I -c "$CARRIER" "$tmp/attached.pid" &
CLAUDE_CODE_SESSION_ID="$OTHER" python3 -I -c "$CARRIER" "$tmp/other.pid" &
# Started by a subshell that exits at once, so launchd takes it.
(CLAUDE_CODE_SESSION_ID="$ID" python3 -I -c "$CARRIER" "$tmp/orphan.pid" &)
CLAUDE_CODE_SESSION_ID="$BROKEN" python3 -I -c "$WRAPPER" "$tmp/wrapper.pid" &
ready=1
for f in attached other orphan wrapper; do written "$tmp/$f.pid" || ready=0; done
if [ "$ready" -ne 1 ]; then
  echo "FAIL: a helper process did not start within 10 seconds, so nothing was measured"
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
fi
attached="$(cat "$tmp/attached.pid")"
other="$(cat "$tmp/other.pid")"
orphan="$(cat "$tmp/orphan.pid")"
read -r wrapper inner < "$tmp/wrapper.pid"
n=0
while [ "$(parent_of "$orphan")" != 1 ] && [ "$n" -lt 50 ]; do sleep 0.1; n=$((n + 1)); done

# The fixture is what it claims to be, read from ps, before the look is asked anything.
if [ "$(parent_of "$attached")" = "$$" ] && [ "$(parent_of "$orphan")" = 1 ] && [ "$(parent_of "$inner")" = "$wrapper" ] && [ "$(parent_of "$wrapper")" = "$$" ]; then
  pass=$((pass + 1)); echo "PASS: the helpers are placed as the cases need: one a child of this shell, one whose parent is launchd, one behind a wrapper"
else
  fail=$((fail + 1)); echo "FAIL: the helpers are not placed as the cases need (attached's parent $(parent_of "$attached"), orphan's $(parent_of "$orphan"), inner's $(parent_of "$inner"), wrapper's $(parent_of "$wrapper"), this shell $$)"
fi

# $1 = the look's output, $2 = pids expected left behind, $3 = pids expected unread, $4 = how many
# attached, $5 = pids that must be in neither list -> "ok" or why not, one line.
judge() {
  python3 -I - "$1" "$2" "$3" "$4" "$5" <<'PY'
import json, sys
raw, left, unread, attached, absent = sys.argv[1:6]
try:
    o = json.loads(raw)
except ValueError:
    print('the look did not print JSON: ' + raw[:200].replace('\n', ' ')); sys.exit()
if not isinstance(o, dict):
    print('the look did not print an object'); sys.exit()
def ids(key):
    v = o.get(key)
    if not isinstance(v, list):
        return 'no list named ' + key
    return sorted(x.get('pid') for x in v if isinstance(x, dict))
want = lambda s: sorted(int(p) for p in s.split())
got = {'left behind': ids('found'), 'unread': ids('unread'), 'attached': o.get('attached', 'no count named attached')}
exp = {'left behind': want(left), 'unread': want(unread), 'attached': int(attached)}
if got != exp:
    print('expected %s, got %s' % (exp, got)); sys.exit()
named = set(got['left behind']) | set(got['unread'])
stray = [p for p in want(absent) if p in named]
if stray:
    print('pids %s were listed and must not be' % stray); sys.exit()
print('ok')
PY
}
check() {   # $1 = what it shows, then judge's arguments
  local what="$1" got
  shift
  got="$(judge "$@")"
  if [ "$got" = ok ]; then
    pass=$((pass + 1)); echo "PASS: $what"
  else
    fail=$((fail + 1)); echo "FAIL: $what ($got)"
  fi
}

# The look as the goal box runs it: handed the id, and the process list on its standard input. It is
# started by this shell itself, as the session's own process starts it, and never inside a command
# substitution, whose own process would stand between the two.
LOOK="$(cat "$tmp/look.py")"
ps -x -o pid=,ppid=,comm= > "$tmp/list.txt"
python3 -I -c "$LOOK" "$ID" < "$tmp/list.txt" > "$tmp/out.txt" 2>&1
out="$(cat "$tmp/out.txt")"
check "attached: a process carrying the id whose parents lead to the look's own line is not left behind" "$out" "$orphan" "" 1 "$attached $other $inner $wrapper"
check "reparented: a process carrying the id whose parent is launchd is left behind, and it alone" "$out" "$orphan" "" 1 "$attached"

# A carrier behind a wrapper, with the whole list: attached. This is the control for the next case.
python3 -I -c "$LOOK" "$BROKEN" < "$tmp/list.txt" > "$tmp/out.txt" 2>&1
check "control: handed the whole process list, a carrier behind a wrapper is attached" "$(cat "$tmp/out.txt")" "" "" 2 ""
# The wrapper's row taken out: the inner carrier's parents cannot be followed.
awk -v w="$wrapper" '$1 != w' "$tmp/list.txt" > "$tmp/cut.txt"
python3 -I -c "$LOOK" "$BROKEN" < "$tmp/cut.txt" > "$tmp/out.txt" 2>&1
out="$(cat "$tmp/out.txt")"
check "unreadable: a carrier whose parent is not in the process list is said to be unread, never attached and never dropped" "$out" "" "$inner" 0 ""
case "$out" in
  *"$wrapper"*) pass=$((pass + 1)); echo "PASS: the unread carrier's reason names the parent that could not be followed, by its pid" ;;
  *) fail=$((fail + 1)); echo "FAIL: the unread carrier's reason does not name parent $wrapper (got: $out)" ;;
esac
# The look started by a shell that did not exist when the list was taken, so its own parent is not
# in the list: it reads that parent's parent from the kernel and still finds the line it descends
# from, so the carriers are attached as in the control, never unread and never left behind.
bash -c 'python3 -I -c "$1" "$2" < "$3" > "$4" 2>&1; :' _ "$LOOK" "$BROKEN" "$tmp/list.txt" "$tmp/out.txt"
check "the look's own line: started by a process younger than the list, it still finds the line it descends from" "$(cat "$tmp/out.txt")" "" "" 2 ""

# An id nothing carries finds nothing.
python3 -I -c "$LOOK" "$ID-nobody" < "$tmp/list.txt" > "$tmp/out.txt" 2>&1
check "an id no process carries: nothing left behind, nothing unread, nothing attached" "$(cat "$tmp/out.txt")" "" "" 0 "$attached $orphan $other"

printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
