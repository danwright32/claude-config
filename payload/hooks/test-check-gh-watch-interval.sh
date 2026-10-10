#!/usr/bin/env bash
# Tests for check-gh-watch-interval.sh (claude-config#1014): a gh watcher that would poll GitHub
# faster than once a minute is refused before it runs, with the command that fixes it; every other
# command, and a watcher at a minute or slower, passes untouched.
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
HOOK="$DIR/check-gh-watch-interval.sh"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

pass=0; fail=0
ok(){ pass=$((pass + 1)); }
bad(){ fail=$((fail + 1)); echo "FAIL: $1"; }
check_eq(){ if [[ "$3" == "$2" ]]; then ok; else bad "$1 (expected '$2', got '$3')"; fi; }
check(){ if [[ "$3" == *"$2"* ]]; then ok; else bad "$1"; echo "  expected to contain: $2"; echo "  actual: ${3:0:1500}"; fi; }

payload(){ # payload <command> [tool]
  python3 -c 'import json, sys; print(json.dumps({"tool_name": sys.argv[2], "tool_input": {"command": sys.argv[1]}, "cwd": sys.argv[3]}))' "$1" "${2:-Bash}" "$WORKDIR"
}
judge(){ # judge <command> [tool]: sets out and rc
  out="$(payload "$1" "${2:-Bash}" | bash "$HOOK" 2>&1)"; rc=$?
}
refused(){ # refused <name> <command>
  judge "$2"
  check_eq "#1014 refused: $1" "2" "$rc"
  check "#1014 and the refusal names the fix: $1" "--interval 60" "$out"
}
allowed(){ # allowed <name> <command>
  judge "$2"
  check_eq "#1014 allowed: $1" "0" "$rc"
  check_eq "#1014 and nothing is said: $1" "" "$out"
}

# 1. A watcher at gh's own default, or any interval under a minute, is refused.
refused "gh pr checks --watch at gh's 10 second default" "gh pr checks 12 --watch"
refused "an interval of 10" "gh pr checks 12 --watch --interval 10"
refused "an interval of 30, short flag" "gh pr checks 12 --watch -i 30"
refused "an interval of 20, joined with =" "gh pr checks --watch --interval=20 12"
refused "an interval of 5, short flag joined" "gh pr checks 12 --watch -i5"
refused "behind rtk, piped on" "rtk gh pr checks 1036 --watch 2>&1 | tail -15"
refused "behind a scoped token and a cd" 'cd /tmp && GH_TOKEN=$(gh auth token -u someone) gh pr checks 3 --watch'
refused "gh named by its path" "/opt/homebrew/bin/gh pr checks 3 --watch --repo acme/widget"
refused "on the second line of the command" "$(printf 'echo start\ngh pr checks 9 --watch')"
refused "gh run watch at its 3 second default" "gh run watch 123456"
refused "gh run watch at 5 seconds" "gh run watch 123456 -i 5"

judge "gh pr checks 12 --watch"
check "#1014 the refusal says what the default costs" "every 10 seconds" "$out"
check "#1014 and whose allowance it spends" "GraphQL allowance" "$out"
check "#1014 and gives the command to run instead" "gh pr checks 12 --watch --interval 60" "$out"
judge "rtk gh pr checks 1036 --watch -i 30 2>&1 | tail -15"
check "#1014 the command it suggests leaves out the shell's redirection" "  gh pr checks 1036 --watch --interval 60" "$out"
judge "gh run watch 123456"
check "#1014 a run watch refusal names its own default" "every 3 seconds" "$out"
check "#1014 and gives its own command to run instead" "gh run watch 123456 --interval 60" "$out"

# 2. A minute or slower passes, as does everything that is not a fast watcher.
allowed "an interval of 60" "gh pr checks 12 --watch --interval 60"
allowed "an interval of 120, joined with =" "gh pr checks 12 --watch --interval=120"
allowed "short flag 60" "gh pr checks 12 --watch -i 60"
allowed "short flag joined 90" "gh pr checks 12 --watch -i90"
allowed "a run watch at 60" "gh run watch 5 --interval 60"
allowed "gh pr checks without --watch reads once" "gh pr checks 12"
allowed "a watcher only quoted in an echo" 'echo "gh pr checks 12 --watch"'
allowed "a watcher only written in a heredoc body" "$(printf "cat > notes.md <<'EOF'\ngh pr checks 1 --watch\nEOF")"
allowed "an interval it cannot read is left to run" 'gh pr checks 12 --watch --interval "$N"'
allowed "an ordinary command" "ls -la"
allowed "a git command that mentions watch" "git log --grep watch"

# Built is not wired (L3): the hook is registered to see every Bash call before it runs. In the
# repository the hooks block is payload/settings.hooks.json; installed under ~/.claude it is
# settings.json, the file Claude Code reads. Naming only the repository's spelling passed in CI and
# failed in the hook suite every pull runs, on 2026-10-10, the first pull after #1049.
SETTINGS=""
for _gw_candidate in "$DIR/../settings.hooks.json" "$DIR/../settings.json"; do
  if [ -f "$_gw_candidate" ]; then SETTINGS="$_gw_candidate"; break; fi
done
# Neither being there is not a pass: a check with no file to read answers like one that found the
# hook unwired, and says nothing about why (L98).
check_eq "#1014 a settings file holding the hooks block is beside the hooks" "yes" \
  "$([ -n "$SETTINGS" ] && echo yes || echo "neither settings.hooks.json nor settings.json beside $DIR")"
wired="$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
print(sum(1 for m in d["hooks"].get("PreToolUse", []) if m.get("matcher") == "Bash"
          for h in m["hooks"] if h.get("command", "").endswith("/hooks/check-gh-watch-interval.sh")))' "${SETTINGS:-/dev/null}")"
check_eq "#1014 registered once as a PreToolUse hook on Bash" "1" "$wired"

# 3. With no python3 the command cannot be read, and it stands down saying so, never silently.
NOPY="$WORKDIR/nopy"; mkdir -p "$NOPY"
for t in bash cat dirname sed awk tr head grep jq printf; do
  p="$(command -v "$t" 2>/dev/null)" && [ -x "$p" ] && ln -sf "$p" "$NOPY/$t"
done
pl="$(payload "gh pr checks 12 --watch")"
out="$(printf '%s' "$pl" | PATH="$NOPY" "$NOPY/bash" "$HOOK" 2>&1)"; rc=$?
check_eq "#1014 with no python3 it does not block" "0" "$rc"
check "#1014 and says it did not run" "DID NOT RUN" "$out"

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
