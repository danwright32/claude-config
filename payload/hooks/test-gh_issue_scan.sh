#!/usr/bin/env bash
# Tests for gh_issue_scan.py, the shared parser behind the `gh issue create` completeness gates
# (claude-config#124).
#
# It is exercised end to end by test-require-issue-fields.sh, which is real coverage, but nothing
# tested it DIRECTLY and its own docstrings carry three dated incidents: a create on line 3 that
# was invisible because a newline is plain whitespace to the lexer, an override on line 1 that
# silently exempted a create three lines later, and `gh issue create --help` being blocked for
# having no category. Those are the cases a change to the splitting logic would break, and they are
# the ones a gate's own suite is least likely to reach, because it asks about the gate's verdict
# rather than about what the parser saw.
#
# Unreadable is its own outcome, never zero creates. The issue field gate refuses an unreadable
# command whose text names a command it judges, saying which quote and where (claude-config#1485),
# and passes one naming none. Either way the scanner must say unreadable, and where, rather than
# read it as nothing to judge.
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }

command -v python3 >/dev/null 2>&1 || { echo "test-gh_issue_scan: python3 is not on PATH, so nothing was verified." >&2; exit 2; }
[ -f "$DIR/gh_issue_scan.py" ] || { echo "test-gh_issue_scan: gh_issue_scan.py is not next to this suite." >&2; exit 2; }

# Every question is asked of the module itself, through one helper, so a check reads as the
# question it is asking rather than as python.
ask() { # ask <mode> <command>  -> one line of output
  PYTHONPATH="$DIR" python3 - "$1" "$2" <<'PY'
import sys
import gh_issue_scan as g

mode, cmd = sys.argv[1], sys.argv[2]
if mode == "writes":
    # Every file the command writes, as path:a for an append or w for a write, then :shown or :hidden.
    print(" ".join("%s:%s:%s" % (p, "a" if a else "w", "shown" if s else "hidden") for p, a, s in g.file_writes(cmd)))
    raise SystemExit
try:
    creates = g.scan_creates(cmd)
except g.Unreadable as e:
    print("UNREADABLE:%s" % e)
    raise SystemExit

if mode == "count":
    print(len(creates))
elif mode == "milestones":
    print("|".join(",".join(g.flag_values(a, "--milestone", "-m")) for a, _ in creates))
elif mode == "labels":
    print("|".join(",".join(g.flag_values(a, "--label", "-l")) for a, _ in creates))
elif mode == "titles":
    print("|".join(",".join(g.flag_values(a, "--title", "-t")) for a, _ in creates))
elif mode == "env":
    print("|".join(",".join(e) for _, e in creates))
elif mode == "found":
    # Each gh command that posts a body from a file, as sub act (#1435).
    print("|".join("%s %s" % kind for kind, _, _, _ in g.scan_gh_in_context(cmd, "/start", {}, g.BODY_FILE_COMMANDS)))
elif mode == "writesat":
    # Where each file the command writes lands, starting in /start (#1436).
    print("|".join(p or "NO" for _, _, _, p in g.file_writes_in_context(cmd, "/start", {"HOME": "/h"})))
elif mode == "bodyfile":
    # Where each create's --body-file resolves, starting in /start with only HOME=/h set (#1416).
    out = []
    for a, _, place in g.scan_creates_in_context(cmd, "/start", {"HOME": "/h"}):
        path, why = g.resolve_path(g.flag_values(a, "--body-file", "-F")[0], place)
        out.append(path or "NO:" + why)
    print("|".join(out))
PY
}

# ---------------------------------------------------------------------------
# Finding the creates. Each of these is a shape a real command really takes.
# ---------------------------------------------------------------------------
[ "$(ask count 'gh issue create --title x --label bug')" = "1" ] \
  && check "a plain create is found" ok || check "a plain create is found" "got $(ask count 'gh issue create --title x --label bug')"
[ "$(ask count 'echo hi && gh issue create -t x')" = "1" ] \
  && check "one after a shell operator is found" ok || check "one after a shell operator is found" "not found"
[ "$(ask count "$(printf 'echo one\ngh issue create -t x\necho three')")" = "1" ] \
  && check "one on its own LINE is found, which a lexer alone would miss" ok \
  || check "one on its own LINE is found, which a lexer alone would miss" "not found"
[ "$(ask count "$(printf 'gh issue create -t a \\\\\n  --label bug')")" = "1" ] \
  && check "one split across a line continuation is ONE create, not two" ok \
  || check "one split across a line continuation is ONE create, not two" "got $(ask count "$(printf 'gh issue create -t a \\\\\n  --label bug')")"
[ "$(ask count "$(printf 'gh issue create -t a\ngh issue create -t b')")" = "2" ] \
  && check "two on separate lines are both found" ok \
  || check "two on separate lines are both found" "got $(ask count "$(printf 'gh issue create -t a\ngh issue create -t b')")"

# gh takes the subcommand's flags in front of it, and rtk, env or sudo can stand in front of gh
# (claude-config#1188), read by lib/shell-words.py, the one reading every gate asks.
for c in 'gh -R o/x issue create -t x' 'gh issue -R o/x create -t x' 'gh --repo=o/x issue create -t x' \
         'rtk gh issue create -t x' 'env GH_TOKEN=x gh issue create -t x' 'sudo -u dan gh issue create -t x' \
         'env GH_TOKEN="a b" gh issue create -t x' 'sudo env X="$(echo y z)" gh issue -R o/x create -t x'; do
  [ "$(ask count "$c")" = "1" ] && check "#1188 a create is found: $c" ok || check "#1188 a create is found: $c" "got $(ask count "$c")"
done
[ "$(ask titles 'gh -R o/x issue --milestone M create -t "the title"')" = "the title" ] \
  && check "#1188 its flags are read wherever they stand" ok \
  || check "#1188 its flags are read wherever they stand" "got $(ask titles 'gh -R o/x issue --milestone M create -t "the title"')"
[ "$(ask milestones 'gh issue -m M create -t x')" = "M" ] \
  && check "#1188 a flag between issue and create is the create's own" ok \
  || check "#1188 a flag between issue and create is the create's own" "got $(ask milestones 'gh issue -m M create -t x')"
[ "$(ask count 'gh --title issue create -t x')" = "0" ] \
  && check "#1188 a flag in front takes the next word, as gh does, so this runs no create" ok \
  || check "#1188 a flag in front takes the next word, as gh does, so this runs no create" "got $(ask count 'gh --title issue create -t x')"

# ---------------------------------------------------------------------------
# And the things that only LOOK like creates. A gate that fires on these is a gate people learn to
# override.
# ---------------------------------------------------------------------------
[ "$(ask count 'echo "run gh issue create when you are ready"')" = "0" ] \
  && check "a create quoted inside a string is not one" ok || check "a create quoted inside a string is not one" "it counted one"
[ "$(ask count "$(printf 'cat <<EOF\ngh issue create -t x\nEOF')")" = "0" ] \
  && check "a create inside a heredoc body is not one" ok || check "a create inside a heredoc body is not one" "it counted one"
[ "$(ask count 'gh issue list && gh pr create -t x')" = "0" ] \
  && check "a different gh subcommand is not one" ok || check "a different gh subcommand is not one" "it counted one"
for flag in --help -h --web -w; do
  [ "$(ask count "gh issue create $flag")" = "0" ] \
    && check "'gh issue create $flag' files nothing, so it is not a create" ok \
    || check "'gh issue create $flag' files nothing, so it is not a create" "it counted one"
done
# The control: the same command WITHOUT the non filing flag is a create, so the checks above are
# not satisfied by a parser that stopped finding anything (L159).
[ "$(ask count 'gh issue create')" = "1" ] \
  && check "the control: a bare create still counts" ok || check "the control: a bare create still counts" "it counted none"

# ---------------------------------------------------------------------------
# Reading the flags off one create. All four forms gh accepts, because a gate reading only two of
# them refuses commands that were complete.
# ---------------------------------------------------------------------------
[ "$(ask milestones 'gh issue create --milestone Ungrouped')" = "Ungrouped" ] \
  && check "--flag value is read" ok || check "--flag value is read" "got $(ask milestones 'gh issue create --milestone Ungrouped')"
[ "$(ask milestones 'gh issue create --milestone=Ungrouped')" = "Ungrouped" ] \
  && check "--flag=value is read" ok || check "--flag=value is read" "got $(ask milestones 'gh issue create --milestone=Ungrouped')"
[ "$(ask milestones 'gh issue create -m Ungrouped')" = "Ungrouped" ] \
  && check "-f value is read" ok || check "-f value is read" "got $(ask milestones 'gh issue create -m Ungrouped')"
[ "$(ask milestones 'gh issue create -mUngrouped')" = "Ungrouped" ] \
  && check "-fvalue attached is read" ok || check "-fvalue attached is read" "got $(ask milestones 'gh issue create -mUngrouped')"
[ "$(ask labels 'gh issue create --label bug --label tech-debt')" = "bug,tech-debt" ] \
  && check "a flag given twice yields both values" ok || check "a flag given twice yields both values" "got $(ask labels 'gh issue create --label bug --label tech-debt')"
# `--label` must not be swallowed by the `-l` short form, which shares its first letter.
[ "$(ask labels 'gh issue create --label bug')" = "bug" ] \
  && check "a long flag is not mistaken for its own short form plus a value" ok \
  || check "a long flag is not mistaken for its own short form plus a value" "got $(ask labels 'gh issue create --label bug')"
# A flag with nothing after it, or another flag after it, contributes nothing: an EMPTY value must
# never satisfy a gate that is checking the field was filled in (L67).
[ -z "$(ask milestones 'gh issue create --milestone')" ] \
  && check "a flag with no value at all yields nothing" ok || check "a flag with no value at all yields nothing" "got something"
[ -z "$(ask milestones 'gh issue create --milestone --label bug')" ] \
  && check "a flag followed by another flag yields nothing" ok || check "a flag followed by another flag yields nothing" "got something"

# A '#' in a title must not swallow the rest of the command, or the flags after it vanish and a
# complete create is reported as missing everything.
[ "$(ask labels 'gh issue create --title "fixes #12 properly" --label bug')" = "bug" ] \
  && check "a hash inside a title does not eat the flags after it" ok \
  || check "a hash inside a title does not eat the flags after it" "got $(ask labels 'gh issue create --title "fixes #12 properly" --label bug')"

# ---------------------------------------------------------------------------
# An override belongs to the ONE command it prefixes. Reading it across the whole call is how an
# unmilestoned create slipped through on 2026-07-29.
# ---------------------------------------------------------------------------
two_seg="$(printf 'SKIP_MILESTONE_CHECK=1 gh issue create -t a\ngh issue create -t b')"
[ "$(ask env "$two_seg")" = "SKIP_MILESTONE_CHECK=1|" ] \
  && check "an override on the first create does not reach the second" ok \
  || check "an override on the first create does not reach the second" "got $(ask env "$two_seg")"
[ "$(ask env 'FOO=1 BAR=2 gh issue create -t a')" = "FOO=1,BAR=2" ] \
  && check "several env assignments in front of one create are all kept" ok \
  || check "several env assignments in front of one create are all kept" "got $(ask env 'FOO=1 BAR=2 gh issue create -t a')"

# ---------------------------------------------------------------------------
# What the command writes itself (claude-config#1246), so a gate judging a body file the same
# command writes reads it from the command, and stands down on what the command does not show.
# ---------------------------------------------------------------------------
writes_is() { # writes_is <description> <expected> <command>
  local got; got="$(ask writes "$3")"
  [ "$got" = "$2" ] && check "$1" ok || check "$1" "got [$got], wanted [$2]"
}
writes_is "a quoted heredoc is shown" "b.md:w:shown" "$(printf "cat > b.md <<'EOF'\nhi \$x\nEOF")"
writes_is "a backslash quoted heredoc is shown" "b.md:w:shown" "$(printf 'cat > b.md <<\\EOF\nhi $x\nEOF')"
writes_is "an unquoted heredoc that expands is hidden" "b.md:w:hidden" "$(printf 'cat > b.md <<EOF\nhi $x\nEOF')"
writes_is "an unquoted heredoc that expands nothing is shown" "b.md:w:shown" "$(printf 'cat > b.md <<EOF\nhi\nEOF')"
writes_is "a tab stripped heredoc closes on its indented delimiter" "b.md:w:shown c.md:w:hidden" "$(printf "cat > b.md <<-'EOF'\n\thi\n\tEOF\nbash x > c.md")"
writes_is "an append is told apart" "b.md:a:shown" "echo hi >> b.md"
writes_is "a here-string is shown" "b.md:w:shown" "cat > b.md <<< hi"
writes_is "cat of a file is hidden" "b.md:w:hidden" "cat a.md > b.md"
writes_is "tee writes its operands, appending with -a" "b.md:a:shown" "printf hi | tee -a b.md"
writes_is "a pipe carried onto the next line still feeds tee" "b.md:w:shown" "$(printf 'printf hi |\ntee b.md')"
writes_is "a heredoc opened on the last line has no body anyone showed" "b.md:w:hidden" "cat > b.md <<'EOF'"
writes_is "an fd duplication is not a file" "" "echo hi 2>&1"
writes_is "a heredoc inside a quoted body is not read as one" "" "gh issue create --body \"\$(cat <<'EOF'
hi > b.md
EOF
)\""

# ---------------------------------------------------------------------------
# Unreadable is its own answer, not zero creates. Zero means "nothing to gate" and lets the command
# through silently; unreadable is a fact the gate has to be able to act on (L11).
# ---------------------------------------------------------------------------
case "$(ask count 'gh issue create --title "unbalanced')" in
  UNREADABLE*) check "a command with unbalanced quotes is reported as unreadable" ok ;;
  *) check "a command with unbalanced quotes is reported as unreadable" "it answered $(ask count 'gh issue create --title "unbalanced') instead" ;;
esac
[ "$(ask count '')" = "0" ] \
  && check "an empty command is zero creates, not unreadable" ok || check "an empty command is zero creates, not unreadable" "got $(ask count '')"

# ---------------------------------------------------------------------------
# Where each create runs (claude-config#1416): the variables and directory the command sets before
# it, so a --body-file is read the way the shell will read it.
# ---------------------------------------------------------------------------
bf() { # bf <description> <expected> <command>
  local got; got="$(ask bodyfile "$3")"
  [ "$got" = "$2" ] && check "$1" ok || check "$1" "got [$got], expected [$2]"
}
bf "a relative path is read against the starting directory" "/start/b.md" 'gh issue create --body-file b.md'
bf "a cd moves it, relative to where the command is" "/start/x/b.md" 'cd x && gh issue create --body-file b.md'
bf "a variable set earlier in the command is followed" "/v/b.md" 'D=/v; gh issue create --body-file "$D/b.md"'
bf "each create sees only what came before it" '/start/b.md|/v/b.md' 'gh issue create --body-file "b.md"; D=/v; gh issue create -F "$D/b.md"'
bf "a subshell's assignment and cd end with it" "NO:\$D is not set in this command, nor in the environment every Bash call starts from (a variable set in an earlier Bash call, or in a shell profile without export, is gone by this one); if it is set where the command runs, re-run with SKIP_BODY_FILE_CHECK=1" '(D=/v; cd /w); gh issue create --body-file "$D/b.md"'
bf "home comes from the environment given" "/h/b.md" 'gh issue create --body-file ~/b.md'
bf "a substitution cannot be worked out" "NO:it holds an expansion the gate cannot work out without running the command" 'gh issue create --body-file "$(pwd)/b.md"'
bf "cd - leaves a relative path unresolved" "NO:it is relative, and the gate cannot tell which directory the command is in" 'cd - && gh issue create --body-file b.md'
# What cd -, pushd and popd go back to, when the command shows it (claude-config#1436).
bf "#1436 cd - goes back to the directory before the last cd" "/start/b.md" 'cd x && cd - && gh issue create --body-file b.md'
bf "#1436 cd - twice comes back again" "/start/x/b.md" 'cd x && cd - && cd - && gh issue create --body-file b.md'
bf "#1436 popd goes back to before the pushd" "/start/b.md" 'pushd x && popd && gh issue create --body-file b.md'
bf "#1436 the stack is a stack" "/a/b.md" 'pushd /a && pushd /b && popd && gh issue create --body-file b.md'
bf "#1436 a pushd inside a subshell ends with it" "NO:it is relative, and the gate cannot tell which directory the command is in" '(pushd /a); popd && gh issue create --body-file b.md'
bf "#1436 cd after a cd the gate cannot follow leaves cd - unknown" "NO:it is relative, and the gate cannot tell which directory the command is in" 'cd "$(pwd)/x" && cd /a && cd - && gh issue create --body-file b.md'
bf "#1436 the unset variable's reason says why the environment cannot help" "NO:\$D is not set in this command, nor in the environment every Bash call starts from (a variable set in an earlier Bash call, or in a shell profile without export, is gone by this one); if it is set where the command runs, re-run with SKIP_BODY_FILE_CHECK=1" 'gh issue create --body-file "$D/b.md"'

# Which gh commands post a body from a file (claude-config#1435): each one found, with its kind.
fd() { # fd <description> <expected> <command>
  local got; got="$(ask found "$3")"
  [ "$got" = "$2" ] && check "$1" ok || check "$1" "got [$got], expected [$2]"
}
fd "#1435 an issue create, edit and comment, and a pr create, edit and comment are all found" \
  "issue create|issue edit|issue comment|pr create|pr edit|pr comment" \
  'gh issue create -t a; gh issue edit 1 -F b; gh issue comment 1 -F c; gh pr create -F d; gh pr edit 2 -F e; gh pr comment 2 -F f'
fd "#1435 a merge, a review and a release are not" "" 'gh pr merge 1 -F a; gh pr review 1 -F b; gh release create v1 -F c'
fd "#1435 behind rtk and -R" "pr create" 'rtk gh -R o/x pr create -F d'
fd "#1435 --web hands the body to a person" "" 'gh pr create --web -F d'
[ "$(ask count 'gh issue edit 1 -F b; gh pr create -F d')" = "0" ] \
  && check "#1435 scan_creates still finds only issue creates" ok \
  || check "#1435 scan_creates still finds only issue creates" "got $(ask count 'gh issue edit 1 -F b; gh pr create -F d')"

# Where each write lands (claude-config#1436): the directory it was written from, not the create's.
wa() { # wa <description> <expected> <command>
  local got; got="$(ask writesat "$3")"
  [ "$got" = "$2" ] && check "$1" ok || check "$1" "got [$got], expected [$2]"
}
wa "#1436 a write before a cd lands where it was written" "/start/b.md" "$(printf "cat > b.md <<'EOF'\nx\nEOF\ncd sub && gh issue create -F ../b.md")"
wa "#1436 a write after a cd lands in that directory" "/start/sub/b.md" 'cd sub && echo x > b.md'
wa "#1436 a write through a variable the command set" "/v/b.md" 'D=/v; echo x > "$D/b.md"'
wa "#1436 a write in a subshell's cd, then one after it" "/start/sub/a.md|/start/b.md" '(cd sub && echo x > a.md) && echo y > b.md'
wa "#1436 a write through a substitution lands nowhere the gate can tell" "NO" 'D=$(mktemp -d); echo x > "$D/b.md"'
wa "#1436 tee writes land the same way" "/start/x/t.md" 'cd x; echo y | tee t.md'

# ---------------------------------------------------------------------------
# The fallback gh reader (claude-config#1449). gh_issue_scan.py carries a crude reader of gh of its
# own, used only when lib/shell-words.py cannot be loaded, and the body file gate leans on it in
# exactly that case, which nothing else runs. A copy of the scanner and the gate with no
# lib/shell-words.py beside them runs it; the real file is never touched. Every shape below is read
# by both copies and the two readings compared, then the gate is run from both copies and its
# answers compared.
# ---------------------------------------------------------------------------
FB_TMP="$(mktemp -d)"
trap 'rm -rf "$FB_TMP"' EXIT
FB="$FB_TMP/hooks"
mkdir -p "$FB/lib"
cp "$DIR/gh_issue_scan.py" "$DIR/issue_field_gate.py" "$DIR/require-issue-fields.sh" "$FB/"
cp "$DIR/lib/claude-session-line.sh" "$FB/lib/"
# A shell-words.py that is there but fails to load is the other way onto the fallback.
FB_BROKEN="$FB_TMP/broken"
mkdir -p "$FB_BROKEN/lib"
cp "$DIR/gh_issue_scan.py" "$FB_BROKEN/"
printf 'raise RuntimeError("broken on purpose")\n' > "$FB_BROKEN/lib/shell-words.py"

# The control: the copy really is on the fallback and the real one really is not, or every
# comparison below compares the shared reader with itself and passes (L1).
reader_of() { # reader_of <dir> -> shared or fallback
  python3 - "$1/gh_issue_scan.py" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("scan_under_test", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
# Asked of gh_command itself: the scanner names the half loaded module _sw before loading it fails,
# so whether _sw exists says nothing (seen 2026-10-21, when this control first read "shared" for both).
print("fallback" if m.gh_command.__module__ == m.__name__ else "shared")
PY
}
[ "$(reader_of "$DIR")" = "shared" ] && check "#1449 the real scanner reads gh with lib/shell-words.py" ok \
  || check "#1449 the real scanner reads gh with lib/shell-words.py" "got $(reader_of "$DIR")"
[ "$(reader_of "$FB")" = "fallback" ] && check "#1449 with lib/shell-words.py missing it uses its fallback" ok \
  || check "#1449 with lib/shell-words.py missing it uses its fallback" "got $(reader_of "$FB")"
[ "$(reader_of "$FB_BROKEN")" = "fallback" ] && check "#1449 with lib/shell-words.py failing to load it uses its fallback" ok \
  || check "#1449 with lib/shell-words.py failing to load it uses its fallback" "got $(reader_of "$FB_BROKEN")"

# The command shapes the shared reader is tested on above, and the shapes that put a flag of the
# subcommand in front of its action, where a reader of only the words after the action misses it.
FB_SHAPES=(
  'gh issue create --title x --label bug'
  'echo hi && gh issue create -t x'
  "$(printf 'echo one\ngh issue create -t x\necho three')"
  "$(printf 'gh issue create -t a \\\\\n  --label bug')"
  "$(printf 'gh issue create -t a\ngh issue create -t b')"
  'gh -R o/x issue create -t x'
  'gh issue -R o/x create -t x'
  'gh --repo=o/x issue create -t x'
  'rtk gh issue create -t x'
  'env GH_TOKEN=x gh issue create -t x'
  'sudo -u dan gh issue create -t x'
  'env GH_TOKEN="a b" gh issue create -t x'
  'sudo env X="$(echo y z)" gh issue -R o/x create -t x'
  'gh -R o/x issue --milestone M create -t "the title"'
  'gh issue -m M create -t x'
  'echo "run gh issue create when you are ready"'
  "$(printf 'cat <<EOF\ngh issue create -t x\nEOF')"
  'gh issue list && gh pr create -t x'
  'gh issue create --help'
  'gh issue create -h'
  'gh issue create --web'
  'gh issue create -w'
  'gh issue create'
  'gh issue create --milestone Ungrouped'
  'gh issue create --milestone=Ungrouped'
  'gh issue create -m Ungrouped'
  'gh issue create -mUngrouped'
  'gh issue create --label bug --label tech-debt'
  'gh issue create --milestone'
  'gh issue create --milestone --label bug'
  'gh issue create --title "fixes #12 properly" --label bug'
  "$(printf 'SKIP_MILESTONE_CHECK=1 gh issue create -t a\ngh issue create -t b')"
  'FOO=1 BAR=2 gh issue create -t a'
  'gh issue create --title "unbalanced'
  ''
  'cd x && gh issue create --body-file b.md'
  'D=/v; gh issue create --body-file "$D/b.md"'
  '(D=/v; cd /w); gh issue create --body-file "$D/b.md"'
  'gh issue create --body-file ~/b.md'
  'cd x && cd - && gh issue create --body-file b.md'
  'pushd /a && pushd /b && popd && gh issue create --body-file b.md'
  'gh issue create -t a; gh issue edit 1 -F b; gh issue comment 1 -F c; gh pr create -F d; gh pr edit 2 -F e; gh pr comment 2 -F f'
  'gh pr merge 1 -F a; gh pr review 1 -F b; gh release create v1 -F c'
  'rtk gh -R o/x pr create -F d'
  'gh pr create --web -F d'
  'gh issue --body-file b.md edit 5'
  'gh pr -F b.md create -t t'
  'gh -R o/x issue -F b.md comment 5'
  'gh pr create -t issue -b edit'
  'gh pr comment 5 --body "issue create" -F b.md'
  'gh issue view 5 -t comment'
  'gh release create v1 -t pr -n comment'
)
# Where the fallback reads MORE than the shared reader, which is its stated design: it does not know
# which of gh's flags take a value, nor what runs a command, so it takes a gh it cannot place as one
# that runs, and the gate asks rather than misses. Each is checked to read more, never less, and the
# gate to refuse there, never to pass.
FB_OVER_READ=(
  'gh --title issue create -t x'
  'echo gh issue create -t x'
)

fb_compare() { # fb_compare <shape>... -> one line per shape: SAME, MORE, or DIFF with both readings
  python3 - "$DIR/gh_issue_scan.py" "$FB/gh_issue_scan.py" "$@" <<'PY'
import importlib.util, sys

def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m

shared, fallback = load("scan_shared", sys.argv[1]), load("scan_fallback", sys.argv[2])

def reading(m, cmd):
    try:
        found = m.scan_gh_in_context(cmd, "/start", {"HOME": "/h"}, m.BODY_FILE_COMMANDS)
    except m.Unreadable as e:
        return "UNREADABLE:%s" % e
    return [(kind, args, envs, sorted(vars(place).items())) for kind, args, envs, place in found]

for cmd in sys.argv[3:]:
    a, b = reading(shared, cmd), reading(fallback, cmd)
    if a == b:
        print("SAME")
    elif isinstance(a, list) and isinstance(b, list) and all(x in b for x in a) and len(b) > len(a):
        print("MORE")
    else:
        print("DIFF shared=%r fallback=%r" % (a, b))
PY
}
fb_lines=()
while IFS= read -r line; do fb_lines+=("$line"); done < <(fb_compare "${FB_SHAPES[@]}")
[ "${#fb_lines[@]}" -eq "${#FB_SHAPES[@]}" ] && check "#1449 every shape was read by both copies" ok \
  || check "#1449 every shape was read by both copies" "${#fb_lines[@]} answers for ${#FB_SHAPES[@]} shapes"
for k in "${!FB_SHAPES[@]}"; do
  [ "${fb_lines[$k]:-}" = "SAME" ] && check "#1449 the fallback reads it as the shared reader does: ${FB_SHAPES[$k]}" ok \
    || check "#1449 the fallback reads it as the shared reader does: ${FB_SHAPES[$k]}" "${fb_lines[$k]:-no answer}"
done
fb_lines=()
while IFS= read -r line; do fb_lines+=("$line"); done < <(fb_compare "${FB_OVER_READ[@]}")
for k in "${!FB_OVER_READ[@]}"; do
  [ "${fb_lines[$k]:-}" = "MORE" ] && check "#1449 the fallback reads more here, never less: ${FB_OVER_READ[$k]}" ok \
    || check "#1449 the fallback reads more here, never less: ${FB_OVER_READ[$k]}" "${fb_lines[$k]:-no answer}"
done

# The gate's answer from each copy: the whole output, so a refusal for a different reason is caught
# as surely as a pass where the other refused.
FB_EMPTY="$FB_TMP/empty.md"; : > "$FB_EMPTY"
FB_PLAIN="$FB_TMP/plain.md"; printf 'a description\n' > "$FB_PLAIN"
FB_ALL='--milestone Ungrouped --label priority-p2 --label bug --body "## Open questions

None"'
gate_from() { # gate_from <hooks dir> <command> -> the gate's output
  printf '%s' "$2" | python3 -c 'import json, sys; json.dump({"tool_name": "Bash", "tool_input": {"command": sys.stdin.read()}}, sys.stdout)' \
    | env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CODE_BRIDGE_SESSION_ID bash "$1/require-issue-fields.sh" 2>&1
}
FB_GATE_SHAPES=(
  "gh issue create --title T $FB_ALL"
  'gh issue create --title T --label priority-p2 --label bug'
  'gh -R o/x issue create --title T --label priority-p2 --label bug'
  "gh -R o/x issue create --title T $FB_ALL"
  'gh issue -m Ungrouped create --title T --label priority-p2 --label bug --body "## Open questions

None"'
  'gh -R o/x issue create --help'
  "gh issue edit 5 --body-file $FB_EMPTY"
  "gh issue --body-file $FB_EMPTY edit 5"
  "gh -R o/x pr -F $FB_EMPTY create --title t"
  "rtk gh -R o/x pr create --title t --body-file $FB_EMPTY"
  "gh pr comment 5 -F $FB_EMPTY"
  "gh pr create --title t --body-file $FB_PLAIN"
  "gh issue --body-file $FB_PLAIN edit 5"
  "gh pr merge 5 --squash --body-file $FB_EMPTY"
  "gh pr create --help --body-file $FB_EMPTY"
  "gh issue create --title t --body-file $FB_TMP/never-written.md $FB_ALL"
  "gh pr create -t issue -b edit --body-file $FB_EMPTY"
)
for c in "${FB_GATE_SHAPES[@]}"; do
  shared="$(gate_from "$DIR" "$c")"; fallback="$(gate_from "$FB" "$c")"
  [ "$shared" = "$fallback" ] && check "#1449 the gate answers the same on the fallback: $c" ok \
    || check "#1449 the gate answers the same on the fallback: $c" "shared [${shared:0:160}] fallback [${fallback:0:160}]"
done
# The positive control on the gate: the comparison above is only worth something if these shapes
# include refusals as well as passes.
[[ "$(gate_from "$FB" "gh issue --body-file $FB_EMPTY edit 5")" == *'"deny"'* ]] \
  && check "#1449 the gate on the fallback refuses an empty body file written in front of the action" ok \
  || check "#1449 the gate on the fallback refuses an empty body file written in front of the action" "it passed"
for c in "${FB_OVER_READ[@]}"; do
  [[ "$(gate_from "$FB" "$c")" == *'"deny"'* && "$(gate_from "$DIR" "$c")" != *'"deny"'* ]] \
    && check "#1449 where the fallback reads more, the gate on it refuses: $c" ok \
    || check "#1449 where the fallback reads more, the gate on it refuses: $c" "shared and fallback did not split refuse and pass"
done

# ---------------------------------------------------------------------------
# A create another program runs (claude-config#1478): a shell's -c string, eval, env -S and the
# launchers, read by lib/shell-words.py (wrapped, RUNNERS). Each is found as the bare create is, its
# flags read from inside the string, and the gate refuses an incomplete one as it refuses it bare.
# ---------------------------------------------------------------------------
WRAPPED_CREATES=("bash -c 'gh issue create -t x -m M'" "sh -c \"gh issue create -t x -m M\"" "zsh -c 'gh issue create -t x -m M'"
                 "bash -lc 'gh issue create -t x -m M'" "eval 'gh issue create -t x -m M'" "eval gh issue create -t x -m M"
                 "env -S 'gh issue create -t x -m M'" "xargs gh issue create -t x -m M" "nohup gh issue create -t x -m M"
                 "time gh issue create -t x -m M" "nice -n 5 gh issue create -t x -m M" "timeout 30 gh issue create -t x -m M"
                 "caffeinate -i gh issue create -t x -m M" "command gh issue create -t x -m M"
                 "rtk proxy gh issue create -t x -m M" "sudo -u dan bash -c 'gh issue create -t x -m M'"
                 "echo hi && bash -c 'echo a; gh issue create -t x -m M'"
                 "find . -maxdepth 0 -exec gh issue create -t x -m M \\;" "watch -n 60 'gh issue create -t x -m M'"
                 "script -q /dev/null gh issue create -t x -m M" "parallel gh issue create -t x -m M ::: y")
for c in "${WRAPPED_CREATES[@]}"; do
  [ "$(ask count "$c")" = "1" ] && check "#1478 a wrapped create is found: $c" ok || check "#1478 a wrapped create is found: $c" "got $(ask count "$c")"
  [ "$(ask milestones "$c")" = "M" ] && check "#1478 and its flags are its own: $c" ok || check "#1478 and its flags are its own: $c" "got $(ask milestones "$c")"
done
[ "$(ask count "bash -c \"sh -c 'gh issue create -t x'\"")" = "1" ] \
  && check "#1478 a shell inside a shell" ok || check "#1478 a shell inside a shell" "not found"
[ "$(ask found "bash -c 'gh pr edit 3 --body-file b.md'")" = "pr edit" ] \
  && check "#1478 a body file command in a string is found" ok || check "#1478 a body file command in a string is found" "got $(ask found "bash -c 'gh pr edit 3 --body-file b.md'")"
[ "$(ask bodyfile "bash -c 'cd /x && gh issue create --body-file b.md'")" = "/x/b.md" ] \
  && check "#1478 a body file is read where the string runs" ok \
  || check "#1478 a body file is read where the string runs" "got $(ask bodyfile "bash -c 'cd /x && gh issue create --body-file b.md'")"
[ "$(ask bodyfile "cd /y && bash -c 'gh issue create --body-file b.md'")" = "/y/b.md" ] \
  && check "#1478 and where the wrapper runs" ok \
  || check "#1478 and where the wrapper runs" "got $(ask bodyfile "cd /y && bash -c 'gh issue create --body-file b.md'")"
# What only mentions one stays text, and a wrapper that cannot be read hides no create beside it:
# that one is check-wrapped-commands.sh's to refuse, never a reason to pass the rest.
for c in "echo \"bash -c 'gh issue create -t x'\"" "grep \"eval gh issue create\" notes.md" \
         "$(printf "cat <<'EOF'\nbash -c 'gh issue create -t x'\nEOF")"; do
  [ "$(ask count "$c")" = "0" ] && check "#1478 control: no create in: $c" ok || check "#1478 control: no create in: $c" "got $(ask count "$c")"
done
[ "$(ask count 'eval "$X"; gh issue create -t x')" = "1" ] \
  && check "#1478 an unreadable wrapper beside a create leaves the create found" ok \
  || check "#1478 an unreadable wrapper beside a create leaves the create found" "got $(ask count 'eval "$X"; gh issue create -t x')"
# The gate itself: an incomplete create is refused wrapped exactly as it is bare.
[[ "$(gate_from "$DIR" "gh issue create --title T")" == *'"deny"'* ]] \
  && check "#1478 control: the gate refuses the bare incomplete create" ok || check "#1478 control: the gate refuses the bare incomplete create" "it passed"
for c in "bash -c 'gh issue create --title T'" "eval gh issue create --title T" "nohup gh issue create --title T" \
         "rtk proxy gh issue create --title T" "xargs gh issue create --title T"; do
  [[ "$(gate_from "$DIR" "$c")" == *'"deny"'* ]] && check "#1478 the gate refuses it wrapped: $c" ok || check "#1478 the gate refuses it wrapped: $c" "it passed"
done

# ---------------------------------------------------------------------------
# A body in a command substitution inside double quotes (claude-config#1485). Of the 23 past commands
# on this Mac naming gh that the scanner could not read (of about 103,000 measured 2026-10-22), 19 were
# a --body "$(cat <<'EOF' ... EOF)" or "$(printf ...)" body holding an apostrophe or a double quote,
# which bash reads as one word and the lexer read as quotes never closed. They are read as one word.
# ---------------------------------------------------------------------------
HEREDOC_BODY="$(printf 'gh issue create --title T -m M --body "$(cat <<'"'"'EOF'"'"'\nIt says "couldn'"'"'t save" (twice).\n\n## Open questions\n\nNone\nEOF\n)"')"
[ "$(ask count "$HEREDOC_BODY")" = "1" ] && check "#1485 a heredoc body in \"\$(...)\" with an apostrophe and double quotes is read" ok \
  || check "#1485 a heredoc body in \"\$(...)\" with an apostrophe and double quotes is read" "got $(ask count "$HEREDOC_BODY")"
[ "$(ask milestones "$HEREDOC_BODY")" = "M" ] && check "#1485 and the create's flags are its own" ok \
  || check "#1485 and the create's flags are its own" "got $(ask milestones "$HEREDOC_BODY")"
PRINTF_BODY="gh pr create -t T --body \"\$(printf 'a test'\"'\"'s temp dir, \"%s\"' \"x\")\" && gh issue create -t U -m N"
[ "$(ask milestones "$PRINTF_BODY")" = "N" ] && check "#1485 a printf body in \"\$(...)\" with '\"'\"' is read, and the create after it found" ok \
  || check "#1485 a printf body in \"\$(...)\" with '\"'\"' is read, and the create after it found" "got $(ask milestones "$PRINTF_BODY")"
# What the shell itself cannot read stays unreadable, and says which quote and where (L11).
case "$(ask count "$(printf 'echo a\n# don'"'"'t\ngh issue create -t x')")" in
  *"line 2, column 6"*) check "#1485 an unreadable command names the quote's line and column" ok ;;
  *) check "#1485 an unreadable command names the quote's line and column" "got $(ask count "$(printf 'echo a\n# don'"'"'t\ngh issue create -t x')")" ;;
esac
case "$(ask count 'gh issue create --body "$(cat <<EOF')" in
  UNREADABLE*) check "#1485 a substitution never closed is still unreadable" ok ;;
  *) check "#1485 a substitution never closed is still unreadable" "got $(ask count 'gh issue create --body "$(cat <<EOF')" ;;
esac
# The gate on the fallback reader answers an unreadable command as it does on the shared one.
UNREAD_CREATE="$(printf '# don'"'"'t\ngh issue create --title T')"
shared="$(gate_from "$DIR" "$UNREAD_CREATE")"; fallback="$(gate_from "$FB" "$UNREAD_CREATE")"
[[ "$shared" == *'"deny"'* && "$shared" = "$fallback" ]] && check "#1485 the gate refuses an unreadable create on both readers alike" ok \
  || check "#1485 the gate refuses an unreadable create on both readers alike" "shared [${shared:0:160}] fallback [${fallback:0:160}]"

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
