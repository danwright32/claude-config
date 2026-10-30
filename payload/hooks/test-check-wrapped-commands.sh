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
LONE="$WORKDIR/lone"; mkdir -p "$LONE/lib"
cp "$HOOK" "$LONE/"
# Only the library each step names is missing: lib/whole-number.sh is there throughout (#1948).
cp "$DIR/lib/whole-number.sh" "$LONE/lib/"
out="$(payload "bash -c 'git push'" | bash "$LONE/check-wrapped-commands.sh" 2>&1)"; rc=$?
check_eq "#1478 with lib/push-scope.sh missing a wrapper beside git is refused" "2" "$rc"
check "#1478 and names the missing file" "lib/push-scope.sh" "$out"
# And the same for lib/whole-number.sh, which reads the ledger's size (#1948).
LONEW="$WORKDIR/lone-whole"; mkdir -p "$LONEW/lib"
cp "$HOOK" "$LONEW/"; cp "$DIR/lib/push-scope.sh" "$DIR/lib/shell-words.py" "$LONEW/lib/"
out="$(payload "bash -c 'git push'" | bash "$LONEW/check-wrapped-commands.sh" 2>&1)"; rc=$?
check_eq "#1948 with lib/whole-number.sh missing a wrapper beside git is refused" "2" "$rc"
check "#1948 and names the missing file" "lib/whole-number.sh" "$out"
out="$(payload "git status" | bash "$LONEW/check-wrapped-commands.sh" 2>&1)"; rc=$?
check_eq "#1948 control: with lib/whole-number.sh missing a command naming no wrapper passes in silence" "0|" "$rc|$out"
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
refused "a different script" "bash ~/.claude/skills/milestone/ensure-milestone.sh \"owner/repo\" \"a git push guard\"" "bash"
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

# 4c. The milestone duplicate check is data too (claude-config#1610). milestone-candidates.sh hands
# the repository to gh as --repo and into the path of a GET, the title to python as a string, and its
# other options to python's int(), gh's --limit, cat and a date pattern; it runs none of them and
# writes nothing but its own temp files. So the whole script is declared, every argument data, under
# the same rules as the spool's note: called alone, each of git, gh and rtk wholly inside a quoted
# argument. In front of it, and of nothing else, exactly one shape may stand: the account rule's
# GH_TOKEN=$(gh auth token -u <login>), with a plain login, to read another account's repository.
# Behind a declared call, its output may be piped into grep, head, tail or cut, which only read
# what they are given and print it; `2>&1` may stand before the first pipe. Nothing else follows.
MC='~/.claude/skills/milestone/milestone-candidates.sh'
allowed "the duplicate check, as the docs give it" "bash $MC \"danwright32/claude-config\" --like \"Stop the gh poll loop before git push\""
allowed "the duplicate check through the absolute path" "bash $HOME/.claude/skills/milestone/milestone-candidates.sh \"owner/repo\" --like \"an rtk rewrite\""
allowed "the duplicate check with the repository unquoted" "bash $MC danwright32/claude-config --like 'a gh issue title'"
allowed "the duplicate check with its other options" "bash $MC \"owner/repo\" --like \"a git title\" --closed-since 2026-10-01 --limit 500"
allowed "the duplicate check for another account" "GH_TOKEN=\$(gh auth token -u other-acct) bash $MC \"example-org/enrollment-tracker\" --like \"Delete the stale gh allow rules\""
allowed "another account, the absolute path" "GH_TOKEN=\$(gh auth token -u danwright32) bash $HOME/.claude/skills/milestone/milestone-candidates.sh \"o/r\" --like \"git\""
allowed "another account, a spool note" "GH_TOKEN=\$(gh auth token -u danwright32) bash $SPOOL note . \"git push\" \"builder #1610\""
# The two real refusals of the duplicate check, 2026-10-23, as they were run (the second with an
# invented account and repository standing for the real ones): each piped its output to grep.
allowed "a real refused duplicate check, piped to grep" "bash $MC \"danwright32/claude-config\" --like \"Stop the wrapped command guard refusing an issue spool note that mentions gh git or rtk\" 2>&1 | grep -E \"DUPLICATE|CLOSE-MATCH\""
allowed "the real refused check for another account, piped to grep" "GH_TOKEN=\$(gh auth token -u other-acct) bash $HOME/.claude/skills/milestone/milestone-candidates.sh \"example-org/enrollment-tracker\" --like \"Delete the stale wildcard allow rules from local Claude settings\" | grep -v -E \"^\\\\s+DESC\""
allowed "the check piped to head" "bash $MC \"o/r\" --like \"a gh title\" | head -20"
allowed "the check piped to tail" "bash $MC \"o/r\" --like \"a gh title\" | tail -n 5"
allowed "the check piped to cut" "bash $MC \"o/r\" --like \"a gh title\" | cut -c1-200"
allowed "the check piped through grep then head" "bash $MC \"o/r\" --like \"a gh title\" 2>&1 | grep -E 'DUPLICATE|CLOSE' | head -5"
allowed "a filter whose quoted pattern says gh" "bash $MC \"o/r\" --like \"x\" | grep 'gh pr'"
allowed "a spool note piped to tail" "bash $SPOOL note . \"git push\" \"builder\" | tail -1"
refused "the check piped to a shell" "bash $MC \"o/r\" --like \"gh\" | sh" "bash"
refused "the check piped to xargs" "bash $MC \"o/r\" --like \"gh\" | xargs gh issue close" "bash"
refused "the check piped to sed, which can write and run" "bash $MC \"o/r\" --like \"gh\" | sed -n '1p'" "bash"
refused "the check piped to awk, which can run" "bash $MC \"o/r\" --like \"gh\" | awk '{print}'" "bash"
refused "the check piped to tee, which writes" "bash $MC \"o/r\" --like \"gh\" | tee out.txt" "bash"
refused "the check piped to python" "bash $MC \"o/r\" --like \"gh\" | python3 -c 'print(1)'" "bash"
refused "a filter given by its path" "bash $MC \"o/r\" --like \"gh\" | /usr/bin/grep x" "bash"
refused "a filter redirected" "bash $MC \"o/r\" --like \"gh\" | grep x > out.txt" "bash"
refused "a filter with a substitution" "bash $MC \"o/r\" --like \"gh\" | grep \"\$(git push)\"" "bash"
refused "a filter chained to a push" "bash $MC \"o/r\" --like \"gh\" | grep x && git push" "bash"
refused "a filter followed by a second command" "bash $MC \"o/r\" --like \"gh\" | grep x; git push" "bash"
refused "an or in place of a pipe" "bash $MC \"o/r\" --like \"gh\" || git push" "bash"
refused "a pipe of stderr too" "bash $MC \"o/r\" --like \"gh\" |& grep x" "bash"
refused "an empty pipe" "bash $MC \"o/r\" --like \"gh\" |" "bash"
refused "an assignment before a filter" "bash $MC \"o/r\" --like \"gh\" | GH_TOKEN=x grep y" "bash"
refused "stderr sent elsewhere before the pipe" "bash $MC \"o/r\" --like \"gh\" 2>/dev/null | grep x" "bash"
refused "2>&1 after a filter" "bash $MC \"o/r\" --like \"gh\" | grep x 2>&1" "bash"
refused "a script piped into the check" "bash ./build.sh | bash $MC \"o/r\" --like \"gh\"" "bash"
judge "bash $MC \"o/r\" --like \"gh\" | sh"
check "#1610 a declared call in another shape is told the shapes it passes in" "passes only called alone, or piped into grep, head, tail or cut" "$out"
judge "bash $SPOOL clear . \"git push\""
check "#1610 a spool subcommand that is not declared is told which one is" "\`bash ~/.claude/hooks/lib/issue-spool.sh note\`, passes only called alone" "$out"
judge "bash ./build.sh && git push"
told=no; [[ $out == *"passes only called alone"* ]] && told=yes
check_eq "#1610 control: an undeclared script is refused but not told that" "2 no" "$rc $told"
refused "the check's words outside the quotes" "bash $MC \"owner/repo\" --like git push" "bash"
refused "a substitution in the check's title" "bash $MC \"owner/repo\" --like \"\$(git push)\"" "bash"
refused "a script of the check's name elsewhere" "bash ./milestone-candidates.sh \"owner/repo\" --like \"git push\"" "bash"
refused "the script beside it that writes" "bash ~/.claude/skills/milestone/ensure-milestone.sh \"owner/repo\" \"gh title\" --create-approved" "bash"
refused "the check chained to a push" "bash $MC \"owner/repo\" --like \"a title\" && git push" "bash"
refused "the check redirected" "bash $MC \"owner/repo\" --like \"gh\" > out.txt" "bash"
refused "the token with no account named" "GH_TOKEN=\$(gh auth token) bash $MC \"o/r\" --like \"gh\"" "bash"
refused "the token's account quoted" "GH_TOKEN=\$(gh auth token -u \"danwright32\") bash $MC \"o/r\" --like \"gh\"" "bash"
refused "the token's account a variable" "GH_TOKEN=\$(gh auth token -u \$USER) bash $MC \"o/r\" --like \"gh\"" "bash"
refused "the token's account a substitution" "GH_TOKEN=\$(gh auth token -u \$(whoami)) bash $MC \"o/r\" --like \"gh\"" "bash"
refused "the token's account starting with a hyphen" "GH_TOKEN=\$(gh auth token -u -x) bash $MC \"o/r\" --like \"gh\"" "bash"
refused "the token's account long form" "GH_TOKEN=\$(gh auth token --user danwright32) bash $MC \"o/r\" --like \"gh\"" "bash"
refused "the token from another host" "GH_TOKEN=\$(gh auth token -u danwright32 --hostname example.com) bash $MC \"o/r\" --like \"gh\"" "bash"
refused "a second command inside the token" "GH_TOKEN=\$(gh auth token -u danwright32; git push) bash $MC \"o/r\" --like \"gh\"" "bash"
refused "the token quoted" "GH_TOKEN=\"\$(gh auth token -u danwright32)\" bash $MC \"o/r\" --like \"gh\"" "bash"
refused "the token in backticks" "GH_TOKEN=\`gh auth token -u danwright32\` bash $MC \"o/r\" --like \"gh\"" "bash"
refused "a token from somewhere else" "GH_TOKEN=\$(cat token.txt) bash $MC \"o/r\" --like \"gh\"" "bash"
refused "a token written out" "GH_TOKEN=abc123 bash $MC \"o/r\" --like \"gh\"" "bash"
refused "another variable's token" "GITHUB_TOKEN=\$(gh auth token -u danwright32) bash $MC \"o/r\" --like \"gh\"" "bash"
refused "a second assignment after the token" "GH_TOKEN=\$(gh auth token -u danwright32) FOO=1 bash $MC \"o/r\" --like \"gh\"" "bash"
refused "an assignment before the token" "FOO=1 GH_TOKEN=\$(gh auth token -u danwright32) bash $MC \"o/r\" --like \"gh\"" "bash"
refused "the token twice" "GH_TOKEN=\$(gh auth token -u a) GH_TOKEN=\$(gh auth token -u b) bash $MC \"o/r\" --like \"gh\"" "bash"
refused "the token exported first" "export GH_TOKEN=\$(gh auth token -u danwright32); bash $MC \"o/r\" --like \"gh\"" "bash"
refused "the token before a different script" "GH_TOKEN=\$(gh auth token -u danwright32) bash ./build.sh \"gh\"" "bash"
refused "the token before another shell" "GH_TOKEN=\$(gh auth token -u danwright32) sh $MC \"o/r\" --like \"gh\"" "sh"
refused "the token before a shell option" "GH_TOKEN=\$(gh auth token -u danwright32) bash -x $MC \"o/r\" --like \"gh\"" "bash"
refused "the token before a substitution in the title" "GH_TOKEN=\$(gh auth token -u danwright32) bash $MC \"o/r\" --like \"\$(git push)\"" "bash"
rm -rf "$WRAPPED_REFUSAL_LEDGER_DIR"
judge "GH_TOKEN=\$(gh auth token -u other-acct) bash $MC \"o/r\" --like \"git push\" | grep x"
check_eq "#1610 a duplicate check that passes is not recorded as a refusal" "absent" "$([ -e "$LEDGER" ] && echo present || echo absent)"

# The scripts whose arguments are data are declared in one place, the guard, and another entry is
# a decision to review, never a line to slip in: this fails until the test is changed with it.
declared="$(sed -n '/^DATA_ARGUMENT_SCRIPTS=(/,/^)/p' "$HOOK" | grep -c '^  "')"
check_eq "#1610 two scripts are declared as taking data, the spool's note and the duplicate check" "2" "$declared"
check "#1574 one is the spool's note" '  "~/.claude/hooks/lib/issue-spool.sh note"' "$(sed -n '/^DATA_ARGUMENT_SCRIPTS=(/,/^)/p' "$HOOK")"
check "#1610 the other is the whole duplicate check" '  "~/.claude/skills/milestone/milestone-candidates.sh"' "$(sed -n '/^DATA_ARGUMENT_SCRIPTS=(/,/^)/p' "$HOOK")"

# The reader's module docstring is the list of every mode its main accepts, data-blanked included,
# so a mode added without its entry fails here rather than going unlisted.
unlisted="$(python3 -c '
import ast, re, sys
src = open(sys.argv[1]).read()
doc = ast.get_docstring(ast.parse(src)) or ""
print(" ".join(m for m in re.findall(r"mode == \"([a-z-]+)\"", src) if "shell-words.py " + m not in doc) or "none")' "$DIR/lib/shell-words.py")"
check_eq "#1574 every mode of lib/shell-words.py is listed in its docstring" "none" "$unlisted"

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
out="$(payload "GH_TOKEN=\$(gh auth token -u danwright32) bash $MC \"o/r\" --like \"a title\"" | bash "$OLDREADER/check-wrapped-commands.sh" 2>&1)"; rc=$?
check_eq "#1610 a reader that cannot read the duplicate check refuses it" "2" "$rc"
# And a reader from before #1610, which reads only "<path> <subcommand>" pairs and nothing in front:
# a whole script entry, or the token in front, is no match there, so it refuses rather than passes.
PRE1610="$WORKDIR/pre1610"; mkdir -p "$PRE1610/lib"
cp "$HOOK" "$PRE1610/"
cp "$DIR/lib/push-scope.sh" "$DIR/lib/whole-number.sh" "$PRE1610/lib/"
python3 -c '
import re, sys
src = open(sys.argv[1]).read()
# The #1574 data_blanked, as it shipped: path and subcommand both required, bash first, nothing before.
old = """def data_blanked(s, declared, home):
    words = _data_words(s)
    if not words or len(words) < 3 or words[0][0] != "bash" or not home.startswith("/"):
        return None
    raw_path, path, _ = words[1]
    if raw_path.startswith("~/"):
        path = home.rstrip("/") + raw_path[1:]
    for entry in declared:
        script, _, sub = entry.rpartition(" ")
        if not script.startswith("~/") or not sub:
            continue
        if path == home.rstrip("/") + script[1:] and words[2][1] == sub:
            kept = [w[0] for w in words[:3]] + ["\x27\x27" if whole else r for r, _, whole in words[3:]]
            return " ".join(kept)
    return None


def main("""
src = re.sub(r"def data_blanked\(.*?\n\n\ndef main\(", lambda m: old, src, count=1, flags=re.S)
open(sys.argv[2], "w").write(src)' "$DIR/lib/shell-words.py" "$PRE1610/lib/shell-words.py"
out="$(payload "bash $MC \"o/r\" --like \"git push\"" | bash "$PRE1610/check-wrapped-commands.sh" 2>&1)"; rc=$?
check_eq "#1610 a reader from before the duplicate check was declared refuses it" "2" "$rc"
out="$(payload "GH_TOKEN=\$(gh auth token -u danwright32) bash $SPOOL note . \"git push\" \"builder\"" | bash "$PRE1610/check-wrapped-commands.sh" 2>&1)"; rc=$?
check_eq "#1610 and refuses the token in front of a note" "2" "$rc"
out="$(payload "bash $SPOOL note . \"git push\" \"builder\"" | bash "$PRE1610/check-wrapped-commands.sh" 2>&1)"; rc=$?
check_eq "#1610 control: that reader still passes a plain note" "0" "$rc"

# 4d. A script run by its path, or sourced, is a script file run by a shell (claude-config#1623).
# `./build.sh && git push` runs the file's commands exactly as `bash ./build.sh && git push` does, and
# no gate reads the file either way, so it is refused beside git, gh or rtk the same. A path is any
# command word holding a slash, outside the directories programs are installed in, and not named git,
# gh or rtk (which every gate reads by that name); `source` and `.` run a file's commands in the shell
# itself. The declared scripts keep their declarations however they are run, by bash or by path.
#
# The guard answers most commands from the payload's text before the reader loads (RUNS_FILE_*), and
# a script run that text misses would pass unread, so every case refused here is also refused by a
# copy of the guard with no reader beside it: there, only reaching the reader can refuse.
LONE1623="$WORKDIR/lone1623"; mkdir -p "$LONE1623"
cp "$HOOK" "$LONE1623/"
refused_file(){ # refused_file <name> <command> <the script file the refusal names>
  judge "$2"
  check_eq "#1623 refused: $1" "2" "$rc"
  check "#1623 and the refusal names the script file: $1" "runs the script file $3," "$out"
  check "#1623 and offers the one command override: $1" "SKIP_WRAPPED_CHECK=1" "$out"
  out="$(payload "$2" | bash "$LONE1623/check-wrapped-commands.sh" 2>&1)"; rc=$?
  check_eq "#1623 and the fast path does not pass it over: $1" "2" "$rc"
}
refused_file "a script run by ./ beside a push" "./build.sh && git push" "./build.sh"
refused_file "a script run by ../ beside gh" "../tools/release.sh && gh pr create --fill" "../tools/release.sh"
refused_file "a relative path with no ./" "scripts/release.sh; git push" "scripts/release.sh"
refused_file "an absolute path outside the program directories" "/srv/someone-else/bin/deploy && git push" "/srv/someone-else/bin/deploy"
refused_file "a path under the home directory beside rtk" "~/bin/deploy.sh && rtk init -g" "~/bin/deploy.sh"
refused_file "a path through a variable" "\$HOME/bin/deploy.sh && git push" "\$HOME/bin/deploy.sh"
refused_file "a quoted path" "\"./build me.sh\" && git push" "./build me.sh"
refused_file "the script after the push" "git status && ./build.sh" "./build.sh"
refused_file "on a line of its own" "$(printf './build.sh\ngit push')" "./build.sh"
refused_file "behind nohup" "nohup ./build.sh & git push" "./build.sh"
refused_file "behind sudo with an option's value" "sudo -u bob ./build.sh; git push" "./build.sh"
refused_file "behind timeout" "timeout 30 ./build.sh && git push" "./build.sh"
refused_file "behind an assignment holding a space" "X=\"a b\" ./build.sh && git push" "./build.sh"
refused_file "behind the account rule's token" "GH_TOKEN=\$(gh auth token -u danwright32) ./build.sh" "./build.sh"
refused_file "as an if condition" "if ./check.sh; then git push; fi" "./check.sh"
refused_file "in a brace group" "{ ./build.sh; } && git push" "./build.sh"
refused_file "a braced variable's path" "\${HOME}/bin/deploy.sh && git push" "\${HOME}/bin/deploy.sh"
refused_file "a quoted variable then a path" "\"\$S\"/run.sh && git push" "\$S/run.sh"
refused_file "two dots then a name" "..hidden/run.sh && git push" "..hidden/run.sh"
refused_file "escaped by a backslash" "\\./build.sh && git push" "./build.sh"
refused_file "inside a substitution" "git commit -m \"\$(./message.sh)\"" "./message.sh"
refused_file "inside bash -c" "bash -c './build.sh && git push'" "./build.sh"
refused_file "run by find -exec" "find . -name '*.sh' -exec ./lint.sh {} \\; && git add -u" "./lint.sh"
refused_file "a temp directory is no program directory" "/tmp/x.sh && git push" "/tmp/x.sh"
refused_file "a program directory left by .." "/usr/bin/../../tmp/x.sh && git push" "/usr/bin/../../tmp/x.sh"
refused_file "a virtual environment's program" ".venv/bin/pytest && git commit -m 'tests'" ".venv/bin/pytest"
refused_file "sourced" "source ./env.sh && git push" "./env.sh"
refused_file "sourced by ." ". ./env.sh && git push" "./env.sh"
refused_file "sourced with no slash" "source env.sh && gh pr merge 7" "env.sh"
# The near miss #1610 dropped: no space before bash makes the token's value end in `bash`, and the
# declared script itself the command, behind an assignment the declaration does not accept.
refused_file "the token run together with bash" "GH_TOKEN=\$(gh auth token -u danwright32)bash $MC \"o/r\" --like \"gh\"" "$MC"
refused_file "a declared script run by path, chained to a push" "$SPOOL note . \"a finding\" \"builder\" && git push" "$SPOOL"
refused_file "a declared script run by path, its words unquoted" "$SPOOL note . git push \"builder\"" "$SPOOL"
refused_file "a declared script's other subcommand, run by path" "$SPOOL clear . \"git push\"" "$SPOOL"
refused_file "a declared script's name elsewhere, run by path" "./issue-spool.sh note . \"git push\" \"builder\"" "./issue-spool.sh"
refused_file "a declared script through a variable" "\$HOME/.claude/hooks/lib/issue-spool.sh note . \"git push\" \"builder\"" "\$HOME/.claude/hooks/lib/issue-spool.sh"
judge "$SPOOL clear . \"git push\""
check "#1623 a declared script run by path in another shape is told the shapes it passes in" "passes only called alone" "$out"
judge "./build.sh && git push"
check "#1623 a script refused is told it can run in a command of its own" "Run the script in a command of its own" "$out"
allowed "a declared note run by its path" "$SPOOL note . \"git push was refused\" \"builder #1623\""
allowed "a declared note by its absolute path" "$HOME/.claude/hooks/lib/issue-spool.sh note . \"gh pr view\" \"builder #1623\""
allowed "the duplicate check run by its path, piped to grep" "$MC \"o/r\" --like \"a gh title\" 2>&1 | grep DUPLICATE"
allowed "the duplicate check by path for another account" "GH_TOKEN=\$(gh auth token -u other-acct) $MC \"o/r\" --like \"git\""
allowed "git by its path" "/usr/bin/git status"
allowed "gh by its path" "/opt/homebrew/bin/gh pr list"
allowed "git by a path outside the program directories" "./vendor/bin/git status"
allowed "env by its path" "/usr/bin/env python3 x.py && git status"
allowed "a system program by its path" "/bin/ls /tmp && git status"
allowed "a Homebrew program by its path" "/opt/homebrew/bin/jq . x.json && git status"
allowed "a program in /usr/local/bin" "/usr/local/bin/node x.js && git status"
allowed "the command line tools' git" "/Library/Developer/CommandLineTools/usr/bin/git status"
allowed "a script by path naming none of the three" "./build.sh --fast"
allowed "paths as arguments" "git add ./build.sh scripts/x.sh && git -C /srv/x/repo status"
allowed "a path echoed" "echo ./build.sh && git status"
allowed "a path in a pipe's argument" "cat ~/x.txt | grep git"
allowed "a path inside a commit message" "git commit -m 'run ./build.sh first'"
allowed "a path in a heredoc body" "$(printf "git commit -F - <<'EOF'\n./build.sh\nEOF")"
allowed "a dot directory as an argument" "git add .claude/settings.json"
# Found replaying real commands: an array append is an assignment, never a command.
allowed "an array append holding a slash" "args+=(-only-testing:AppTests/CopyTests) && git status"
allowed "an array assignment holding a slash" "files=(src/a.ts src/b.ts) && git add \"\${files[@]}\""
allowed "the override, for one command" "SKIP_WRAPPED_CHECK=1 ./build.sh && git push"

# The cost stays flat: a command naming git with paths only as arguments is answered before the
# reader is loaded, so with the reader missing it still passes in silence, while one running a
# script by its path reaches the reader and, with none, is refused as not judged. The commonest
# passes measured on 30 days of real commands are among them: a jq program's parentheses, an
# assignment of a path, a URL or a path at the start of a line in a heredoc, `${x}/y` as an argument.
lone_passes(){ # lone_passes <name> <command>
  out="$(payload "$2" | bash "$LONE1623/check-wrapped-commands.sh" 2>&1)"; rc=$?
  check_eq "#1623 never loads the reader: $1" "0|" "$rc|$out"
}
lone_passes "a jq program" "gh pr list --json number,title --jq '.[] | (.number) | tostring'"
lone_passes "an assignment of a path" "S=/private/tmp/x/scratchpad && mkdir -p \$S && git status"
lone_passes "an assignment of a path after ;" "cd /x; S=/private/tmp/x && git status"
lone_passes "a URL at the start of a heredoc line" "$(printf "git commit -F - <<'EOF'\nhttps://github.com/o/r/pull/1\nEOF")"
lone_passes "a braced variable as an argument" "git -C \${HOME}/repo status"
lone_passes "arithmetic" "N=\$(( \$N / 2 )) && git status"
out="$(payload "git -C /srv/x/repo add ./src/a.ts && git commit -m 'x'" | bash "$LONE1623/check-wrapped-commands.sh" 2>&1)"; rc=$?
check_eq "#1623 paths only as arguments never load the reader" "0|" "$rc|$out"
out="$(payload "GH_TOKEN=\$(gh auth token -u danwright32) gh issue list --repo o/r" | bash "$LONE1623/check-wrapped-commands.sh" 2>&1)"; rc=$?
check_eq "#1623 nor does a gh call holding a slash behind the token" "0|" "$rc|$out"
out="$(payload "./build.sh && git push" | bash "$LONE1623/check-wrapped-commands.sh" 2>&1)"; rc=$?
check_eq "#1623 a script by path with the reader missing is refused as not judged" "2" "$rc"
check "#1623 and says it runs a script by its path" "runs a script by its path" "$out"
out="$(payload "sudo -u bob ./build.sh; git push" | bash "$LONE1623/check-wrapped-commands.sh" 2>&1)"; rc=$?
check_eq "#1623 the fast path sees a script behind a runner's option value" "2" "$rc"
out="$(payload "X=\"a b\" ./build.sh && git push" | bash "$LONE1623/check-wrapped-commands.sh" 2>&1)"; rc=$?
check_eq "#1623 the fast path sees a script behind an assignment holding a space" "2" "$rc"
out="$(payload ". ./env.sh && git push" | bash "$LONE1623/check-wrapped-commands.sh" 2>&1)"; rc=$?
check_eq "#1623 the fast path sees a sourced file" "2" "$rc"

# 4e. A script call declared read only (claude-config#1669). Dan, 2026-10-24, approving exactly this
# one: "Allow lesson only". `claude-sync lesson <id>` only reads LESSONS.md and prints one entry, so
# when it stands as a command of its own, by the live clone's path (~/ or the home directory written
# out), by bash or by its path, with nothing in front and one plain id after, it is no unread
# wrapper, and a gh call beside it is judged by the gates as usual. Every other subcommand of
# claude-sync commits, pushes or pulls, and stays refused beside git, gh or rtk.
CS='~/claude-config-sync/claude-sync'
allowed "a lesson read beside gh" "$CS lesson L174 && gh issue view 1669"
allowed "a lesson read after gh" "gh issue view 1669; $CS lesson L1001"
allowed "a lesson read by the home directory written out" "$HOME/claude-config-sync/claude-sync lesson L174 && gh pr view 7"
allowed "a lesson read run by bash" "bash $CS lesson L174 && gh issue view 1669"
allowed "a lesson read by its id" "$CS lesson 3f9a2b1c4d && gh issue view 1669"
allowed "a lesson read piped to a filter beside gh" "$CS lesson L174 | cut -c1-200; gh issue view 1669"
allowed "a lesson read with its errors kept" "$CS lesson L174 2>&1 && gh issue view 1669"
allowed "two lessons read beside gh" "$CS lesson L174; $CS lesson L1; gh issue view 1669"
rm -rf "$WRAPPED_REFUSAL_LEDGER_DIR"
judge "$CS lesson L174 && gh issue view 1669"
check_eq "#1669 a lesson read that passes is not recorded as a refusal" "absent" "$([ -e "$LEDGER" ] && echo present || echo absent)"
refused_file "claude-sync sync beside gh" "$CS sync && gh pr view 7" "$CS"
refused_file "claude-sync send beside gh" "$CS send && gh pr view 7" "$CS"
refused_file "claude-sync pull beside gh" "$CS pull; gh pr view 7" "$CS"
refused_file "claude-sync status beside gh" "$CS status && gh pr view 7" "$CS"
refused_file "claude-sync next-lesson beside gh" "$CS next-lesson && gh issue view 1" "$CS"
refused_file "claude-sync lesson-faults, a longer name, beside gh" "$CS lesson-faults && gh issue view 1" "$CS"
refused_file "claude-sync with no subcommand beside gh" "$CS && gh issue view 1" "$CS"
refused_file "a lesson read with no id" "$CS lesson && gh issue view 1" "$CS"
refused_file "a lesson read with a second argument" "$CS lesson L174 sync && gh issue view 1" "$CS"
refused_file "a lesson read whose id is a substitution" "$CS lesson \"\$(git push)\" && gh issue view 1" "$CS"
refused_file "a lesson read whose id is a variable" "$CS lesson \$N && gh issue view 1" "$CS"
refused_file "a lesson read behind an assignment" "SYNC_REPO=/srv/x $CS lesson L174 && gh issue view 1" "$CS"
refused_file "a lesson read behind BASH_ENV, which bash runs first" "BASH_ENV=./x.sh $CS lesson L174 && gh issue view 1" "$CS"
refused_file "a lesson read after BASH_ENV is exported" "export BASH_ENV=./x.sh; $CS lesson L174 && gh issue view 1" "$CS"
refused_file "a lesson read redirected into a file" "$CS lesson L174 > out.txt && gh issue view 1" "$CS"
refused_file "the development clone's copy" "./claude-sync lesson L174 && gh issue view 1" "./claude-sync"
refused_file "a claude-sync elsewhere" "~/elsewhere/claude-sync lesson L174 && gh issue view 1" "~/elsewhere/claude-sync"
refused_file "a lesson read beside an undeclared script" "$CS lesson L174 && ./build.sh && git push" "./build.sh"
refused "a lesson read run by sh" "sh $CS lesson L174 && gh issue view 1" "sh"
refused "a lesson read piped into a shell" "$CS lesson L174 | bash && gh issue view 1" "bash"
# The read only calls are declared in one place, and another is a decision for Dan, never a line to
# slip in: this fails until the test is changed with it.
read_only_block="$(sed -n '/^READ_ONLY_CALLS=(/,/^)/p' "$HOOK")"
read_only="$(grep -c '^  "' <<< "$read_only_block")"
check_eq "#1669 one call is declared read only, claude-sync lesson" "1" "$read_only"
check "#1669 it is the live clone's lesson" '  "~/claude-config-sync/claude-sync lesson"' "$read_only_block"

# 4f. A word inside a quoted title or body is no git command (claude-config#1699). A builder's
# `gh pr create` titled with the word git was refused on 2026-10-24; replayed through every Bash
# hook here it passes them all, and the refusal is Claude Code's own check on an agent isolated in a
# worktree. These hold this guard to never becoming a second source of it.
allowed "a pull request titled with the word git" "gh pr create --title \"Record git worktree state in the hand back\" --body-file /srv/x/pr-body.md"
allowed "a pull request titled with bash and git" "gh pr create --title \"Run bash checks on git hooks\" --body \"Closes #5\""
allowed "a pull request body naming a script and a push" "gh pr create --title \"Fix git\" --body \"Run ./build.sh, then bash -c and git push\""
allowed "a pull request body in a heredoc naming a script" "$(printf "gh pr create --title \"Stop git titles refusing\" --body \"\$(cat <<'EOF'\nCloses #1699\n./build.sh first, then git push\nbash x.sh\nEOF\n)\"")"
allowed "an issue comment naming eval and git" "gh issue comment 1699 --body 'eval and git and bash -c in a sentence'"

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
recorded "a script run by its path" "./secret-build-1623.sh && git push" "direct" script-file
recorded "a sourced file" ". ./secret-env-1623.sh && git push" "source" script-file

# The script file's name and the command are nowhere in what was recorded.
for held_cmd in "bash ./secret-build-1492.sh && git push origin private-branch-1492" \
  "./secret-build-1492.sh && git push origin private-branch-1492"; do
  rm -rf "$WRAPPED_REFUSAL_LEDGER_DIR"
  judge "$held_cmd"
  held="$(cat "$LEDGER" 2>/dev/null)"
  check_eq "#1492 the record holds a line for the refusal: $held_cmd" "1" "$(grep -c . "$LEDGER" 2>/dev/null || true)"
  case "$held" in
    *secret-build*|*private-branch*|*"git push"*|*/*) bad "#1492 the record holds no command text and no path (got: $held)" ;;
    *) ok ;;
  esac
done

# Each reason the reader can give has a category of its own, so a new one arriving in
# lib/shell-words.py with no category here fails this, rather than being counted as "other" for ever
# (L96). The first eight cases above are one per reason; the last two, a script run by its path and
# one sourced (claude-config#1623), share the script-file reason under wrappers of their own.
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
# Said as one valid JSON object whatever the note holds (claude-config#1906). The note names the
# record's path, so a path holding a newline and a tab is what broke the hand built object this
# used to print, and invalid output is a hook failure, which onFailure block turns into a refusal of
# the very override it meant to allow.
. "$DIR/lib/hook-notice.sh"
odd="$NOTDIR/line one
line two	tab"
json="$(payload "SKIP_WRAPPED_CHECK=1 bash -c \"\$CMD\" # git" | WRAPPED_REFUSAL_LEDGER_DIR="$odd" bash "$HOOK" 2>/dev/null)"; rc=$?
check_eq "#1906 a record path holding a newline still lets the override run" "0" "$rc"
check_eq "#1906 and says it could not be recorded as one valid systemMessage" "" "$(hook_notice_verdict "$json" 'could not be recorded in .*line one\nline two\ttab')"
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

# A byte that is not UTF-8 stops bash's =~ matching under a UTF-8 locale (claude-config#1885), so the
# fast path read the words after one as absent and passed the command before the reader loaded. Each
# case hands the hook such a byte in front of the words it looks for, written into the JSON raw, under
# en_US.UTF-8, and expects the verdict the same command gets without it. The copies with no reader
# (LONE, LONE1623) refuse whatever the fast path does not pass, so they judge the fast path alone.
BAD=$'\xff'
if LC_ALL=en_US.UTF-8 bash -c '[[ "$1" =~ git ]]' _ "${BAD}git"; then
  echo "SUITE-PART-UNMEASURED #1885 the fault itself: =~ under en_US.UTF-8 here matches past a byte that is not UTF-8, so the byte cases pass with or without the fix"
fi
raw_payload(){ printf '{"tool_name":"Bash","tool_input":{"command":"%s"},"cwd":"%s"}' "$1" "$WORKDIR"; }
utf8_run(){ # utf8_run <hook> <command>: sets out and rc
  out="$(raw_payload "$2" | LC_ALL=en_US.UTF-8 bash "$1" 2>&1)"; rc=$?
}
for c in "bash -c 'git push'" "eval x; echo ok; git status"; do
  utf8_run "$LONE/check-wrapped-commands.sh" "echo ok; $c"
  check_eq "#1885 control: with no reader the fast path passes on: $c" "2" "$rc"
  utf8_run "$LONE/check-wrapped-commands.sh" "echo $BAD; $c"
  check_eq "#1885 a byte that is not UTF-8 in front does not hide it from the fast path: $c" "2" "$rc"
done
utf8_run "$LONE/check-wrapped-commands.sh" "eval x; echo $BAD; git status"
check_eq "#1885 nor does one between the wrapper and git" "2" "$rc"
utf8_run "$LONE1623/check-wrapped-commands.sh" "echo $BAD; ./build.sh && git push"
check_eq "#1885 nor a script run by its path" "2" "$rc"
utf8_run "$HOOK" "echo $BAD; eval \$CMD && git status"
check_eq "#1885 with the reader, the command after the byte is judged and refused" "2" "$rc"
check "#1885 and the refusal names the wrapper" "\`eval\`" "$out"
utf8_run "$HOOK" "echo $BAD; git status"
check_eq "#1885 control: a byte in front of a command naming no wrapper still passes in silence" "0|" "$rc|$out"

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
