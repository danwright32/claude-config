#!/usr/bin/env bash
# Tests for check-rtk-init.sh (claude-config#1468): a Bash command that runs `rtk init` is refused
# before it runs, in any spelling that runs it, and a command that only mentions it is not.
#
# Measured in claude-config#1446: `rtk init -g` deletes this config's rtk-rewrite.sh and its hash
# baseline, installs rtk's own hook with none of its refusals, and adds @RTK.md to CLAUDE.md. Dan
# decided on 2026-10-21 that both Macs stay on rtk 0.31.0 and nobody runs it.
#
# The hook never runs rtk, so nothing here does either: each case hands the hook a PreToolUse
# payload and reads its exit code and what it said.
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/check-rtk-init.sh"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

pass=0; fail=0
ok(){ pass=$((pass + 1)); }
bad(){ fail=$((fail + 1)); echo "FAIL: $1"; }
check_eq(){ if [[ "$3" == "$2" ]]; then ok; else bad "$1 (expected '$2', got '$3')"; fi; }
check(){ if [[ "$3" == *"$2"* ]]; then ok; else bad "$1"; echo "  expected to contain: $2"; echo "  actual: ${3:0:1500}"; fi; }

command -v python3 >/dev/null 2>&1 || { echo "test-check-rtk-init: python3 is not on PATH, so nothing was verified." >&2; exit 2; }

payload(){ # payload <command>
  python3 -c 'import json, sys; print(json.dumps({"tool_name": "Bash", "tool_input": {"command": sys.argv[1]}, "cwd": sys.argv[2]}))' "$1" "$WORKDIR"
}
judge(){ # judge <command>: sets out and rc
  out="$(payload "$1" | bash "$HOOK" 2>&1)"; rc=$?
}
refused(){ # refused <name> <command>
  judge "$2"
  check_eq "#1468 refused: $1" "2" "$rc"
  check "#1468 and the refusal offers the one command override: $1" "SKIP_RTK_INIT_CHECK=1" "$out"
}
allowed(){ # allowed <name> <command>
  judge "$2"
  check_eq "#1468 allowed: $1" "0" "$rc"
  check_eq "#1468 and nothing is said: $1" "" "$out"
}

# 1. Every spelling that runs rtk init is refused.
refused "rtk init, bare" "rtk init"
refused "rtk init -g" "rtk init -g"
refused "rtk init --global --auto-patch" "rtk init --global --auto-patch"
refused "rtk init --uninstall" "rtk init -g --uninstall"
refused "rtk init for another agent" "rtk init --agent cursor"
refused "rtk's own option in front of init" "rtk -v init -g"
refused "after cd &&" "cd /tmp && rtk init -g"
refused "after a semicolon" "git status; rtk init"
refused "after ||" "false || rtk init -g"
refused "in a subshell" "(cd /tmp && rtk init -g)"
refused "in a command substitution" 'echo "$(rtk init -g)"'
refused "inside if" "if true; then rtk init -g; fi"
refused "on the second line of the command" "$(printf 'echo start\nrtk init -g')"
refused "by its path under the home folder" "~/.local/bin/rtk init -g"
refused "by a path built from HOME, quoted" '"$HOME/.local/bin/rtk" init'
refused "by an absolute path" "/opt/homebrew/bin/rtk init --auto-patch"
refused "behind command" "command rtk init"
refused "behind env" "env rtk init -g"
refused "behind env with a setting" "env RTK_TELEMETRY_DISABLED=1 rtk init -g"
refused "behind an inline assignment" "HOME=/tmp/x rtk init -g"
refused "behind sudo" "sudo rtk init"
refused "behind exec" "exec rtk init"
refused "--show beside a flag that writes" "rtk init --show --auto-patch"
# A quote never closed leaves only the crude cut at every separator, which still holds the init.
refused "after a quote never closed, read by the crude cut" "echo don't; rtk init -g"

judge "rtk init -g"
check "#1468 the refusal says what rtk init does to this config" "deletes" "$out"
check "#1468 and names the hook it deletes" "rtk-rewrite.sh" "$out"
check "#1468 and points at the measurement" "claude-config#1446" "$out"
check "#1468 and at the decision" "claude-config#1468" "$out"
check "#1468 and names the read only form that is allowed" "rtk init --show" "$out"

# 2. What only reads, or only mentions it, passes.
allowed "rtk init --show only reads" "rtk init --show"
allowed "rtk init -g --show" "rtk init -g --show"
allowed "rtk -v init --show" "rtk -v init --show"
allowed "rtk init --help" "rtk init --help"
allowed "rtk init -h" "rtk init -h"
allowed "a mention inside echo" 'echo "rtk init"'
allowed "a mention in grep's pattern" 'grep -n "rtk init" notes.md'
allowed "a commit message naming it" 'git commit -m "Refuse rtk init, which replaces our rtk hook"'
allowed "a heredoc body naming it" "$(printf "git commit -F - <<'EOF'\nrtk init -g\nEOF")"
allowed "git's own init through rtk" "rtk git init"
allowed "git init" "git init"
allowed "another rtk subcommand" "rtk gain"
allowed "rtk rewrite of a command naming init" 'rtk rewrite "rtk init -g"'
allowed "an ordinary command" "ls -la"
allowed "the override, for one command" "SKIP_RTK_INIT_CHECK=1 rtk init -g"

# Built is not wired (L3): the hook is registered to see every Bash call before it runs. In the
# repository the hooks block is payload/settings.hooks.json; installed it is settings.json.
. "$DIR/lib/settings-file.sh"
SETTINGS="$(hook_settings_file "$DIR/..")"
check_eq "#1468 a settings file holding the hooks block is beside the hooks" "yes" \
  "$([ -n "$SETTINGS" ] && echo yes || echo "neither settings.hooks.json nor settings.json beside $DIR")"
wired="$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
print(sum(1 for m in d["hooks"].get("PreToolUse", []) if m.get("matcher") == "Bash"
          for h in m["hooks"] if h.get("command", "").endswith("/hooks/check-rtk-init.sh")))' "${SETTINGS:-/dev/null}")"
check_eq "#1468 registered once as a PreToolUse hook on Bash" "1" "$wired"

# 3. With no python3 the command cannot be read. The harm here is the loss of the hook, so a command
# whose text names both rtk and init is refused as not judged, saying so, rather than let through;
# one that names neither still passes in silence.
NOPY="$WORKDIR/nopy"; mkdir -p "$NOPY"
for t in bash cat dirname sed awk tr head grep jq printf; do
  p="$(command -v "$t" 2>/dev/null)" && [ -x "$p" ] && ln -sf "$p" "$NOPY/$t"
done
nopy(){ out="$(payload "$1" | PATH="$NOPY" "$NOPY/bash" "$HOOK" 2>&1)"; rc=$?; }
nopy "rtk init -g"
check_eq "#1468 with no python3 a command naming rtk init is refused" "2" "$rc"
check "#1468 and says it could not be judged" "could not be read" "$out"
check "#1468 and offers the override" "SKIP_RTK_INIT_CHECK=1" "$out"
nopy "SKIP_RTK_INIT_CHECK=1 rtk init -g"
check_eq "#1468 with no python3 the override still lets it run" "0|" "$rc|$out"
nopy "ls -la"
check_eq "#1468 control: with no python3 a command naming neither passes in silence" "0|" "$rc|$out"

# 4. The shared reader missing is the same: refused as not judged, naming what is missing.
LONE="$WORKDIR/lone"; mkdir -p "$LONE"
cp "$HOOK" "$LONE/"
out="$(payload "rtk init -g" | bash "$LONE/check-rtk-init.sh" 2>&1)"; rc=$?
check_eq "#1468 with lib/push-scope.sh missing a command naming rtk init is refused" "2" "$rc"
check "#1468 and names the missing file" "lib/push-scope.sh" "$out"
check "#1468 and the remedy" "claude-sync pull" "$out"
mkdir -p "$LONE/lib"; cp "$DIR/lib/push-scope.sh" "$LONE/lib/"
out="$(payload "rtk init -g" | bash "$LONE/check-rtk-init.sh" 2>&1)"; rc=$?
check_eq "#1468 with lib/shell-words.py missing it is refused" "2" "$rc"
check "#1468 and names that file" "shell-words.py" "$out"
out="$(printf '{"tool_input": {"command": "rtk init -g"' | bash "$HOOK" 2>&1)"; rc=$?
check_eq "#1468 a payload nothing can read, naming rtk init, is refused" "2" "$rc"
check "#1468 and says the payload could not be read" "could not read the hook payload" "$out"
out="$(payload "ls -la" | bash "$LONE/check-rtk-init.sh" 2>&1)"; rc=$?
check_eq "#1468 control: a command naming neither passes in silence even with the reader missing" "0|" "$rc|$out"

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
