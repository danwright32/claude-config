#!/usr/bin/env bash
# Tests for check-wrapped-commands.sh (claude-config#1478): a Bash command that names git, gh or rtk
# and hands a shell, eval or env -S a command nobody can read before it runs is refused, once, for
# every gate; a wrapped command that can be read passes here, since the gates themselves judge it
# through the shared reader, and so does an unreadable wrapper in a command naming none of the three.
#
# The hook runs nothing it is handed, so nothing here does either: each case hands the hook a
# PreToolUse payload and reads its exit code and what it said.
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/check-wrapped-commands.sh"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

pass=0; fail=0
ok(){ pass=$((pass + 1)); }
bad(){ fail=$((fail + 1)); echo "FAIL: $1"; }
check_eq(){ if [[ "$3" == "$2" ]]; then ok; else bad "$1 (expected '$2', got '$3')"; fi; }
check(){ if [[ "$3" == *"$2"* ]]; then ok; else bad "$1"; echo "  expected to contain: $2"; echo "  actual: ${3:0:1500}"; fi; }

command -v python3 >/dev/null 2>&1 || { echo "test-check-wrapped-commands: python3 is not on PATH, so nothing was verified." >&2; exit 2; }

payload(){ # payload <command>
  python3 -c 'import json, sys; print(json.dumps({"tool_name": "Bash", "tool_input": {"command": sys.argv[1]}, "cwd": sys.argv[2]}))' "$1" "$WORKDIR"
}
judge(){ # judge <command>: sets out and rc
  out="$(payload "$1" | bash "$HOOK" 2>&1)"; rc=$?
}
refused(){ # refused <name> <command> <the wrapper the refusal names>
  judge "$2"
  check_eq "#1478 refused: $1" "2" "$rc"
  check "#1478 and the refusal names the wrapper: $1" "\`$3\`" "$out"
  check "#1478 and offers the one command override: $1" "SKIP_WRAPPED_CHECK=1" "$out"
}
allowed(){ # allowed <name> <command>
  judge "$2"
  check_eq "#1478 allowed: $1" "0" "$rc"
  check_eq "#1478 and nothing is said: $1" "" "$out"
}

# 1. A wrapper whose command cannot be read, in a command naming git, gh or rtk, is refused.
refused "a variable holding the command bash -c runs" "CMD='git push --force'; bash -c \"\$CMD\"" "bash -c"
refused "sh -c of a substitution" "sh -c \"\$(cat cmd.txt)\" && git status" "sh -c"
refused "zsh -c of a variable after a literal command" "zsh -c \"set -e; \$CMD\" # git push" "zsh -c"
refused "eval of a variable" "PUSH='gh pr merge 7'; eval \"\$PUSH\"" "eval"
refused "eval of a variable naming rtk" "X='rtk init -g'; eval \"\$X\"" "eval"
refused "env -S of a variable" "env -S \"\$CMD\" # git" "env -S"
refused "a string holding a quote that never closes" "bash -c \"git push 'x\"" "bash -c"
refused "a shell fed a here string" "bash <<< 'git push --force'" "bash"
refused "a shell fed by a pipe" "echo 'git push' | sh" "sh"
refused "a shell fed a heredoc" "$(printf "bash <<'EOF'\ngit push --force\nEOF")" "bash"
refused "a shell fed a file" "bash < push.sh && git status" "bash"
refused "an eval that changes directory before a push" "eval 'cd /tmp' && git push" "eval"
refused "wrapping deeper than the reader reads" "eval eval eval eval eval eval git push" "eval"
refused "behind sudo and nohup" "sudo nohup bash -c \"\$CMD\" # gh" "bash -c"
refused "a shell running a script file beside git" "bash ./build.sh && git push" "bash"
refused "find -execdir, whose directory cannot be told" "find . -name x -execdir git add {} \\;" "find -execdir"
refused "find -exec that never ends" "find . -exec git push" "find -exec"
refused "watch of a variable" "watch -n 5 \"\$CMD\" # git" "watch"
refused "parallel reading its commands from its input" "parallel -j 4 < jobs.txt && git push" "parallel"

judge "CMD='git push --force'; bash -c \"\$CMD\""
check "#1478 the refusal says why it cannot be read" "variable or a substitution" "$out"
check "#1478 and which gates it is refused for" "push, commit, add, merge, issue and rtk gates" "$out"
check "#1478 and points at the issue" "claude-config#1478" "$out"
check "#1478 and says what to do instead" "Write out the command it runs in full" "$out"
judge "bash <<< 'git push'"
check "#1478 a shell fed its input says so" "reads its commands from its input" "$out"

# 2. What can be read passes here (the gates judge it), and so does what names no git, gh or rtk.
allowed "a wrapped push that can be read" "bash -c 'git push --force'"
allowed "eval of plain words" "eval git push"
allowed "a launcher" "nohup git push &"
allowed "find -exec that can be read" "find . -name '*.md' -exec git add {} +"
allowed "watch that can be read" "watch -n 5 'git status'"
allowed "script that can be read" "script -q /dev/null git push"
allowed "parallel that can be read" "parallel git push ::: origin upstream"
allowed "a script file in a command naming none of the three" "bash ./build.sh --fast"
allowed "a variable among the string's arguments" "bash -c \"git push origin \$BRANCH\""
allowed "an unreadable wrapper naming none of the three" 'eval "$(ssh-agent -s)"'
allowed "bash -c of a variable naming none of the three" 'bash -c "$CMD"'
allowed "a wrapper only mentioned by echo" "echo \"bash -c \\\"\\\$CMD\\\"\" && git status"
allowed "inside a commit message" "git commit -m 'eval \"\$CMD\" was refused'"
allowed "inside a heredoc body" "$(printf "git commit -F - <<'EOF'\nbash -c \"\$CMD\"\nEOF")"
allowed "a shell asked its version" "bash --version && git --version"
allowed "an ordinary git command" "git status"
allowed "an ordinary command" "ls -la"
allowed "the override, for one command" "SKIP_WRAPPED_CHECK=1 bash -c \"\$CMD\" # git"

# Built is not wired (L3): the hook is registered to see every Bash call before it runs. In the
# repository the hooks block is payload/settings.hooks.json; installed it is settings.json.
. "$DIR/lib/settings-file.sh"
SETTINGS="$(hook_settings_file "$DIR/..")"
wired="$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
print(sum(1 for m in d["hooks"].get("PreToolUse", []) if m.get("matcher") == "Bash"
          for h in m["hooks"] if h.get("command", "").endswith("/hooks/check-wrapped-commands.sh")))' "${SETTINGS:-/dev/null}")"
check_eq "#1478 registered once as a PreToolUse hook on Bash" "1" "$wired"

# 3. With no python3 the command cannot be read, so one naming a wrapper beside git, gh or rtk is
# refused as not judged, saying so; one naming neither still passes in silence.
NOPY="$WORKDIR/nopy"; mkdir -p "$NOPY"
for t in bash cat dirname sed awk tr head grep jq printf; do
  p="$(command -v "$t" 2>/dev/null)" && [ -x "$p" ] && ln -sf "$p" "$NOPY/$t"
done
nopy(){ out="$(payload "$1" | PATH="$NOPY" "$NOPY/bash" "$HOOK" 2>&1)"; rc=$?; }
nopy "bash -c 'git push'"
check_eq "#1478 with no python3 a wrapper beside git is refused" "2" "$rc"
check "#1478 and says it could not be read" "could not be read" "$out"
check "#1478 and offers the override" "SKIP_WRAPPED_CHECK=1" "$out"
nopy "SKIP_WRAPPED_CHECK=1 bash -c 'git push'"
check_eq "#1478 with no python3 the override still lets it run" "0|" "$rc|$out"
nopy "git status"
check_eq "#1478 control: with no python3 a command naming no wrapper passes in silence" "0|" "$rc|$out"

# 4. The shared reader missing is the same: refused as not judged, naming what is missing.
LONE="$WORKDIR/lone"; mkdir -p "$LONE"
cp "$HOOK" "$LONE/"
out="$(payload "bash -c 'git push'" | bash "$LONE/check-wrapped-commands.sh" 2>&1)"; rc=$?
check_eq "#1478 with lib/push-scope.sh missing a wrapper beside git is refused" "2" "$rc"
check "#1478 and names the missing file" "lib/push-scope.sh" "$out"
mkdir -p "$LONE/lib"; cp "$DIR/lib/push-scope.sh" "$LONE/lib/"
out="$(payload "bash -c 'git push'" | bash "$LONE/check-wrapped-commands.sh" 2>&1)"; rc=$?
check_eq "#1478 with lib/shell-words.py missing it is refused" "2" "$rc"
check "#1478 and names that file" "shell-words.py" "$out"
out="$(printf '{"tool_input": {"command": "bash -c git push"' | bash "$HOOK" 2>&1)"; rc=$?
check_eq "#1478 a payload nothing can read, naming a wrapper and git, is refused" "2" "$rc"
check "#1478 and says the payload could not be read" "could not read the hook payload" "$out"
out="$(payload "ls -la" | bash "$LONE/check-wrapped-commands.sh" 2>&1)"; rc=$?
check_eq "#1478 control: a command naming neither passes in silence even with the reader missing" "0|" "$rc|$out"

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
