#!/usr/bin/env bash
# Tests for lib/shell_code_lines.py, the one reader of which lines of a shell file are its code
# (claude-config#1663), shared by hand-rolled-wait.py (#1679), hand-rolled-checkout.py (#1663),
# heredoc-in-substitution.py (#1690) and scan-subshell-globals.py (#2063). Each of those suites
# proves its own scan; this proves the reader they stand on, so a change to how quoting is followed
# is caught here by name rather than as four scans drifting at once (L613).
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$DIR/lib"
W="$(mktemp -d "${TMPDIR:-/tmp}/shell-code-lines.XXXXXXXX")" || W=""
case "${W%/}" in ''|/|"${HOME%/}") echo "refusing to run: throwaway directory came back as '$W'" >&2; exit 2 ;; esac
trap 'rm -rf "$W"' EXIT

pass=0; fail=0
eq(){ if [ "$2" = "$3" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 (wanted '$2', got '$3')"; fi; }

# A fixture of every shape the reader has to tell apart, one per line:
#  1 code                         2 a comment
#  3 a single quoted string opening over lines, whose next line (4) is text, closing on 5
#  6 a double quoted string holding a $( ... ) that opens over lines; 7 is code inside it; 8 closes
#  9 a heredoc opened as code inside a substitution, 10 its body (yielded), 11 its delimiter
#  12 the substitution closing      13 a heredoc opened at the top level, 14 its body, 15 delimiter
#  16 the empty line after the final newline, which is code like any other
_H='<''<'
{
  printf 'echo one\n'
  printf '# a comment\n'
  printf "X='first\n"
  printf "still text | grep -q x\n"
  printf "last'\n"
  printf 'Y="$(\n'
  printf '  printf code\n'
  printf ')"\n'
  printf 'Z="$(python3 - %s%s\n' "$_H" "'PY'"
  printf "print('body')\n"
  printf 'PY\n'
  printf ')"\n'
  printf 'cat %s%s\n' "$_H" 'EOF'
  printf "it's prose\n"
  printf 'EOF\n'
} > "$W/f.sh"

out="$(python3 -I -B -c '
import sys
sys.path.insert(0, sys.argv[1])
from shell_code_lines import code_lines
text = open(sys.argv[2]).read()
print(" ".join(str(n) for n, _ in code_lines(text)))
for n, _, ops in code_lines(text, with_heredocs=True):
    for strip, word, inside in ops:
        print("op %d %s %s" % (n, word, "inside" if inside else "top"))
' "$LIB" "$W/f.sh" 2>&1)"
lines="$(printf '%s\n' "$out" | sed -n 1p)"
eq "#1663 code lines skip a comment and the text inside a quoted string over lines, and keep a substitution's lines and a heredoc's body" \
  "1 3 6 7 8 9 10 12 13 14 16" "$lines"
eq "#1690 a heredoc inside a substitution is told from one at the top level" \
  "op 9 PY inside|op 13 EOF top" "$(printf '%s\n' "$out" | grep '^op ' | paste -sd'|' -)"
# An apostrophe in a heredoc's prose does not carry a quote past its end: a line after it is code.
printf 'echo after\n' >> "$W/f.sh"
after="$(python3 -I -B -c '
import sys
sys.path.insert(0, sys.argv[1])
from shell_code_lines import code_lines
print(" ".join(str(n) for n, _ in code_lines(open(sys.argv[2]).read())))
' "$LIB" "$W/f.sh" 2>&1)"
eq "#1663 an apostrophe in a heredoc body leaves the line after the heredoc as code" "1 3 6 7 8 9 10 12 13 14 16 17" "$after"

# A plain `( ... )` inside a substitution closes itself, not the substitution (claude-config#2063).
# The shape of claude-sync's send_hook_tests: a subshell on the middle line of a `"$( { ... } )"`
# over three lines. Its `)` used to close the `$(`, so the third line read as inside the double
# quotes, and the brace closing the group there was never seen.
{
  printf 'd="$( { printf one\n'
  printf '        (set -f; cd /tmp && ls)\n'
  printf '        printf two; } | cut -c1)"\n'
  printf 'echo after\n'
} > "$W/p.sh"
plain="$(python3 -I -B -c '
import sys
sys.path.insert(0, sys.argv[1])
from shell_code_lines import code_lines
print(" ".join(str(n) for n, _ in code_lines(open(sys.argv[2]).read())))
' "$LIB" "$W/p.sh" 2>&1)"
eq "#2063 a subshell inside a substitution over lines leaves the substitution's next line as code" "1 2 3 4 5" "$plain"

# read_lines gives each line's code alone, so a brace in quoted text, a comment, an escape or a
# heredoc's body is never counted as the shell's (claude-config#2063).
{
  printf 'f() { echo "{" '"'"'}'"'"' \\{  # a { comment\n'
  printf '  cat %s%s\n' "$_H" 'EOF'
  printf '{ body\n'
  printf 'EOF\n'
  printf '}\n'
} > "$W/b.sh"
bare="$(python3 -I -B -c '
import sys
sys.path.insert(0, sys.argv[1])
from shell_code_lines import read_lines
for n, line, kind, bare, ops in read_lines(open(sys.argv[2]).read()):
    print("%d %s %d %d" % (n, kind, bare.count("{"), bare.count("}")))
' "$LIB" "$W/b.sh" 2>&1 | paste -sd'|' -)"
eq "#2063 read_lines counts only the shell's own braces, line by line" \
  "1 code 1 0|2 code 0 0|3 heredoc 0 0|4 end 0 0|5 code 0 1|6 code 0 0" "$bare"

# A brace inside a bracket expression is a character a pattern matches, not a brace group: the case
# pattern of mt_is_interpreter in lib/merge-target.sh, the [[ =~ ]] regex in
# test-suite-scratch-isolation.sh, and a ${v//[{]/} replacement (claude-config#2068). A test
# command's own brackets, a brace group and a parameter expansion are still counted.
{
  printf '%s\n' "f() {  # opens"
  printf '%s\n' "    '\"\$'*|'\$'[A-Za-z_{]*) return 0 ;;"
  printf '%s\n' '  [[ "$v" =~ \$[{]?(PY)$ ]] && v=${v//[{]/}'
  printf '%s\n' '  [ -n "$v" ] && { echo ${v}; }'
  printf '%s\n' '  x=${a[${i}]}; [[ -n ${x} ]]'
  printf '%s\n' '}'
} > "$W/k.sh"
braces="$(python3 -I -B -c '
import sys
sys.path.insert(0, sys.argv[1])
from shell_code_lines import read_lines, brace_depth
print(" ".join(str(brace_depth(r[3])) for r in read_lines(open(sys.argv[2]).read())))
' "$LIB" "$W/k.sh" 2>&1)"
eq "#2068 a brace in a bracket expression is not counted, every other brace is" "1 0 0 0 0 -1 0" "$braces"

# The end marker is the whole word after the opener with its quotes taken out, as bash reads it and
# lib/shell-words.py gives it (claude-config#2080). A pattern of its own read 'E'OF and E"OF" as E,
# and END-OF as END, so every line after the first body was read as that body. Arithmetic opens no
# heredoc, and each heredoc's next line is the file's code again.
{
  printf 'cat %s%s\n' "$_H" "'E'OF"
  printf 'x\nEOF\necho a\n'
  printf 'cat %s%s\n' "$_H" 'E"OF"'
  printf 'x\nEOF\necho b\n'
  printf 'cat %s%s\n' "$_H" 'END-OF'
  printf 'x\nEND-OF\necho c\n'
  printf 'echo $((1%s2))\n' "$_H"
  printf 'echo d\n'
} > "$W/m.sh"
kinds="$(python3 -I -B -c '
import sys
sys.path.insert(0, sys.argv[1])
from shell_code_lines import read_lines
print(" ".join(r[2] for r in read_lines(open(sys.argv[2]).read())))
' "$LIB" "$W/m.sh" 2>&1)"
eq "#2080 a quoted in part or hyphenated end marker is read whole, and arithmetic opens nothing" \
  "code heredoc end code code heredoc end code code heredoc end code code code code" "$kinds"

# Without lib/shell-words.py beside it there is no reading of a marker, and the reader says so the
# first time it is asked, rather than reading every heredoc as never closing. Importing it still
# works, so a scan that checks its own readers first can say which one is missing.
#
# The reader is lib's own, and the one load of shell-words.py it makes is pointed at an empty folder,
# so the load fails as it does where the file is missing, and the refusal has to name that folder.
# A copy of the reader made in $W and imported from there showed the same, but the Slack drafts
# gate reads this suite before it runs, when that copy is not on disk: it could not find the
# module and refused the whole suite when a session ran it (claude-config#2668).
# test-slack-drafts-only-gate.sh judges this suite, so importing from a folder made here fails there.
mkdir -p "$W/nolib"
noreader="$(python3 -I -B -c '
import importlib.util, os, sys
found = importlib.util.spec_from_file_location
def beside_nothing(name, location=None, *rest, **more):
    if os.path.basename(str(location)) == "shell-words.py":
        location = os.path.join(sys.argv[2], "shell-words.py")
    return found(name, location, *rest, **more)
importlib.util.spec_from_file_location = beside_nothing
sys.path.insert(0, sys.argv[1])
from shell_code_lines import read_lines
print("imported")
try:
    list(read_lines("cat <<EOF\nEOF\n"))
    print("read with no reader")
except Exception as e:
    print("refused: %s" % e)
' "$LIB" "$W/nolib" 2>&1 | paste -sd'|' -)"
case "$noreader" in
  "imported|refused: "*"lib/shell-words.py could not be loaded"*"nolib/shell-words.py"*) eq "#2080 without shell-words.py the reader refuses, loudly" ok ok ;;
  *) eq "#2080 without shell-words.py the reader refuses, loudly" "imported|refused: ...lib/shell-words.py could not be loaded...nolib/shell-words.py..." "$noreader" ;;
esac

# Loading the reader leaves no shell-words bytecode for a caller that writes bytecode (#2080). Every
# load above runs with -B, so it could never see a writer: this one runs without it, as a scan that
# imports the reader would. -I drops the PYTHONDONTWRITEBYTECODE the runner and arming hand every
# suite (#2751), and the process reports its own flag, so bytecode switched off reads as a failure,
# never as clean. -X pycache_prefix, which -I does not drop, sends whatever this one process writes
# into $W and nowhere else, so the count is this suite's own writes. Counting lib/__pycache__ instead
# failed on a file anything else had left there: a probe run by hand, another suite running at the
# same moment, an older run (#2757). Its import of shell_code_lines lands there too, the control
# that the writes went where they are counted (L322).
mkdir -p "$W/pyc"
_bc="$(python3 -I -X pycache_prefix="$W/pyc" -c '
import sys
sys.path.insert(0, sys.argv[1])
import shell_code_lines
print(sys.flags.dont_write_bytecode, shell_code_lines.READER_ERROR)
' "$LIB" 2>&1 | paste -sd'|' -)"
eq "#2751 the load below runs with bytecode on and loads the reader (flag, reader error)" "0 None" "$_bc"
_own="$(find "$W/pyc" -name 'shell_code_lines.*.pyc' | wc -l | tr -d ' ')"
eq "#2757 control: that load's own bytecode landed in its throwaway prefix" 1 "$_own"
_pyc="$(find "$W/pyc" -name 'shell-words*' | sed 's#.*/##' | paste -sd' ' -)"
eq "#2080 loading the reader leaves no shell-words bytecode (written by this load)" "" "$_pyc"

# A # after an escaped space, ; or ( is inside a word, so a quote that opens after it on the line is
# open on the lines that follow, which are text (claude-config#3464). The reader took the # for a
# comment, skipped the quote, and read those lines as code. It asks lib/shell-words.py's word_starts
# now, the rule the command reader asks. The control is a real comment: its quote opens nothing, so line 3 opens one instead.
lines_of() { # lines_of <first line of a four line file>: the numbers of its code lines
  printf '%s\ntext | grep -q x\ncloses"\necho code\n' "$1" > "$W/hash.sh"
  python3 -I -B -c '
import sys
sys.path.insert(0, sys.argv[1])
from shell_code_lines import code_lines
print(" ".join(str(n) for n, _ in code_lines(open(sys.argv[2]).read())))
' "$LIB" "$W/hash.sh" 2>&1
}
eq "#3464 a quote after a # that follows an escaped space is open on the next lines" "1 4 5" "$(lines_of 'echo a\ # "opens')"
eq "#3464 and after a # that follows an escaped ;" "1 4 5" "$(lines_of 'echo a\;# "opens')"
eq "#3464 and after a # that follows an escaped (" "1 4 5" "$(lines_of 'echo a\(# "opens')"
eq "#3464 the control: mid word it always was" "1 4 5" "$(lines_of 'echo a# "opens')"
eq "#3464 the control: a real comment's quote opens nothing, so the next lines are code, after a space" "1 2 3" "$(lines_of 'echo a # "opens')"
eq "#3464 the control: and after an escaped backslash and a space" "1 2 3" "$(lines_of 'echo a \\ # "opens')"
eq "#3464 the control: and after a ;" "1 2 3" "$(lines_of 'echo a;# "opens')"

# A backslash at the end of a line joins it to the next, and the reader went line by line, so it
# took every # that starts a line for a comment (claude-config#3475). Joined onto a word the # is
# text and the rest of its line is code: bash 3.2, zsh, sh and dash all print a#b and RAN for
# `echo a\` then `#b; echo RAN` (measured 2026-11-23, texts that only echo). The reader dropped that
# line, and never followed a quote or a heredoc opened after the #. The controls are the lines the
# same shells do take for comments, the opposite mistake: a backslash that ends a COMMENT, or a
# heredoc's closing line, joins nothing (#3481).
#
# The same day's second fault: an unquoted heredoc's body is joined the same way BEFORE a line is
# compared with the marker, so a marker line after a body line ending in a backslash does not close
# it (#3492). The reader closed there, and an apostrophe in the body lines after then hid the code
# past the real end.
#
# Every fixture is read by ONE python start (L298); reading_of picks a line of its output.
mkdir -p "$W/j"
TAB="$(printf '\t')"
mk() { # mk <name> <line>...: a fixture of those lines
  local name="$1"; shift
  printf '%s\n' "$@" > "$W/j/$name"
}
# Red before the fix: the # line is code.
mk word         'echo a\' '#b; echo RAN' 'echo next'
mk three        'echo a\\\' '#b; echo RAN' 'echo next'
mk through      'echo a\' '\' '#b; echo RAN' 'echo next'
mk escaped      'echo a\ \' '#b; echo RAN' 'echo next'
mk closequote   'echo "a"\' '#b; echo RAN' 'echo next'
mk inside       'x=$(echo a\' '#b; echo RAN)' 'echo "$x"'
mk twice        'echo a\' '#b\' '#c; echo RAN' 'echo next'
mk quote        'echo a\' '#b "opens' 'text; echo NOT' 'closes"; echo RAN' 'echo AFTER'
mk opener       'echo a\' "#b; cat ${_H}E" 'echo BODY' 'E' 'echo next'
# Controls, a comment in every shell.
mk space        'echo a \' '#b; echo RAN' 'echo next'
mk two          'echo a\\' '#b; echo RAN' 'echo next'
mk comment      'echo a # c\' '#b; echo RAN' 'echo next'
mk comment3     'echo a # c\\\' '#b; echo RAN' 'echo next'
mk wholeline    '# c\' '#b; echo RAN' 'echo next'
mk thencode     '# c\' 'echo RAN' 'echo next'
mk spacecomment 'echo a \' '# c \' 'echo RAN'
mk semicolon    'echo a;\' '#b; echo RAN' 'echo next'
mk blank        'echo a\' ' #b; echo RAN' 'echo next'
mk alone        '\' '#b; echo RAN' 'echo next'
mk closingline  "cat ${_H}'E\\'" 'body' 'E\' '#b; echo RAN' 'echo next'
# The heredoc. Red before the fix:
mk h-second     "cat ${_H}E" 'a\' 'E' "it's body" 'E' 'echo AFTER'
mk h-split      "cat ${_H}EOF" 'body' 'E\' 'OF' 'echo after'
mk h-rest       "cat ${_H}E" 'a\' 'E' '# $(echo RAN1)' "x='" '$(echo RAN2)' "'" 'echo end'
mk h-tabs       "cat ${_H}-E" "${TAB}a\\" "${TAB}E" '# c' 'echo end'
mk h-marker     "cat ${_H}E" 'body' 'E\' 'E' '# c' 'echo end'
# Closed at the marker in bash and zsh. In h-bare and h-tabbare a backslash joins the closing line to
# the line before, where another shell reads on (lib/heredoc-closes.json), so those two are named
# and the comment after them is not left out (#3592); after the rest the comment is a comment.
mk h-bare       "cat ${_H}E" 'body' '\' 'E' '# c' 'echo after'
mk h-two        "cat ${_H}E" 'a\\' 'E' '# c' 'echo after'
mk h-quoted     "cat ${_H}'E'" 'a\' 'E' '# c' 'echo after'
mk h-middle     "cat ${_H}E" 'a\' 'b' 'E' '# c' 'echo after'
mk h-tabbare    "cat ${_H}-E" "${TAB}body" "${TAB}\\" "${TAB}E" '# c' 'echo after'
mk h-inside     "x=\$(cat ${_H}E" 'a\' 'E' ')' 'echo after'
mk h-between    "cat ${_H}E" 'a\' 'E' '# c' 'E' 'echo after'
readings="$(python3 -I -B -c '
import os, sys
sys.path.insert(0, sys.argv[1])
from shell_code_lines import code_lines, heredoc_body_lines, read_lines
for name in sorted(os.listdir(sys.argv[2])):
    text = open(os.path.join(sys.argv[2], name)).read()
    print("%s code: %s" % (name, " ".join(str(n) for n, _ in code_lines(text))))
    print("%s kinds: %s" % (name, " ".join(r[2] for r in read_lines(text))))
    print("%s body: %s" % (name, " ".join(str(n) for n in sorted(heredoc_body_lines(text)))))
    print("%s ops: %s" % (name, " ".join("%d:%s" % (n, o[1]) for n, _, ops in code_lines(text, with_heredocs=True) for o in ops)))
' "$LIB" "$W/j" 2>&1)"
reading_of() { # reading_of <fixture> <code|kinds|body|ops>: that reading, from the one run above
  printf '%s\n' "$readings" | sed -n "s/^$1 $2: //p"
}
eq "#3475 the control: every fixture was read (4 readings each)" "$(($(ls "$W/j" | wc -l) * 4))" "$(printf '%s\n' "$readings" | grep -c ': ')"
eq "#3475 a # line joined onto a word is code" "1 2 3 4" "$(reading_of word code)"
eq "#3475 and after three backslashes" "1 2 3 4" "$(reading_of three code)"
eq "#3475 and through a line that is only a backslash" "1 2 3 4 5" "$(reading_of through code)"
eq "#3475 and after an escaped space" "1 2 3 4" "$(reading_of escaped code)"
eq "#3475 and onto a closing quote" "1 2 3 4" "$(reading_of closequote code)"
eq "#3475 and inside a substitution" "1 2 3 4" "$(reading_of inside code)"
eq "#3475 and two such lines in a row" "1 2 3 4 5" "$(reading_of twice code)"
eq "#3475 a quote opening after the joined # is followed: its text is not code, the line after it closes is" "1 2 5 6" "$(reading_of quote code)"
eq "#3475 a heredoc opened after the joined # is read" "code code heredoc end code code" "$(reading_of opener kinds)"
eq "#3475 and named" "2:E" "$(reading_of opener ops)"
eq "#3475 the control: joined after a space the # is a comment" "1 3 4" "$(reading_of space code)"
eq "#3475 the control: two backslashes join nothing" "1 3 4" "$(reading_of two code)"
eq "#3481 the control: a backslash ending a comment joins nothing" "1 3 4" "$(reading_of comment code)"
eq "#3481 the control: nor do three" "1 3 4" "$(reading_of comment3 code)"
eq "#3481 the control: nor one ending a whole line comment" "3 4" "$(reading_of wholeline code)"
eq "#3481 the control: and the code line after such a comment is code" "2 3 4" "$(reading_of thencode code)"
eq "#3481 the control: a comment joined after a space ends at its line" "1 3 4" "$(reading_of spacecomment code)"
eq "#3475 the control: joined after a ; the # is a comment" "1 3 4" "$(reading_of semicolon code)"
eq "#3475 the control: a # after a blank on the joined line is a comment" "1 3 4" "$(reading_of blank code)"
eq "#3475 the control: joined to nothing the # is a comment" "1 3 4" "$(reading_of alone code)"
eq "#3481 the control: a heredoc's closing line ending in a backslash joins nothing" "1 2 5 6" "$(reading_of closingline code)"
eq "#3492 a marker joined to the body line before closes nothing, the marker alone does" \
  "code heredoc heredoc heredoc end code code" "$(reading_of h-second kinds)"
eq "#3492 so the code after the real end is code, apostrophe in the body or not" "1 2 3 4 6 7" "$(reading_of h-second code)"
eq "#3492 and the lines between are the heredoc's body" "2 3 4" "$(reading_of h-second body)"
eq "#3492 a marker split over two joined lines closes, as bash and zsh read it" \
  "code heredoc heredoc end code code" "$(reading_of h-split kinds)"
# No real end comes: every shell takes the rest for body, where a substitution runs in a comment and
# in a quoted string alike. The reader closes at the joined marker, so the rest is read as code, and
# drops none of it.
eq "#3492 with no real end the rest is read as code" "code heredoc end code code quoted quoted code code" "$(reading_of h-rest kinds)"
eq "#3492 and none of it is dropped, a comment or quoted text included" "1 2 4 5 6 7 8 9" "$(reading_of h-rest code)"
eq "#3492 nor counted as the heredoc's body" "2" "$(reading_of h-rest body)"
eq "#3492 the same under the tab stripping form" "1 2 4 5 6" "$(reading_of h-tabs code)"
eq "#3492 and where the body line before is the marker and a backslash" "code heredoc heredoc end code code code" "$(reading_of h-marker kinds)"
eq "#3492 none of that rest dropped either" "1 2 3 5 6 7" "$(reading_of h-marker code)"
eq "#3492 a backslash only line then the marker closes, as bash and zsh read it" "code heredoc heredoc end code code code" "$(reading_of h-bare kinds)"
eq "#3592 and another shell reads on there, so the comment after it is not left out" "1 2 3 5 6 7" "$(reading_of h-bare code)"
eq "#3492 the control: two backslashes join nothing" "1 2 5 6" "$(reading_of h-two code)"
eq "#3492 the control: a quoted marker's body joins nothing" "1 2 5 6" "$(reading_of h-quoted code)"
eq "#3492 the control: a backslash in the middle of the body" "1 2 3 6 7" "$(reading_of h-middle code)"
eq "#3492 tabs, a backslash only line, the marker: closed, as bash reads it" "code heredoc heredoc end code code code" "$(reading_of h-tabbare kinds)"
eq "#3592 and another shell reads on there, so the comment after it is not left out" "1 2 3 5 6 7" "$(reading_of h-tabbare code)"
eq "#3492 the control: inside a substitution with no real end, closed at the joined marker as bash 3.2 runs it" \
  "code heredoc end code code code" "$(reading_of h-inside kinds)"
eq "#3492 the control: between a joined marker and the real end a # line is body, dropped as in any body" "1 2 3 6 7" "$(reading_of h-between code)"

# ---- where a heredoc ends, against the shells (claude-config#3592) ----
# The reader ends a heredoc where bash and zsh end it (#3500), and that left three kinds of heredoc
# read with nothing said: one whose opener is joined to the next line by a backslash between its <<
# and the end of its marker, so the marker is not the word on that line (the reader took `<<E` and a
# backslash for a marker no line is, and read the rest of the file as the body, the code after the
# real end included); one the shells do not end alike (a line that is only a backslash and then the
# marker, a marker split over two lines, a marker after a line that starts as it does and ends in
# backslashes: bash and zsh end it where dash or ksh read on, or the reverse); and one no shell ends
# where the reader does (a marker joined to the line before, with no marker after it).
#
# unsure_heredocs(text) names each such heredoc by the line it opens on, and code_lines leaves out
# nothing after one. The shapes are lib/heredoc-closes.json, the one list this suite and the mods'
# reader's suite both run. Every row is run here through each shell the list was measured with, so
# the list cannot say what the shells do not do, and then asked of the reader: a probe line is read
# as every shell reads it, or its heredoc is named and the line is not left out.
python3 -I -B - "$LIB" "$LIB/heredoc-closes.json" "$W" > "$W/closes.tsv" <<'PY'
import importlib.util
import json
import os
import re
import shutil
import signal
import subprocess
import sys

lib, list_path, scratch = sys.argv[1:4]
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("shell_code_lines", os.path.join(lib, "shell_code_lines.py"))
scl = importlib.util.module_from_spec(spec)
spec.loader.exec_module(scl)
with open(list_path) as f:
    doc = json.load(f)


def say(ok, what, why=""):
    print("ok\t" + what if ok else "FAIL\t%s\t%s" % (what, why))


def run(argv, text):
    """What the text prints, run by argv as a -c text; None when it is still running at 10 seconds.
    The shell is started in a group of its own and the whole group is stopped with it."""
    p = subprocess.Popen(argv + ["-c", text], cwd=scratch, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                         stderr=subprocess.DEVNULL, start_new_session=True,
                         env={"PATH": "/usr/bin:/bin", "HOME": scratch})
    try:
        out, _ = p.communicate(timeout=10)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(p.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        p.communicate()
        return None
    return out.decode("utf-8", "replace")


def classify(text, out):
    """What a shell did with each probe line: ran it ("code") or kept it as text ("body")."""
    got = {}
    for n, line in enumerate(text.split("\n"), 1):
        tag = "P%02d" % n
        if "echo " + tag not in line:
            continue
        if out is None:
            got[n] = "hung"
        elif re.search("echo " + tag, out):
            got[n] = "body"
        elif re.search("(?m)^" + tag, out):
            got[n] = "code"
        else:
            got[n] = "neither"
    return got


# A shell is held to the list only where it is the one the list was measured with (L411).
measured = []
for name, shell in doc["shells"].items():
    if not shutil.which(shell["run"][0]):
        print("unmeasured\t%s\tthere is no %s on this machine" % (name, shell["run"][0]))
    elif os.uname().sysname != doc["os"]:
        print("unmeasured\t%s\tthe list was measured on %s and this is %s" % (name, doc["os"], os.uname().sysname))
    elif (run(shell["run"], shell["probe"]) or "").strip() != shell["prints"]:
        print("unmeasured\t%s\tit is not the %s the list was measured with" % (name, shell["run"][0]))
    else:
        measured.append(name)
print("shells\t" + ",".join(measured))

can_name = hasattr(scl, "unsure_heredocs")
say(can_name, "#3592 the reader can say which heredocs it is not sure of", "shell_code_lines has no unsure_heredocs")
for row in doc["rows"]:
    name, text = row["name"], row["text"]
    answers = {int(n): v for n, v in row["lines"].items()}
    for shell in measured:
        want = {n: v if isinstance(v, str) else next(k for k, who in v.items() if shell in who) for n, v in answers.items()}
        got = classify(text, run(doc["shells"][shell]["run"], text))
        say(got == want, "#3592 the list says what %s does: %s" % (shell, name), "the list says %r and %s did %r" % (want, shell, got))
    marks = scl.unsure_heredocs(text) if can_name else []
    code = {n for n, _ in scl.code_lines(text)}
    body = scl.heredoc_body_lines(text)
    want_named = row["named"]["scanner"]
    say(bool(marks) == want_named, "#3592 the reader %s the heredoc: %s" % ("names" if want_named else "does not name", name),
        "it named %r" % (marks,))
    for n, v in sorted(answers.items()):
        mine = "body" if n in body else "code" if n in code else "left out"
        if marks:
            say(n in code, "#3592 after a heredoc it names the reader leaves out no line: %s, line %d" % (name, n), "line %d was %s" % (n, mine))
        else:
            say(mine == v, "#3592 a line of a heredoc it does not name is read as every shell reads it: %s, line %d" % (name, n),
                "the reader read %s, and the shells: %r" % (mine, v))

# The heredoc is named by the line it opens on, once, whichever of its lines gave it away.
if can_name:
    marks = scl.unsure_heredocs("echo a\ncat <<E\nb\\\nE\necho c\n")
    say([m[0] for m in marks] == [2] and all(isinstance(m[1], str) and m[1] for m in marks),
        "#3592 a heredoc is named by the line it opens on, with why", "got %r" % (marks,))
    marks = scl.unsure_heredocs("cat <<E\\\nx\nbody\nEx\necho c\n")
    say([m[0] for m in marks] == [1], "#3592 an opener joined to the next line is named by its own line", "got %r" % (marks,))
    marks = scl.unsure_heredocs("x=$((1<<\\\n2))\necho $x\n")
    say(marks == [], "#3592 the control: a shift in arithmetic joined to the next line opens nothing and names nothing", "got %r" % (marks,))
    marks = scl.unsure_heredocs("cat <<E | \\\ncat\nbody\nE\necho c\n")
    say(marks == [], "#3592 the control: a backslash later on the opener's line joins the command, not the marker", "got %r" % (marks,))
PY
closes_rc=$?
eq "#3592 the comparison with the shells ran to its end" "0" "$closes_rc"
closes_checks=0
while IFS="$TAB" read -r verdict what why; do
  case "$verdict" in
    ok) pass=$((pass + 1)); closes_checks=$((closes_checks + 1)) ;;
    FAIL) fail=$((fail + 1)); closes_checks=$((closes_checks + 1)); echo "FAIL: $what ($why)" ;;
    unmeasured) echo "SUITE-PART-UNMEASURED what $what does with each heredoc of #3592, because $why" ;;
    shells) echo "the shells held to the list of #3592: ${what:-none}" ;;
    *) fail=$((fail + 1)); echo "FAIL: #3592 a row of the comparison is one this suite reads (got: $verdict)" ;;
  esac
done < "$W/closes.tsv"
# Each row makes one check of the reader's naming and one for each probe line, so a list that was
# not read, or a comparison that stopped early, is caught by its count (L288).
if [ "$closes_checks" -ge 120 ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: #3592 the comparison checked its rows (only $closes_checks checks, where the list makes well over 120)"; fi

# Every scan that reads through this reader reads the repository's own shell files, so one check
# here stands for them all: no tracked shell file holds a heredoc the reader is not sure of. A file
# that gains one fails this suite, where each scan alone would have read on (L621).
TREE_ROOT="$(bash "$DIR/lib/checkout-root.sh" "$DIR/.." 2>/dev/null || true)"
if [ -z "$TREE_ROOT" ] || [ ! -d "$TREE_ROOT" ]; then
  echo "SUITE-PART-UNMEASURED whether a shell file of the repository holds a heredoc the reader is not sure of, because $DIR/.. is not the payload of a claude-config checkout"
else
  # The sync tool, a shell file with no extension, is added by name in the reading below: named
  # here as a word after `bash`, the Slack drafts gate takes it for a script this suite may run.
  bash "$DIR/lib/repo-files.sh" "$TREE_ROOT" '*.sh' > "$W/tree-files" 2>/dev/null
  python3 -I -B - "$LIB" "$TREE_ROOT" "$W/tree-files" > "$W/tree-named" <<'PY'
import os
import sys
sys.dont_write_bytecode = True
sys.path.insert(0, sys.argv[1])
import shell_code_lines as scl
read = 0
for rel in open(sys.argv[3]).read().split("\n") + ["claude-sync"]:
    path = os.path.join(sys.argv[2], rel)
    if not rel or not os.path.isfile(path):
        continue
    try:
        text = open(path, encoding="utf-8", errors="replace").read()
    except OSError:
        continue
    read += 1
    for line, why in (scl.unsure_heredocs(text) if hasattr(scl, "unsure_heredocs") else [(0, "the reader cannot say")]):
        print("%s:%d: %s" % (rel, line, why))
print("read %d" % read)
PY
  tree_read="$(sed -n 's/^read //p' "$W/tree-named")"
  if [ "${tree_read:-0}" -ge 300 ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: #3592 the repository's shell files were read (only '${tree_read:-none}' of them, where it ships hundreds)"; fi
  eq "#3592 no shell file of the repository holds a heredoc the reader is not sure of" "" "$(grep -v '^read ' "$W/tree-named" | head -20)"
  # The mods' reader is held to the same list, through a copy: a mod's tests can import only the
  # mod's own files. The copy is the list's text after one line, so it cannot come to say otherwise.
  if sed '1,/^export default$/d' "$TREE_ROOT/payload/mods/mod-kit/tests/heredoc-closes.ts" 2>/dev/null | cmp -s - "$LIB/heredoc-closes.json"; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL: #3592 payload/mods/mod-kit/tests/heredoc-closes.ts no longer holds the text of payload/hooks/lib/heredoc-closes.json after its 'export default' line: put the list's text there again, whole"
  fi
fi

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
