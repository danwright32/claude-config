#!/usr/bin/env bash
# Tests for check-zsh-builtins.sh and its judge zsh_builtin_gate.py (claude-config#2200): a Bash
# command whose `log`, in command position, would run zsh's own builtin rather than /usr/bin/log is
# refused before it runs, naming the fix, and every command that reaches the real tool, or only
# mentions the word, passes.
#
# Reproduced 2026-11-04 in the Bash tool on this Mac: `log show --last 1m 2>/dev/null | wc -l` printed
# 0 with exit 0, while `/usr/bin/log show --last 1m 2>/dev/null | wc -l` printed 15793. `whence -w log`
# says `log: builtin`, and any argument makes it print `(eval):log:1: too many arguments`.
#
# The hook never runs log, so nothing here does either: each case hands the hook a PreToolUse payload
# and reads its exit code and what it said. Every refused case is also run against a LOOSER copy of
# the judge whose predicate never fires, and must pass there (L1): that proves the refusal comes from
# the predicate, not from a reader that failed and refused everything.
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/check-zsh-builtins.sh"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

pass=0; fail=0
ok(){ pass=$((pass + 1)); }
bad(){ fail=$((fail + 1)); echo "FAIL: $1"; }
check_eq(){ if [[ "$3" == "$2" ]]; then ok; else bad "$1 (expected '$2', got '$3')"; fi; }
check(){ if [[ "$3" == *"$2"* ]]; then ok; else bad "$1"; echo "  expected to contain: $2"; echo "  actual: ${3:0:1500}"; fi; }

command -v python3 >/dev/null 2>&1 || { echo "test-check-zsh-builtins: python3 is not on PATH, so nothing was verified." >&2; exit 2; }
[ -f "$HOOK" ] || { bad "#2200 $HOOK does not exist"; printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"; exit 1; }

# The looser copy: the hook, its judge and its libraries, with the judge's predicate made to never
# fire. Checked to differ from the real judge, since a substitution that matched nothing would leave
# a copy identical to the original and every looser run would prove nothing (L100).
LOOSE="$WORKDIR/loose"; mkdir -p "$LOOSE/lib"
cp "$HOOK" "$DIR/zsh_builtin_gate.py" "$LOOSE/"
cp "$DIR/lib/shell-words.py" "$LOOSE/lib/"
python3 - "$LOOSE/zsh_builtin_gate.py" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace("def shadowed(words):\n", "def shadowed(words):\n    return None\n\n\ndef _was_shadowed(words):\n", 1)
open(p, "w").write(s)
PY
if cmp -s "$DIR/zsh_builtin_gate.py" "$LOOSE/zsh_builtin_gate.py"; then
  bad "#2200 the looser copy of the judge is identical to the real one, so def shadowed(words) was not found to loosen"
fi

payload(){ # payload <command>
  python3 -c 'import json, sys; print(json.dumps({"tool_name": "Bash", "tool_input": {"command": sys.argv[1]}, "cwd": sys.argv[2]}))' "$1" "$WORKDIR"
}
judge(){ # judge <command> [hook]: sets out and rc, as zsh runs the Bash tool on both Macs
  out="$(payload "$1" | SHELL=/bin/zsh bash "${2:-$HOOK}" 2>&1)"; rc=$?
}
refused(){ # refused <name> <command> <the fix the refusal must name>
  judge "$2"
  check_eq "#2200 refused: $1" "2" "$rc"
  check "#2200 and the refusal names the fix: $1" "$3" "$out"
  judge "$2" "$LOOSE/check-zsh-builtins.sh"
  check_eq "#2200 the looser copy, whose predicate never fires, lets it through: $1" "0|" "$rc|$out"
}
allowed(){ # allowed <name> <command>
  judge "$2"
  check_eq "#2200 allowed: $1" "0|" "$rc|$out"
}

# 1. Every spelling zsh runs as its builtin is refused, wherever the command stands.
refused "log show, the issue's own case" "log show --last 20m --predicate 'process == \"Google Chrome\"'" "/usr/bin/log show"
refused "log stream" "log stream --level debug" "/usr/bin/log stream"
refused "log collect" "log collect --last 1h" "/usr/bin/log collect"
refused "log config" "log config --status" "/usr/bin/log config"
refused "log stats, any argument fails the builtin" "log stats" "/usr/bin/log stats"
refused "an option only, any argument fails the builtin" "log -h" "/usr/bin/log"
refused "piped to wc, the control that exposed it" "log show --last 2m | wc -l" "/usr/bin/log show"
refused "errors hidden and piped to tail" "log show --last 1m 2>/dev/null | tail -5" "/usr/bin/log show"
refused "after cd &&" "cd /tmp && log show --last 1m" "/usr/bin/log show"
refused "after a semicolon" "true; log show" "/usr/bin/log show"
refused "after ||" "false || log show" "/usr/bin/log show"
refused "in a subshell" "(log show --last 1m)" "/usr/bin/log show"
refused "in a group" "{ log show; }" "/usr/bin/log show"
refused "in a command substitution" 'echo "$(log show --last 1m)"' "/usr/bin/log show"
refused "in a backquote substitution" 'x=`log show`' "/usr/bin/log show"
refused "in a substitution in an unquoted heredoc body" $'cat <<EOF\n$(log show)\nEOF' "/usr/bin/log show"
refused "behind an assignment" "FOO=1 log show" "/usr/bin/log show"
refused "behind a leading redirection" "2>/dev/null log show" "/usr/bin/log show"
refused "inside if" "if true; then log show; fi" "/usr/bin/log show"
refused "inside a for loop" "for i in 1; do log show; done" "/usr/bin/log show"
refused "on the second line" $'echo start\nlog show' "/usr/bin/log show"
refused "quoted name, which zsh still runs as the builtin" '"log" show' "/usr/bin/log show"
refused "backslashed name, which skips aliases but not builtins" '\log show' "/usr/bin/log show"
# Measured with zsh 5.9 on 2026-11-04: each of these still ran the builtin and printed nothing.
refused "behind time" "time log show" "/usr/bin/log show"
refused "behind builtin" "builtin log show" "/usr/bin/log show"
refused "behind noglob" "noglob log show" "/usr/bin/log show"
refused "behind nocorrect" "nocorrect log show" "/usr/bin/log show"
refused "behind exec" "exec log show" "/usr/bin/log show"
refused "behind the dash modifier" "- log show" "/usr/bin/log show"
# eval and zsh -c run it in zsh too; the innermost shell is the one that decides.
refused "through eval" "eval 'log show'" "/usr/bin/log show"
refused "in zsh -c" "zsh -c 'log show'" "/usr/bin/log show"
refused "in zsh -c inside bash -c" "bash -c 'zsh -c \"log show\"'" "/usr/bin/log show"

judge "log show --last 2m | wc -l"
check "#2200 the refusal says log is zsh's own builtin" "builtin" "$out"
check "#2200 and says what the builtin prints" "too many arguments" "$out"
check "#2200 and why it misleads" "no matching" "$out"
check "#2200 and offers command as the other fix" "command log" "$out"
check "#2200 and points at the issue" "claude-config#2200" "$out"

# 2. What reaches the real tool, or only mentions the word, passes in silence.
allowed "the full path" "/usr/bin/log show --last 20m"
allowed "the full path piped" "/usr/bin/log show --last 2m 2>/dev/null | wc -l"
allowed "behind command, which looks only for programs (measured)" "command log show --last 1m"
allowed "behind env, which runs the program" "env log show"
allowed "behind sudo" "sudo log collect --last 1h"
allowed "behind nohup" "nohup log stream &"
allowed "through xargs" "echo x | xargs log show"
allowed "in bash -c, where log is the program" "bash -c 'log show --last 1m'"
allowed "in sh -c" "sh -c 'log show'"
allowed "zsh -c inside, bash -c innermost" "zsh -c \"bash -c 'log show'\""
allowed "through find -exec, which runs the program" "find . -maxdepth 0 -exec log show \\;"
allowed "a bare log, which is the builtin and lists logins" "log"
allowed "a bare log with a redirection only" "log 2>/dev/null"
allowed "git log" "git log --oneline -5"
allowed "git log piped" "git log -1 --format=%H | head -1"
allowed "git log through rtk" "rtk git log -3"
allowed "git log after cd" "cd /tmp && git log -1"
allowed "a log file path" "tail -n 20 /var/log/system.log"
allowed "a relative log file" "cat ./build.log"
allowed "a script named log run by its path" "./log show"
allowed "echo of the words" "echo log show"
allowed "a quoted mention" 'echo "run log show to see it"'
allowed "a grep pattern" 'grep -n "log show" notes.md'
allowed "a commit message" 'git commit -m "Refuse a bare log show"'
allowed "a quoted heredoc body" $'cat <<\'EOF\'\nlog show\nEOF'
allowed "an unquoted heredoc body is text too" $'cat <<EOF\nlog show\nEOF'
allowed "a word that only starts with log" "logger hello"
allowed "a word that only ends with log" "blog show"
allowed "an ordinary command" "ls -la"

# 3. Another shell runs log as the program, so outside zsh nothing is refused.
out="$(payload "log show --last 1m" | SHELL=/bin/bash bash "$HOOK" 2>&1)"; rc=$?
check_eq "#2200 under bash, log show is the program and passes" "0|" "$rc|$out"
# Another tool's payload is not a shell command.
out="$(python3 -c 'import json; print(json.dumps({"tool_name": "Write", "tool_input": {"file_path": "/tmp/x", "content": "log show"}}))' | SHELL=/bin/zsh bash "$HOOK" 2>&1)"; rc=$?
check_eq "#2200 a Write naming log show is not judged" "0|" "$rc|$out"

# Built is not wired (L3): registered to see every Bash call before it runs, blocking on failure.
. "$DIR/lib/settings-file.sh"
SETTINGS="$(hook_settings_file "$DIR/..")"
wired="$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
print(sum(1 for m in d["hooks"].get("PreToolUse", []) if m.get("matcher") == "Bash"
          for h in m["hooks"] if h.get("command", "").endswith("/hooks/check-zsh-builtins.sh")
          and h.get("onFailure") == "block"))' "${SETTINGS:-/dev/null}")"
check_eq "#2200 registered once as a PreToolUse hook on Bash, blocking on failure" "1" "$wired"

# 4. With the reader missing the command cannot be read word by word. A command whose text puts log
# with an argument at the start of a command is refused as not judged; git log still passes.
LONE="$WORKDIR/lone"; mkdir -p "$LONE"
cp "$HOOK" "$DIR/zsh_builtin_gate.py" "$LONE/"
judge "log show --last 1m" "$LONE/check-zsh-builtins.sh"
check_eq "#2200 with lib/shell-words.py missing, log show is refused" "2" "$rc"
check "#2200 and says it could not be read word by word" "could not be read" "$out"
check "#2200 and names the missing file" "shell-words.py" "$out"
check "#2200 and still names the fix" "/usr/bin/log" "$out"
judge "cd /tmp && log show" "$LONE/check-zsh-builtins.sh"
check_eq "#2200 with the reader missing, log show after cd is refused" "2" "$rc"
judge "git log -1" "$LONE/check-zsh-builtins.sh"
check_eq "#2200 control: with the reader missing, git log passes in silence" "0|" "$rc|$out"

# With no python3 at all the wrapper reads the text the same crude way.
NOPY="$WORKDIR/nopy"; mkdir -p "$NOPY"
for t in bash; do
  p="$(command -v "$t" 2>/dev/null)" && [ -x "$p" ] && ln -sf "$p" "$NOPY/$t"
done
nopy(){ out="$(payload "$1" | SHELL=/bin/zsh PATH="$NOPY" "$NOPY/bash" "$HOOK" 2>&1)"; rc=$?; }
nopy "log show --last 1m"
check_eq "#2200 with no python3, log show is refused" "2" "$rc"
check "#2200 and says why it could not be read" "python3" "$out"
nopy "git log -1"
check_eq "#2200 control: with no python3, git log passes in silence" "0|" "$rc|$out"
nopy "ls -la"
check_eq "#2200 control: with no python3, a command naming no log passes in silence" "0|" "$rc|$out"

# A payload nothing can parse, naming log show at the start of the command, is refused.
out="$(printf '{"tool_name": "Bash", "tool_input": {"command": "log show --last 1m"' | SHELL=/bin/zsh bash "$HOOK" 2>&1)"; rc=$?
check_eq "#2200 an unparseable payload holding log show is refused" "2" "$rc"
check "#2200 and says the payload could not be read" "could not read the hook payload" "$out"

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
