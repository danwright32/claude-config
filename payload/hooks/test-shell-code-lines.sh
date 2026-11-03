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
mkdir -p "$W/nolib"
cp "$LIB/shell_code_lines.py" "$W/nolib/"
noreader="$(python3 -I -B -c '
import sys
sys.path.insert(0, sys.argv[1])
from shell_code_lines import read_lines
print("imported")
try:
    list(read_lines("cat <<EOF\nEOF\n"))
    print("read with no reader")
except Exception as e:
    print("refused: %s" % e)
' "$W/nolib" 2>&1 | paste -sd'|' -)"
case "$noreader" in
  "imported|refused: "*"lib/shell-words.py could not be loaded"*) eq "#2080 without shell-words.py the reader refuses, loudly" ok ok ;;
  *) eq "#2080 without shell-words.py the reader refuses, loudly" "imported|refused: ...lib/shell-words.py could not be loaded..." "$noreader" ;;
esac
_pyc="$(ls "$LIB/__pycache__" 2>/dev/null | grep -c '^shell-words' || true)"
eq "#2080 loading the reader leaves no shell-words bytecode in lib/" 0 "$_pyc"

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
