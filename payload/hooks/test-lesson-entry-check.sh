#!/usr/bin/env bash
# Tests for the check that runs the moment a lesson is WRITTEN (claude-config#374).
#
# A lesson entry written into LESSONS.md in the wrong shape is invisible from the moment it is
# saved: absent from the generated lessons index, which loads into every session in every project, unreadable
# by `claude-sync lesson`, uncounted by the duplicate check and by the number minter. Nothing
# reported it. The only thing that noticed was the next sync, which can be days later, and by then
# the malformed entry had been holding the ENTIRE lessons file back from publishing, so every
# lesson written after it was stuck too.
#
# Measured 2026-09-11: L683 and L684, both written on this Mac, were each missing their bold
# marker. Neither had ever appeared in the index. A second fault (an entry too long for the index)
# then surfaced only after the first was fixed, because the cap check cannot see an entry the
# format check rejects.
#
# The predicates are NOT copied here. The hook runs `claude-sync lesson-faults`, which walks the
# same list the send walks, so the write time check and the gate cannot disagree about what a
# fault is (L41, L686).
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/lesson-entry-check.sh"
REPO="$(cd "$DIR/../.." && pwd)"
# WHERE THIS IS RUNNING. Two copies of these hooks exist: the repo's payload/hooks, which sits
# beside a claude-sync and a payload/, and the INSTALLED copy under the config root, which does
# not. This suite drives the real claude-sync, so in the installed copy it was measuring a tool
# that is not there and failing for that reason alone. Measured 2026-09-11, by the first
# `claude-sync recheck` that was able to finish.
#
# Said in the one agreed shape the runner reads, so it is reported as NOT RUN rather than as broken
# code, and never as a pass.
if [ ! -f "$REPO/claude-sync" ] || [ ! -d "$REPO/payload" ]; then
  echo "test-lesson-entry-check: $REPO is not a checkout of this repo (no claude-sync and payload/ in it), so the tool this suite drives is not there." >&2
  printf 'SUITE-NOT-RUN %s\n' "needs the repository above it, and $REPO is not one"
  echo "passed: 0, failed: 0"
  printf 'SUITE-RESULT passed=0 failed=0\n'
  exit 2
fi
SYNC="$REPO/claude-sync"

pass=0
fail=0
check() { # check <description> <result>   ("ok" passes, anything else is the failure text)
  if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi
}
# Both trim with parameter expansion rather than piping into `head`. Under pipefail a short
# circuiting consumer kills its producer and the pipeline reports a failure that never happened
# (L183), and this repo ratchets the count of such pipelines down rather than up.
says() { # says <description> <text> <substring>
  case "$2" in *"$3"*) check "$1" ok ;; *) check "$1" "did not say '$3' (said: ${2:0:200})" ;; esac
}
silent() { # silent <description> <text>
  if [ -z "$(printf '%s' "$2" | tr -d '[:space:]')" ]; then check "$1" ok; else check "$1" "it said: ${2:0:200}"; fi
}

[ -f "$HOOK" ] || { echo "FAIL: no hook at $HOOK"; echo "passed: 0, failed: 1"; printf 'SUITE-RESULT passed=0 failed=1\n'; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/claude-sync-work.lessonentry.XXXXXXXX")" || WORK=""
case "${WORK%/}" in
  ''|/|"${HOME%/}") echo "refusing to run: throwaway directory came back as '$WORK'" >&2; exit 2 ;;
esac
trap 'rm -rf "$WORK"' EXIT

HOME_FIX="$WORK/claude"; mkdir -p "$HOME_FIX/hooks"
printf 'ENTRY_CAP=80\n' > "$HOME_FIX/hooks/test-rule-file-budget.sh"
printf '# rules\n@LESSONS-INDEX.md\n' > "$HOME_FIX/CLAUDE.md"
REG="$WORK/clones"
printf '%s\n' "$REPO" > "$REG"

payload_for() { # payload_for <tool name> <file path>
  python3 -c '
import json, sys
print(json.dumps({"tool_name": sys.argv[1], "tool_input": {"file_path": sys.argv[2]}}))
' "$1" "$2"
}
run_hook() { # run_hook <tool name> <file path>
  payload_for "$1" "$2" | CLAUDE_HOME="$HOME_FIX" SYNC_CLONE_REGISTRY="$REG" bash "$HOOK" 2>&1
}

sound() { printf '# Lessons\n\n## Proof over green\n\n- **L1. a rule that fits.** body\n' > "$HOME_FIX/LESSONS.md"; }

echo "lesson entry check: a sound file is not spoken about"

sound
out="$(run_hook Edit "$HOME_FIX/LESSONS.md")"
silent "a lessons file with nothing wrong says nothing" "$out"

echo "lesson entry check: each fault is refused where it was written"

# The fault the issue was opened about: the bold marker left off. Nothing else in the system
# reports this until the next sync.
printf '# Lessons\n\n## Proof over green\n\n- **L1. a rule that fits.** body\n- L2. an entry with the bold left off.\n' > "$HOME_FIX/LESSONS.md"
out="$(run_hook Edit "$HOME_FIX/LESSONS.md")"
says "a malformed entry is refused" "$out" '"decision":"block"'
says "and the refusal names the entry" "$out" "L2"
says "and says what shape it should have been" "$out" '- **L'
says "and says the whole file cannot publish until it is fixed" "$out" "publish"

# The second fault, which the first one HIDES: an entry too long for the index.
_long="A rule long enough to render past the fixture cap of eighty characters but well inside the real one."
printf '# Lessons\n\n## Proof over green\n\n- **L1. a rule that fits.** body\n- **L2. %s** body\n' "$_long" > "$HOME_FIX/LESSONS.md"
out="$(run_hook Edit "$HOME_FIX/LESSONS.md")"
says "an entry too long for the index is refused" "$out" '"decision":"block"'
says "and it is told what to write" "$out" 'SHORT:'

# A duplicate number, which is the fault that spreads to the other Mac.
printf '# Lessons\n\n## Proof over green\n\n- **L1. a rule that fits.** body\n- **L1. claimed twice.** body\n' > "$HOME_FIX/LESSONS.md"
out="$(run_hook Edit "$HOME_FIX/LESSONS.md")"
says "a duplicate number is refused" "$out" "used 2 times"

# A short form that has drifted from its rule (claude-config#389). On 2026-09-17 L480's scored 0.38
# against the 0.40 floor, and the only thing that measured it was the CI run after the push, which
# turned main red and stopped both Macs receiving config. The fixture SWAPS two short forms, so
# every entry is still well formed and every rendered line still fits: only the meaning moved.
printf '# Lessons\n\n## Proof over green\n\n- **L1. A guard is only real once it has been seen to fail against a deliberate defect.** body\n  SHORT: A scheduled job reporting success on nothing found cannot be trusted.\n- **L2. A scheduled job that reports success when it found nothing is indistinguishable from one that saw every item pass.** body\n  SHORT: A guard is only real once seen to fail.\n' > "$HOME_FIX/LESSONS.md"
out="$(run_hook Edit "$HOME_FIX/LESSONS.md")"
says "a short form drifted from its rule is refused when it is written" "$out" '"decision":"block"'
says "and the refusal names the floor it fell under" "$out" "floor"
says "and names the lesson" "$out" "L2"

# The same lesson stored twice, and an entry carrying a second SHORT line (claude-config#392). Both
# sat in the real file on 2026-09-17 while check-lessons called the numbering sound.
printf '# Lessons\n\n## Proof over green\n\n- **L1. a rule that fits.** body\n- **L2. a rule that fits.** body\n' > "$HOME_FIX/LESSONS.md"
out="$(run_hook Edit "$HOME_FIX/LESSONS.md")"
says "the same rule stored under two numbers is refused" "$out" "L1 and L2"
printf '# Lessons\n\n## Proof over green\n\n- **L1. a rule that fits.** body\n  SHORT: a rule that fits.\n  SHORT: a rule.\n' > "$HOME_FIX/LESSONS.md"
out="$(run_hook Edit "$HOME_FIX/LESSONS.md")"
says "an entry carrying two SHORT lines is refused" "$out" "2 SHORT lines"

# And it says so ONLY into the session. The tool notifies the desktop on a non interactive failure,
# which is right for the background sync job and wrong here: it reaches somebody who is already
# looking at the answer, and a test run of this suite put real notifications on the real screen
# until the hook suppressed them (L2).
printf '# Lessons\n\n## Proof over green\n\n- L2. bare.\n' > "$HOME_FIX/LESSONS.md"
NOTED="$WORK/notified"; : > "$NOTED"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s"\n' "$NOTED" > "$WORK/fake-notifier"
chmod +x "$WORK/fake-notifier"
out="$(payload_for Edit "$HOME_FIX/LESSONS.md" | CLAUDE_HOME="$HOME_FIX" SYNC_CLONE_REGISTRY="$REG" \
       SYNC_NOTIFIER="$WORK/fake-notifier" PATH="$WORK:$PATH" bash "$HOOK" 2>&1)"
says "the fault still reaches the session" "$out" '"decision":"block"'
if [ -s "$NOTED" ]; then
  _noted="$(cat "$NOTED")"
  check "and nothing was pushed to the desktop" "it notified: ${_noted:0:120}"
else
  check "and nothing was pushed to the desktop" ok
fi

echo "lesson entry check: it fires on the writes that happen, and nothing else"

sound
for tool in Write MultiEdit; do
  printf '# Lessons\n\n## Proof over green\n\n- L2. bare.\n' > "$HOME_FIX/LESSONS.md"
  out="$(run_hook "$tool" "$HOME_FIX/LESSONS.md")"
  says "a $tool of the lessons file is checked too" "$out" '"decision":"block"'
done

# A file that is not the lessons file is none of its business, however broken. Without this the
# hook would run the whole check on every edit anybody makes anywhere.
printf '# Lessons\n\n## Proof over green\n\n- L2. bare.\n' > "$HOME_FIX/LESSONS.md"
printf 'hello\n' > "$WORK/other.md"
out="$(run_hook Edit "$WORK/other.md")"
silent "an edit to another file says nothing, even with the lessons file broken" "$out"
# And a LESSONS.md somewhere else is not this one: the file that publishes is the one under the
# config root, and a project's own notes are not governed by the sync.
mkdir -p "$WORK/elsewhere"
cp "$HOME_FIX/LESSONS.md" "$WORK/elsewhere/LESSONS.md"
out="$(run_hook Edit "$WORK/elsewhere/LESSONS.md")"
silent "a LESSONS.md outside the config root is not this one" "$out"

echo "lesson entry check: a lesson written by a SHELL command is checked too (claude-config#537)"

# The hook used to be registered on Edit|Write|MultiEdit only, and read its target from the tool's
# file_path, so a lesson appended with a heredoc or sed was never judged. In auto mode that is the
# DEFAULT way files get written. On 2026-09-21 L1003 and L1005 were written that way, both missing
# their bold marker, and held the whole lessons file back from the next send. The Bash mode keys on
# the state reached, the file having changed since it was last checked, never on reading the
# command text (L247), so a payload naming no file at all must still be judged.
bash_payload() { python3 -c 'import json; print(json.dumps({"tool_name": "Bash", "tool_input": {"command": "cat >> LESSONS.md <<EOF"}}))'; }
run_after_bash() { bash_payload | CLAUDE_HOME="$HOME_FIX" SYNC_CLONE_REGISTRY="$REG" bash "$HOOK" --after-bash 2>&1; }
rm -f "$HOME_FIX/state/lesson-entry-check.stamp"
printf '# Lessons\n\n## Proof over green\n\n- **L1. a rule that fits.** body\n- L2. appended by a shell command with the bold left off.\n' > "$HOME_FIX/LESSONS.md"
out="$(run_after_bash)"
says "a lesson file changed by a shell command is checked, and a fault refused" "$out" '"decision":"block"'
says "and the refusal names the entry" "$out" "L2"
says "and does not claim a tool wrote it, only that the file changed" "$out" "changed since it was last checked"
out="$(run_after_bash)"
silent "the same unchanged fault is reported once, not on every shell command after it" "$out"
printf '# Lessons\n\n## Proof over green\n\n- **L1. a rule that fits.** body\n- **L2. fixed now.** body\n' > "$HOME_FIX/LESSONS.md"
out="$(run_after_bash)"
silent "a shell command that leaves the file sound says nothing" "$out"
printf -- '- L3. appended again, bare.\n' >> "$HOME_FIX/LESSONS.md"
out="$(run_after_bash)"
says "the next shell append that breaks it is refused again" "$out" "L3"

# An edit made through the tools is checked where it is made, and a shell command straight after it
# must not report the same change a second time.
printf '# Lessons\n\n## Proof over green\n\n- L4. bare, written by Edit.\n' > "$HOME_FIX/LESSONS.md"
out="$(run_hook Edit "$HOME_FIX/LESSONS.md")"
says "control: the Edit of that fault is refused" "$out" '"decision":"block"'
out="$(run_after_bash)"
silent "and the shell command after it does not report it again" "$out"

# A config root with no lessons file has nothing to check.
EMPTY_HOME="$WORK/emptyhome"; mkdir -p "$EMPTY_HOME"
out="$(bash_payload | CLAUDE_HOME="$EMPTY_HOME" SYNC_CLONE_REGISTRY="$REG" bash "$HOOK" --after-bash 2>&1)"
silent "with no lessons file the Bash mode says nothing" "$out"

# The Bash mode is only real if the platform calls it (L1004): the shipped settings must register
# it on the Bash matcher of PostToolUse.
python3 - "$REPO/payload/settings.hooks.json" <<'PY' && check "settings register the Bash mode on PostToolUse Bash" ok || check "settings register the Bash mode on PostToolUse Bash" "not registered"
import json, sys
d = json.load(open(sys.argv[1]))
for group in d.get("hooks", {}).get("PostToolUse", []):
    if group.get("matcher") == "Bash":
        for h in group.get("hooks", []):
            if h.get("command", "").endswith("hooks/lesson-entry-check.sh --after-bash"):
                sys.exit(0)
sys.exit(1)
PY

echo "lesson entry check: it never goes quiet on its own failure"

# No clone of the tool to ask means nothing was checked, which is not the same as nothing being
# wrong, and the two must not arrive as the same silence (L98, L11).
printf '# Lessons\n\n## Proof over green\n\n- L2. bare.\n' > "$HOME_FIX/LESSONS.md"
EMPTY_REG="$WORK/noclones"; : > "$EMPTY_REG"
out="$(payload_for Edit "$HOME_FIX/LESSONS.md" | CLAUDE_HOME="$HOME_FIX" SYNC_CLONE_REGISTRY="$EMPTY_REG" bash "$HOOK" 2>&1)"
says "with no clone to ask, it says the entry was NOT checked" "$out" "could not"
says "and names what it was looking for" "$out" "claude-sync"

# A clone that does not KNOW the command has judged nothing, and saying the lesson is broken
# because the tool could not be asked is a claim this never measured (L11, L440). It happens by
# DESIGN rather than by accident: the clone this calls updates on its own schedule, so between this
# config reaching a Mac and that clone pulling, the command is genuinely absent. A change applied
# before the code that needs it deploys has to leave the deployed code working (L640).
OLD="$WORK/oldclone"; mkdir -p "$OLD"
cat > "$OLD/claude-sync" <<'OLDEOF'
#!/usr/bin/env bash
echo "claude-sync: unknown command '$1' (try: push, pull, sync, status, check-lessons, help)" >&2
exit 1
OLDEOF
chmod +x "$OLD/claude-sync"
printf '%s
' "$OLD" > "$WORK/oldreg"
printf '# Lessons

## Proof over green

- L2. bare.
' > "$HOME_FIX/LESSONS.md"
out="$(payload_for Edit "$HOME_FIX/LESSONS.md" | CLAUDE_HOME="$HOME_FIX" SYNC_CLONE_REGISTRY="$WORK/oldreg" bash "$HOOK" 2>&1)"
says "a clone too old to know the command says the entry was NOT checked" "$out" "could not be checked"
says "and names the clone that has to be updated" "$out" "$OLD"
case "$out" in *"leaves the file unable to publish"*) check "and does not claim the lesson is broken" "it blamed the lesson" ;; *) check "and does not claim the lesson is broken" ok ;; esac

# A payload it cannot read is the same kind of failure and must not read as a clean file.
out="$(printf 'not json at all' | CLAUDE_HOME="$HOME_FIX" SYNC_CLONE_REGISTRY="$REG" bash "$HOOK" 2>&1)"
silent "an unreadable payload names no file, so there is nothing to check and nothing to say" "$out"

echo "lesson entry check: a sync that is running cannot stop it answering"

# The whole reason the hook runs `lesson-faults` rather than `check-lessons`: it takes no lock. A
# lock taking command REFUSES while another run holds it, so without this the session that wrote a
# broken lesson would be told nothing precisely while the watcher was busy, which is most of the
# time (L110, L109).
LOCKED="$WORK/lockedclone"
mkdir -p "$LOCKED/payload/hooks/lib"
cp "$SYNC" "$LOCKED/claude-sync"
cp "$DIR/lib/lesson-index-cap.sh" "$LOCKED/payload/hooks/lib/lesson-index-cap.sh"
printf '%s\n' "$LOCKED" > "$WORK/lockedreg"
# The lock exactly as the tool takes it: a directory holding a LIVE pid and this run's hostname,
# which is the shape acquire_lock waits on rather than breaks.
sleep 120 &
holder=$!
mkdir -p "$LOCKED/.sync-lock"
printf '%s' "$holder" > "$LOCKED/.sync-lock/pid"
printf '%s' "locktest" > "$LOCKED/.sync-lock/host"

printf '# Lessons\n\n## Proof over green\n\n- L2. bare.\n' > "$HOME_FIX/LESSONS.md"

# The POSITIVE CONTROL first. Without it this fixture might simply be a lock nothing waits on, and
# the assertion below would pass against a state where no lock was held at all (L159).
ctrl="$(SYNC_HOSTNAME=locktest SYNC_LOCK_WAIT=2 SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 \
        CLAUDE_HOME="$HOME_FIX" SYNC_REPO="$LOCKED" bash "$LOCKED/claude-sync" push 2>&1)"
says "the held lock really does stop a lock taking command" "$ctrl" "already running"

# SYNC_LOCK_WAIT is passed in so that a REGRESSION here fails in seconds rather than sitting in the
# tool's ninety second wait. It shortens a wait and changes nothing else about what is measured.
out="$(payload_for Edit "$HOME_FIX/LESSONS.md" \
       | SYNC_HOSTNAME=locktest SYNC_LOCK_WAIT=2 CLAUDE_HOME="$HOME_FIX" \
         SYNC_CLONE_REGISTRY="$WORK/lockedreg" bash "$HOOK" 2>&1)"
says "the write time check still answers while that lock is held" "$out" '"decision":"block"'
says "and its answer is the fault, not a complaint about the lock" "$out" "L2"
case "$out" in *"already running"*) check "and it says nothing about another run" "it complained about the lock" ;; *) check "and it says nothing about another run" ok ;; esac

kill "$holder" 2>/dev/null
wait "$holder" 2>/dev/null

# --- the reader this whole check runs through (claude-config#486) --------------
#
# The file the tool call wrote is read out of the payload with python3, and the answer is emitted
# as JSON by python3 too. With no python3 the target came back empty, the hook exited 0 in
# silence, and a lesson written into LESSONS.md was never checked: the same quiet as a lesson with
# nothing wrong in it, which is the quiet this hook exists to end (L490, L98, L11).
. "$DIR/lib/no-python-path.sh"
NOPY_ROOT="$WORK/nopy"
NOPY="$NOPY_ROOT/bin"
npp_build_bin "$NOPY" jq
if npp_reaches_python3 "$NOPY"; then
  check "the bare directory really reaches no python3" "it found one, so nothing below measures its absence"
else check "the bare directory really reaches no python3" ok; fi

NOPY_OUT=""; NOPY_RC=0
nopy_hook() {  # nopy_hook <payload> -> sets NOPY_OUT and NOPY_RC
  NOPY_OUT="$(printf '%s' "$1" | env PATH="$NOPY" CLAUDE_HOME="$HOME_FIX" \
      SYNC_CLONE_REGISTRY="$WORK/reg" "$NOPY/bash" "$HOOK" 2>&1)"; NOPY_RC=$?
}

nopy_hook "$(payload_for Edit "$HOME_FIX/LESSONS.md")"; out="$NOPY_OUT"
says "with no python3 a write to the lessons file is reported rather than passed in silence" "$out" "python3"
if [ "$NOPY_RC" = 2 ]; then check "and it is reported in the one way a hook with no python3 can, on stderr with exit 2" ok
else check "and it is reported in the one way a hook with no python3 can, on stderr with exit 2" "exited $NOPY_RC"; fi
says "and it says what goes unnoticed when nothing checks the entry" "$out" "LESSONS-INDEX.md"

# A write to something else takes nothing from the missing reader, so there is nothing to report
# (L54, L324). With no python3 the target cannot be read, so this is narrowed on the raw payload:
# a payload that never mentions the lessons file cannot be about one.
nopy_hook "$(payload_for Edit "$WORK/notes.md")"; out="$NOPY_OUT"
if [ "$NOPY_RC" = 0 ]; then check "a write to an unrelated file is not reported over a reader it never needed" ok
else check "a write to an unrelated file is not reported over a reader it never needed" "exited $NOPY_RC saying: ${out:0:200}"; fi
silent "and it says nothing about that write" "$out"

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
