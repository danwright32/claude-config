#!/usr/bin/env bash
# test-db-write-ask-git-fails.sh: db-write-ask.sh when git itself fails while it checks whether a
# commit adds a project to a checkout's Supabase test project list (claude-config#2989).
#
# Kept apart from test-db-write-ask.sh on purpose (PR #2999). The fake git here has to answer the
# hook's listing of the checkout, so this file names that git command, and scanners-before-push.sh
# selects any suite naming it as a whole tree scanner and runs it before every push. A false
# positive is meant to cost a few seconds there, and this suite takes about that; the main suite
# took 57 seconds on CI and 108 at a load average of 72 here (2026-11-14), which is the premise
# that gate's header says expires when one suite takes a large share of its budget (#1997). So
# these cases live here, the main suite is not selected, and .claude/scanners-floor.txt names this
# one.
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/db-write-ask.sh"

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }

if [ ! -f "$HOOK" ]; then
  echo "FAIL: there is no db-write-ask.sh beside this suite at $DIR"
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
# A HOME of its own, so the Mac's real settings.local.json is never read; CLAUDE_HOME cleared too.
EMPTY_HOME="$WORK/empty-home"
mkdir -p "$EMPTY_HOME"

# verdict <git folder> <command> <cwd>: the hook's answer to that Bash call, run with the fake git
# in <git folder> first on the PATH, as "<decision> rc=<exit>|<reason>".
verdict() {
  local body rc payload
  payload="$(python3 -c 'import json, sys; print(json.dumps({"session_id": "s1", "transcript_path": sys.argv[3], "hook_event_name": "PreToolUse", "cwd": sys.argv[2], "tool_name": "Bash", "tool_input": {"command": sys.argv[1], "description": "d"}}))' "$2" "$3" "$NONE_T")"
  body="$(cd "$WORK" && printf '%s' "$payload" | PATH="$1:$PATH" env -u CLAUDE_HOME HOME="$EMPTY_HOME" bash "$HOOK" 2>/dev/null)"; rc=$?
  printf '%s' "$body" | python3 -c '
import json, sys
t = sys.stdin.read().strip()
try:
    h = (json.loads(t) if t else {}).get("hookSpecificOutput") or {}
except Exception:
    print("badjson rc=" + sys.argv[1] + "|" + t[:300], end=""); sys.exit()
print(h.get("permissionDecision", "none") + " rc=" + sys.argv[1] + "|" + h.get("permissionDecisionReason", ""), end="")' "$rc"
}

# A linked project whose committed list names its own ref, as the main suite builds it. Every ref
# is invented.
APPLY="$WORK/apply"
TESTP="$APPLY/testproj"
mkdir -p "$TESTP/supabase/.temp" "$TESTP/.claude"
printf 'testprojectref000001' > "$TESTP/supabase/.temp/project-ref"
TESTP_GIT=(git -C "$TESTP" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false -c core.hooksPath=/dev/null)
"${TESTP_GIT[@]}" init -q
printf '# the test projects of this checkout\n\ntestprojectref000001\nanothertestref000002\n' > "$TESTP/.claude/supabase-test-projects"
"${TESTP_GIT[@]}" add -f .claude/supabase-test-projects && "${TESTP_GIT[@]}" commit -q -m list
NONE_T="$APPLY/no-apply.jsonl"
printf '{"type": "user", "sessionId": "s1", "message": {"role": "user", "content": "hi"}}\n' > "$NONE_T"

# git failing is asked about, saying so.
GITSTUB="$APPLY/gitstub"; mkdir -p "$GITSTUB"
printf '#!/bin/sh\necho "fatal: index file corrupt" >&2\nexit 3\n' > "$GITSTUB/git"; chmod +x "$GITSTUB/git"
r="$(verdict "$GITSTUB" 'git commit -m x' "$TESTP")"
case "$r" in
  "ask rc=0|"*"could not be told: git ls-files failed (exit 3)"*) check "a commit whose checkout git cannot read is asked about, saying git failed (#2989)" ok ;;
  *) check "a commit whose checkout git cannot read is asked about, saying git failed (#2989)" "$r" ;;
esac
# A git that lists a list and then fails its diff is asked about, saying the diff failed.
printf '#!/bin/sh\ncase " $* " in\n  *" ls-files "*) printf "H .claude/supabase-test-projects\\000"; exit 0 ;;\n  *" rev-parse "*) exit 0 ;;\n  *) echo "fatal: bad object" >&2; exit 5 ;;\nesac\n' > "$GITSTUB/git"
r="$(verdict "$GITSTUB" 'git commit -m x' "$TESTP")"
case "$r" in
  "ask rc=0|"*"could not be told: git diff failed (exit 5)"*) check "a commit whose git diff fails is asked about, saying so (#2989)" ok ;;
  *) check "a commit whose git diff fails is asked about, saying so (#2989)" "$r" ;;
esac

echo "passed: $pass, failed: $fail"
echo "SUITE-RESULT passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
