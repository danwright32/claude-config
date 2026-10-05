#!/usr/bin/env bash
# Tests for push-scope-notice.sh, which REFUSES a push every push gate would stand down on because
# it names a directory that could not be resolved (claude-config#552, refusing since #589).
#
# Since #532 the shared resolver refuses rather than judging the session repository in its place,
# and the thirteen gates that use it exit 0 on that refusal, which left the push unjudged. #552 had
# this hook only say so, as context the model received, and let the push through; since #589 it
# blocks with exit 2 and states the reason and the remedy on stderr, once, instead of thirteen
# copies from thirteen gates (L42, L320).
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/push-scope-notice.sh"
# The hooks block is settings.hooks.json in the repository and settings.json once installed, and this
# suite runs in both places, so it reads whichever sits beside the hooks. Hard coding the repo's name
# failed every pull, where the suite runs from the installed copy.
SETTINGS="$DIR/../settings.hooks.json"
[ -f "$SETTINGS" ] || SETTINGS="$DIR/../settings.json"

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }
says() { case "$2" in *"$3"*) check "$1" ok ;; *) check "$1" "did not say '$3': ${2:0:300}" ;; esac; }
silent() { if [ -z "$2" ]; then check "$1" ok; else check "$1" "it said: ${2:0:300}"; fi; }

[ -f "$HOOK" ] || { echo "FAIL: no hook at $HOOK"; echo "passed: 0, failed: 1"; printf 'SUITE-RESULT passed=0 failed=1\n'; exit 1; }

W="$(mktemp -d "${TMPDIR:-/tmp}/claude-sync-work.pushnotice.XXXXXXXX")" || W=""
case "${W%/}" in ''|/|"${HOME%/}") echo "refusing: throwaway came back as '$W'" >&2; exit 2 ;; esac
trap 'rm -rf "$W"' EXIT
git init -q "$W/session" 2>/dev/null
git init -q "$W/target" 2>/dev/null

run() { # run <command> [cwd] -> the hook's stdout; stderr kept apart in $W/err
  python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","hook_event_name":"PreToolUse","tool_input":{"command":sys.argv[1]},"cwd":sys.argv[2]}))' \
    "$1" "${2:-$W/session}" | bash "$HOOK" 2>"$W/err"
}

echo "push scope notice: a push no gate can judge is refused (claude-config#589)"

# It used to only TELL the session, as additionalContext, and let the push through: a gate that
# cannot find its target and then lets the command through fails open (L42, L320). On 2026-09-29 an
# Ovation subagent pushed with a quoted -C path and no global gate checked it. Now it refuses, with
# the reason, so the push is spelled in a form the gates can read before it goes anywhere.
out="$(run "cd $W/no-such-dir && git push")"; rc=$?
err="$(cat "$W/err")"
[ "$rc" -eq 2 ] && check "a push naming a missing directory is refused" ok || check "a push naming a missing directory is refused" "exit $rc"
says "and names the directory it could not resolve" "$err" "$W/no-such-dir"
says "and says the push gates could not judge this push" "$err" "no push gate could judge this push"
says "and that it did not fall back to the session repository" "$err" "$W/session"
says "and how to push so it can be judged" "$err" "spell it absolutely"
out="$(run "git -C $W/no-such-dir push")"; rc=$?
[ "$rc" -eq 2 ] && check "a git -C naming a missing directory is refused too" ok || check "a git -C naming a missing directory is refused too" "exit $rc"
out="$(run "git -C \"\$WT\" push")"; rc=$?
[ "$rc" -eq 2 ] && check "a git -C naming a variable is refused" ok || check "a git -C naming a variable is refused" "exit $rc"
# The case from the report: a quoted worktree path holding a space RESOLVES, so it is not refused.
git init -q "$W/with space" 2>/dev/null
out="$(run "git -C \"$W/with space\" push")"; rc=$?
[ "$rc" -eq 0 ] && check "a quoted -C path with a space is resolved, not refused" ok || check "a quoted -C path with a space is resolved, not refused" "exit $rc: $(cat "$W/err")"
silent "and says nothing" "$out"

echo "push scope notice: silent where there is nothing to announce"

# Since #589 the hook refuses with exit 2 and speaks on STDERR, so "silent" means all three: exit 0,
# nothing on stdout, nothing on stderr. Checking stdout alone could not see a wrong refusal.
allowed() { # allowed <description> <command>
  local out rc
  out="$(run "$2")"; rc=$?
  if [ "$rc" -eq 0 ] && [ -z "$out" ] && [ ! -s "$W/err" ]; then check "$1" ok
  else check "$1" "exit $rc, stdout [${out:0:200}], stderr [$(head -c 200 "$W/err")]"; fi
}
allowed "a push the gates can resolve is let through, saying nothing" "cd $W/target && git push"
allowed "a plain push from the session repository is let through, saying nothing" "git push"
allowed "a command that is not a push is let through, saying nothing" "cd $W/no-such-dir && git status"
allowed "a push quoted inside an argument is let through, saying nothing" "gh issue create --body \"cd $W/no-such-dir && git push\""

echo "push scope notice: it is actually run"

python3 - "$SETTINGS" <<'PY' && check "settings register it on PreToolUse Bash" ok || check "settings register it on PreToolUse Bash" "not registered"
import json, sys
d = json.load(open(sys.argv[1]))
for group in d.get("hooks", {}).get("PreToolUse", []):
    if group.get("matcher") == "Bash":
        for h in group.get("hooks", []):
            if h.get("command", "").endswith("hooks/push-scope-notice.sh"):
                sys.exit(0)
sys.exit(1)
PY

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
