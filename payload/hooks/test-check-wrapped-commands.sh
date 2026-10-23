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
# Every refusal is recorded (claude-config#1492), so every case here records into a ledger of this
# suite's own, never the Mac's real one, whose counts decide how the refusal is narrowed.
export WRAPPED_REFUSAL_LEDGER_DIR="$WORKDIR/ledger"
LEDGER="$WRAPPED_REFUSAL_LEDGER_DIR/refusals.tsv"

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
# refused as not judged, saying so; one naming neither still passes in silence. The PATH holds every
# ordinary tool the refusal's record is written with (claude-config#1492) and lacks only python3.
NOPY="$WORKDIR/nopy"; mkdir -p "$NOPY"
for t in bash cat dirname sed awk tr head grep jq printf date mkdir hostname wc tail mv mktemp rm; do
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

# 4b. A note to the issue spool is data, not a command (claude-config#1574). `issue-spool.sh note`
# hands every argument after `note` to python as a string and runs none of them, so a finding whose
# quoted text names git, gh or rtk passes. Only that script, only that subcommand, only a call of it
# alone, and only where each of those words sits inside an argument quoted whole: everything else is
# refused exactly as before. Every command below is one an agent would run; none is run here.
SPOOL='~/.claude/hooks/lib/issue-spool.sh'
allowed "a spool note whose text says git push" "bash $SPOOL note . \"git push was refused, gh pr view and rtk too\" \"builder #1574\""
allowed "a spool note in single quotes" "bash $SPOOL note . 'the gh poll loop' 'builder #1574'"
allowed "a spool note naming git only in its reporter" "bash $SPOOL note . \"a finding\" \"git builder\""
allowed "a spool note through the absolute path" "bash $HOME/.claude/hooks/lib/issue-spool.sh note . \"git push\" \"builder\""
allowed "a real refused note from 2026-10-23, a quote inside the text" "bash $SPOOL note . \"gh's own fixed interval in 'gh pr checks --watch --interval 60', at ~/.claude/state/gh-poll/<session>/pause\" \"builder #1482\""
refused "the words outside the quotes" "bash $SPOOL note . git push \"builder\"" "bash"
refused "a word half quoted" "bash $SPOOL note . git\" push\" \"builder\"" "bash"
refused "a different script" "bash ~/.claude/skills/milestone/milestone-candidates.sh \"owner/repo\" --like \"a git push guard\"" "bash"
refused "the spool's other subcommands" "bash $SPOOL clear . \"git push\"" "bash"
refused "a script of the same name elsewhere" "bash ./issue-spool.sh note . \"git push\" \"builder\"" "bash"
refused "the spool's path through a variable" "bash \$HOME/.claude/hooks/lib/issue-spool.sh note . \"git push\" \"builder\"" "bash"
refused "a substitution inside the note" "bash $SPOOL note . \"\$(git push)\" \"builder\"" "bash"
refused "backticks inside the note" "bash $SPOOL note . \"\`git push\`\" \"builder\"" "bash"
refused "a quote that never closes" "bash $SPOOL note . \"git push \"x\" \"builder\"" "bash"
refused "a chained second command" "bash $SPOOL note . \"a finding\" \"builder\" && git push" "bash"
refused "a chained second command whose words are quoted" "bash $SPOOL note . \"x\" \"y\"; bash ./build.sh \"git\"" "bash"
refused "a note piped on" "bash $SPOOL note . \"git push\" \"builder\" | sh" "bash"
refused "an assignment before the spool" "CLAUDE_ISSUE_SPOOL_MIDCLEAR='git push' bash $SPOOL note . \"x\" \"y\"" "bash"
refused "a shell option before the spool" "bash -x $SPOOL note . \"git push\" \"builder\"" "bash"
refused "another shell running the spool" "sh $SPOOL note . \"git push\" \"builder\"" "sh"
refused "a note redirected" "bash $SPOOL note . \"git push\" \"builder\" > out.txt" "bash"
rm -rf "$WRAPPED_REFUSAL_LEDGER_DIR"
judge "bash $SPOOL note . \"git push was refused\" \"builder #1574\""
check_eq "#1574 a spool note that passes is not recorded as a refusal" "absent" "$([ -e "$LEDGER" ] && echo present || echo absent)"

# The scripts whose arguments are data are declared in one place, the guard, and a second entry is
# a decision to review, never a line to slip in: this fails until the test is changed with it.
declared="$(sed -n '/^DATA_ARGUMENT_SCRIPTS=(/,/^)/p' "$HOOK" | grep -c '^  "')"
check_eq "#1574 one script subcommand is declared as taking data, the spool's note" "1" "$declared"
check "#1574 and it is the spool's note" '  "~/.claude/hooks/lib/issue-spool.sh note"' "$(sed -n '/^DATA_ARGUMENT_SCRIPTS=(/,/^)/p' "$HOOK")"

# A reader that cannot judge the note is a refusal, never a pass: here it lacks the mode that reads
# the quoting, as an older shell-words.py installed beside a newer guard would.
OLDREADER="$WORKDIR/oldreader"; mkdir -p "$OLDREADER/lib"
cp "$HOOK" "$OLDREADER/"
cp "$DIR/lib/push-scope.sh" "$OLDREADER/lib/"
sed 's/mode == "data-blanked"/mode == "not-a-mode-1574"/' "$DIR/lib/shell-words.py" > "$OLDREADER/lib/shell-words.py"
out="$(payload "bash $SPOOL note . \"git push\" \"builder\"" | bash "$OLDREADER/check-wrapped-commands.sh" 2>&1)"; rc=$?
check_eq "#1574 a reader that cannot read the note's quoting refuses it" "2" "$rc"
out="$(payload "bash $SPOOL note . \"a finding\" \"builder\"" | bash "$OLDREADER/check-wrapped-commands.sh" 2>&1)"; rc=$?
check_eq "#1574 control: a note naming none of the three passes with that reader" "0|" "$rc|$out"

# 5. Every refusal is recorded (claude-config#1492): one tab separated line of time, Mac, wrapper,
# reason category and outcome, so how often the refusal fires, and on what, can be read after a week
# of real use. Never the command, never a path: a script file's name is somebody's content.
HOST_SHORT="$(hostname 2>/dev/null)"; HOST_SHORT="${HOST_SHORT%%.*}"
line_of(){ # the ledger's only line, or what is wrong with it
  local n
  n="$(grep -c . "$LEDGER" 2>/dev/null || true)"
  case "$n" in 1) cat "$LEDGER" ;; *) printf 'LEDGER HOLDS %s LINES' "${n:-no}" ;; esac
}
recorded(){ # recorded <name> <command> <wrapper> <reason category> [outcome]
  rm -rf "$WRAPPED_REFUSAL_LEDGER_DIR"
  judge "$2"
  local l now ts host wrapper reason outcome extra
  l="$(line_of)"
  IFS=$'\t' read -r ts host wrapper reason outcome extra <<< "$l"
  now="$(date +%s)"
  check_eq "#1492 recorded with the right wrapper, reason and outcome: $1" "$3|$4|${5:-refused}|" "$wrapper|$reason|$outcome|${extra:-}"
  check_eq "#1492 and on this Mac: $1" "$HOST_SHORT" "$host"
  case "$ts" in ''|*[!0-9]*) bad "#1492 and stamped with the time: $1 (got '$ts')" ;;
    *) if [ $((now - ts)) -ge 0 ] && [ $((now - ts)) -le 60 ]; then ok; else bad "#1492 and stamped with the time: $1 ($ts against $now)"; fi ;;
  esac
}
recorded "a variable" "CMD='git push --force'; bash -c \"\$CMD\"" "bash -c" variable
recorded "a quote never closed" "bash -c \"git push 'x\"" "bash -c" quote
recorded "a shell fed by a pipe" "echo 'git push' | sh" "sh" input
recorded "an eval that changes directory" "eval 'cd /tmp' && git push" "eval" eval-cd
recorded "wrapping too deep" "eval eval eval eval eval eval git push" "eval" depth
recorded "a script file" "bash ./secret-build-1492.sh && git push" "bash" script-file
recorded "find -execdir" "find . -name x -execdir git add {} \\;" "find -execdir" execdir
recorded "a find -exec never ended" "find . -exec git push" "find -exec" unended

# The script file's name and the command are nowhere in what was recorded.
rm -rf "$WRAPPED_REFUSAL_LEDGER_DIR"
judge "bash ./secret-build-1492.sh && git push origin private-branch-1492"
held="$(cat "$LEDGER" 2>/dev/null)"
check_eq "#1492 the record holds a line for the refusal" "1" "$(grep -c . "$LEDGER" 2>/dev/null || true)"
case "$held" in
  *secret-build*|*private-branch*|*"git push"*|*/*) bad "#1492 the record holds no command text and no path (got: $held)" ;;
  *) ok ;;
esac

# Each reason the reader can give has a category of its own, so a new one arriving in
# lib/shell-words.py with no category here fails this, rather than being counted as "other" for ever
# (L96). The eight cases above are one per reason.
whys="$(python3 -c 'import re, sys; print(len(re.findall(r"^WHY_[A-Z_]+ = ", open(sys.argv[1]).read(), re.M)))' "$DIR/lib/shell-words.py")"
check_eq "#1492 every reason the reader gives is one of the eight categories recorded above" "8" "$whys"

# An override is recorded as one, with what it overrode, and the command still runs in silence.
recorded "the override" "SKIP_WRAPPED_CHECK=1 bash -c \"\$CMD\" # git" "bash -c" variable overridden
check_eq "#1492 and the override still says nothing" "0|" "$rc|$out"

# What is not refused is not recorded.
rm -rf "$WRAPPED_REFUSAL_LEDGER_DIR"
judge "bash -c 'git push --force'"
judge "git status"
judge 'bash -c "$CMD"'
check_eq "#1492 nothing passed is recorded" "absent" "$([ -e "$LEDGER" ] && echo present || echo absent)"

# Refused as not judged is recorded too, under the wrapper the command names and why it was not.
rm -rf "$WRAPPED_REFUSAL_LEDGER_DIR"
out="$(payload "bash -c 'git push'" | bash "$LONE/check-wrapped-commands.sh" 2>&1)"; rc=$?
IFS=$'\t' read -r _ _ wrapper reason outcome <<< "$(line_of)"
check_eq "#1492 a refusal with no reader to judge it is recorded" "2|bash|reader-missing|refused" "$rc|$wrapper|$reason|$outcome"
rm -rf "$WRAPPED_REFUSAL_LEDGER_DIR"
nopy "eval 'git push'"
IFS=$'\t' read -r _ _ wrapper reason outcome <<< "$(line_of)"
check_eq "#1492 a refusal with no python3 is recorded" "2|eval|no-python3|refused" "$rc|$wrapper|$reason|$outcome"

# An unwritable record leaves the decision exactly as it was and says so, once (L95).
NOTDIR="$WORKDIR/not-a-dir"; : > "$NOTDIR"
out="$(payload "CMD='git push --force'; bash -c \"\$CMD\"" | WRAPPED_REFUSAL_LEDGER_DIR="$NOTDIR" bash "$HOOK" 2>&1)"; rc=$?
check_eq "#1492 an unwritable record still refuses" "2" "$rc"
check "#1492 and still says why" "variable or a substitution" "$out"
check_eq "#1492 and says, once, that the refusal could not be recorded" "1" "$(grep -o 'could not be recorded' <<< "$out" | grep -c .)"
out="$(payload "SKIP_WRAPPED_CHECK=1 bash -c \"\$CMD\" # git" | WRAPPED_REFUSAL_LEDGER_DIR="$NOTDIR" bash "$HOOK" 2>&1)"; rc=$?
check_eq "#1492 an unwritable record still lets the override run" "0" "$rc"
check_eq "#1492 and says, once, that the override could not be recorded" "1" "$(grep -o 'could not be recorded' <<< "$out" | grep -c .)"
out="$(payload "bash -c 'git push'" | WRAPPED_REFUSAL_LEDGER_DIR="$NOTDIR" bash "$LONE/check-wrapped-commands.sh" 2>&1)"; rc=$?
check_eq "#1492 an unwritable record still refuses what could not be judged" "2" "$rc"
check "#1492 and says that too" "could not be recorded" "$out"

# The record is capped: past its limit and a tenth more it keeps the newest lines, so it can never
# grow without bound, and it is not rewritten on every refusal below that.
rm -rf "$WRAPPED_REFUSAL_LEDGER_DIR"; mkdir -p "$WRAPPED_REFUSAL_LEDGER_DIR"
python3 -c 'import sys; [print("%d\tolder\tbash\tinput\trefused" % (1000 + i)) for i in range(int(sys.argv[1]))]' 11 > "$LEDGER"
out="$(payload "echo 'git push' | sh" | WRAPPED_REFUSAL_LEDGER_MAX=10 bash "$HOOK" 2>&1)"
check_eq "#1492 past the cap the record keeps the newest lines" "10" "$(grep -c . "$LEDGER")"
check "#1492 and the newest is the refusal just made" "$HOST_SHORT	sh	input	refused" "$(tail -n 1 "$LEDGER")"
check_eq "#1492 and the oldest went" "1002" "$(head -n 1 "$LEDGER" | cut -f 1)"
python3 -c 'import sys; [print("%d\tolder\tbash\tinput\trefused" % (1000 + i)) for i in range(int(sys.argv[1]))]' 5 > "$LEDGER"
out="$(payload "echo 'git push' | sh" | WRAPPED_REFUSAL_LEDGER_MAX=10 bash "$HOOK" 2>&1)"
check_eq "#1492 control: under the cap nothing is dropped" "6" "$(grep -c . "$LEDGER")"

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
