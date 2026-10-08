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
ROOT="$(git -C "$DIR" rev-parse --show-toplevel 2>/dev/null || true)"
SKILLS="$ROOT/payload/skills"
# The repository's skills, never an installed ~/.claude/skills: that folder also holds skills no send
# carries (the Claude app's own downloads, plugin skills), which this suite has no say over (L36).
# An installed copy says so in the shape the runner reads as NOT RUN, and the runner re-runs it from
# the checkout (claude-config#155, #237).
if [ -z "$ROOT" ] || [ ! -d "$SKILLS" ]; then
  printf 'SUITE-NOT-RUN %s\n' "reads the repository's payload/skills, and there is no repository above $DIR"
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
has "$out" "findings=5" && ok || bad "exactly the five bare calls are flagged" "$out"

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
