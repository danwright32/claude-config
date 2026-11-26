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

# heredoc_openers reads a line on its own, for the whole tree scans that read a file a line at a time
# and follow neither its quotes nor its arithmetic (claude-config#2080). The marker is the whole
# word as heredoc_opener reads it, and a word is taken only where it starts as a marker is written,
# so `$((1<<2))` and a quoted `1<<2` open nothing. Printed by the heredoc-markers mode as
# <line>TAB<marker>, one row per opener.
markers() { printf '%s' "$1" | python3 -B "$SW" heredoc-markers 2>&1; }
_H='<''<'
got="$(markers "cat ${_H}'E'OF
x
cat ${_H}E\"OF\" ${_H}-END-OF
y=\$((1${_H}2)); grep -c '1${_H}2' f
z=\$(cat ${_H}<\"\$f\")
cat ${_H}\\EOF")"
want="$(printf '1\tEOF\n3\tEOF\n3\tEND-OF\n6\tEOF')"
[ "$got" = "$want" ] && check "#2080 heredoc-markers reads each marker whole, quotes removed, and opens nothing on a shift or a here string" ok \
  || check "#2080 heredoc-markers reads each marker whole, quotes removed, and opens nothing on a shift or a here string" "got [$got]"
got="$(printf '%s' "x" | python3 -B "$SW" heredoc-markers; echo "rc=$?")"
[ "$got" = "rc=0" ] && check "#2080 a text opening no heredoc prints nothing and exits 0" ok \
  || check "#2080 a text opening no heredoc prints nothing and exits 0" "got [$got]"
py_got="$(python3 -B -c '
import importlib.util, sys
s = importlib.util.spec_from_file_location("sw", sys.argv[1]); m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
h = "<" "<"
print(m.heredoc_opener("x" + h + "1EOF", 1), m.heredoc_opener("x" + h + "1EOF", 1, marker_start=True),
      m.heredoc_opener(h + "$\x27EOF\x27", 0, marker_start=True)[0], m.heredoc_openers("a " + h + "-\x27E\x27OF b")[0])' "$SW" 2>&1)"
[ "$py_got" = "('1EOF', False, False, 7) None EOF (2, 'EOF', True, True, 10)" ] \
  && check "#2080 marker_start refuses only a word not started as a marker is written, and heredoc_openers gives where each opens" ok \
  || check "#2080 marker_start refuses only a word not started as a marker is written, and heredoc_openers gives where each opens" "got [$py_got]"
# A reader that must not miss a heredoc asks with marker_start False (claude-config#2641: the Slack
# drafts gate, over a script it cannot follow). Then a marker starting with a digit is an opener,
# over a whole text of several lines, a here string still is not, and quoted says whether the shell
# expands the body. The same text asked the default way, as the scans ask, misses the digit marker.
py_got="$(python3 -B -c '
import importlib.util, sys
s = importlib.util.spec_from_file_location("sw", sys.argv[1]); m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
h = "<" "<"
text = "bash " + h + "1\necho x\n1\ncat " + h + "\x27EOF\x27\ny\nEOF\ngrep -c x " + h + "<" + " \"$1\"\n"
print([(o[1], o[3]) for o in m.heredoc_openers(text, marker_start=False)], [(o[1], o[3]) for o in m.heredoc_openers(text)])' "$SW" 2>&1)"
[ "$py_got" = "[('1', False), ('EOF', True)] [('EOF', True)]" ] \
  && check "#2641 heredoc_openers with marker_start False takes a marker starting with a digit, and by default does not" ok \
  || check "#2641 heredoc_openers with marker_start False takes a marker starting with a digit, and by default does not" "got [$py_got]"

# #2447: a backslash newline outside single quotes is a line continuation, which the shell removes,
# so a command continued that way has the same words as one written on one line, and its leading
# assignments come off it, at the top level and inside a substitution alike. Inside single quotes it
# is two characters the shell keeps.
cont_got="$(python3 -B -c '
import importlib.util, sys
s = importlib.util.spec_from_file_location("sw", sys.argv[1]); m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
out = []
for c in ["A=1 B=2 \\\n  curl https://e.invalid/h", "x=$(\nA=1 \\\n curl https://e.invalid/h)"]:
    for r in m.every_command(c):
        if "x=" not in r[1]:
            out.append((m.command_words(r[1]), m.split(r[1])[0], m.first_word(m.split(r[1])[1])[0]))
out.append(m.command_words("echo '"'"'a\\\nb'"'"'"))
print(out)' "$SW" 2>&1)"
[ "$cont_got" = "[(['A=1', 'B=2', 'curl', 'https://e.invalid/h'], ['A=1', 'B=2'], 'curl'), (['A=1', 'curl', 'https://e.invalid/h'], ['A=1'], 'curl'), ['echo', 'a\\\\\\nb']]" ] \
  && check "#2447 a backslash newline continuation is removed from a command's words, at the top level and in a substitution, and kept inside single quotes" ok \
  || check "#2447 a backslash newline continuation is removed from a command's words, at the top level and in a substitution, and kept inside single quotes" "got [$cont_got]"

# #2447: the readers that split a command's words themselves read a continuation the same way: the
# directory a cd moves to, the string a bash -c runs, the file a source reads and rtk's subcommand
# each come out as written on one line, not with a newline in front.
cont_readers="$(python3 -B -c '
import importlib.util, sys
s = importlib.util.spec_from_file_location("sw", sys.argv[1]); m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
print(repr(m.cd_target("cd \\\n/w")))
print(repr(m.wrapped("bash \\\n-c \"git push\"")))
print(repr(m._script_run("source", "source \\\n/x/file.sh")))
print(repr(m.rtk_field([("rtk", "\\\ninit -g")])))' "$SW" 2>&1 | paste -sd'|' -)"
[ "$cont_readers" = "'/w'|('bash -c', 'git push', '')|('source', None, $(python3 -B -c '
import importlib.util, sys
s = importlib.util.spec_from_file_location("sw", sys.argv[1]); m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
print(repr(m.WHY_FILE % "/x/file.sh"))' "$SW"))|'rtk\\x1dinit\\x1d\\x1d-g'" ] \
  && check "#2447 cd_target, wrapped, a sourced file and rtk_field read past a backslash newline continuation" ok \
  || check "#2447 cd_target, wrapped, a sourced file and rtk_field read past a backslash newline continuation" "got [$cont_readers]"

# spans gives each body the reading skipped as text: where its << is (the opener parts gives the
# command that opens it) and where the body is, so a caller can tell whose body it is (#2722).
spans_read="$(python3 -B -c '
import importlib.util, sys
s = importlib.util.spec_from_file_location("sw", sys.argv[1]); m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
cmd = "cat <<A; tee f <<'"'"'B'"'"'\na1\nA\nb1\nb2\nB\necho done"
parts, spans, hd = [], [], []
m.commands(cmd, heredocs=hd, parts=parts, spans=spans)
for opener, start, end in spans:
    owner = [cmd[p["start"]:p["end"]].strip() for p in parts if any(o[0] == opener for o in p["openers"])]
    print(cmd[opener:opener + 2] + "|" + "/".join(owner) + "|" + cmd[start:end].replace("\n", "~"))
print(len(spans) == len(hd))' "$SW" 2>&1 | paste -sd'^' -)"
[ "$spans_read" = "<<|cat <<A|~a1^<<|tee f <<'B'|~b1~b2^True" ] \
  && check "#2722 spans names each body's opener, its command, and its text, one for each body heredocs is given" ok \
  || check "#2722 spans names each body's opener, its command, and its text, one for each body heredocs is given" "got [$spans_read]"

# ---- a comment inside an array's ( ) ends at the line break (#2683) ----
# An apostrophe in such a comment opened a quote that ran on past the array. The comment ends where
# the line does: a newline, or in the flattened form with no newline, the "; " standing for one.
array_read="$(python3 -I -B -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("sw", sys.argv[1])
sw = importlib.util.module_from_spec(spec); spec.loader.exec_module(sw)
for c in sys.argv[2:]:
    print("|".join(t.strip() for d, t in sw.commands(c, "/s")))' "$SW" \
  "$(printf 'a=(\n  "x"\n  # the note'"'"'s\n  "y"\n)\necho after')" \
  "a=(\"x\" # the note's; \"y\"); echo after" 2>&1)"
want='a=(
  "x"
  # the note'"'"'s
  "y"
)|echo after
a=("x" # the note'"'"'s; "y")|echo after'
[ "$array_read" = "$want" ] && check "#2683 a comment in an array ends at the line break, newline or flattened" ok \
  || check "#2683 a comment in an array ends at the line break, newline or flattened" "got [$array_read]"

# Inside single quotes nothing but the closing quote changes the reading, and inside double quotes or
# an unquoted heredoc body only a backslash, a $, a backquote (and in double quotes the closing ")
# do, so the reader goes straight to the next of those, or to the end of the body it is in, rather
# than one character at a time: the 1.8 MB claude-sync suite is mostly quoted text, and reading it
# was a fifth of the Slack drafts gate's time judging it (claude-config#2918). Counted by the
# characters the reader takes one at a time, and checked for the same reading at every stop.
stepped_py="$(mktemp "${TMPDIR:-/tmp}/sw-stepped.XXXXXX")" || exit 1
cat > "$stepped_py" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("sw", sys.argv[1])
sw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sw)
taken = [0]
class Counted(str):
    def __getitem__(self, k):
        taken[0] += 1
        return str.__getitem__(self, k)
wrong = []
long = "x y " * 2500
for label, text, want in (
        ("single quotes", "echo '%s'; git push" % long, ["echo '%s'" % long, "git push"]),
        ("double quotes", 'echo "%s $(date) %s"; git push' % (long, long), ["date", 'echo "%s $(date) %s"' % (long, long), "git push"]),
        ("a heredoc body", "cat <<EOF\n%s\n$(date)\n%s\nEOF\ngit push" % (long, long), ["cat <<EOF", "date", "git push"])):
    taken[0] = 0
    got = [t.strip() for d, t in sw.commands(Counted(text), "/")]
    if got != want:
        wrong.append("%s read as %r" % (label, [g[:30] for g in got]))
    if taken[0] > 400:
        wrong.append("%s: %d characters taken one at a time, of %d" % (label, taken[0], len(text)))
# A quote left open where a heredoc body ends is still refused, as the shell finds the closing line first.
for text in ("cat <<EOF\n$(echo 'x\nEOF\n", "cat <<EOF\n$(echo \"x\nEOF\n", "echo 'never closed"):
    try:
        sw.commands(text, "/")
        wrong.append("%r was read, not refused" % text)
    except sw.Unreadable:
        pass
print("; ".join(wrong) or "ok")
PY
stepped="$(python3 -B "$stepped_py" "$SW" 2>&1)"
rm -f "$stepped_py"
check "#2918 the reader goes straight through quoted text and heredoc bodies, and reads them as before" "$stepped"

# And through the text of commands, ${ }, $(( )), a plain ( ) and $'...', each of which changes the
# reading only at a few characters (FRAME_STOPS): stepping one character at a time through commands was
# most of the reader's time judging the claude-sync suite once quoted text was gone past (#2918, a
# second cut). shell_split reads a quoted command a piece at a time, answering and raising as
# shlex.split does, here over every text of up to four of the characters shlex reads specially.
frames_py="$(mktemp "${TMPDIR:-/tmp}/sw-frames.XXXXXX")" || exit 1
cat > "$frames_py" <<'PY'
import importlib.util, itertools, shlex, sys
spec = importlib.util.spec_from_file_location("sw", sys.argv[1])
sw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sw)
taken = [0]
class Counted(str):
    def __getitem__(self, k):
        taken[0] += 1
        return str.__getitem__(self, k)
wrong = []
words = "alpha/beta-gamma.x=1 " * 500
for label, text, want in (
        ("commands", "echo %s\ngit push %s" % (words, words), ["echo " + words.strip(), "git push " + words.strip()]),
        ("${ }", "echo ${x:-%s}; git push" % words, ["echo ${x:-%s}" % words, "git push"]),
        ("$(( ))", "echo $((%s)); git push" % ("1 + 2 * " * 500 + "3"), ["echo $((%s))" % ("1 + 2 * " * 500 + "3"), "git push"]),
        ("an array's ( )", "a=(%s); git push" % words, ["a=(%s)" % words, "git push"]),
        ("$'...'", "echo $'%s'; git push" % words, ["echo $'%s'" % words, "git push"])):
    taken[0] = 0
    got = [t.strip() for d, t in sw.commands(Counted(text), "/")]
    if got != want:
        wrong.append("%s read as %r" % (label, [g[:30] for g in got]))
    if taken[0] > 400:
        wrong.append("%s: %d characters taken one at a time, of %d" % (label, taken[0], len(text)))
def answer(fn, t):
    try:
        return fn(t)
    except ValueError as e:
        return ("ValueError", str(e))
for k in range(5):
    for combo in itertools.product("a'\"\\ \n\t", repeat=k):
        t = "".join(combo)
        if answer(sw.shell_split, t) != answer(lambda x: shlex.split(x, posix=True), t):
            wrong.append("shell_split(%r) is %r, shlex.split gives %r" % (t, answer(sw.shell_split, t), answer(lambda x: shlex.split(x, posix=True), t)))
            break
read = [0]
real = sw.shlex.split
def counted(*a, **k):
    read[0] += 1
    return real(*a, **k)
sw.shlex.split = counted
sw.shell_split("git commit -m \"it's \\\"done\\\"\" --author 'A B' a\\ b")
sw.shlex.split = real
if read[0]:
    wrong.append("a quoted command was handed to shlex, which reads it a character at a time")
print("; ".join(wrong[:5]) or "ok")
PY
frames="$(python3 -B "$frames_py" "$SW" 2>&1)"
rm -f "$frames_py"
check "#2918 the reader goes straight through commands, \${ }, \$(( )), ( ) and \$'...', and splits quoted words as shlex does" "$frames"

# ---- a process substitution: its commands are commands (claude-config#3213) ----
# Until #3213 a <( ), >( ) or zsh's =( ) was read as a plain ( ), so the reader gave no command for
# what the shell runs inside one. Where each runs was measured 2026-11-18 (bash 3.2.57, zsh 5.9).
has 'cat <(echo INNER)' "$X" "#3213 a <( ) holds a command"
has 'echo hi > >(echo INNER)' "$X" "#3213 a >( ) holds a command"
has 'cat =(echo INNER)' "$X" "#3213 zsh's =( ) at the start of a word holds a command"
has 'diff <(echo one) <(echo INNER)' "$X" "#3213 the second of two is read"
has 'cat <(echo one; echo INNER)' "$X" "#3213 each command inside one is read"
has 'cat <(cat <(echo INNER))' "$X" "#3213 one inside another is read"
has 'a=( <(echo INNER) )' "$X" "#3213 one in an array's words is read"
has 'echo ${x:-<(echo INNER)}' "$X" "#3213 one in the word of an unquoted \${ } is read"
has 'echo x<(echo INNER)' "$X" "#3213 one in the middle of a word is read"
has 'echo \\<(echo INNER)' "$X" "#3213 one after an escaped backslash is read"
has 'echo "$(cat <(echo INNER))"' "$X" "#3213 one inside a quoted \$( ) is read"
has 'case $x in <(echo INNER)) echo y ;; esac' "$X" "#3213 one in a case pattern is read"
has 'cat <(echo INNER) b.txt' 'cat <(echo INNER) b.txt' "#3213 its text stays in the command that holds it"
has 'cat <(cd /tmp; echo one); echo INNER' "$X" "#3213 the command after one is still read"
# only <command text> <description>: the reader returns that text as its one command.
only() {
  local got
  got="$(reading "$1")"
  if [[ "$got" == "$1"$'\n'"rc=0" ]]; then check "$2" ok
  else check "$2" "reading was [$(printf '%s' "$got" | tr '\n' '|')]"; fi
}
only 'echo "<(echo INNER)"' "#3213 control: inside double quotes it is text"
only "echo '<(echo INNER)'" "#3213 control: inside single quotes it is text"
only 'echo "${x:-<(echo INNER)}"' "#3213 control: in a double quoted \${ } it is text"
only 'x=(echo INNER)' "#3213 control: an array assignment is no =( )"
only 'echo $(( 3 <(2) ))' "#3213 control: a comparison in arithmetic is no <( )"
only 'a=(one two)' "#3213 control: an array of plain words is read as before"
# A cd inside one ends with it, as the shell's does: the command after runs where the line began.
proc_dir="$(printf '%s' 'cat <(cd /tmp/elsewhere; echo one); git push' | python3 -B "$SW" commands | python3 -c '
import sys
recs = [r.split("\x1f", 1) for r in sys.stdin.read().split("\x1e") if r]
print("|".join("%s:%s" % (d, t.strip()) for d, t in recs))')"
if [[ "$proc_dir" == ":cd /tmp/elsewhere|/tmp/elsewhere:echo one|:cat <(cd /tmp/elsewhere; echo one)|:git push" ]]; then
  check "#3213 a cd inside one moves only the commands inside it" ok
else
  check "#3213 a cd inside one moves only the commands inside it" "reading was [$proc_dir]"
fi

# ---- an unquoted heredoc the shells keep open (claude-config#3492) ----
# A backslash at the end of a line of an UNQUOTED heredoc's body joins that line to the next, so an
# end marker on the next line is the tail of a longer line and closes nothing. The heredoc stays
# open, the rest of the text is its body, and every $( ) in that rest runs, single quotes or not.
# The reader closed the heredoc at any line that was the marker, read the rest as commands, and so
# read a substitution in single quotes there as a word that never runs: less than the shell runs,
# with nothing named. An unquoted heredoc whose marker never comes was read the same way.
#
# Measured 2026-11-23 with texts that only echo, in bash 3.2.57, bash --posix, sh, dash, zsh 5.9,
# zsh emulating sh and ksh 93u+, each as a -c text, a file and an eval:
#   * one or three backslashes before the marker line, with <<- and tabs too: open in all seven
#   * two or four: closed in all seven; a quoted marker, in any form: closed, a backslash joins nothing
#   * a joined marker and then the marker on a line of its own: closed there in all seven
#   * a line that is only a backslash and then the marker, a marker split over two lines by a
#     backslash, a marker line ending in a backslash and then an empty line: bash, sh and zsh close
#     (the joined line IS the marker) where dash or ksh do not
#   * a line that starts as the marker does and ends in backslashes, then the marker: ksh keeps the
#     first of those backslashes as text, so it joins where the others do not and the reverse
# Where the shells do not close an unquoted heredoc at the first line that is its marker (they
# close it later, or differ, or never close it while a $ or a backquote stands in the rest), the
# reader names the heredoc's << in `unsure` for a caller that asks, as it names a # it cannot tell
# from a comment, and gives that caller the shells' closing line where they agree on one. A caller
# that does not ask is given the reading it always was.
#
# Each row is run here by the shells this machine has, with `touch ran` for the marker.
echo "the command reader: an unquoted heredoc closes only where the shells close it (claude-config#3492)"
OPEN_T="$(mktemp -d "${TMPDIR:-/tmp}/sw-heredoc-open.XXXXXXXX")" || exit 1
case "${OPEN_T%/}" in ''|/|"${HOME%/}") echo "refusing to run: throwaway directory came back as '$OPEN_T'" >&2; exit 2 ;; esac
# One line for each check: "ok<TAB>description" or "FAIL<TAB>description<TAB>why".
python3 -B - "$SW" "$OPEN_T" > "$OPEN_T/rows.tsv" <<'PY'
import importlib.util
import os
import shutil
import subprocess
import sys
import tempfile

sw_path, scratch = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location("shell_words", sw_path)
sw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sw)

B = "\\"
RAN = "echo '$(touch ran)'"
T = RAN + "\necho end\n"
# (description, text, what the reader must say when asked which lines it is unsure of):
# "not listed" where every shell closes the heredoc at the first line that is its marker, as the
# reader always read it, and "unsure" where they close it anywhere else, differ, or never close it.
ROWS = [
    ("the control: no backslash", "cat <<E\na\nE\n" + T, "not listed"),
    ("one backslash before the marker line", "cat <<E\na" + B + "\nE\n" + T, "unsure"),
    ("two backslashes before the marker line", "cat <<E\na" + B * 2 + "\nE\n" + T, "not listed"),
    ("three backslashes before the marker line", "cat <<E\na" + B * 3 + "\nE\n" + T, "unsure"),
    ("four backslashes before the marker line", "cat <<E\na" + B * 4 + "\nE\n" + T, "not listed"),
    ("a space and a backslash before the marker line", "cat <<E\na " + B + "\nE\n" + T, "unsure"),
    ("a backslash after a substitution, before the marker line", "cat <<E\n$(echo a)" + B + "\nE\n" + T, "unsure"),
    ("two backslashes, then one, before the marker line", "cat <<E\na" + B * 2 + "\nb" + B + "\nE\n" + T, "unsure"),
    ("in a pipeline", "cat <<E | cat\na" + B + "\nE\n" + T, "unsure"),
    ("the tail with no line break after it", "cat <<E\na" + B + "\nE\n" + RAN, "unsure"),
    ("a backslash and a carriage return before the marker line", "cat <<E\na" + B + "\r\nE\n" + T, "not listed"),
    ("a backslash and a space before the marker line", "cat <<E\na" + B + " \nE\n" + T, "not listed"),
    ("<<- the control", "cat <<-E\n\ta\n\tE\n" + T, "not listed"),
    ("<<- one backslash before the marker line", "cat <<-E\n\ta" + B + "\n\tE\n" + T, "unsure"),
    ("<<- two backslashes before the marker line", "cat <<-E\n\ta" + B * 2 + "\n\tE\n" + T, "not listed"),
    ("<<- a backslash in the middle of the body", "cat <<-E\n\ta" + B + "\n\tb\n\tE\n" + T, "not listed"),
    ("a single quoted marker", "cat <<'E'\na" + B + "\nE\n" + T, "not listed"),
    ("a double quoted marker", "cat <<\"E\"\na" + B + "\nE\n" + T, "not listed"),
    ("a marker quoted by a backslash", "cat <<" + B + "E\na" + B + "\nE\n" + T, "not listed"),
    ("a marker quoted in part", "cat <<E''\na" + B + "\nE\n" + T, "not listed"),
    ("<<- a quoted marker", "cat <<-'E'\n\ta" + B + "\n\tE\n" + T, "not listed"),
    ("a quoted marker, a line that is only a backslash", "cat <<'E'\n" + B + "\nE\n" + T, "not listed"),
    ("a backslash in the middle of the body", "cat <<E\na" + B + "\nb\nE\n" + T, "not listed"),
    ("two backslashes in the middle of the body", "cat <<E\na" + B + "\nb" + B + "\nc\nE\n" + T, "not listed"),
    ("a joined marker, then the marker on its own line", "cat <<E\na" + B + "\nE\nE\n" + T, "unsure"),
    ("a joined marker that ends in a backslash itself, then the marker", "cat <<E\na" + B + "\nE" + B + "\nb\nE\n" + T, "not listed"),
    ("a joined marker, an indented one, then the marker", "cat <<E\na" + B + "\n E\nE\n" + T, "not listed"),
    ("a joined marker, a substitution, then the marker", "cat <<E\na" + B + "\nE\n$(touch ran)\nE\n", "unsure"),
    ("a joined marker inside a substitution in the body", "cat <<E\n$(echo a" + B + "\nE\n)\nE\n" + T, "unsure"),
    ("a marker line that ends in a backslash", "cat <<E\nbody\nE" + B + "\n" + T, "unsure"),
    ("a marker line that ends in two backslashes", "cat <<E\nbody\nE" + B * 2 + "\n" + T, "unsure"),
    ("a marker that never comes", "cat <<E\nbody\n" + T, "unsure"),
    ("two heredocs, the first left open", "cat <<A <<B\na" + B + "\nA\nb\nB\n" + T, "unsure"),
    ("two heredocs, the second left open", "cat <<A <<B\na\nA\nb" + B + "\nB\n" + T, "unsure"),
    ("two heredocs, a quoted one and then one left open", "cat <<'A' <<B\na" + B + "\nA\nb" + B + "\nB\n" + T, "unsure"),
    ("two heredocs, the second quoted", "cat <<A <<'B'\na\nA\nb" + B + "\nB\n" + T, "not listed"),
    ("two heredocs, the first joined and then closed", "cat <<A <<B\na" + B + "\nA\nA\nb\nB\n" + T, "unsure"),
    ("in a $( ), the tail inside it", "x=$(cat <<E\na" + B + "\nE\n" + RAN + "\n)\necho end\n", "unsure"),
    ("in a $( ), closed later", "x=$(cat <<E\na" + B + "\nE\nE\n)\n" + T, "unsure"),
    # Where the shells differ.
    ("a line that is only a backslash, then the marker", "cat <<E\n" + B + "\nE\n" + T, "unsure"),
    ("a body line, a line that is only a backslash, then the marker", "cat <<E\na\n" + B + "\nE\n" + T, "unsure"),
    ("a marker split over two lines by a backslash", "cat <<EOF\na\nE" + B + "\nOF\n" + T, "unsure"),
    ("a marker line ending in a backslash, then an empty line", "cat <<E\nbody\nE" + B + "\n\n" + T, "unsure"),
    ("a marker line ending in a backslash, then the marker", "cat <<E\nbody\nE" + B + "\nE\n" + T, "unsure"),
    ("the start of the marker and a backslash, then the marker", "cat <<EOF\nEO" + B + "\nEOF\n" + T, "unsure"),
    ("the start of the marker and two backslashes, then the marker", "cat <<EOF\nEO" + B * 2 + "\nEOF\n" + T, "unsure"),
    ("<<- a line that is only a backslash, then the marker", "cat <<-E\n" + B + "\n\tE\n" + T, "unsure"),
    ("<<- a tab and a backslash, then the marker", "cat <<-E\n\t" + B + "\n\tE\n" + T, "unsure"),
    ("<<- the start of the marker and a backslash, then the marker", "cat <<-EOF\n\tEO" + B + "\n\tEOF\n" + T, "unsure"),
    # A heredoc on ONE line, no line break anywhere in the text. No shell gives it a body: the line
    # ends with the text, so it reads an empty body to the end and runs every command after the <<
    # on that line (bash 3.2 and zsh, measured 2026-11-23: `cat <<E; echo RAN; E` printed RAN, then
    # "command not found" for E). The reader takes such a text for the flattened form the push hooks
    # make, a "; " standing for each line break, and so took the command for the body.
    ("one line: a command, then the marker", "cat <<E; touch ran; E", "unsure"),
    ("one line: a quoted marker, a command, then the marker", "cat <<'E'; touch ran; E", "unsure"),
    ("one line: a command, then the marker, then more", "cat <<E; touch ran; E; echo end", "unsure"),
    ("one line, the control: a command and no marker after it", "cat <<E; touch ran", "listed"),
    # The OPENER's own line ends in a backslash (review of #3495). Every shell reads a backslash
    # and a line break before or inside the marker word as joining the two lines, so the marker is
    # the word that results, unquoted: `cat <<E\` and then `x` waits for a line that is Ex, the
    # line that is E closes nothing, and the rest is a body whose $( ) runs. Inside double quotes
    # the two lines are joined the same way. The reader took the backslash for one quoting the
    # line break, so the marker was quoted, never came, and the rest was read as commands, with
    # nothing named. Measured 2026-11-23 in bash 3.2.57, bash --posix, sh, dash, zsh 5.9 and ksh
    # 93u+, which agree on every row here but two: with `<<` and then a backslash and -E on the
    # next line, bash, sh and dash strip tabs and zsh and ksh do not, and a heredoc in a $( ) so
    # opened is a syntax error in dash, zsh and ksh. The reader names every opener that holds
    # such a join, whether or not it can follow it, so nothing it read as a command before is
    # dropped on the strength of the join.
    ("the opener line ends in a backslash, a line, then the marker", "cat <<E" + B + "\nx\nE\n" + T, "unsure"),
    ("the opener line ends in a backslash, then the marker", "cat <<E" + B + "\nE\n" + T, "unsure"),
    ("the opener line ends in a backslash, a word, a body, then the marker", "cat <<E" + B + "\nF\nbody\nE\n" + T, "unsure"),
    ("<< and a backslash, the marker on the next line, a joined marker later", "cat <<" + B + "\nE\nbody" + B + "\nE\n" + T, "unsure"),
    ("<<-E and a backslash, a line, then the marker after a tab", "cat <<-E" + B + "\nx\n\tE\n" + T, "unsure"),
    ("the opener line ends in a backslash, a $( ) in the body, then the joined marker", "cat <<E" + B + "\nx\n" + RAN + "\nEx\necho end\n", "unsure"),
    ("the opener line ends in a backslash, then an empty line", "cat <<E" + B + "\n\n" + RAN + "\nE\necho end\n", "unsure"),
    ("<< and a backslash, the marker on the next line", "cat <<" + B + "\nE\n" + RAN + "\nE\necho end\n", "unsure"),
    ("<<, a blank and a backslash, the marker on the next line", "cat << " + B + "\nE\n" + RAN + "\nE\necho end\n", "unsure"),
    ("<<- and a backslash, the marker on the next line", "cat <<-" + B + "\nE\n\t" + RAN + "\n\tE\necho end\n", "unsure"),
    ("<< and a backslash, -E on the next line", "cat <<" + B + "\n-E\n\t" + RAN + "\n\tE\necho end\n", "unsure"),
    ("the opener line ends in a backslash, and the joined marker closes it", "cat <<E" + B + "\nx\nbody\nEx\n" + T, "unsure"),
    ("a double quoted marker joined over two lines", "cat <<\"E" + B + "\nx\"\n" + RAN + "\nEx\necho end\n", "unsure"),
    ("a marker quoted by a backslash, then joined to the next line", "cat <<" + B + "E" + B + "\nx\n" + RAN + "\nEx\necho end\n", "unsure"),
    ("the opener line ends in three backslashes", "cat <<E" + B * 3 + "\nx\n" + RAN + "\nE" + B + "x\necho end\n", "unsure"),
    ("the opener line ends in a backslash, then a ; and a command", "cat <<E" + B + "\n; " + RAN + "\necho end\n", "unsure"),
    ("two heredocs, the second's opener line ends in a backslash", "cat <<A <<E" + B + "\nx\na\nA\nE\n" + T, "unsure"),
    ("two heredocs, the first's opener joined to the second's", "cat <<A" + B + "\n<<E\na\nA\nb\nE\n" + T, "unsure"),
    ("in a $( ), the opener line ends in a backslash", "y=$(cat <<E" + B + "\nx\nE\n" + RAN + "\n)\necho end\n", "unsure"),
    # A quoted marker that holds a line break itself (single quotes keep the backslash and the
    # line break; double quotes keep a bare line break): no line is that marker, so bash, sh and
    # zsh never close the heredoc, while dash and ksh close it at those two lines, where the
    # reader did. Named where the reader closes it.
    ("a single quoted marker that holds a backslash and a line break, those two lines later", "cat <<'E" + B + "\nx'\nbody\nE" + B + "\nx\n" + T, "unsure"),
    ("a double quoted marker that holds a line break, those two lines later", "cat <<\"E\nx\"\nbody\nE\nx\n" + T, "unsure"),
    # The controls. Two backslashes are one quoted backslash and join nothing. A backslash after
    # a blank joins the next line to the COMMAND, not to the marker, which the reader always read
    # as the shells do.
    ("the control: the opener line ends in two backslashes", "cat <<E" + B * 2 + "\nx\nE\n" + T, "not listed"),
    ("the control: a backslash after a blank on the opener line", "cat <<E " + B + "\nx\n" + RAN + "\nE\necho end\n", "listed"),
]
# Rows every one of the seven kept the heredoc open in, so one shell here must run the marker, or the
# row measures nothing.
OPEN = {"one backslash before the marker line", "three backslashes before the marker line",
        "a space and a backslash before the marker line", "<<- one backslash before the marker line",
        "a marker line that ends in a backslash", "a marker that never comes",
        "two heredocs, the second left open", "the tail with no line break after it",
        "one line: a command, then the marker", "one line: a quoted marker, a command, then the marker",
        "one line: a command, then the marker, then more", "one line, the control: a command and no marker after it",
        "the opener line ends in a backslash, a line, then the marker", "the opener line ends in a backslash, then the marker",
        "the opener line ends in a backslash, a word, a body, then the marker",
        "<< and a backslash, the marker on the next line, a joined marker later",
        "<<-E and a backslash, a line, then the marker after a tab",
        "the opener line ends in a backslash, a $( ) in the body, then the joined marker",
        "the opener line ends in a backslash, then an empty line", "<< and a backslash, the marker on the next line",
        "the control: a backslash after a blank on the opener line"}
SHELLS = {"bash": ["bash", "--noprofile", "--norc", "-c"], "bash --posix": ["bash", "--posix", "--noprofile", "--norc", "-c"],
          "sh": ["sh", "-c"], "dash": ["dash", "-c"], "zsh": ["zsh", "-f", "-c"], "ksh": ["ksh", "-c"]}
HAVE = [name for name in SHELLS if shutil.which(SHELLS[name][0])]
# ksh 93u+ never returns from this one (measured 2026-11-23, 5 seconds, three times).
SKIP = {("ksh", "two heredocs, the first left open")}


def runs(shell, text):
    d = tempfile.mkdtemp(prefix="run-", dir=scratch)
    try:
        subprocess.run(SHELLS[shell] + [text], cwd=d, stdin=subprocess.DEVNULL,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=20,
                       env={"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": d})
        return os.path.exists(os.path.join(d, "ran"))
    finally:
        shutil.rmtree(d, ignore_errors=True)


def asked(text):
    """(the commands, the lines named, whether the reading gave up)."""
    marks = []
    try:
        cut = [t.strip() for _, t in sw.commands(text, unsure=marks)]
    except sw.Unreadable:
        return [], marks, True
    except TypeError as e:
        return [], [("no unsure", str(e))], True
    return cut, marks, False


def reading(text):
    cut, marks, gave_up = asked(text)
    if marks:
        return "unsure"
    if gave_up:
        return "unreadable"
    return "listed" if "touch ran" in cut else "not listed"


def say(ok, what, why=""):
    print("ok\t" + what if ok else "FAIL\t" + what + "\t" + why)


print("shells\t" + " ".join(HAVE))
for name, text, want in ROWS:
    got = reading(text)
    ran = [shell for shell in HAVE if (shell, name) not in SKIP and runs(shell, text)]
    shown = text.replace("\\", "\\\\").replace("\n", "\\n").replace("\t", "\\t").replace("\r", "\\r")
    say(not (ran and got == "not listed"),
        "#3492 a substitution a shell runs after a heredoc it keeps open is never left out: %s" % name,
        "%s ran the marker and the reader left it out: [%s]" % (" and ".join(ran), shown))
    say(got == want, "#3492 the reader says %s: %s" % (want, name),
        "the reader said %s, wanted %s: [%s]" % (got, want, shown))
    if name in OPEN:
        say(bool(ran), "#3492 the row is a real one, a shell here runs the marker: %s" % name,
            "none of %s ran it: [%s]" % (", ".join(HAVE), shown))

def unasked(text, bodies=None):
    try:
        return [t.strip() for _, t in sw.commands(text, heredocs=bodies)]
    except sw.Unreadable:
        return ["unreadable"]


# What is named is the heredoc's own <<, to the end of the line it is on, and the caller that asks
# is given the rest as commands, as a heredoc that never closes always was read.
OPEN_TEXT = "cat <<E\na" + B + "\nE\n" + T
cut, marks, gave_up = asked(OPEN_TEXT)
say(marks == [(4, 7)] and not gave_up, "#3492 a heredoc left open is named by its << and the line it opens on",
    "named %r, gave up: %s" % (marks, gave_up))
say(cut == ["cat <<E", "a" + B + "\nE", RAN, "echo end"],
    "#3492 a caller that asks is given the rest of a heredoc left open as commands", "commands gave %r" % (cut,))
# A heredoc joined and then closed: the caller that asks is given the shells' reading, the joined
# marker part of the body and the body ending at the marker on a line of its own, and its name.
LATER_TEXT = "cat <<E\na" + B + "\nE\nE\n" + T
marks, bodies = [], []
try:
    cut = [t.strip() for _, t in sw.commands(LATER_TEXT, heredocs=bodies, unsure=marks)]
except sw.Unreadable:
    cut = ["unreadable"]
say(cut == ["cat <<E", RAN, "echo end"] and bodies == [(False, "cat ", "a" + B + "\nE")] and marks == [(4, 7)],
    "#3492 a caller that asks is given a joined marker as part of the body, and the heredoc's name",
    "commands gave %r, the bodies %r, named %r" % (cut, bodies, marks))
# A caller that does not ask is given the reading it always was, in each of the three: other gates
# read through the reader, and what such a heredoc means to each is that gate's to decide.
DIFFER_TEXT = "cat <<E\n" + B + "\nE\n" + T
bodies = []
got = (unasked(OPEN_TEXT), unasked(LATER_TEXT, bodies), unasked(DIFFER_TEXT))
say(got == (["cat <<E", RAN, "echo end"], ["cat <<E", "E", RAN, "echo end"], ["cat <<E", RAN, "echo end"])
    and bodies == [(False, "cat ", "a" + B)],
    "#3492 a caller that does not ask is given the reading it always was",
    "commands gave %r and the bodies %r" % (got, bodies))
# A marker that never comes at all, with no $ and no backquote after it: no shell runs anything
# from the rest as a substitution, the reading goes on to the rest as commands as it always did,
# and nothing is named. (What the heredoc's command is fed is then the whole rest, in the reader
# and the shells alike.)
text, want = "cat <<E\nbody\necho end\n", ["cat <<E", "body", "echo end"]
cut, marks, gave_up = asked(text)
say(cut == want and not marks and not gave_up and unasked(text) == want,
    "#3492 with no $ or backquote after it, nothing is named and the reading is as it was: a marker that never comes",
    "commands gave %r, named %r" % (cut, marks))
# A JOINED marker with no $ and no backquote after it was read the same way until the review of
# #3495: closed at the marker, nothing named, on the ground that no shell runs a substitution from
# the rest. But the rest is still the heredoc's body, and the shells feed it to the heredoc's
# command, while the reading took it for commands of its own. Where the reading closes a heredoc
# that no shell closes, it is named whatever follows, and the caller that asks is given the rest
# as commands, as for a heredoc that never closes.
text = "cat <<E\na" + B + "\nE\necho end\n"
cut, marks, gave_up = asked(text)
say(cut == ["cat <<E", "a" + B + "\nE", "echo end"] and marks == [(4, 7)] and not gave_up
    and unasked(text) == ["cat <<E", "echo end"],
    "#3492 a joined marker with no $ or backquote after it is named too, and a caller that does not ask reads as before",
    "commands gave %r, named %r, unasked %r" % (cut, marks, unasked(text)))
# What that hid, measured 2026-11-23 in bash 3.2.57, bash --posix, sh, dash, zsh 5.9 and ksh 93u+
# with an interpreter and a module that only creates a file: fed by a heredoc whose marker is
# joined to a comment line, it was given the next line too, an import, and ran it, in all six,
# while the reader gave that line as a shell command and the body as the comment alone
# (test-slack-drafts-comment-start.sh holds that case, through the gate). Here the heredoc's
# command is a grep that looks for the line after the marker, and `touch ran` follows only where
# it finds it: where a shell fed that line to grep as part of the body. A quoted marker that holds
# a line break is never closed by bash, sh and zsh (dash and ksh close it at those two lines, as
# the reader did), with the same result. (description, text, whether the reader must name the
# heredoc, whether a shell here must feed the line after the marker to grep)
FED = [
    ("the control: a heredoc every shell closes", "grep -q fed <<E && touch ran\nnote\nE\nfed\n", False, False),
    ("a marker joined to the line before", "grep -q fed <<E && touch ran\nnote" + B + "\nE\nfed\n", True, True),
    ("in a pipeline", "cat <<E | grep -q fed && touch ran\nnote" + B + "\nE\nfed\n", True, True),
    ("<<- and tabs", "grep -q fed <<-E && touch ran\n\tnote" + B + "\n\tE\nfed\n", True, True),
    ("three backslashes", "grep -q fed <<E && touch ran\nnote" + B * 3 + "\nE\nfed\n", True, True),
    ("the control: two backslashes", "grep -q fed <<E && touch ran\nnote" + B * 2 + "\nE\nfed\n", False, False),
    ("the control: a quoted marker", "grep -q fed <<'E' && touch ran\nnote" + B + "\nE\nfed\n", False, False),
    # Not held to be a real row on every machine: the shells differ, and only those named above
    # were measured.
    ("a single quoted marker that holds a backslash and a line break, those two lines later",
     "grep -q fed <<'E" + B + "\nx' && touch ran\nnote\nE" + B + "\nx\nfed\n", True, False),
    ("a double quoted marker joined over two lines, those two lines later",
     "grep -q fed <<\"E" + B + "\nx\" && touch ran\nnote\nE" + B + "\nx\nfed\n", True, True),
]
for name, text, named, real in FED:
    fed = [shell for shell in HAVE if runs(shell, text)]
    cut, marks, gave_up = asked(text)
    shown = text.replace("\\", "\\\\").replace("\n", "\\n").replace("\t", "\\t")
    say(not fed or bool(marks),
        "#3492 a heredoc a shell keeps open and feeds to its command is never read as closed with nothing named: %s" % name,
        "%s fed the line after the marker to the heredoc's command and the reader named nothing: [%s]" % (" and ".join(fed), shown))
    say(bool(marks) == named, "#3492 the reader %s the heredoc that feeds its command: %s" % ("names" if named else "does not name", name),
        "named %r, commands %r: [%s]" % (marks, cut, shown))
    if real:
        say(bool(fed), "#3492 the row is a real one, a shell here feeds the line after the marker to the heredoc's command: %s" % name,
            "none of %s did: [%s]" % (", ".join(HAVE), shown))
# An opener whose line ends in a backslash is named by its << to the end of its marker word, past
# the line break the shells join, and the caller that asks is given the shells' reading of it: the
# marker is the joined word, unquoted, so a body it closes is read for its substitutions and one
# it never closes is read on as commands. A caller that does not ask is given the reading it
# always was, the backslash quoting the line break.
JOIN_TEXT = "cat <<E" + B + "\nx\nE\n" + T
cut, marks, gave_up = asked(JOIN_TEXT)
say(cut == ["cat <<E" + B + "\nx", "E", RAN, "echo end"] and marks == [(4, 10)] and not gave_up,
    "#3492 an opener joined to the next line is named once, by its << to the end of its marker word",
    "commands gave %r, named %r, gave up: %s" % (cut, marks, gave_up))
JOIN_CLOSED = "cat <<E" + B + "\nx\n" + RAN + "\nEx\necho end\n"
marks, bodies = [], []
try:
    cut = [t.strip() for _, t in sw.commands(JOIN_CLOSED, heredocs=bodies, unsure=marks)]
except sw.Unreadable:
    cut = ["unreadable"]
say(cut == ["cat <<E" + B + "\nx", "touch ran", "echo end"] and bodies == [(False, "cat ", RAN)] and marks == [(4, 10)],
    "#3492 a caller that asks is given the joined marker, unquoted, and the substitutions of the body it closes",
    "commands gave %r, the bodies %r, named %r" % (cut, bodies, marks))
bodies = []
got = (unasked(JOIN_TEXT), unasked(JOIN_CLOSED, bodies))
say(got == (["cat <<E" + B + "\nx", "E", RAN, "echo end"], ["cat <<E" + B + "\nx", RAN, "Ex", "echo end"]) and bodies == [],
    "#3492 a caller that does not ask is given the reading it always was of an opener joined to the next line",
    "commands gave %r and the bodies %r" % (got, bodies))
# The opener helper itself: asked for joins, it reads the marker as the shells do and says where
# each join is; not asked, it reads as it always did, for every other caller of it.
joins = []
got = (sw.heredoc_opener(JOIN_TEXT, 4, joins=joins), joins, sw.heredoc_opener(JOIN_TEXT, 4))
say(got == (("Ex", False, False, 10), [7], ("E\nx", False, True, 10)),
    "#3492 heredoc_opener reads a join in the marker as the shells do only where it is asked to",
    "gave %r" % (got,))
joins = []
got = (sw.heredoc_opener('cat <<"E' + B + '\nx" y', 4, joins=joins), joins,
       sw.heredoc_opener("cat <<- " + B + "\n E", 4, joins=[]), sw.heredoc_opener("cat <<" + B + "\n", 4, joins=[]))
say(got == (("Ex", False, True, 12), [8], ("E", True, False, 12), None),
    "#3492 heredoc_opener reads a join in double quotes and before the marker word, and no marker where none follows",
    "gave %r" % (got,))
# A quoted marker's body is read as written, so a marker that never comes names nothing: no shell
# runs anything in it, and the rest is read as commands, as it was.
cut, marks, gave_up = asked("cat <<'E'\nbody\n" + T)
say(cut == ["cat <<'E'", "body", RAN, "echo end"] and not marks and not gave_up,
    "#3492 the control: a quoted heredoc that never closes names nothing and is read as it was",
    "commands gave %r, named %r" % (cut, marks))
# A text with no line break at all is read as it was, the "; " taken for the line break the push
# hooks made it from. Which "; " was a line break cannot be told, and as typed no shell gives the
# heredoc a body there and every shell runs what the reading took for one, so a heredoc the reading
# closed in such a text is named for a caller that asks, by its << and the "; " after it. A caller
# that does not ask is given the reading it always was.
for text, want in (("cat <<E; a" + B + "; E; " + RAN, ["cat <<E", RAN]),
                   ("cat <<E; a; E; echo x", ["cat <<E", "echo x"])):
    cut, marks, gave_up = asked(text)
    say(cut == want and marks == [(4, 7)] and not gave_up and unasked(text) == want,
        "#3492 a text with no line break is read as it was, and the heredoc it closes is named: %s" % text,
        "commands gave %r, named %r, unasked %r" % (cut, marks, unasked(text)))
# The control: one the reading never closes is read on as commands, as the shells run them, and
# nothing is named.
cut, marks, gave_up = asked("cat <<E; a; echo x")
say(cut == ["cat <<E", "a", "echo x"] and not marks and not gave_up,
    "#3492 the control: a heredoc with no line break that never closes names nothing and is read on",
    "commands gave %r, named %r" % (cut, marks))
PY
rc=$?
[ "$rc" -eq 0 ] || check "#3492 the comparison ran to its end" "python3 exited $rc"
# rows_checked <rows file> <issue>: counts each "ok" or "FAIL" line of a comparison as a check, and
# leaves the shells the comparison ran in ROWS_SHELLS and how many checks it made in ROWS_COUNT.
rows_checked() {
  local verdict what why
  ROWS_SHELLS=""
  ROWS_COUNT=0
  while IFS=$'\t' read -r verdict what why; do
    case "$verdict" in
      ok) check "$what" ok; ROWS_COUNT=$((ROWS_COUNT + 1)) ;;
      FAIL) check "$what" "$why"; ROWS_COUNT=$((ROWS_COUNT + 1)) ;;
      shells) ROWS_SHELLS="$what" ;;
      *) check "$2 a row of the comparison is one this suite reads" "got: $verdict" ;;
    esac
  done < "$1"
}
rows_checked "$OPEN_T/rows.tsv" "#3492"
OPEN_SHELLS="$ROWS_SHELLS"
OPEN_ROWS="$ROWS_COUNT"
rm -rf "$OPEN_T"
case " $OPEN_SHELLS " in
  *" bash "*) check "#3492 the texts were run by this machine's bash" ok ;;
  *) check "#3492 the texts were run by this machine's bash" "no bash was found, so no row was measured against a shell" ;;
esac
for shell in zsh dash ksh; do
  case " $OPEN_SHELLS " in
    *" $shell "*) ;;
    *) echo "SUITE-PART-UNMEASURED what $shell does with each text of #3492, because there is no $shell on this machine" ;;
  esac
done
# A run that compared nothing must not read as a pass.
[ "$OPEN_ROWS" -ge 100 ] || check "#3492 the comparison checked its rows" "only $OPEN_ROWS checks were made, where the table makes two for each row and more, well over 100"

# ---- an end marker written as a dollar quote (claude-config#3566) ----
# The reader took the text between the quotes of <<$'...' for the marker as written, and the next
# quote for its end. The shells that know a dollar quote read its escapes first: after <<$'E\\F'
# (two backslashes) the body ends at the line E\F (one), and the reader ended it at the line with
# two, so every command between those two lines was body text to a gate and a command to the shell.
# After <<$'p\'6' the reader found no marker at all. And dash knows no dollar quote: to it the $ is a
# character of the marker, so no heredoc whose marker holds one ends at the same line in every shell.
#
# The markers are lib/heredoc-markers.json, the one list of markers for this reader and for mod-kit's
# (hooks/commands.ts readDelimiter), in place of a list in each reader's suite that the other never
# ran. This suite runs it, and mod-kit's runs its copy of it (mods/mod-kit/tests/heredoc-markers.ts,
# held to the list's text at the end of this section). It says, for each, the line each of seven
# shells ends the body at (measured 2026-11-24 with texts
# that only print: bash 3.2.57, bash --posix, sh, dash, zsh 5.9, zsh emulating sh and ksh 93u+, each
# as a -c text, a file and an eval). Every row is run here again by each of those shells this
# machine has, so the list cannot say what they do not do; a shell of the same name that is not the
# one measured (sh that is dash, a newer bash) is said to be unmeasured and held to nothing. Then
# every row is asked of the reader, on any machine:
#   * where all seven share a line, the reader gives that marker and names nothing
#   * where they do not, the reader names the heredoc in `unsure` for a caller that asks, and
#     where bash and zsh share a line, which is every dollar quote whose escapes they read alike,
#     its marker is that line for every caller
#   * a command after the line bash and zsh end the body at is a command to the reader too, whatever
#     other line the list names comes after it
echo "the command reader: an end marker written as a dollar quote (claude-config#3566)"
MARK_T="$(mktemp -d "${TMPDIR:-/tmp}/sw-heredoc-marker.XXXXXXXX")" || exit 1
case "${MARK_T%/}" in ''|/|"${HOME%/}") echo "refusing to run: throwaway directory came back as '$MARK_T'" >&2; exit 2 ;; esac
python3 -B - "$SW" "$MARK_T" "$DIR/lib/heredoc-markers.json" > "$MARK_T/rows.tsv" <<'PY'
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile

sw_path, scratch, rows_path = sys.argv[1], sys.argv[2], sys.argv[3]
spec = importlib.util.spec_from_file_location("shell_words", sw_path)
sw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sw)
with open(rows_path) as f:
    data = json.load(f)

B = "\\"
SHELLS, GROUPS, ROWS = data["shells"], data["groups"], data["rows"]
EVERY = set(GROUPS["all"])


def members(v):
    return set(GROUPS[v] if isinstance(v, str) else v)


def output_of(argv, text):
    """The lines a shell prints for a text that only prints."""
    d = tempfile.mkdtemp(prefix="run-", dir=scratch)
    try:
        p = subprocess.run(argv + [text], cwd=d, stdin=subprocess.DEVNULL,
                           stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=20,
                           env={"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": d})
        return p.stdout.decode("utf-8", "replace").split("\n")
    except subprocess.TimeoutExpired:
        return NO_ANSWER
    finally:
        shutil.rmtree(d, ignore_errors=True)


# What output_of gives for a shell that did not finish: never read as "printed nothing".
NO_ANSWER = ["(no answer in 20 seconds)"]


def printed(shell, text):
    return output_of(SHELLS[shell]["run"], text)


# The list says what seven named shells did, on macOS. A machine's bash, sh or dash can be another
# shell altogether (on Linux sh is often dash, and bash is newer than 3.2), so a shell here is held
# to the list only where its probe prints what the measured one's did. The rest is said to be
# unmeasured, by name, and is no failure: what the reader must give is read from the list alone,
# on any machine.
HAVE = []
for name in SHELLS:
    probe, want = SHELLS[name]["probe"], SHELLS[name]["prints"]
    if not shutil.which(probe[0]):
        print("unmeasured\twhat %s does with each marker of #3566, because there is no %s on this machine" % (name, probe[0]))
        continue
    said = output_of(probe[:-1], probe[-1])[0].strip()
    if said.startswith(want):
        HAVE.append(name)
    else:
        print("unmeasured\twhat %s does with each marker of #3566, because the list was measured on one that says '%s' and this machine's says '%s'"
              % (name, want, said))


def shown(t):
    t = t.replace(B, B * 2).replace("\n", B + "n").replace("\t", B + "t")
    return "".join(c if " " <= c <= "~" else "<%02x>" % ord(c) for c in t)


READER = [0]  # how many checks were of the reader alone, which no machine's shells decide


def say(ok, what, why="", shells=False):
    print("ok\t" + what if ok else "FAIL\t" + what + "\t" + why)
    READER[0] += 0 if shells else 1


def opener(text, at):
    """(what heredoc_opener gives, where it says a dollar quote opens), the second None for a
    reader that cannot be asked."""
    doubts = []
    try:
        return sw.heredoc_opener(text, at, doubts=doubts), doubts
    except TypeError:
        return sw.heredoc_opener(text, at), None


def read(text, ask):
    """(the commands, the bodies, the lines named) as a caller that asks, or does not, is given them."""
    bodies, marks = [], []
    try:
        if ask:
            cut = [t.strip() for _, t in sw.commands(text, heredocs=bodies, unsure=marks)]
        else:
            cut = [t.strip() for _, t in sw.commands(text, heredocs=bodies)]
    except sw.Unreadable:
        return ["unreadable"], bodies, marks
    return cut, bodies, marks


BODY = "v=$((1+1))"
for row in ROWS:
    name, word, quoted, closes = row["name"], row["word"], row["quoted"], row["closes"]
    lines = list(closes) + row.get("never", [])
    head = "cat <<" + word
    named = (4, len(head))
    where = "%s, <<%s" % (name, shown(word))

    # The list against the measured shells this machine has: each ends the body at the lines the
    # list says it does and at no other line the list names, and expands the body or not as it says.
    for line in lines if HAVE else []:
        text = head + "\n" + BODY + "\n" + line + "\necho RAN\n"
        want = members(closes.get(line, []))
        wrong, kept = [], []
        for shell in HAVE:
            got = printed(shell, text)
            if got == NO_ANSWER:
                wrong.append("%s gave no answer, so what it does was not seen" % shell)
            elif ("RAN" in got) != (shell in want):
                wrong.append("%s %s" % (shell, "ended it there" if "RAN" in got else "did not end it there"))
            elif "RAN" in got and ("v=2" in got) == quoted:
                kept.append(shell)
        say(not wrong, "#3566 the list says what each shell here does at the line %s: %s" % (shown(line), where),
            "; ".join(wrong), shells=True)
        say(not kept, "#3566 the list says whether the body is expanded, ended at the line %s: %s" % (shown(line), where),
            "%s %s it" % (" and ".join(kept), "expanded" if quoted else "did not expand"), shells=True)

    seven = [line for line in closes if members(closes[line]) == EVERY]
    both = [line for line in closes if {"bash", "zsh"} <= members(closes[line])]
    got, doubts = opener(head, 4)
    if seven:
        say(got == (seven[0], False, quoted, len(head)) and doubts == [],
            "#3566 a marker all seven shells read alike is read as they read it, and no dollar quote is named: " + where,
            "heredoc_opener gave %r and named %r" % (got, doubts))
    else:
        say(bool(doubts), "#3566 heredoc_opener says where the dollar quote the shells read differently opens: " + where,
            "it named %r" % (doubts,))
    if both and not seven:
        say(got == (both[0], False, True, len(head)),
            "#3566 a marker bash and zsh read alike is read as they read it: " + where, "heredoc_opener gave %r" % (got,))
        say(sw.heredoc_opener(head, 4) == got, "#3566 a caller that does not ask is given the same marker: " + where,
            "heredoc_opener gave %r" % (sw.heredoc_opener(head, 4),))

    # Through commands(), ended at the line bash and zsh share: the body is the one line, the
    # command after it is a command, and the heredoc is named unless all seven shells share the line.
    for line in both:
        text = head + "\n" + BODY + "\n" + line + "\necho RAN\n"
        want = ([head, "echo RAN"], [(quoted, "cat ", BODY)])
        cut, bodies, marks = read(text, False)
        say((cut, bodies) == want, "#3566 a caller that does not ask is given the body bash and zsh end: " + where,
            "commands gave %r and the bodies %r" % (cut, bodies))
        cut, bodies, marks = read(text, True)
        say((cut, bodies) == want and marks == ([] if seven else [named]),
            "#3566 a caller that asks is given it too, %s: %s" % ("and nothing is named" if seven else "and the heredoc's name", where),
            "commands gave %r, the bodies %r, named %r" % (cut, bodies, marks))
        # A command between that line and any other line the list names is never body text.
        for other in lines:
            if other == line:
                continue
            text = head + "\n" + BODY + "\n" + line + "\necho BETWEEN\n" + other + "\necho RAN\n"
            can = [shell for shell in HAVE if shell in members(closes[line])]
            ran = [shell for shell in can if "BETWEEN" in printed(shell, text)]
            cut, bodies, marks = read(text, False)
            say("echo BETWEEN" in cut,
                "#3566 a command after the line %s is a command, with the line %s after it: %s" % (shown(line), shown(other), where),
                "%s ran it and the reader gave %r" % (" and ".join(ran) or "no shell here", cut))
            if can:
                say(bool(ran), "#3566 the row is a real one, a shell here runs the command after the line %s: %s" % (shown(line), where),
                    "none of %s ran it" % ", ".join(can), shells=True)
    if not both:
        # The shells share no line, so no reading is theirs: every one of them is named, and a
        # caller that asks is told, whichever line the text ends the body at.
        for line in lines:
            text = head + "\n" + BODY + "\n" + line + "\necho RAN\n"
            cut, bodies, marks = read(text, True)
            say(marks[:1] == [named], "#3566 a heredoc bash and zsh end at different lines is named, ended at the line %s: %s" % (shown(line), where),
                "named %r" % (marks,))

# What the reader gives where bash and zsh share no line: the reading it always was of a dollar
# double quote (bash's), a line break for \n as the two read it (no line can be that marker), and
# any other escape as written.
PINS = [("$'E" + B + "nF'", "E\nF"), ("$'E" + B + "qF'", "E" + B + "qF"), ("$'E" + B + "$F'", "E" + B + "$F"),
        ("$'E" + B + "u0041'", "E" + B + "u0041"), ("$'E" + B + "x'", "E" + B + "x"), ("$'E" + B + "1'", "E" + B + "1"),
        ("$'E" + B + "177'", "E" + B + "177"), ("$'E" + B + "cAF'", "E" + B + "cAF"), ("$'E" + B + "0F'", "E" + B + "0F"),
        ("$'E" + B + "x00F'", "E" + B + "x00F"), ("$'E" + B + "x7f'", "E" + B + "x7f"), ("$'E" + B + "x80'", "E" + B + "x80"),
        ("$'E" + B + "777'", "E" + B + "777"), ('$"EOF"', "EOF"), ('$"E' + B * 2 + 'F"', "E" + B + "F"), ("$$'EOF'", "$EOF")]
listed = {row["word"] for row in ROWS}
for word, marker in PINS:
    head = "cat <<" + word
    got, doubts = opener(head, 4)
    say(got == (marker, False, True, len(head)) and bool(doubts),
        "#3566 a marker bash and zsh read differently is given as %s, and named: <<%s" % (shown(marker), shown(word)),
        "heredoc_opener gave %r and named %r" % (got, doubts))
# Every character from 2 to 126 written as two hex digits and as three octal ones is that
# character to bash and zsh alike (measured 2026-11-24, 250 markers), so the reader gives it.
wrong = []
for v in range(2, 127):
    for esc in ("x%02x" % v, "%03o" % v):
        head = "cat <<$'E" + B + esc + "G'"
        got, doubts = opener(head, 4)
        if got != ("E" + chr(v) + "G", False, True, len(head)) or not doubts:
            wrong.append(esc)
say(not wrong, "#3566 a hex or octal escape for a character from 2 to 126 is read as that character",
    "%d of 250 were not, the first: %s" % (len(wrong), " ".join(wrong[:6])))
# Where the dollar quotes open, for the caller that names them; and none where a $ before a quote
# is no dollar quote's.
got = [opener("cat <<" + word, 4)[1] for word in ("E$'O'F", "$'a'$'b'", 'E$"O"F', B + "$'EOF'", '"$"' + "'EOF'", "'EOF'", "EOF")]
say(got == [[7], [6, 10], [7], [], [], [], []],
    "#3566 heredoc_opener names each dollar quote by where its $ stands, and nothing else", "named %r" % (got,))
# A dollar quote ends at the first quote no backslash escapes, so one whose last quote is escaped
# never closes and opens no heredoc, where the reader ended it at that escaped quote.
got = (opener("cat <<$'E" + B + "'", 4)[0], opener("cat <<$'E" + B * 2 + "'", 4)[0], opener("cat <<'E" + B + "'", 4)[0])
say(got == (None, ("E" + B, False, True, 12), ("E" + B, False, True, 10)),
    "#3566 a dollar quote ends at the first quote no backslash escapes, and a plain quote at the first quote",
    "heredoc_opener gave %r" % (got,))
# The issue's own text, whole: both shells run the command between the two lines.
text = "cat <<$'E" + B * 2 + "F'\nbody\nE" + B + "F\necho BETWEEN\nE" + B * 2 + "F\necho end\n"
cut, bodies, marks = read(text, False)
say(cut[:2] == ["cat <<$'E" + B * 2 + "F'", "echo BETWEEN"] and bodies == [(True, "cat ", "body")],
    "#3566 the lines between the marker the shells end the body at and the marker as written are commands",
    "commands gave %r and the bodies %r" % (cut, bodies))
# The marker printing mode the line at a time scans read: a marker holding a tab is printed whole
# after the first tab, and one holding a line break, which no line of a body can be, gets no row,
# so such a scan reads the lines after it as code.
p = subprocess.run([sys.executable, "-B", sw_path, "heredoc-markers"], stdout=subprocess.PIPE, timeout=20,
                   input=("cat <<$'E" + B + "tF'\ncat <<$'E" + B + "nF' <<$'p" + B + "x36'\n").encode())
say(p.stdout.decode() == "1\tE\tF\n2\tp6\n", "#3566 heredoc-markers prints a translated marker, and no row for one that holds a line break",
    "printed %r" % (p.stdout.decode(),))
print("listed\t%d" % len(ROWS))
print("reader\t%d" % READER[0])
PY
rc=$?
[ "$rc" -eq 0 ] || check "#3566 the comparison ran to its end" "python3 exited $rc"
MARK_LISTED="$(awk -F'\t' '$1 == "listed" { print $2 }' "$MARK_T/rows.tsv")"
MARK_READER="$(awk -F'\t' '$1 == "reader" { print $2 }' "$MARK_T/rows.tsv")"
# A shell this machine lacks, or one that is not the shell the list was measured on, is a part
# not measured, said by name; the checks of the reader do not need it.
awk -F'\t' '$1 == "unmeasured" { print "SUITE-PART-UNMEASURED " $2 }' "$MARK_T/rows.tsv"
grep -v -E '^(listed|reader|unmeasured)	' "$MARK_T/rows.tsv" > "$MARK_T/checks.tsv"
rows_checked "$MARK_T/checks.tsv" "#3566"
# A run that compared nothing, or a list cut short, must not read as a pass. The floor is on the
# checks of the reader, which are made on every machine, whatever shells it has.
[ "${MARK_LISTED:-0}" -ge 54 ] || check "#3566 the list holds its markers" "only ${MARK_LISTED:-0} markers were read from lib/heredoc-markers.json, where it holds 54"
[ "${MARK_READER:-0}" -ge 200 ] || check "#3566 the comparison checked the reader" "only ${MARK_READER:-0} checks of the reader were made, where the list makes over 200"

# The mods' reader is held to the same list, through a copy: a mod's tests can import only the
# mod's own files (the same arrangement as lib/heredoc-closes.json, claude-config#3592). The copy is
# the list's text after one line, so it cannot come to say otherwise. A copy that is not there and
# a copy that differs are said apart (L11).
MARK_ROOT="$(bash "$DIR/lib/checkout-root.sh" "$DIR/.." 2>/dev/null || true)"
if [ -z "$MARK_ROOT" ] || [ ! -d "$MARK_ROOT" ]; then
  echo "SUITE-PART-UNMEASURED whether the mods' suite reads the same heredoc markers as this one, because $DIR/.. is not the payload of a claude-config checkout"
else
  MARK_COPY="$MARK_ROOT/payload/mods/mod-kit/tests/heredoc-markers.ts"
  if [ ! -f "$MARK_COPY" ]; then
    check "#3566 the mods' suite has the list of markers" "payload/mods/mod-kit/tests/heredoc-markers.ts is not there, so the mods' suite has no list to run: write it again, its header and then the text of payload/hooks/lib/heredoc-markers.json"
  else
    # Compared from a file: a pipe into a reader that stops at the first difference can report a
    # failure of its own under pipefail (test-pipefail-shortcircuit.sh).
    sed '1,/^export default$/d' "$MARK_COPY" > "$MARK_T/copy-text"
    if cmp -s "$MARK_T/copy-text" "$DIR/lib/heredoc-markers.json"; then
      check "#3566 the mods' suite reads the same list of markers" ok
    else
      check "#3566 the mods' suite reads the same list of markers" "payload/mods/mod-kit/tests/heredoc-markers.ts no longer holds the text of payload/hooks/lib/heredoc-markers.json after its 'export default' line: put the list's text there again, whole"
    fi
  fi
fi
rm -rf "$MARK_T"

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
