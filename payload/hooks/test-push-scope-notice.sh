#!/usr/bin/env bash
# Tests for push-scope-notice.sh, which tells the SESSION when every push gate stood down because
# the push named a directory that could not be resolved (claude-config#552).
#
# Since #532 the shared resolver refuses rather than judging the session repository in its place,
# and the thirteen gates that use it exit 0 on that refusal. Right, but the refusal's sentence went
# to stderr, which a PreToolUse hook exiting 0 shows to nobody, so a push nothing judged read
# exactly like a push judged clean (L98). This one hook says it once, as context the model receives,
# instead of thirteen copies from thirteen gates.
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
SETTINGS="$DIR/../settings.hooks.json"

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

echo "push scope notice: the skip it exists to announce"

out="$(run "cd $W/no-such-dir && git push")"
says "a push naming a missing directory tells the session" "$out" '"additionalContext"'
says "and names the directory it could not resolve" "$out" "$W/no-such-dir"
says "and says the push gates did not judge this push" "$out" "no push gate judged this push"
says "and that it did not fall back to the session repository" "$out" "$W/session"
# The shape the platform accepts, judged by the repo's own reader of it, so a payload Claude Code
# would reject cannot pass here (claude-config#478).
if printf '%s' "$out" | python3 "$DIR/lib/hook-output.py" --payload >/dev/null 2>&1; then check "the output is a shape Claude Code accepts" ok
else check "the output is a shape Claude Code accepts" "$(printf '%s' "$out" | python3 "$DIR/lib/hook-output.py" --payload 2>&1)"; fi
out="$(run "git -C $W/no-such-dir push")"
says "a git -C naming a missing directory is announced too" "$out" '"additionalContext"'

echo "push scope notice: silent where there is nothing to announce"

silent "a push the gates can resolve says nothing" "$(run "cd $W/target && git push")"
silent "a plain push from the session repository says nothing" "$(run "git push")"
silent "a command that is not a push says nothing" "$(run "cd $W/no-such-dir && git status")"
silent "a push quoted inside an argument says nothing" "$(run "gh issue create --body \"cd $W/no-such-dir && git push\"")"

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
