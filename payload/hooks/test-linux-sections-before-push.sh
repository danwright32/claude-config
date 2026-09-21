#!/usr/bin/env bash
# Tests for linux-sections-before-push.sh, the gate that runs the sections a push touches on Linux
# before letting it through (claude-config#339).
#
# Every check drives the REAL hook with a real payload, against a throwaway git repository built to
# hold the answer it expects. What matters most here is not that it blocks: it is every direction
# in which it must NOT block, because a gate that stops a push over a question the machine cannot
# ask is worse than no gate, and one that blocks in a repository it knows nothing about is worse
# still (L98, L42).
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/linux-sections-before-push.sh"

pass=0; fail=0
check(){ if [ "$2" = ok ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 ($2)"; fi; }

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/claude-sync-linuxgate-test.XXXXXXXX")" || TMPROOT=""
# An rm -rf on a path from a command that can fail, refused up front rather than relied on being
# harmless (L5, L9). The same line the suites next door hold for their own directories.
case "${TMPROOT%/}" in
  ''|/|"${HOME%/}"|"${TMPDIR:-/tmp}"|"${TMPDIR:-/tmp}"/)
    echo "test-linux-sections-before-push: refusing to run: throwaway directory came back as '$TMPROOT'." >&2; exit 2 ;;
esac
[ -d "$TMPROOT" ] || { echo "test-linux-sections-before-push: '$TMPROOT' is not a directory." >&2; exit 2; }
trap 'rm -rf "$TMPROOT"' EXIT

# A repository shaped like the one the hook is for: a runner, an audit, and a commit to diff
# against. Both scripts are STUBS whose exit status the caller chooses, because what is under test
# is the hook's handling of what it is told, not docker and not the audit.
mkrepo(){   # $1 = name   $2 = the exit status the audit stub returns   -> prints the path
  local r="$TMPROOT/$1"
  mkdir -p "$r/tests"
  git -C "$r" init -q 2>/dev/null || { git init -q "$r" 2>/dev/null; }
  printf 'x\n' > "$r/seed.txt"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$r/tests/run-on-linux.sh"
  cat > "$r/tests/audit-changed-sections.sh" <<AUDIT
#!/usr/bin/env bash
echo "stub audit ran: AUDIT_ON_LINUX=\${AUDIT_ON_LINUX:-} base=\${1:-}"
echo "  == LISTED alpha =="
exit $2
AUDIT
  chmod +x "$r/tests/run-on-linux.sh" "$r/tests/audit-changed-sections.sh"
  git -C "$r" add -A 2>/dev/null
  git -C "$r" -c user.email=p@l -c user.name=p commit -qm seed 2>/dev/null
  # A base to diff against, so the hook does not fall out early for want of one.
  git -C "$r" branch -f main HEAD 2>/dev/null
  git -C "$r" branch -f origin/main HEAD 2>/dev/null
  printf '%s' "$r"
}

# The status is written to a file rather than returned through a command substitution: that runs in
# a subshell, so a variable set inside it does not survive, and the first version of this died on an
# unbound RC rather than reporting a wrong one, which is the better of the two ways to be wrong.
OUTFILE="$TMPROOT/.hook-out"
RC=0
# Every run keeps the gate's stand down record inside the throwaway directory. Without this the
# fixture repositories wrote into ~/.claude/state/linux-sections, the record a real push reads, and
# five fixture repos appeared in it (L2: a test must be structurally unable to touch live state).
export LINUX_SECTIONS_STATE_DIR="${LINUX_SECTIONS_STATE_DIR:-$TMPROOT/linux-state-default}"
run(){   # $1 = repo   $2 = the command the payload carries   -> fills $OUT and $RC
  printf '{"tool_name":"Bash","tool_input":{"command":%s},"cwd":%s}' \
    "$(printf '%s' "$2" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')" \
    "$(printf '%s' "$1" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')" \
    | bash "$HOOK" > "$OUTFILE" 2>&1
  RC=$?
  OUT="$(cat "$OUTFILE" 2>/dev/null || true)"
}

# --- a section that fails on Linux blocks the push. This is the one thing it may block on.
R1="$(mkrepo fails 1)"
run "$R1" 'git push'; o1="$OUT"
[ "$RC" -eq 2 ] && check "a section failing on Linux blocks the push" ok \
                || check "a section failing on Linux blocks the push" "rc=$RC out=$o1"
case "$o1" in *'PUSH BLOCKED'*) check "and says so in the words the other gates use" ok ;;
              *) check "and says so in the words the other gates use" "out=$o1" ;; esac
case "$o1" in *'LISTED alpha'*) check "and carries what the audit reported" ok ;;
              *) check "and carries what the audit reported" "out=$o1" ;; esac
case "$o1" in *'AUDIT_ON_LINUX=1'*) check "and it really asked for the Linux run" ok ;;
              *) check "and it really asked for the Linux run" "out=$o1" ;; esac

# --- the Linux runner could not run at all: the push goes through, and the hook SAYS so. Measured
#     on 2026-09-21 while timing what a push waits on (claude-config#523): docker is installed on
#     this Mac and its daemon is not running, so this gate returned in 1.5 seconds having judged
#     nothing, in complete silence, and a push nobody checked on Linux looked exactly like one that
#     passed (L98, L557).
R7="$(mkrepo unmeasured 0)"
cat > "$R7/tests/audit-changed-sections.sh" <<'AUDIT'
#!/usr/bin/env bash
echo "audit-changed-sections: these changed sections were NOT judged, because the Linux runner could not run here:" >&2
echo "  == LISTED alpha ==" >&2
echo "That is UNMEASURED, not a pass." >&2
exit 0
AUDIT
chmod +x "$R7/tests/audit-changed-sections.sh"
run "$R7" 'git push'; o7="$OUT"
[ "$RC" -eq 0 ] && check "a Linux run that could not happen does not block the push" ok \
                || check "a Linux run that could not happen does not block the push" "rc=$RC out=$o7"
case "$o7" in *UNMEASURED*) check "but the hook repeats that nothing was judged on Linux" ok ;;
              *) check "but the hook repeats that nothing was judged on Linux" "it said: [$o7]" ;; esac
case "$o7" in *'LISTED alpha'*) check "and names the sections nothing judged" ok ;;
              *) check "and names the sections nothing judged" "it said: [$o7]" ;; esac

# --- the RECORD of how often Linux actually judged a push (claude-config#529). A gate that stands
#     down on most pushes is close to not being there, and the difference is invisible unless it is
#     counted: this one stood down on every push on this Mac between 2026-09-07 and 2026-09-21 and
#     nothing anywhere knew (L557).
STATE="$TMPROOT/linux-state"
runrec(){ LINUX_SECTIONS_STATE_DIR="$STATE" run "$1" "$2"; }   # a record of its own, so the counts here are only this block's
R8="$(mkrepo counted 0)"
cat > "$R8/tests/audit-changed-sections.sh" <<'AUDIT'
#!/usr/bin/env bash
echo "audit-changed-sections: these changed sections were NOT judged, because the Linux runner could not run here:" >&2
echo "  == LISTED alpha ==" >&2
echo "That is UNMEASURED, not a pass." >&2
exit 0
AUDIT
chmod +x "$R8/tests/audit-changed-sections.sh"
runrec "$R8" 'git push'; o8="$OUT"
runrec "$R8" 'git push'; o8b="$OUT"
case "$o8b" in *"judged 0 of the 2"*) check "it counts the pushes Linux did not judge, and says so" ok ;;
  *) check "it counts the pushes Linux did not judge, and says so" "it said: [$o8b]" ;; esac

# A push Linux DID judge is counted as judged, and the count is per repository.
R9="$(mkrepo countedok 0)"
cat > "$R9/tests/audit-changed-sections.sh" <<'AUDIT'
#!/usr/bin/env bash
echo "audit-changed-sections: audited 1 section(s) changed against ${1:-}, on Linux, and each one ran on its own and passed."
exit 0
AUDIT
chmod +x "$R9/tests/audit-changed-sections.sh"
runrec "$R9" 'git push'
cat > "$R9/tests/audit-changed-sections.sh" <<'AUDIT'
#!/usr/bin/env bash
echo "audit-changed-sections: these changed sections were NOT judged, because the Linux runner could not run here:" >&2
echo "That is UNMEASURED, not a pass." >&2
exit 0
AUDIT
chmod +x "$R9/tests/audit-changed-sections.sh"
runrec "$R9" 'git push'; o9b="$OUT"
case "$o9b" in *"judged 1 of the 2"*) check "and a push it did judge counts as judged" ok ;;
  *) check "and a push it did judge counts as judged" "it said: [$o9b]" ;; esac
[ "$(find "$STATE" -name '*.txt' -type f 2>/dev/null | grep -c . || true)" -ge 2 ] \
  && check "and each repository has its own record" ok \
  || check "and each repository has its own record" "records: $(ls "$STATE" 2>/dev/null | tr '\n' ' ')"

# A push with nothing to judge (no section changed) is NOT a stand down, or the count would say
# the gate is failing on every push that touches no test.
R10="$(mkrepo nothingtodo 0)"
cat > "$R10/tests/audit-changed-sections.sh" <<'AUDIT'
#!/usr/bin/env bash
echo "audit-changed-sections: tests/test-claude-sync.sh is unchanged against ${1:-}, so no section needed running on its own. The full suite still runs."
exit 0
AUDIT
chmod +x "$R10/tests/audit-changed-sections.sh"
runrec "$R10" 'git push'; o10="$OUT"
[ -z "$o10" ] && check "a push with no section to judge says nothing and counts nothing" ok \
  || check "a push with no section to judge says nothing and counts nothing" "it said: [$o10]"

# A state directory it cannot write is not a reason to stop a push, and it says so rather than
# going quiet about its own bookkeeping (L42, L98).
R11="$(mkrepo unwritable 0)"
cp "$R8/tests/audit-changed-sections.sh" "$R11/tests/audit-changed-sections.sh"
LINUX_SECTIONS_STATE_DIR="/dev/null/nope" run "$R11" 'git push'; o11="$OUT"
[ "$RC" -eq 0 ] && check "a record it cannot write does not block the push" ok \
  || check "a record it cannot write does not block the push" "rc=$RC out=$o11"
case "$o11" in *UNMEASURED*) check "and the stand down is still reported" ok ;;
  *) check "and the stand down is still reported" "it said: [$o11]" ;; esac

# --- everything it must NOT block on.
R2="$(mkrepo passes 0)"
run "$R2" 'git push'; o2="$OUT"
[ "$RC" -eq 0 ] && check "a clean audit lets the push through" ok \
                || check "a clean audit lets the push through" "rc=$RC out=$o2"

# The audit refusing to answer is its own problem, not evidence about this push.
R3="$(mkrepo refuses 2)"
run "$R3" 'git push'; o3="$OUT"
[ "$RC" -eq 0 ] && check "an audit that could not answer does not block the push" ok \
                || check "an audit that could not answer does not block the push" "rc=$RC out=$o3"

# A repository this does not apply to: no runner, so nothing to run and nothing to say.
R4="$(mkrepo norunner 1)"; rm -f "$R4/tests/run-on-linux.sh"
run "$R4" 'git push'; o4="$OUT"
[ "$RC" -eq 0 ] && check "a repository with no Linux runner is left alone" ok \
                || check "a repository with no Linux runner is left alone" "rc=$RC out=$o4"
[ -z "$o4" ] && check "and it says nothing at all there" ok \
             || check "and it says nothing at all there" "out=$o4"

# Not a push at all.
R5="$(mkrepo notapush 1)"
run "$R5" 'git status'; o5="$OUT"
[ "$RC" -eq 0 ] && check "a command that is not a push is ignored" ok \
                || check "a command that is not a push is ignored" "rc=$RC out=$o5"

# The override, which must be explained to the user but must work.
R6="$(mkrepo override 1)"
run "$R6" 'SKIP_LINUX_CHECK=1 git push'; o6="$OUT"
[ "$RC" -eq 0 ] && check "the override lets a failing push through" ok \
                || check "the override lets a failing push through" "rc=$RC out=$o6"

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
