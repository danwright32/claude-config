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
# With no reader (claude-config#1449, #2059). The scanner finds every command with lib/shell-words.py
# and keeps no reading of its own, so when that file is missing or fails to load it reads nothing:
# every command is unreadable, saying the reader could not be loaded, and the gate refuses any command
# naming a command it judges, as it refuses any command it cannot read. It fails closed, a decision of
# #2059: the crude reader it carried before could misread what the shared one reads, so a command the
# gate refuses could pass whenever the reader was gone. A copy of the scanner and the gate with no
# lib/shell-words.py beside them, and one with a shell-words.py that fails to load, run it; the real
# file is never touched.
# ---------------------------------------------------------------------------
FB_TMP="$(mktemp -d)"
trap 'rm -rf "$FB_TMP"' EXIT
FB="$FB_TMP/hooks"
mkdir -p "$FB/lib"
cp "$DIR/gh_issue_scan.py" "$DIR/issue_field_gate.py" "$DIR/require-issue-fields.sh" "$FB/"
cp "$DIR/lib/claude-session-line.sh" "$FB/lib/"
FB_BROKEN="$FB_TMP/broken"
mkdir -p "$FB_BROKEN/lib"
cp "$DIR/gh_issue_scan.py" "$DIR/issue_field_gate.py" "$DIR/require-issue-fields.sh" "$FB_BROKEN/"
cp "$DIR/lib/claude-session-line.sh" "$FB_BROKEN/lib/"
printf 'raise RuntimeError("broken on purpose")\n' > "$FB_BROKEN/lib/shell-words.py"

# The control: each copy really has no reader and the real one really has it, or every check below
# asks the shared reader and passes (L1).
reader_of() { # reader_of <dir> -> shared or missing
  python3 - "$1/gh_issue_scan.py" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("scan_under_test", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
print("missing" if m.READER_ERROR else "shared")
PY
}
[ "$(reader_of "$DIR")" = "shared" ] && check "#1449 the real scanner reads commands with lib/shell-words.py" ok \
  || check "#1449 the real scanner reads commands with lib/shell-words.py" "got $(reader_of "$DIR")"
[ "$(reader_of "$FB")" = "missing" ] && check "#1449 with lib/shell-words.py missing it has no reader" ok \
  || check "#1449 with lib/shell-words.py missing it has no reader" "got $(reader_of "$FB")"
[ "$(reader_of "$FB_BROKEN")" = "missing" ] && check "#1449 with lib/shell-words.py failing to load it has no reader" ok \
  || check "#1449 with lib/shell-words.py failing to load it has no reader" "got $(reader_of "$FB_BROKEN")"

# A create in a substitution in the body of a heredoc whose end marker is unquoted is run by the
# shell, so it is a create (claude-config#2053). A quoted marker keeps the body text.
count_in() { # count_in <dir> <command> -> how many creates that copy of the scanner finds
  python3 - "$1/gh_issue_scan.py" "$2" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("scan_under_test", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
try:
    print(len(m.scan_creates(sys.argv[2])))
except m.Unreadable as e:
    print("UNREADABLE:%s" % e)
PY
}
HD_C='gh issue create -t x'
[ "$(count_in "$DIR" $'cat <<EOF\nfiled $('"$HD_C"$')\nEOF')" = 1 ] && check "#2053 a create in an unquoted heredoc body's substitution is seen" ok \
  || check "#2053 a create in an unquoted heredoc body's substitution is seen" "got $(count_in "$DIR" $'cat <<EOF\nfiled $('"$HD_C"$')\nEOF')"
[ "$(count_in "$DIR" $'cat <<\'EOF\'\nfiled $('"$HD_C"$')\nEOF')" = 0 ] && check "#2053 control, a quoted body is text" ok \
  || check "#2053 control, a quoted body is text" "got $(count_in "$DIR" $'cat <<\'EOF\'\nfiled $('"$HD_C"$')\nEOF')"
[ "$(count_in "$DIR" $'cat <<E"OF"\nb\nEOF\n'"$HD_C")" = 1 ] && check "#2053 a create after a partly quoted marker's body is seen" ok \
  || check "#2053 a create after a partly quoted marker's body is seen" "got $(count_in "$DIR" $'cat <<E"OF"\nb\nEOF\n'"$HD_C")"
# A backquote left open in an unquoted body is a substitution bash refuses to run (measured on bash
# 3.2, 2026-11-02: it prints the error and runs nothing in the body), so the command is unreadable,
# and the gate refuses it because its text names the create.
case "$(count_in "$DIR" $'cat <<EOF\ndon`t\n'"$HD_C"$'\nEOF')" in
  UNREADABLE*) check "#2053 a body the reader cannot read is unreadable, never zero creates" ok ;;
  *) check "#2053 a body the reader cannot read is unreadable, never zero creates" "got $(count_in "$DIR" $'cat <<EOF\ndon`t\n'"$HD_C"$'\nEOF')" ;;
esac
[ "$(count_in "$DIR" $'cat <<EOF\n${X:-$('"$HD_C"$')}\nEOF')" = 1 ] && check "#2053 a create in a substitution inside \${ } in an unquoted body is seen" ok \
  || check "#2053 a create in a substitution inside \${ } in an unquoted body is seen" "got $(count_in "$DIR" $'cat <<EOF\n${X:-$('"$HD_C"$')}\nEOF')"
[ "$(count_in "$DIR" $'cat <<EOF\nno substitution, just '"$HD_C"$'\nEOF')" = 0 ] && check "#2053 control: an unquoted body with no substitution is text" ok \
  || check "#2053 control: an unquoted body with no substitution is text" "seen as a create"


# The command shapes the shared reader is tested on above, and the shapes that put a flag of the
# subcommand in front of its action.
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
# Shapes a crude reading would take for a create that runs.
FB_OVER_READ=(
  'gh --title issue create -t x'
  'echo gh issue create -t x'
)

# With no reader every shape above is unreadable, naming the reader, whatever it holds; the empty
# command alone is nothing to read.
no_reader() { # no_reader <dir> <shape>... -> one line per shape: MISSING, NONE, or what it read
  python3 - "$1/gh_issue_scan.py" "${@:2}" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("scan_no_reader", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
for cmd in sys.argv[2:]:
    try:
        found = m.scan_gh_in_context(cmd, "/start", {"HOME": "/h"}, m.BODY_FILE_COMMANDS)
    except m.Unreadable as e:
        print("MISSING" if "lib/shell-words.py could not be loaded" in str(e) else "OTHER:%s" % e)
        continue
    print("NONE" if not cmd.strip() and found == [] else "READ:%r" % (found,))
try:
    m.file_writes("cat > b.md <<'EOF'\nx\nEOF")
    print("WRITES READ")
except m.Unreadable as e:
    print("WRITES MISSING" if "lib/shell-words.py could not be loaded" in str(e) else "WRITES OTHER:%s" % e)
PY
}
for d in "$FB" "$FB_BROKEN"; do
  name="${d#"$FB_TMP"/}"
  nr_lines=()
  nr_out="$(no_reader "$d" "${FB_SHAPES[@]}" "${FB_OVER_READ[@]}")"
  while IFS= read -r line; do [ -n "$line" ] && nr_lines+=("$line"); done <<NR_OUT
$nr_out
NR_OUT
  all=("${FB_SHAPES[@]}" "${FB_OVER_READ[@]}")
  [ "${#nr_lines[@]}" -eq "$(( ${#all[@]} + 1 ))" ] && check "#2059 $name: every shape was asked" ok \
    || check "#2059 $name: every shape was asked" "${#nr_lines[@]} answers for ${#all[@]} shapes and the write"
  for k in "${!all[@]}"; do
    want=MISSING; [ -z "${all[$k]}" ] && want=NONE
    [ "${nr_lines[$k]:-}" = "$want" ] && check "#2059 $name: with no reader it reads nothing: ${all[$k]}" ok \
      || check "#2059 $name: with no reader it reads nothing: ${all[$k]}" "${nr_lines[$k]:-no answer}"
  done
  [ "${nr_lines[${#all[@]}]:-}" = "WRITES MISSING" ] && check "#2059 $name: with no reader the writes are unreadable too" ok \
    || check "#2059 $name: with no reader the writes are unreadable too" "${nr_lines[${#all[@]}]:-no answer}"
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
# Every shape the gate refuses with its reader, it refuses without one; and without one it refuses
# every shape naming a create that files or a body file, the two things it judges, saying the reader
# could not be loaded. It passes what names neither, so it is not refusing everything.
FB_PASSES=('gh -R o/x issue create --help' "gh pr merge 5 --squash --body-file $FB_EMPTY" 'gh issue list' 'echo hi')
for d in "$FB" "$FB_BROKEN"; do
  name="${d#"$FB_TMP"/}"
  for c in "${FB_GATE_SHAPES[@]}" "${FB_OVER_READ[@]}"; do
    case " ${FB_PASSES[*]} " in *" $c "*) continue ;; esac
    out="$(gate_from "$d" "$c")"
    [[ "$out" == *'"deny"'* && "$out" == *'lib/shell-words.py could not be loaded'* ]] \
      && check "#2059 $name: with no reader the gate refuses, naming the reader: $c" ok \
      || check "#2059 $name: with no reader the gate refuses, naming the reader: $c" "got [${out:0:200}]"
  done
  for c in "${FB_PASSES[@]}"; do
    out="$(gate_from "$d" "$c")"
    [[ "$out" != *'"deny"'* ]] && check "#2059 $name: with no reader the gate passes what names nothing it judges: $c" ok \
      || check "#2059 $name: with no reader the gate passes what names nothing it judges: $c" "got [${out:0:200}]"
  done
done
# The control: the shapes include ones the gate refuses with its reader, and ones it passes.
[[ "$(gate_from "$DIR" "gh issue --body-file $FB_EMPTY edit 5")" == *'"deny"'* ]] \
  && check "#1449 control: the gate refuses an empty body file written in front of the action" ok \
  || check "#1449 control: the gate refuses an empty body file written in front of the action" "it passed"
[[ "$(gate_from "$DIR" "gh pr create --title t --body-file $FB_PLAIN")" != *'"deny"'* ]] \
  && check "#1449 control: the gate passes a body file with a description" ok \
  || check "#1449 control: the gate passes a body file with a description" "it refused"

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
# What the shell itself cannot read stays unreadable, and says which quote and where (L11). The
# quote is a real one: a # after a blank starts a comment, where a lone quote is only text, so the
# fixture this replaces (`# don't` on line 2) was a command bash reads (claude-config#2059).
case "$(ask count "$(printf 'echo a\necho don'"'"'t\ngh issue create -t x')")" in
  *"line 2, column 9"*) check "#1485 an unreadable command names the quote's line and column" ok ;;
  *) check "#1485 an unreadable command names the quote's line and column" "got $(ask count "$(printf 'echo a\necho don'"'"'t\ngh issue create -t x')")" ;;
esac
[ "$(ask count "$(printf 'echo a\n# don'"'"'t\ngh issue create -t x')")" = "1" ] \
  && check "#2059 a quote inside a comment is text, so the create after it is found" ok \
  || check "#2059 a quote inside a comment is text, so the create after it is found" "got $(ask count "$(printf 'echo a\n# don'"'"'t\ngh issue create -t x')")"
case "$(ask count 'gh issue create --body "$(cat <<EOF')" in
  UNREADABLE*) check "#1485 a substitution never closed is still unreadable" ok ;;
  *) check "#1485 a substitution never closed is still unreadable" "got $(ask count 'gh issue create --body "$(cat <<EOF')" ;;
esac
case "$(ask count 'gh issue create -t x \')" in
  UNREADABLE*"backslash"*) check "#1485 a command ending in a lone backslash is unreadable, and says so" ok ;;
  *) check "#1485 a command ending in a lone backslash is unreadable, and says so" "got $(ask count 'gh issue create -t x \')" ;;
esac
# The gate refuses an unreadable create, with its reader and without one, each saying why.
UNREAD_CREATE="$(printf 'echo don'"'"'t\ngh issue create --title T')"
shared="$(gate_from "$DIR" "$UNREAD_CREATE")"; missing="$(gate_from "$FB" "$UNREAD_CREATE")"
[[ "$shared" == *'"deny"'* && "$shared" == *"line 1, column 9"* ]] && check "#1485 the gate refuses an unreadable create, naming the quote" ok \
  || check "#1485 the gate refuses an unreadable create, naming the quote" "got [${shared:0:200}]"
[[ "$missing" == *'"deny"'* && "$missing" == *"lib/shell-words.py could not be loaded"* && "$missing" != *"Close that quote"* ]] \
  && check "#2059 with no reader the gate refuses it, naming the reader, not a quote" ok \
  || check "#2059 with no reader the gate refuses it, naming the reader, not a quote" "got [${missing:0:200}]"

# ---------------------------------------------------------------------------
# One reading of the command (claude-config#2059). The scanner finds its commands with the shared
# reader, lib/shell-words.py's commands(), so it sees a create that a substitution runs, in double
# quotes or backquotes, and reads every heredoc end marker as the shell does, a partly quoted or
# hyphenated one included. Its own readings missed the first (measured 2026-11-01) and misread the
# second: `<<'E'OF` and `<<E"OF"` were read as the marker E and `<<END-OF` as END.
# ---------------------------------------------------------------------------
for c in 'echo "$(gh issue create -t x -m M)"' 'echo `gh issue create -t x -m M`' 'echo "`gh issue create -t x -m M`"' \
         'X="$(gh issue create -t x -m M)"; echo "$X"' 'echo "made $(echo a; gh issue create -t x -m M)"'; do
  [ "$(ask milestones "$c")" = "M" ] && check "#2059 a create a substitution runs is found, with its own flags: $c" ok \
    || check "#2059 a create a substitution runs is found, with its own flags: $c" "got $(ask milestones "$c")"
done
[ "$(ask count 'echo "gh issue create -t x" `echo gh issue create`')" = "0" ] \
  && check "#2059 control: a create only quoted or echoed is not one" ok \
  || check "#2059 control: a create only quoted or echoed is not one" "got $(ask count 'echo "gh issue create -t x" `echo gh issue create`')"
[ "$(ask bodyfile '(cd /x; echo "$(cd /y)"); gh issue create --body-file b.md')" = "/start/b.md" ] \
  && check "#2059 a cd in a subshell or a substitution stays there" ok \
  || check "#2059 a cd in a subshell or a substitution stays there" "got $(ask bodyfile '(cd /x; echo "$(cd /y)"); gh issue create --body-file b.md')"
[ "$(ask count 'f() { gh issue create -t x; }; case y in y) gh issue create -t z;; esac')" = "2" ] \
  && check "#2059 a create in a function body and in a case branch is found" ok \
  || check "#2059 a create in a function body and in a case branch is found" "got $(ask count 'f() { gh issue create -t x; }; case y in y) gh issue create -t z;; esac')"
# Each misread marker, inside a body in "$( )": the body's text is the body, never the create's flags.
for m in "'E'OF:EOF" 'E"OF":EOF' 'END-OF:END-OF'; do
  c="$(printf 'gh issue create -t T --body "$(cat <<%s\nx" -m M "y\n%s\n)"' "${m%%:*}" "${m#*:}")"
  [ "$(ask milestones "$c")" = "" ] && check "#2059 a body in \"\$( )\" ending at the marker ${m%%:*} gives the create no flags" ok \
    || check "#2059 a body in \"\$( )\" ending at the marker ${m%%:*} gives the create no flags" "got $(ask milestones "$c")"
done
# And on a file the command writes: the body ends at its real closing line, so the write after it is
# seen, and the body is shown when the marker is quoted in any part.
writes_is "#2059 a write after a <<'E'OF body is seen" "a.md:w:shown b.md:w:hidden" "$(printf "cat > a.md <<'E'OF\n\$X\nEOF\necho \$Y > b.md")"
writes_is "#2059 a write after a <<E\"OF\" body is seen, and the body is shown" "a.md:w:shown b.md:w:hidden" "$(printf 'cat > a.md <<E"OF"\n$X\nEOF\necho $Y > b.md')"
writes_is "#2059 a write after a <<END-OF body is seen" "a.md:w:shown b.md:w:hidden" "$(printf 'cat > a.md <<END-OF\nx\nEND-OF\necho $Y > b.md')"
# The gate: a body file written from a <<E"OF" heredoc is text the command shows, so an incomplete one
# is refused, where reading it as hidden passed it unjudged.
EOF_BODY="$(printf 'cat > b.md <<E"OF"\n$X has no section\nEOF\ngh issue create --title T --milestone Ungrouped --label priority-p2 --label bug --body-file b.md')"
[[ "$(gate_from "$DIR" "$EOF_BODY")" == *'"deny"'*"Open questions"* ]] \
  && check "#2059 the gate refuses an incomplete body file written from a <<E\"OF\" heredoc" ok \
  || check "#2059 the gate refuses an incomplete body file written from a <<E\"OF\" heredoc" "got [$(eof_out="$(gate_from "$DIR" "$EOF_BODY")"; printf '%s' "${eof_out:0:200}")]"
[[ "$(gate_from "$DIR" 'echo "$(gh issue create --title T)"')" == *'"deny"'* ]] \
  && check "#2059 the gate refuses an incomplete create a substitution runs" ok \
  || check "#2059 the gate refuses an incomplete create a substitution runs" "it passed"

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
