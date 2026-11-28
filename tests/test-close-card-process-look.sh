#!/usr/bin/env bash
# The close this session card's look for a process a command left behind, run against real
# processes (claude-config#3770).
#
# The look is the Python in PROCESS_LOOK (payload/mods/goal-box/hooks/close.ts). The goal box's own
# suite stands in for it, which is how the first version shipped a look that counted the session's
# own connected servers as left behind: they carry the session's id for as long as the session is
# open, and no test held a process that was still attached. Here one driver process stands where
# the session's own process does. It starts real processes carrying a made up id and runs the look
# itself as its child, handing it the process list as the goal box does:
#
#   attached      a child of the driver, as a connected server is a child of the session's process.
#                 The look is a child of the driver too, so the child's parents lead to a process
#                 the look descends from: not left behind.
#   reparented    a process whose parent has exited, so launchd (pid 1) is its parent: left behind.
#   unreadable    a carrier whose parent's row is taken out of the process list handed to the look:
#                 its parents can be followed neither to the look's own line nor to launchd, so the
#                 look says it could not tell, and never that it is attached.
#   another id    a process carrying a different id is in neither list.
#   own line      the look started through a shell younger than the process list still finds the
#                 line of parents it descends from, reading the kernel's record where the list has
#                 no row.
#   own line cut  the row of the driver's own parent is taken out of the list, so the look cannot
#                 follow its own line to launchd. A carrier it can still place on the part it did
#                 read is attached; the reparented one, whose own parents were followed to launchd,
#                 is handed back as one it could not tell apart (`unplaced`, with `own` saying why),
#                 never as unread and never as found.
#
# Before any real process is started, the look's own logic is run on planted worlds (the review of
# pull request 3826, 2026-11-27): a process list written out as text, with four spots of the look's
# text swapped for planted values (which pids carry the id, the look's own pid, its parent, the
# kernel's record), each swap checked to have happened exactly once. That is the only way to stand
# the look where the kernel's record of its own line is not trusted, which no real process can be
# made to do.
#
# Processes are told apart by pid and parent pid as ps reads them, never by a command's text. The
# look reads a process's environment through the kernel as macOS has it, so anywhere else the suite
# says UNMEASURED and why. The driver stops every helper by its own pid before it ends and reaps
# the ones that are its children; a helper it could not stop ends by itself after ten minutes, and
# a wait for a helper to be placed gives up after five, both numbers this suite sets. Seen to fail
# against the look as first shipped (L1).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
. "$ROOT/payload/hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?
unmeasured() { echo "SUITE-PART-UNMEASURED $1"; printf 'SUITE-RESULT passed=0 failed=0\n'; exit 0; }

[ "$(uname)" = Darwin ] || unmeasured "the look reads a process's environment through the macOS kernel, so it is run against real processes on macOS only"
command -v python3 >/dev/null 2>&1 || unmeasured "the look is run with python3, which this machine lacks"

# The driver: reads the look out of close.ts, places the helpers, runs each case, judges it, stops
# the helpers and prints one line per check and the suite's result. Its exit code is the suite's.
python3 -I - "$ROOT/payload/mods/goal-box/hooks/close.ts" "${SUITE_HANG_SECONDS:-300}" <<'PY'
import json, os, re, signal, subprocess, sys, time

passed = failed = 0


def check(what, problem):
    global passed, failed
    if problem:
        failed += 1
        print('FAIL: %s (%s)' % (what, problem))
    else:
        passed += 1
        print('PASS: ' + what)


def done():
    print('SUITE-RESULT passed=%d failed=%d' % (passed, failed))
    sys.stdout.flush()
    sys.exit(1 if failed else 0)


# The look's own text, as the template literal in close.ts holds it.
m = re.search(r'^export const PROCESS_LOOK = `\n(.*?)^`$', open(sys.argv[1]).read(), re.M | re.S)
if not m or '${' in m.group(1):
    check('the look can be read out of close.ts as plain text', 'PROCESS_LOOK is not a plain template literal there')
    done()
LOOK = m.group(1).replace('\\\\', '\\')
HANG = int(sys.argv[2]) if sys.argv[2].isdigit() else 300

ID = 'close-look-%d-%d' % (os.getpid(), int(time.time()))
SLEEPER = [sys.executable, '-I', '-c', 'import time; time.sleep(600)']
# A helper that outlives its starter is given no pipe of the starter's: one it inherited would keep
# the read of that pipe, and this suite's own output, open for as long as the helper lives (L235).
QUIET = 'stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL'
WRAPPER = 'import subprocess, sys, time\nprint(subprocess.Popen(sys.argv[1:], %s).pid, flush=True)\ntime.sleep(600)' % QUIET
STARTER = 'import subprocess, sys\nprint(subprocess.Popen(sys.argv[1:], %s).pid, flush=True)' % QUIET
quiet = dict(stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
carrying = lambda ident: dict(os.environ, CLAUDE_CODE_SESSION_ID=ident)
children = []
strangers = []


def process_list():
    return subprocess.run(['ps', '-x', '-o', 'pid=,ppid=,comm='], stdout=subprocess.PIPE, check=True).stdout


def parent_of(pid):
    out = subprocess.run(['ps', '-o', 'ppid=', '-p', str(pid)], stdout=subprocess.PIPE).stdout.split()
    return int(out[0]) if out else None


def look(ident, listing, through_shell=False):
    argv = [sys.executable, '-I', '-c', LOOK, ident]
    if through_shell:
        # The shell did not exist when the list was taken, and stays the look's parent.
        argv = ['/bin/sh', '-c', '"$@"; :', 'sh'] + argv
    r = subprocess.run(argv, input=listing, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    return r.stdout.decode('utf-8', 'replace')


def judged(raw, left, unread, attached, absent=(), unplaced=(), own=None):
    """None when the look's answer is the one expected, else what differs. `unplaced` are the
    carriers it could not tell apart because its own line failed, and `own` is text its reason for
    that must hold, or None when its own line must have been followed whole."""
    try:
        o = json.loads(raw)
    except ValueError:
        return 'the look did not print JSON: ' + raw[:300].replace('\n', ' ')
    if not isinstance(o, dict):
        return 'the look did not print an object'

    def ids(key):
        v = o.get(key)
        return sorted(x.get('pid') for x in v if isinstance(x, dict)) if isinstance(v, list) else 'no list named ' + key
    said = o.get('own', 'no field named own')
    own_as_expected = said is None if own is None else isinstance(said, str) and own in said
    got = {'left behind': ids('found'), 'unread': ids('unread'), 'could not be told apart': ids('unplaced'), 'attached': o.get('attached', 'no count named attached'), 'own line': 'as expected' if own_as_expected else said}
    exp = {'left behind': sorted(left), 'unread': sorted(unread), 'could not be told apart': sorted(unplaced), 'attached': attached, 'own line': 'as expected'}
    if got != exp:
        return 'expected %s (own line: %s), got %s' % (exp, 'followed whole' if own is None else 'a reason holding %r' % own, got)
    stray = [p for p in absent if p in got['left behind'] or p in got['unread'] or p in got['could not be told apart']]
    return 'pids %s were listed and must not be' % stray if stray else None


# The look's own logic on a planted world. Four spots of its text are swapped for planted values,
# each exactly once, so what is judged is the look's own following of parents.
SWAPS = [
    ('want not in env_of(pid)', 'pid not in CARRIERS'),
    ('me = os.getpid()', 'me = ME'),
    ('parent[me] = os.getppid()', 'parent[me] = MYPARENT'),
    ('def kernel_parent(pid):', 'def kernel_parent(pid):\n    return KERNEL.get(pid)\ndef real_kernel_parent(pid):'),
]


def planted(rows, carriers, me, myparent, kernel):
    src = LOOK
    for old, new in SWAPS:
        if src.count(old) != 1:
            return 'the look no longer holds exactly one %r, so it cannot be stood on a planted world' % old
        src = src.replace(old, new)
    head = 'CARRIERS = %r\nME = %r\nMYPARENT = %r\nKERNEL = %r\n' % (sorted(carriers), me, myparent, dict(kernel))
    r = subprocess.run([sys.executable, '-I', '-c', head + src, 'planted'], input=rows.encode(), stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    return r.stdout.decode('utf-8', 'replace')


# The planted world: 1 launchd; 100 Terminal; 110 login; 120 the shell; 200 the session's own
# process; 300 a connected server (carries the id, attached); 400 a node the session left behind
# (carries the id, parent launchd). The look is 900, a child of 200, and is not in the list.
BASE = """
  100     1 /Applications/Terminal
  110   100 login
  120   110 -zsh
  200   120 claude
  300   200 node
  400     1 node
"""
NO_LOGIN = BASE.replace('  110   100 login\n', '')
check('planted, control: with the whole list the one left behind is found and the connected server is attached',
      judged(planted(BASE, [300, 400], 900, 200, {900: 200}), [400], [], 1))
check("planted, the look's own line cut above the session's process (the review's T2): the process whose own parents lead to launchd is one it could not tell apart, never unread, and it says its own line failed",
      judged(planted(NO_LOGIN, [300, 400], 900, 200, {900: 200}), [], [], 1, unplaced=[400], own='process 110'))
check("planted, the look's own parent not in the list and the kernel's record not trusted (the review's T3): every carrier, the connected server included, is one it could not tell apart",
      judged(planted(BASE, [300, 400], 900, 850, {}), [], [], 0, unplaced=[300, 400], own='process 850'))
check("planted, a carrier whose own parent is not in the list, the look's own line whole: that carrier alone is unread, and the look does not say its own line failed",
      judged(planted(BASE + '  600   500 node\n', [300, 400, 600], 900, 200, {900: 200}), [400], [600], 1))
check("planted, a carrier whose parents loop back on themselves, the look's own line whole: that carrier alone is unread",
      judged(planted(BASE + '  700   710 node\n  710   700 node\n', [300, 400, 700], 900, 200, {900: 200}), [400], [700], 1))
check("planted, both at once: a carrier whose own parents could not be followed stays unread, and only the one the look's own line would have placed is one it could not tell apart",
      judged(planted(NO_LOGIN + '  600   500 node\n', [300, 400, 600], 900, 200, {900: 200}), [], [600], 1, unplaced=[400], own='process 110'))


try:
    # A child of this driver carrying the id, and one carrying another id.
    attached = subprocess.Popen(SLEEPER, env=carrying(ID), **quiet)
    other = subprocess.Popen(SLEEPER, env=carrying(ID + '-other'), **quiet)
    children += [attached, other]
    # A carrier behind a wrapper that is this driver's child, under an id of its own.
    wrapper = subprocess.Popen([sys.executable, '-I', '-c', WRAPPER] + SLEEPER, env=carrying(ID + '-broken'), stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    children.append(wrapper)
    inner = int(wrapper.stdout.readline())
    strangers.append(inner)
    # A carrier whose starter exits at once, so launchd takes it.
    started = subprocess.run([sys.executable, '-I', '-c', STARTER] + SLEEPER, env=carrying(ID), stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=True)
    orphan = int(started.stdout)
    strangers.append(orphan)
    t0 = time.monotonic()
    while parent_of(orphan) != 1 and time.monotonic() - t0 < HANG:
        time.sleep(0.1)

    # The fixture is what it claims to be, read from ps, before the look is asked anything.
    placed = {'attached': parent_of(attached.pid), 'other': parent_of(other.pid), 'wrapper': parent_of(wrapper.pid), 'inner': parent_of(inner), 'orphan': parent_of(orphan)}
    want = {'attached': os.getpid(), 'other': os.getpid(), 'wrapper': os.getpid(), 'inner': wrapper.pid, 'orphan': 1}
    check('the helpers are placed as the cases need: children of the driver, one behind a wrapper, one whose parent is launchd', None if placed == want else 'parents read %s, wanted %s' % (placed, want))
    if placed != want:
        done()

    listing = process_list()
    out = look(ID, listing)
    check("attached: a process carrying the id whose parents lead to the look's own line is not left behind", judged(out, [orphan], [], 1, [attached.pid, other.pid, inner, wrapper.pid]))
    check('reparented: a process carrying the id whose parent is launchd is left behind, and it alone', judged(out, [orphan], [], 1, [attached.pid]))
    check('another id: a child carrying a different id, one this id begins, is not counted as attached and is in neither list', judged(out, [orphan], [], 1, [other.pid]))

    # With the whole list a carrier behind a wrapper is attached: the control for the next case.
    check('control: handed the whole process list, a carrier behind a wrapper is attached', judged(look(ID + '-broken', listing), [], [], 2))
    # The wrapper's row taken out: the inner carrier's parents cannot be followed.
    cut = b'\n'.join(row for row in listing.split(b'\n') if row.split()[:1] != [str(wrapper.pid).encode()])
    out = look(ID + '-broken', cut)
    check('unreadable: a carrier whose parent is not in the process list is said to be unread, never attached and never dropped', judged(out, [], [inner], 0))
    check("the unread carrier's reason names the parent that could not be followed, by its pid", None if str(wrapper.pid) in out else 'parent %d is not named in %s' % (wrapper.pid, out[:300]))

    # Started through a shell that did not exist when the list was taken, the look's own parent is
    # not in the list: it reads that parent's parent from the kernel and still finds its line.
    check("the look's own line: started by a process younger than the list, it still finds the line it descends from", judged(look(ID + '-broken', listing, through_shell=True), [], [], 2))

    # The row of this driver's own parent taken out: the look's own line cannot be followed to
    # launchd. The child still meets the part that was read; the reparented one cannot be told apart.
    above = str(os.getppid()).encode()
    cut = b'\n'.join(row for row in listing.split(b'\n') if row.split()[:1] != [above])
    check("the look's own line cut: with the row of the driver's parent taken out, the reparented carrier is one it could not tell apart, the child is still attached, and it names the parent it could not follow",
          'the driver has no parent row to take out of the list' if cut == listing else judged(look(ID, cut), [], [], 1, [attached.pid, other.pid], unplaced=[orphan], own=above.decode()))

    check('an id no process carries: nothing left behind, nothing unread, nothing attached', judged(look(ID + '-nobody', listing), [], [], 0, [attached.pid, orphan, other.pid]))
finally:
    for p in children:
        p.kill()
    for p in children:
        p.wait()
    for pid in strangers:
        try:
            os.kill(pid, signal.SIGKILL)
        except OSError:
            pass
done()
PY
