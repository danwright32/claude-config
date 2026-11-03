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

# ---- the skipped bodies a caller asks for (#2050) ----
asked="$(python3 -B -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("sw", sys.argv[1])
sw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sw)
got = []
sw.commands("cat <<E\"OF\"\na $(x)\nEOF\ncat <<EOF\nb $(y) `z`\nEOF", "", got)
print(got)' "$SW")"
[ "$asked" = "[(True, 'cat ', 'a \$(x)'), (False, 'cat ', 'b \$(y) \`z\`')]" ] \
  && check "#2053 the skipped bodies carry their quoting" ok \
  || check "#2053 the skipped bodies carry their quoting" "got [$asked]"

# ---- the #2050 consumers' shape: (quoted, before, body) triples, nothing for an unclosed body ----
# -B: a bytecode cache left in lib/ fails test-push-scope.sh's #1017 check for every suite after it.
shape="$(python3 -I -B -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("sw", sys.argv[1])
sw = importlib.util.module_from_spec(spec); spec.loader.exec_module(sw)
closed = []
sw.commands("cat <<'"'"'EOF'"'"'\nbody\nEOF", "", closed)
open_ = []
sw.commands("cat <<EOF\nnever closes", "", open_)
print(closed, [len(t) for t in closed], open_)' "$SW")"
[ "$shape" = "[(True, 'cat ', 'body')] [3] []" ] && check "#2050 the heredocs option gives one triple per closed body and none for an unclosed one" ok \
  || check "#2050 the heredocs option gives one triple per closed body and none for an unclosed one" "got [$shape]"

# ---- through the push recogniser every push gate asks ----
P='git push origin main'
if ps_is_git_push $'cat <<EOF\nnote $('"$P"$')\nEOF'; then check "#2053 a push in an unquoted body substitution is a push" ok
else check "#2053 a push in an unquoted body substitution is a push" "not seen"; fi
if ps_is_git_push $'cat <<EOF\nnote `'"$P"$'`\nEOF'; then check "#2053 a push in an unquoted body backquote is a push" ok
else check "#2053 a push in an unquoted body backquote is a push" "not seen"; fi
if ps_is_git_push $'cat <<\'EOF\'\nnote $('"$P"$')\nEOF'; then check "#2053 control: a push in a quoted body is not a push" "seen as a push"
else check "#2053 control: a push in a quoted body is not a push" ok; fi

# ---- a case pattern's ) closes no subshell (#2074) ----
# Each command's directory, as the push gates are given it: a cd inside the subshell ends with it,
# wherever the case pattern's ) falls, and the commands of a branch are commands of their own. The
# branches are read one after another, as the reader reads every compound command, so a cd in one
# carries into the next; what this holds is where the subshell ends.
case_dirs="$(python3 -I -B -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("sw", sys.argv[1])
sw = importlib.util.module_from_spec(spec); spec.loader.exec_module(sw)
for c in sys.argv[2:]:
    print("|".join(d + ":" + t.strip() for d, t in sw.commands(c, "/s")))' "$SW" \
  '(case y in y) cd /w;; esac; cd /x); git push' \
  'cd /a; (case y in (y) cd /w;; z|v) cd /q;& *) cd /r;;& esac); git push' \
  'x=$(case a in a) cd /w;; esac); git push' \
  'case y in y) cd /w;; esac; git push')"
want='/s:case y in|/s:cd /w|/w:esac|/w:cd /x|/s:git push
/s:cd /a|/a:case y in|/a:cd /w|/w:cd /q|/q:cd /r|/r:esac|/a:git push
/s:case a in|/s:cd /w|/w:esac|/s:x=$(case a in a) cd /w;; esac)|/s:git push
/s:case y in|/s:cd /w|/w:esac|/w:git push'
[ "$case_dirs" = "$want" ] && check "#2074 a cd after a case pattern's ) stays in its subshell or substitution" ok \
  || check "#2074 a cd after a case pattern's ) stays in its subshell or substitution" "got [$case_dirs]"
if ps_is_git_push 'case y in a|b) git push origin main;; esac'; then check "#2074 a push in a branch after a|b) is a push" ok
else check "#2074 a push in a branch after a|b) is a push" "not seen"; fi
if ps_is_git_push 'case y in a) echo git push;; esac'; then check "#2074 control: a push only echoed in a branch is not a push" "seen as a push"
else check "#2074 control: a push only echoed in a branch is not a push" ok; fi

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
