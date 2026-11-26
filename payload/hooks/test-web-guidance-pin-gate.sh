#!/usr/bin/env bash
# Tests for web-guidance-pin-gate.sh (claude-config#3565): a Bash command that runs the web guidance
# tool at any version but the pinned one is refused before it runs, in any spelling that runs it,
# and a command that only mentions the package is not.
#
# The hook never runs npx, so nothing here does either: each case hands the hook a PreToolUse
# payload and reads its exit code and what it said. The package is named in two halves, so this
# file is not itself a finding of tests/test-web-guidance-pin.sh.
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/web-guidance-pin-gate.sh"
NAME="modern-web-""guidance"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

pass=0; fail=0
ok(){ pass=$((pass + 1)); }
bad(){ fail=$((fail + 1)); echo "FAIL: $1"; }
check_eq(){ if [[ "$3" == "$2" ]]; then ok; else bad "$1 (expected '$2', got '$3')"; fi; }
check(){ if [[ "$3" == *"$2"* ]]; then ok; else bad "$1"; echo "  expected to contain: $2"; echo "  actual: ${3:0:1500}"; fi; }

command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 is not on PATH, so nothing was verified."; printf 'SUITE-RESULT passed=0 failed=1\n'; exit 1; }
[ -f "$HOOK" ] || { echo "FAIL: $HOOK is missing, so nothing refuses an unpinned run."; printf 'SUITE-RESULT passed=0 failed=1\n'; exit 1; }
PIN="$(python3 "$DIR/lib/web-guidance-pin.py" pin 2>&1)" || { echo "FAIL: the pin could not be read: $PIN"; printf 'SUITE-RESULT passed=0 failed=1\n'; exit 1; }

payload(){ # payload <command>
  python3 -c 'import json, sys; print(json.dumps({"tool_name": "Bash", "tool_input": {"command": sys.argv[1]}, "cwd": sys.argv[2]}))' "$1" "$WORKDIR"
}
judge(){ # judge <command> [hook]: sets out and rc
  out="$(payload "$1" | bash "${2:-$HOOK}" 2>&1)"; rc=$?
}
refused(){ # refused <name> <command>
  judge "$2"
  check_eq "refused: $1" "2" "$rc"
  check "and the refusal names the pinned command: $1" "npx -y $NAME@$PIN search" "$out"
}
allowed(){ # allowed <name> <command>
  judge "$2"
  check_eq "allowed: $1" "0" "$rc"
  check_eq "and nothing is said: $1" "" "$out"
}

# 1. Every spelling that runs another version, or none, is refused.
refused "@latest, as the rule file wrote it" "DISABLE_TELEMETRY=1 npx -y $NAME@latest search \"modal dialog\""
refused "@latest retrieve" "DISABLE_TELEMETRY=1 npx -y $NAME@latest retrieve \"dialog\""
refused "an older version" "DISABLE_TELEMETRY=1 npx -y $NAME@0.0.206 search \"x\""
refused "a newer version" "npx -y $NAME@99.0.0 search x"
refused "a version range" "npx -y $NAME@^1 search x"
refused "no version" "npx -y $NAME search x"
refused "npx with no -y" "npx $NAME@latest search x"
refused "after cd &&" "cd /tmp && DISABLE_TELEMETRY=1 npx -y $NAME@latest search x"
refused "behind env" "env DISABLE_TELEMETRY=1 npx -y $NAME@latest search x"
refused "behind rtk proxy" "rtk proxy npx -y $NAME@latest search x"
refused "inside bash -c" "bash -c 'npx -y $NAME@latest search x'"
refused "in a pipeline" "npx -y $NAME@latest search x | head -5"
refused "npm exec" "npm exec -y $NAME@latest -- search x"
refused "npx --package=" "npx --package=$NAME@latest modern-web search x"
refused "npx -p" "npx -p $NAME@latest modern-web search x"
refused "pnpm dlx" "pnpm dlx $NAME@latest search x"
refused "bunx" "bunx $NAME@latest search x"
refused "npm install" "npm install -g $NAME"
refused "the pinned one beside an unpinned one" "npx -y $NAME@$PIN search x && npx -y $NAME@latest retrieve y"

# 2. The pinned command, and commands that only mention the package, pass.
allowed "the pinned search" "DISABLE_TELEMETRY=1 npx -y $NAME@$PIN search \"modal dialog\""
allowed "the pinned retrieve" "DISABLE_TELEMETRY=1 npx -y $NAME@$PIN retrieve \"dialog\""
allowed "a grep for it" "grep -rn $NAME@latest ."
allowed "an echo of it" "echo npx -y $NAME@latest"
allowed "a commit message naming it" "git commit -m 'stop running npx -y $NAME@latest'"
allowed "npm view, which runs nothing" "npm view $NAME time --json"
allowed "npm diff, which runs nothing" "npm diff --diff=$NAME@$PIN --diff=$NAME@latest"
allowed "another package by npx" "npx -y prettier@3.3.3 --check ."
allowed "a command not naming it" "ls -la"

# 3. A gate that cannot read the command refuses, saying so, only when the package is named.
mkdir -p "$WORKDIR/hooks/lib"
cp "$HOOK" "$WORKDIR/hooks/"
python3 -B "$DIR/lib/install-hook-libs.py" "$DIR/lib" "$WORKDIR/hooks/lib" push-scope.sh shell-words.py \
  || bad "unread: lib/install-hook-libs.py could not install push-scope.sh and shell-words.py"
judge "npx -y $NAME@latest search x" "$WORKDIR/hooks/web-guidance-pin-gate.sh"
check_eq "unread: with lib/web-guidance-pin.py missing it refuses" "2" "$rc"
check "unread: and says the judge is missing" "web-guidance-pin.py, which holds the pin and judges the command, is missing" "$out"
judge "npx -y prettier@3.3.3 --check ." "$WORKDIR/hooks/web-guidance-pin-gate.sh"
check_eq "unread: a command not naming the package still passes" "0" "$rc"
python3 -B "$DIR/lib/install-hook-libs.py" "$DIR/lib" "$WORKDIR/hooks/lib" web-guidance-pin.py \
  || bad "unread: lib/install-hook-libs.py could not install web-guidance-pin.py"
judge "npx -y $NAME@latest search x" "$WORKDIR/hooks/web-guidance-pin-gate.sh"
check "unread: with the pin file missing it refuses, saying the pin could not be read" "could not judge it" "$out"
check_eq "unread: and exits 2" "2" "$rc"

out="$(printf '{"tool_name": "Bash", "tool_input": {"command": "npx %s@lat' "$NAME" | bash "$HOOK" 2>&1)"; rc=$?
check_eq "unread: a payload cut short that names the package is refused" "2" "$rc"

printf 'SUITE-RESULT passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
