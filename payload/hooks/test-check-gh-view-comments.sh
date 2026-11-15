#!/usr/bin/env bash
# Tests for check-gh-view-comments.sh (claude-config#2891): a `gh issue view` or `gh pr view` asked
# for --comments, as text, is refused before it runs, with the command that reads the whole thread;
# every other view passes untouched.
#
# The cause was measured on 2026-11-14 against gh 2.89.0 (evidence in the PR): with its output not a
# terminal, which a Bash call's never is, `gh issue view N --comments` prints ONLY the comments, never
# the title or body, and prints nothing at all, exiting 0, for an issue with none. Through the gh guard
# on PATH, through `rtk proxy` and through the real binary by its path the bytes were the same, so the
# fault is gh's own and the refusal is ours.
#
# The hook never calls gh, so nothing here stubs it: each case hands the hook a PreToolUse payload
# and reads its exit code and what it said. Nothing reaches the network (L2).
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/check-gh-view-comments.sh"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

pass=0; fail=0
ok(){ pass=$((pass + 1)); }
bad(){ fail=$((fail + 1)); echo "FAIL: $1"; }
check_eq(){ if [[ "$3" == "$2" ]]; then ok; else bad "$1 (expected '$2', got '$3')"; fi; }
check(){ if [[ "$3" == *"$2"* ]]; then ok; else bad "$1"; echo "  expected to contain: $2"; echo "  actual: ${3:0:1500}"; fi; }

payload(){ # payload <command>
  python3 -c 'import json, sys; print(json.dumps({"tool_name": "Bash", "tool_input": {"command": sys.argv[1]}, "cwd": sys.argv[2]}))' "$1" "$WORKDIR"
}
judge(){ # judge <command>: sets out and rc
  out="$(payload "$1" | bash "$HOOK" 2>&1)"; rc=$?
}
refused(){ # refused <name> <command>
  judge "$2"
  check_eq "#2891 refused: $1" "2" "$rc"
  check "#2891 and the refusal names the fix: $1" "--json title,body,comments" "$out"
}
allowed(){ # allowed <name> <command>
  judge "$2"
  check_eq "#2891 allowed: $1" "0" "$rc"
  check_eq "#2891 and nothing is said: $1" "" "$out"
}

# 1. Every way of asking gh for the comments as text is refused.
refused "the form the builders ran" "gh issue view 2237 --repo danwright32/claude-config --comments"
refused "the short flag" "gh issue view 2237 -c"
refused "a pull request" "gh pr view 12 --comments"
refused "the flag spelled true" "gh issue view 12 --comments=true"
refused "through rtk proxy" "rtk proxy gh issue view 2891 --repo acme/widget --comments"
refused "through rtk proxy, redirected into a file" "rtk proxy gh issue view 2891 --repo acme/widget --comments > out.txt 2>&1; wc -c out.txt"
refused "gh named by its path" "/opt/homebrew/bin/gh issue view 3 --comments"
refused "-R in front of the subcommand" "gh -R acme/widget issue view 3 --comments"
refused "after a cd" "cd /tmp && gh issue view 3 --comments | head -40"
refused "in bash -c" "bash -c 'gh issue view 3 --comments'"

judge "gh issue view 2237 --repo acme/widget --comments > notes.txt 2>&1"
check "#2891 the refusal says what gh prints instead" "only the comments" "$out"
check "#2891 and that an issue with none prints nothing" "nothing at all" "$out"
check "#2891 and gives the command to run instead, its redirection left out" "  gh issue view 2237 --repo acme/widget --json title,body,comments" "$out"
judge "gh pr view 12 -c"
check "#2891 a pr view refusal gives its own command" "  gh pr view 12 --json title,body,comments,reviews" "$out"

# 2. Every view that is not one, and every other command, passes.
allowed "an issue view without comments" "gh issue view 2237 --repo acme/widget"
allowed "the JSON form, comments included" "gh issue view 2237 --repo acme/widget --json body,comments"
allowed "the flag spelled false" "gh issue view 12 --comments=false"
allowed "the web form" "gh issue view 12 --comments --web"
allowed "the web form, clustered with -c" "gh pr view 12 -cw"
allowed "a comment being posted" "gh issue comment 12 --body 'see the comments'"
allowed "a view only quoted in an echo" 'echo "gh issue view 12 --comments"'
allowed "a repository named with a c" "gh issue view 12 -R acme/c"
allowed "an ordinary command" "ls -la"

# Built is not wired (L3): registered once as a PreToolUse hook on Bash, in whichever spelling of the
# settings file sits beside the hooks.
. "$DIR/lib/settings-file.sh"
SETTINGS="$(hook_settings_file "$DIR/..")"
check_eq "#2891 a settings file holding the hooks block is beside the hooks" "yes" \
  "$([ -n "$SETTINGS" ] && echo yes || echo "neither settings.hooks.json nor settings.json beside $DIR")"
wired="$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
print(sum(1 for m in d["hooks"].get("PreToolUse", []) if m.get("matcher") == "Bash"
          for h in m["hooks"] if h.get("command", "").endswith("/hooks/check-gh-view-comments.sh")))' "${SETTINGS:-/dev/null}")"
check_eq "#2891 registered once as a PreToolUse hook on Bash" "1" "$wired"

# 3. With the shared reader missing it stands down saying so, never silently (L98): the command runs,
# exit 0, and the line is the systemMessage Claude Code shows (claude-config#1912).
. "$DIR/lib/hook-notice.sh"
notice_of(){ local why; why="$(hook_notice_verdict "$json" "$2")"; if [ "$rc" -eq 0 ] && [ -z "$why" ]; then ok; else bad "$1 (exit $rc) $why"; fi; }
LONE="$WORKDIR/lone"; mkdir -p "$LONE/lib"
cp "$HOOK" "$LONE/"
python3 "$DIR/lib/install-hook-libs.py" "$DIR/lib" "$LONE/lib" hook-notice.sh || bad "the lone hook's hook-notice.sh could not be installed"
json="$(payload "gh issue view 3 --comments" | bash "$LONE/check-gh-view-comments.sh" 2>/dev/null)"; rc=$?
notice_of "#2891 with lib/push-scope.sh missing it does not block, and names the missing file and the remedy" "lib/push-scope.sh.*claude-sync pull"
# The control: a command that never names a view with comments leaves at once, silent, reader or not.
out="$(payload "ls -la" | bash "$LONE/check-gh-view-comments.sh" 2>&1)"; rc=$?
check_eq "#2891 control: a command with no comments flag passes in silence even with the reader missing" "0|" "$rc|$out"

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
