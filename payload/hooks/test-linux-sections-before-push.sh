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
