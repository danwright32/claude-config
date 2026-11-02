#!/usr/bin/env bash
# The shared command reader (lib/shell-words.py commands()) reads the substitutions inside the body
# of an UNQUOTED heredoc as commands, because the shell expands that body and runs every $( ) and
# backquote in it (claude-config#2053). It skipped every body as plain text, so a command written in
# a substitution there was never seen by any gate reading through the reader. A body whose end
# marker is quoted in any way (whole, in part, or by one backslash) runs nothing and stays text.
#
# Each case is a measurement on this Mac's shells first (probe in the PR), then asked of the reader:
# both the commands mode a caller runs and ps_is_git_push, the push recogniser every push gate asks.
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SW="$DIR/lib/shell-words.py"

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }

# shellcheck source=lib/push-scope.sh
. "$DIR/lib/push-scope.sh" || { echo "FAIL: cannot source lib/push-scope.sh"; printf 'SUITE-RESULT passed=0 failed=1\n'; exit 1; }

# The commands the reader returns, one text per line (newlines inside a text shown as \n), and its
# exit code on the last line: 0 for a trusted reading, 3 for the crude cut.
reading() { # reading <command text>
  local out rc
  out="$(printf '%s' "$1" | python3 -B "$SW" commands)"
  rc=$?
  printf '%s' "$out" | python3 -c '
import sys
for rec in sys.stdin.read().split("\x1e"):
    if rec:
        print(rec.split("\x1f", 1)[1].strip().replace("\n", "\\n"))'
  echo "rc=$rc"
}

# has <command text> <a command text the reader must return> <description>
has() {
  local got
  got="$(reading "$1")"
  local lines=$'\n'"$got"$'\n'
  if [[ "$lines" == *$'\n'"$2"$'\n'* && "$lines" == *$'\nrc=0\n'* ]]; then check "$3" ok
  else check "$3" "reading was [$(printf '%s' "$got" | tr '\n' '|')]"; fi
}
# lacks <command text> <a text that must not be among the commands> <description>
lacks() {
  local got
  got="$(reading "$1")"
  if [[ "$got" == *"$2"* ]]; then check "$3" "reading was [$(printf '%s' "$got" | tr '\n' '|')]"
  else check "$3" ok; fi
}

X='echo INNER'

# ---- an unquoted body: its substitutions are commands ----
has $'cat <<EOF\na $('"$X"$') b\nEOF' "$X" "#2053 a \$( ) in an unquoted heredoc body is a command"
has $'cat <<EOF\na `'"$X"$'` b\nEOF' "$X" "#2053 a backquote in an unquoted heredoc body is a command"
has $'cat <<-EOF\n\ta $('"$X"$')\n\tEOF' "$X" "#2053 a \$( ) in a tab stripped (<<-) body is a command"
has $'cat << EOF\na $('"$X"$')\nEOF' "$X" "#2053 a space before the marker is still an unquoted marker"
has $'cat <<END-OF\na $('"$X"$')\nEND-OF' "$X" "#2053 a marker holding a hyphen is read whole"
lacks $'cat <<END-OF\ngit push\nEND-OF' "git push" "#2053 control: a hyphenated marker's body ends at END-OF, so its lines are text"
has $'cat <<EOF\nit\'s "a" $('"$X"$') x\nEOF' "$X" "#2053 quotes in the body are text, and do not hide the substitution"
has $'cat <<EOF\n${V:-$('"$X"$')}\nEOF' "$X" "#2053 a substitution inside \${ } in the body is a command"
has $'cat <<A <<B\none\nA\na $('"$X"$')\nB' "$X" "#2053 the second of two bodies is read"
has $'cat <<A <<B\na $('"$X"$')\nA\ntwo\nB' "$X" "#2053 the first of two bodies is read"
has $'git commit -F - <<EOF\nmsg $('"$X"$')\nEOF\necho after' "echo after" "#2053 the command after the body is still read"
has $'cat <<EOF; echo same\na $('"$X"$')\nEOF' "echo same" "#2053 a command after the opener on its line is still read"
has $'x="$(cat <<EOF\na $('"$X"$')\nEOF\n)"' "$X" "#2053 a body inside a substitution is read the same"
# The flattened form the push hooks read, each newline made "; ".
has 'cat <<EOF; a $('"$X"'); EOF' "$X" "#2053 the flattened form reads an unquoted body the same"

# ---- the body itself is still nobody's command ----
lacks $'cat <<EOF\ngit push origin main\nEOF' "git push" "#2053 control: a body line that reads like a push is not a command"
lacks $'cat <<EOF\n\\$('"$X"$') \\`'"$X"$'\\`\nEOF' "$X" "#2053 an escaped \$( and backquote in the body run nothing"
has $'cat <<EOF\na $('"$X"$')\nEOF' "cat <<EOF" "#2053 the command holding the heredoc is still one command"

# ---- a quoted marker, in any form: the body runs nothing ----
lacks $'cat <<\'EOF\'\na $('"$X"$')\nEOF' "$X" "#2053 control: a single quoted marker keeps the body text"
lacks $'cat <<"EOF"\na $('"$X"$')\nEOF' "$X" "#2053 control: a double quoted marker keeps the body text"
lacks $'cat <<\\EOF\na $('"$X"$')\nEOF' "$X" "#2053 control: a backslash quoted marker keeps the body text"
lacks $'cat <<E"OF"\na $('"$X"$')\nEOF' "$X" "#2053 control: a partly double quoted marker keeps the body text"
lacks $'cat <<E\'OF\'\na $('"$X"$')\nEOF' "$X" "#2053 control: a partly single quoted marker keeps the body text"
lacks $'cat <<E\\OF\na $('"$X"$')\nEOF' "$X" "#2053 control: a marker with a backslash inside keeps the body text"
lacks $'cat <<-\'EOF\'\n\ta $('"$X"$')\n\tEOF' "$X" "#2053 control: a quoted <<- marker keeps the body text"
has $'cat <<E"OF"\na $('"$X"$')\nEOF\necho after' "echo after" "#2053 the partly quoted marker's body ends at its real closing line"
lacks $'cat <<E"OF"\ngit push\nEOF' "git push" "#2053 control: a partly quoted marker's body is not read as commands"

# ---- a substitution left open at the end of its body cannot be trusted ----
got="$(reading $'cat <<EOF\ndon`t\nEOF\necho after')"
[[ $'\n'"$got"$'\n' == *$'\nrc=3\n'* ]] && check "#2053 a backquote left open in a body is the crude reading" ok \
  || check "#2053 a backquote left open in a body is the crude reading" "reading was [$(printf '%s' "$got" | tr '\n' '|')]"

# ---- the skipped bodies a caller asks for (#2050), and the substitutions in one body ----
asked="$(python3 -B -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("sw", sys.argv[1])
sw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sw)
got = []
sw.commands("cat <<E\"OF\"\na $(x)\nEOF\ncat <<EOF\nb $(y) `z`\nEOF", "", got)
print(got)
print(sw.body_substitutions("b $(y) `z` $(w $(v))"))
try:
    sw.body_substitutions("don`t")
    print("read")
except sw.Unreadable:
    print("unreadable")' "$SW")"
[ "$asked" = "[(True, 'cat ', 'a \$(x)'), (False, 'cat ', 'b \$(y) \`z\`')]
['y', 'z', 'w \$(v)']
unreadable" ] && check "#2053 the skipped bodies carry their quoting, and a body's own substitutions are found" ok \
  || check "#2053 the skipped bodies carry their quoting, and a body's own substitutions are found" "got [$asked]"

# ---- through the push recogniser every push gate asks ----
P='git push origin main'
if ps_is_git_push $'cat <<EOF\nnote $('"$P"$')\nEOF'; then check "#2053 a push in an unquoted body substitution is a push" ok
else check "#2053 a push in an unquoted body substitution is a push" "not seen"; fi
if ps_is_git_push $'cat <<EOF\nnote `'"$P"$'`\nEOF'; then check "#2053 a push in an unquoted body backquote is a push" ok
else check "#2053 a push in an unquoted body backquote is a push" "not seen"; fi
if ps_is_git_push $'cat <<\'EOF\'\nnote $('"$P"$')\nEOF'; then check "#2053 control: a push in a quoted body is not a push" "seen as a push"
else check "#2053 control: a push in a quoted body is not a push" ok; fi

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
