#!/usr/bin/env bash
# A whole tree scan: a send touching these paths runs this suite (claude-config#809).
# send-gate: scans skills/ hooks/lib/skill-audit.py
# No skill helper reports success when it failed (claude-config#677).
#
# reel-plan's push_to_notes.py never read the exit status of the osascript that applies the tick
# boxes, so an AppleScript that failed with nothing on stdout printed "wrote note" and exited 0.
# plan-council's post-discussion.sh filed its fallback issue with no priority, no category and, when
# the plan's milestone did not exist yet, no milestone: the issue field gate only sees commands typed
# in a session, so a script's own `gh issue create` goes straight past it.
#
# Each was fixed with a test of its own failure path. This suite is what catches the NEXT one: it
# runs `skill-audit.py exits` over every helper in every skill, found on disk, and refuses the three
# shapes those defects took (see the scanner's docstring). Every rule is first seen to fire on a
# fixture built to break it, and seen NOT to fire on the corrected form of the same fixture, so the
# rule is neither blind nor a blanket (L1, L104).
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUDIT="$DIR/lib/skill-audit.py"
ROOT="$(bash "$DIR/lib/checkout-root.sh" "$DIR/.." 2>/dev/null || true)"
SKILLS="$ROOT/payload/skills"
# The repository's skills, never an installed ~/.claude/skills: that folder also holds skills no send
# carries (the Claude app's own downloads, plugin skills), which this suite has no say over (L36).
# An installed copy says so in the shape the runner reads as NOT RUN, and the runner re-runs it from
# the checkout (claude-config#155, #237).
if [ -z "$ROOT" ] || [ ! -d "$SKILLS" ]; then
  printf 'SUITE-NOT-RUN %s\n' "reads the repository's payload/skills, and $DIR is not in a claude-config checkout"
  exit 2
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "FAIL: python3 is not on PATH, so no skill helper could be checked. Refusing to report them as sound."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
fi

pass=0
fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/    /' | awk 'NR <= 40'; return 0; }
has() { grep -qF -- "$2" <<< "$1"; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/skill-exits.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
S="$TMP/skills/fixture"
mkdir -p "$S"

scan() { out="$(python3 "$AUDIT" exits "$TMP/skills" 2>&1)"; rc=$?; }
# fires <rule> <line> <what>: the scan fails and names that rule at that line of the fixture file
fires() { has "$out" "$FILE:$2: $1" && ok || bad "$3 ($1 at line $2)" "$out"; }
quiet() { has "$out" "$FILE:" && bad "$1" "$out" || ok; }

# --- P1: a process whose exit status nobody reads -----------------------------------------------
FILE="fixture/helper.py"
cat > "$S/helper.py" <<'PY'
import os
import subprocess
from subprocess import run as sh


def _osascript(script):
    return subprocess.run(["osascript", "-e", script], capture_output=True, text=True)


def apply(title):
    return _osascript(title)


def main():
    r = apply("a")
    if r.returncode != 0:
        return 1
    r = apply("b")
    print(r.stdout)
    subprocess.run(["true"])
    sh(["true"])
    os.system("true")
    out = subprocess.run(["true"], capture_output=True).stdout
    p = subprocess.Popen(["true"])
    try:
        int("x")
    except Exception:
        pass
    for line in []:
        try:
            int(line)
        except:
            continue
    try:
        int("y")
    except (ValueError, BaseException):
        ...
    q = subprocess.Popen(["true"])
    out, err = q.communicate()
    with subprocess.Popen(["true"]) as w:
        pass
    return 0
PY
scan
[ "$rc" -eq 1 ] && ok || bad "a helper with every defect fails the scan (rc=$rc)" "$out"
fires P1 18 "a result reassigned after its status was read is checked again, and this one is not"
fires P1 20 "a bare subprocess.run drops its status"
fires P1 21 "an imported alias of run is followed"
fires P1 22 "a bare os.system drops its status"
fires P1 23 "a result whose stdout is read and status is not"
fires P1 24 "a Popen nobody waits on"
fires P2 27 "except Exception: pass"
fires P2 32 "a bare except: continue"
fires P2 36 "a tuple holding BaseException, with an ellipsis body"
fires P1 38 "a Popen whose output is read by communicate() and whose status is not"
fires P1 40 "a Popen opened in a with whose status is never read"
has "$out" "$FILE:15:" && bad "the first apply() IS checked on the next line, so it is not flagged" "$out" || ok
has "$out" "$FILE:7:" && bad "a function returning the process result defers to its callers" "$out" || ok

# The corrected form of every line above passes.
cat > "$S/helper.py" <<'PY'
import json
import os
import subprocess
from subprocess import run as sh


def _osascript(script):
    return subprocess.run(["osascript", "-e", script], capture_output=True, text=True)


def apply(title):
    return _osascript(title)


def main():
    r = apply("a")
    if r.returncode != 0:
        return 1
    r = apply("b")
    if r.returncode != 0 or r.stdout.strip() != "applied":
        return 1
    subprocess.run(["true"], check=True)
    sh(["true"], check=True)
    if os.system("true") != 0:
        return 1
    done = subprocess.run(["true"], capture_output=True)
    done.check_returncode()
    status = subprocess.call(["true"])
    p = subprocess.Popen(["true"])
    if p.wait() != 0:
        return status
    with subprocess.Popen(["true"]) as w:
        if w.wait() != 0:
            return 1
    try:
        json.loads("x")
    except json.JSONDecodeError:
        pass
    try:
        int("y")
    except Exception as exc:
        print(f"could not: {exc}")
        raise
    return subprocess.check_call(["true"])
PY
scan
[ "$rc" -eq 0 ] && ok || bad "the corrected helper passes the scan (rc=$rc)" "$out"
quiet "no line of the corrected helper is flagged"
rm -f "$S/helper.py"

# --- P1 across methods: a long lived process must have its ENDING read (#3650) ----------------
# A process held on an attribute outlives the method that started it, so a poll() made right after
# it starts says nothing about how it ended. The check follows the attribute through every method of
# the class (directly, through a local taken from it, and into a method or function of the same file
# it is handed to), and a read in the starting method counts only when it waits for the end. A local
# process checked only by poll() and then used again has had only its start checked. Where the
# process is handed to something the check cannot follow, it says so (U1) rather than passing quietly.
FILE="fixture/monitor.py"
cat > "$S/monitor.py" <<'PY'
import subprocess
from shutil import which as stop_group


class EndsRead:
    def start(self):
        self.p = subprocess.Popen(["sleep", "9"])

    def stop(self):
        status = self.p.wait(timeout=5)
        return status == 0


class EndsReadThroughAlias:
    def start(self):
        proc = subprocess.Popen(["cat"], stdin=subprocess.PIPE)
        self.beat = proc
        if proc.poll() is not None:
            raise RuntimeError("ended at once")

    def end(self):
        proc, self.beat = self.beat, None
        if proc is not None:
            proc.stdin.close()
            if proc.wait(timeout=5) != 0:
                raise RuntimeError("ended badly")


class EndsReadByAHelper:
    def start(self):
        self.q = subprocess.Popen(["sleep", "9"])

    def end(self):
        proc = self.q
        return self._exit(proc, 5)

    def _exit(self, proc, within):
        return proc.wait(timeout=within)


class EndsReadAsState:
    def start(self):
        self.r = subprocess.Popen(["sleep", "9"])

    def state(self):
        if self.r.poll() is not None:
            return "exited %s" % self.r.returncode
        return ""


class EndsReadWhereItStarts:
    def run(self):
        self.s = subprocess.Popen(["true"])
        return self.s.wait()


class CheckedOnlyAtItsStart:
    def start(self):
        proc = subprocess.Popen(["cat"], stdin=subprocess.PIPE)
        self.beat = proc
        if proc.poll() is not None:
            raise RuntimeError("ended at once")

    def end(self):
        self.beat.stdin.close()


class NeverRead:
    def start(self):
        self.e = subprocess.Popen(["sleep", "9"])

    def stop(self):
        self.e.terminate()


class StatusDropped:
    def start(self):
        self.f = subprocess.Popen(["sleep", "9"])
        self.g = subprocess.Popen(["sleep", "9"])

    def stop(self):
        self.f.wait()

    def state(self):
        return self.g.returncode


class HandedAway:
    def start(self):
        self.h = subprocess.Popen(["sleep", "9"])

    def stop(self):
        stop_group(self.h)


def polled_then_fed(lines):
    p = subprocess.Popen(["cat"], stdin=subprocess.PIPE)
    if p.poll() is not None:
        return 1
    for line in lines:
        p.stdin.write(line)
    p.stdin.close()
    return 0


def polled_then_handed(lines):
    p = subprocess.Popen(["cat"], stdin=subprocess.PIPE)
    if p.poll() is not None:
        return 1
    stop_group(p)
    return 0


def polled_in_a_loop():
    p = subprocess.Popen(["cat"], stdout=subprocess.PIPE)
    while p.poll() is None:
        p.stdout.readline()
    return 0


def polled_then_waited_by_a_helper():
    p = subprocess.Popen(["cat"], stdin=subprocess.PIPE)
    if p.poll() is not None:
        return 1
    p.stdin.close()
    return _finish(p)


def _finish(proc):
    return proc.wait(timeout=5)


def polled_then_waited():
    p = subprocess.Popen(["cat"], stdin=subprocess.PIPE)
    if p.poll() is not None:
        return 1
    p.stdin.close()
    return p.wait(timeout=5)


class Holder:
    pass


def held_elsewhere(holder):
    holder.proc = subprocess.Popen(["sleep", "9"])


class EndedWithoutAReadOnItsOwnPath:
    def start(self):
        proc = subprocess.Popen(["cat"], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        self.beat = proc
        if proc.poll() is not None:
            raise RuntimeError("ended at once")

    def one_beat(self):
        if not self.beat.stdout.readline():
            raise RuntimeError("it ended: %s" % self.beat.wait(timeout=1))

    def end(self):
        self.beat.stdin.close()


class EndedAndReapedByAnotherMethod:
    def start(self):
        self.t = subprocess.Popen(["sleep", "9"])

    def stop(self):
        self.t.terminate()
        return self._reap()

    def _reap(self):
        return self.t.wait(timeout=5)
PY
scan
[ "$rc" -eq 1 ] && ok || bad "#3650 a class whose processes' endings go unread fails the scan (rc=$rc)" "$out"
has "$out" "$FILE:7:" && bad "#3650 a process held on an attribute and waited on in another method passes" "$out" || ok
has "$out" "$FILE:16:" && bad "#3650 a process whose ending is read through a local taken from the attribute passes" "$out" || ok
has "$out" "$FILE:31:" && bad "#3650 a process handed to a method of its class that waits on it passes" "$out" || ok
has "$out" "$FILE:43:" && bad "#3650 a poll() whose result is used and a returncode after it, in another method, pass" "$out" || ok
has "$out" "$FILE:53:" && bad "#3650 a process waited on in the method that starts it passes" "$out" || ok
fires P1 59 "#3650 a process held on an attribute and checked only at its start"
has "$out" "$FILE:59: P1 proc = subprocess.Popen(...) is held on self.beat" && has "$out" "only asked whether it is still running, at line 61" && ok \
  || bad "#3650 #3663 the finding names the attribute and the start check it rests on" "$out"
fires P1 70 "#3650 a process held on an attribute that no method reads"
fires P1 78 "#3650 a wait() in another method whose result is dropped is no read"
fires P1 79 "#3650 a returncode read with nothing before it asking for the status is no read"
fires P1 90 "#3650 a process held on an attribute and handed to a call the check cannot follow"
has "$out" "$FILE:90:" && has "$out" "handed to stop_group(...) at line 93" && ok \
  || bad "#3650 the finding says which hand off it could not follow" "$out"
fires P1 97 "#3650 a local process checked only by poll() at its start and then used for longer"
fires U1 107 "#3650 a local process polled and then handed to a call the check cannot follow is reported as not judged"
fires P1 115 "#3663 a loop that only asks whether the process is still running never reads how it ended"
has "$out" "$FILE:122:" && bad "#3650 a local process handed to a function of the file that waits on it passes" "$out" || ok
has "$out" "$FILE:134:" && bad "#3650 a local process polled at its start and waited on at its end passes" "$out" || ok
fires P1 146 "#3650 a process held on another object's attribute is still a finding"
fires P1 151 "#3650 a process whose ending is read only on an error path, and not where the code ends it"
has "$out" "$FILE:151:" && has "$out" "EndedWithoutAReadOnItsOwnPath.end() ends it at line 161" && ok \
  || bad "#3650 the finding names the method that ends the process without reading it" "$out"
has "$out" "$FILE:166:" && bad "#3650 a process ended in one method and waited on by a method it calls passes" "$out" || ok
has "$out" "findings=9 unjudged=1" && ok || bad "#3650 #3663 exactly the nine findings and the one not judged" "$out"

# A process the check could not judge is said, and counted, but does not by itself fail the scan.
cat > "$S/monitor.py" <<'PY'
import subprocess
from shutil import which as stop_group


def polled_then_handed(lines):
    p = subprocess.Popen(["cat"], stdin=subprocess.PIPE)
    if p.poll() is not None:
        return 1
    stop_group(p)
    return 0
PY
scan
[ "$rc" -eq 0 ] && has "$out" "$FILE:6: U1" && has "$out" "findings=0 unjudged=1" && ok \
  || bad "#3650 a helper the check could only partly judge passes and says so (rc=$rc)" "$out"
rm -f "$S/monitor.py"

# --- the three blind spots #3650 left (#3663) -------------------------------------------------
# (a) A poll() whose result is only compared with None asks whether the process is still running,
#     never how it ended, whether it is written `while p.poll() is None`, `None is p.poll()`, or
#     through a name that is only ever compared with None.
# (b) Inside a method, both branches are followed: a method that ends a held process must read how
#     it ended on every path after the end, and the method that starts one settles it only when
#     every path out of it has waited for the end.
# (c) A hand off deeper than one level is not followed, and it is said: in a finding's words, or as
#     a U1 counted in the summary line when nothing else is found.
FILE="fixture/blind.py"
cat > "$S/blind.py" <<'PY'
import subprocess
import time


def waits_by_asking_if_running():
    p = subprocess.Popen(["sleep", "1"])
    while p.poll() is None:
        time.sleep(0.1)
    return 0


def asked_through_a_name():
    p = subprocess.Popen(["sleep", "1"])
    exited = p.poll()
    if exited is not None:
        return 1
    time.sleep(1)
    return 0


def asked_the_other_way_round():
    p = subprocess.Popen(["sleep", "1"])
    if None is p.poll():
        return 1
    return 0


def waits_by_asking_then_reads():
    p = subprocess.Popen(["sleep", "1"])
    while p.poll() is None:
        time.sleep(0.1)
    return p.returncode


def read_through_a_name():
    p = subprocess.Popen(["sleep", "1"])
    while True:
        rc = p.poll()
        if rc is not None:
            return rc
        time.sleep(0.1)


class AskedOnlyWhetherRunning:
    def start(self):
        self.p = subprocess.Popen(["sleep", "9"])

    def stop(self):
        if self.p.poll() is None:
            self.p.terminate()
            self.p.wait()


class ReadOnOneBranchOfItsEnd:
    def start(self):
        self.q = subprocess.Popen(["sleep", "9"])

    def stop(self, quick):
        self.q.terminate()
        if quick:
            return 0
        return self.q.wait(timeout=5)


class ReadBeforeItsEnd:
    def start(self):
        self.r = subprocess.Popen(["sleep", "9"])

    def stop(self):
        if self.r.poll() is not None:
            return self.r.returncode
        self.r.kill()


class WaitedOnOneBranchWhereItStarts:
    def run(self, block):
        self.s = subprocess.Popen(["sleep", "9"])
        if block:
            return self.s.wait()
        return None

    def pid(self):
        return self.s.pid


class ReadOnEveryBranchOfItsEnd:
    def start(self):
        self.t = subprocess.Popen(["sleep", "9"])

    def stop(self, quick):
        self.t.terminate()
        if quick:
            return self.t.wait(timeout=1)
        try:
            return self.t.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.t.kill()
            return self.t.wait()


class WaitedOnEveryBranchWhereItStarts:
    def run(self, block):
        if not block:
            return None
        self.u = subprocess.Popen(["sleep", "9"])
        if block > 1:
            return self.u.wait(timeout=1)
        return self.u.wait()


class EndedThroughTwoHelpers:
    def start(self):
        self.v = subprocess.Popen(["sleep", "9"])

    def stop(self):
        self.v.terminate()
        return self._settle(self.v)

    def _settle(self, proc):
        return self._reap(proc)

    def _reap(self, proc):
        return proc.wait(timeout=5)


def checked_then_handed_down():
    p = subprocess.Popen(["cat"], stdin=subprocess.PIPE)
    rc = p.poll()
    if rc is not None:
        return rc
    return _feed(p)


def _feed(proc):
    return _write(proc)


def _write(proc):
    proc.stdin.write(b"x")
    return 0
PY
scan
[ "$rc" -eq 1 ] && ok || bad "#3663 a helper with the three blind spots fails the scan (rc=$rc)" "$out"
fires P1 6 "#3663 (a) a loop asking only whether the process still runs never reads how it ended"
fires P1 13 "#3663 (a) a poll() result held in a name only compared with None is no read"
fires P1 22 "#3663 (a) None compared with poll() the other way round is no read"
has "$out" "$FILE:6:" && has "$out" "only asked whether it is still running" && ok \
  || bad "#3663 (a) the finding says the process was only asked whether it still runs" "$out"
has "$out" "$FILE:29:" && bad "#3663 (a) a loop that asks and then reads returncode passes" "$out" || ok
has "$out" "$FILE:36:" && bad "#3663 (a) a poll() result that is returned, not only compared with None, passes" "$out" || ok
fires P1 46 "#3663 (a) a method ending the process after asking only whether it runs reads nothing"
has "$out" "$FILE:46:" && has "$out" "AskedOnlyWhetherRunning.stop() ends it at line 50" && ok \
  || bad "#3663 (a) the finding names the method that ends it" "$out"
fires P1 56 "#3663 (b) a method ending the process reads how it ended on one branch only"
has "$out" "$FILE:56:" && has "$out" "ReadOnOneBranchOfItsEnd.stop() ends it at line 59" && ok \
  || bad "#3663 (b) the finding names the method and the end on the unread branch" "$out"
fires P1 67 "#3663 (b) a read made before the end, on another branch, is no read of the end"
fires P1 77 "#3663 (b) a process waited on only on one branch of the method that starts it"
has "$out" "$FILE:88:" && bad "#3663 (b) a method reading the end on every branch, its except included, passes" "$out" || ok
has "$out" "$FILE:105:" && bad "#3663 (b) a start method that waits on every path after the start passes" "$out" || ok
fires P1 113 "#3663 (c) a process ended and handed two levels down is not taken as read"
has "$out" "$FILE:113:" && has "$out" "which hands it on to self._reap(...) at line 120" && ok \
  || bad "#3663 (c) the finding says the hand off goes deeper than the check follows" "$out"
fires U1 127 "#3663 (c) a local process handed two levels down is counted as not judged"
has "$out" "$FILE:127:" && has "$out" "which hands it on to _write(...) at line 135" && ok \
  || bad "#3663 (c) the U1 names both hand offs" "$out"
has "$out" "findings=8 unjudged=1" && ok || bad "#3663 exactly the eight findings and the one not judged" "$out"
rm -f "$S/blind.py"

# --- S1: a script filing an issue the field gate never sees -------------------------------------
rm -f "$S/helper.py"
FILE="fixture/file-issue.sh"
cat > "$S/file-issue.sh" <<'SH'
#!/usr/bin/env bash
# gh issue create is named in this comment and is not a call
url="$(gh issue create --repo "$repo" --title "$t" --body "$b")"
gh issue create --repo "$repo" --title "$t" --milestone "$m"
gh issue create --repo "$repo" --title "$t" \
  --milestone "$m" \
  --label priority-p2 --label planning
gh issue create --repo "$repo" --title "$t" --milestone "$m" "${label_args[@]}"
if [ -n "$repo" ]; then
    gh issue create --repo "$repo" --title "$t"
fi
if ! gh issue create --repo "$repo" --title "$t"; then exit 1; fi
[ -n "$repo" ] && gh issue create --repo "$repo" --title "$t"
gh -R "$repo" issue create --title "$t"
env GH_TOKEN="$tok" gh issue --repo "$repo" create --title "$t"
echo "gh -R x issue create is quoted here and is not a call"
bash -c 'gh issue create --repo x --title t'
nohup gh issue create --repo x --title t
echo "bash -c 'gh issue create --title t' is quoted here and is not a call"
gh issue new --repo x --title t
SH
scan
[ "$rc" -eq 1 ] && ok || bad "a script filing issues without their fields fails the scan (rc=$rc)" "$out"
fires S1 3 "an issue with no milestone and no labels"
fires S1 4 "an issue with a milestone and no labels"
fires S1 10 "an indented call inside a block"
fires S1 12 "a call after if !"
fires S1 13 "a call after &&"
has "$out" "$FILE:2:" && bad "a comment naming the command is not a call" "$out" || ok
has "$out" "$FILE:5:" && bad "labels given on a continuation line count" "$out" || ok
has "$out" "$FILE:8:" && bad "labels passed through an array count" "$out" || ok
fires S1 14 "#1188 a call with -R in front of issue"
fires S1 15 "#1188 a call behind env with --repo between issue and create"
has "$out" "$FILE:16:" && bad "#1188 a quoted mention is not a call" "$out" || ok
fires S1 17 "#1478 a call a shell runs from its -c string"
fires S1 18 "#1478 a call through nohup"
has "$out" "$FILE:19:" && bad "#1478 a quoted mention of a wrapped call is not a call" "$out" || ok
fires S1 20 "#2411 gh issue new, gh's other name for create, read by the one reading of gh's words"
has "$out" "findings=10" && ok || bad "exactly the ten calls are flagged" "$out"

# The calls are read by lib/shell-words.py (#1188). Without it the scan cannot tell a call from a
# mention, so it says so as a finding of its own rather than passing the script, and the audit's
# other checks still load (the lessons review of #1188).
mkdir -p "$TMP/noreader"
python3 "$DIR/lib/install-hook-libs.py" "$DIR/lib" "$TMP/noreader" skill-audit.py \
  || bad "#2147 the hook helpers could not be installed into $TMP/noreader"
out="$(python3 "$TMP/noreader/skill-audit.py" exits "$TMP/skills" 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && has "$out" "could not be checked" && has "$out" "shell-words.py" && ok \
  || bad "#1188 a missing reader is a finding naming it, not a pass (rc=$rc)" "$out"
mkdir -p "$TMP/quiet/skills/plain"
printf '#!/usr/bin/env bash\necho hello\nls -la\n' > "$TMP/quiet/skills/plain/helper.sh"
out="$(python3 "$TMP/noreader/skill-audit.py" exits "$TMP/quiet/skills" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok || bad "#1188 a helper with no gh issue create is not reported for the missing reader (rc=$rc)" "$out"
out="$(python3 "$TMP/noreader/skill-audit.py" links "$TMP/none-such" 2>&1)"
has "$out" "Traceback" && bad "#1188 and the audit's other checks still run without it" "$out" || ok

# --- nothing to scan is not a pass -------------------------------------------------------------
mkdir -p "$TMP/none"
out="$(python3 "$AUDIT" exits "$TMP/none" 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && has "$out" "no skills" && ok || bad "a folder with no skills is refused (rc=$rc)" "$out"

# --- the real skills ---------------------------------------------------------------------------
out="$(python3 "$AUDIT" exits "$SKILLS" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then ok; else bad "no skill helper reports success on failure (rc=$rc)" "$out"; fi
grep '^EXITS ' <<< "$out"

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
