#!/usr/bin/env bash
# A whole tree scan: a send touching these paths runs this suite (claude-config#809).
# send-gate: scans hooks/ skills/ mods/ commands/ agents/
# No apostrophe inside Python a shell file embeds in single quotes ends that quote early
# (claude-config#3755).
#
# THE FAULT. A hook that writes its Python as one single quoted shell word (the program after
# python3 -c, or a variable assigned one and handed to python3 -c) gives the shell the first apostrophe as the
# closing quote, wherever it sits: in a Python comment, a string or a docstring. What follows it is
# read as shell, the next apostrophe opens a new quote, and python3 runs a different program from
# the one written, often one that still compiles. bash -n does not see it whenever the apostrophes
# still pair up. On 2026-11-26 the builder of #3689 wrote one in payload-write-gate.sh, and it was
# caught only because the Slack drafts gate could no longer follow the script.
#
# HOW AN EARLY QUOTE IS TOLD FROM A DELIBERATE ONE. The scan reads each such word as the shell does,
# a run at a time, and asks whether the text the shell hands python3 is the whole program written:
#   1. A single quoted run may end only where the word ends (a space, a newline, an operator), or
#      straight into a double quoted run (the '"'"' way of writing an apostrophe, or a quoted value
#      spliced in), or into \' followed by a new run (the '\'' way). Ending into anything else, a
#      letter, a digit, another quote at once ('' inside the program), or an unquoted $ expansion,
#      is an apostrophe the shell took as a close, named at its line. That covers an apostrophe
#      inside a word (don't, it's), in a comment, a string or a docstring alike.
#   2. The program as the shell joins it, a spliced value standing as 0, must compile with python3.
#      That covers an apostrophe at the end of a word inside a string or a docstring ("the users'
#      list"), where the word, and the program, end at the apostrophe.
#   3. The program must not end inside a Python comment: a comment the closing quote sits in is one
#      whose apostrophe ended the program ("# the users' list"), with the rest run as shell.
# Python's own apostrophe strings cannot be written inside single quotes at all, so the first
# apostrophe of any of them is caught by 1 or 2.
#
# WHAT IT READS. Every file lib/repo-files.sh lists that is shell (named .sh, .bash or .zsh, or with
# a shell on its #! line), once each, as bytes (L297), never a list of hooks (L96). A python3 -c is
# judged where it is the file's own code, read through lib/shell_code_lines.py; one inside a quoted
# string or a heredoc's body is another program's input (a suite's fixture), counted as skipped and
# not judged. A variable is judged where it is assigned a single quoted word on a line of code and
# is handed to python3 -c in the same file, or is named ..._PY, the name test-python-bad-bytes.sh
# reads as a program. The python3 -c reader is lib/python_c_programs.py, the one the other two
# scans of inline programs use. There is no skip list.
#
# A file it cannot read, a quote that never closes, and a reader that will not load each fail the
# scan; none of them passes as nothing found.
#
# This file names no python3 call with -c as text: its fixtures are written with printf, the call as
# @PY@ and each apostrophe as an octal escape, so no scan of inline programs reads them as programs.
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The checkout this copy is the payload of, found by the one shared test (lib/checkout-root.sh,
# claude-config#1567).
ROOT="${EMBEDDED_PY_ROOT:-$(bash "$DIR/lib/checkout-root.sh" "$DIR/.." 2>/dev/null || true)}"

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)" | sed '2,$s/^/  /'; fi; }

if [ -z "$ROOT" ] || [ ! -d "$ROOT" ]; then
  echo "test-embedded-python-quotes: $DIR/.. is not the payload of a claude-config checkout, so there were no files of this repository to read." >&2
  printf 'SUITE-NOT-RUN %s\n' "needs the repository to read its files, and $DIR/.. is not the payload of a claude-config checkout"
  exit 2
fi
if ! command -v python3 >/dev/null 2>&1; then
  printf 'SUITE-NOT-RUN %s\n' "the scan is a python3 program, and python3 is not on PATH"
  exit 2
fi

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/embedded-python-quotes.XXXXXXXX")" || TMPROOT=""
case "${TMPROOT%/}" in
  ''|/|"${HOME%/}") echo "test-embedded-python-quotes: refusing to run: throwaway directory came back as '$TMPROOT'." >&2; exit 2 ;;
esac
trap 'chmod -R u+rwX "$TMPROOT" 2>/dev/null; rm -rf "$TMPROOT"' EXIT

# The scan is a file python3 reads, never a -c program, so it is not itself held in single quotes.
# scan.py <root> <list file> [--starts]: for each path in the list, relative to root, prints
#   HIT <path>:<line>: ...      an early ended quote, at the line to edit
#   UNCLOSED <path>:<line>: ... a program whose quote never closes, which it cannot vouch for
#   UNREAD <path>: ...          a listed file it could not read
#   UNPARSED <path>: ...        a file whose code lines could not be read
#   JUDGED <path>:<line>        with --starts, each program judged, at the line it starts on
#   SKIPPED <path>:<line>       with --starts, each program inside a string or a heredoc's body
# and last, always, READ files=<n> programs=<n> variables=<n> skipped=<n>. With the reader of code
# lines unable to load it prints NOREADER and exits 3 before reading anything.
cat > "$TMPROOT/scan.py" <<'PY'
import io, os, re, sys, tokenize

root, listing = sys.argv[1], sys.argv[2]
starts = "--starts" in sys.argv[3:]
sys.path.insert(0, os.environ["EMBEDDED_PY_LIB"])
# The one reader of python3 -c calls, shared with test-python-c-ascii.sh and test-python-bad-bytes.sh.
from python_c_programs import START
import shell_code_lines
if shell_code_lines.READER_ERROR:
    print("NOREADER lib/shell_code_lines.py could not load lib/shell-words.py (%s), so which lines are code cannot be read"
          % shell_code_lines.READER_ERROR)
    sys.exit(3)

ENDS = b" \t\n;|&()<>"
NAME_USE = re.compile(rb"(?<![A-Za-z0-9_./-])python3?(?:[ \t]+-[A-Za-z]+)*?[ \t]+-[A-Za-z]*c[ \t]+\"?\$\{?([A-Za-z_][A-Za-z0-9_]*)")
NAMED_PY = re.compile(rb"(?<![A-Za-z0-9_])([A-Za-z_][A-Za-z0-9_]*_PY)='")
EXPANSION = re.compile(rb"\$\{[^}]*\}|\$\([^)]*\)|\$[A-Za-z_][A-Za-z0-9_]*|\$[0-9@*#?$!-]")
DQ_ESCAPE = re.compile(rb"\\([$`\"\\\n])")
SHEBANG = re.compile(rb"^#!.*\b(?:ba|z|da|k)?sh\b")
QUIET = (tokenize.NEWLINE, tokenize.NL, tokenize.ENDMARKER, tokenize.DEDENT, tokenize.INDENT)


def line_of(b, k):
    return b.count(b"\n", 0, k) + 1


def shell_runs(b, i):
    """The runs of the shell word starting at i, each (kind, start, end) in raw indices: S single
    quoted, D double quoted, E a backslash escape, X an unquoted expansion, B a bare byte. Returns
    (runs, index just past the word, whether a quote never closed)."""
    out, n = [], len(b)
    while i < n:
        c = b[i:i + 1]
        if c == b"'":
            j = b.find(b"'", i + 1)
            if j < 0:
                return out, i, True
            out.append(("S", i, j + 1))
            i = j + 1
        elif c == b'"':
            j = i + 1
            while j < n and b[j:j + 1] != b'"':
                j += 2 if b[j:j + 1] == b"\\" else 1
            if j >= n:
                return out, i, True
            out.append(("D", i, j + 1))
            i = j + 1
        elif c == b"\\":
            out.append(("E", i, min(i + 2, n)))
            i += 2
        elif c == b"$":
            m = EXPANSION.match(b, i)
            k = m.end() if m else i + 1
            out.append(("X", i, k))
            i = k
        elif c in ENDS:
            break
        else:
            out.append(("B", i, i + 1))
            i += 1
    return out, i, False


def joined(b, runs):
    """The program as the shell hands it to python3, each expansion standing as 0, and for each of
    its bytes the raw index it came from."""
    prog, where = bytearray(), []
    for kind, s, e in runs:
        if kind == "S":
            piece, base = b[s + 1:e - 1], s + 1
            where.extend(range(base, base + len(piece)))
        elif kind == "E":
            piece = b[s + 1:e]
            where.append(s + 1)
        elif kind == "D":
            piece = EXPANSION.sub(b"0", DQ_ESCAPE.sub(rb"\1", b[s + 1:e - 1]))
            where.extend([s] * len(piece))
        elif kind == "X":
            piece = b"0"
            where.append(s)
        else:
            piece = b[s:e]
            where.append(s)
        prog += piece
    return bytes(prog), where


def judge(b, shown, at, what):
    """Judge the shell word at index at when it opens with a single quote. Returns whether it did."""
    if b[at:at + 1] != b"'":
        return False
    start_line = line_of(b, at)
    if starts:
        print("JUDGED %s:%d" % (shown, start_line))
    runs, end, unclosed = shell_runs(b, at)
    # An early close is looked for first, unclosed or not: past it the shell pairs every later quote
    # the other way, which is often what leaves a quote open at the end of the file.
    for idx, (kind, s, e) in enumerate(runs):
        if kind != "S" or idx + 1 == len(runs):
            continue
        nxt = runs[idx + 1]
        if nxt[0] == "D" or (nxt[0] == "E" and b[nxt[1] + 1:nxt[2]] == b"'"):
            continue
        tail = b[e:e + 40].split(b"\n")[0].decode("utf-8", "replace")
        print("HIT %s:%d: an apostrophe on this line ends the single quoted %s starting on line %d early: the shell takes"
              " it as the closing quote and reads what follows it (%s) as shell. Write it as '\"'\"' or rephrase."
              % (shown, line_of(b, e - 1), what, start_line, tail))
        return True
    if unclosed:
        print("UNCLOSED %s:%d: the %s starting here opens a quote that never closes, so what it hands python3 cannot be read"
              % (shown, start_line, what))
        return True
    prog, where = joined(b, runs)
    text = prog.decode("utf-8", "replace")
    try:
        compile(text, "<program>", "exec", dont_inherit=True)
    except SyntaxError as err:
        pos = len("".join(text.splitlines(True)[:(err.lineno or 1) - 1]).encode("utf-8", "replace"))
        raw = where[min(pos, len(where) - 1)] if where else at
        print("HIT %s:%d: the %s starting on line %d does not compile as the shell hands it to python3 (%s);"
              " an apostrophe in it may have ended its quote early" % (shown, line_of(b, raw), what, start_line, err.msg))
        return True
    except ValueError as err:
        print("HIT %s:%d: the %s cannot be compiled (%s)" % (shown, start_line, what, err))
        return True
    last = None
    try:
        for tok in tokenize.generate_tokens(io.StringIO(text).readline):
            if tok.type not in QUIET:
                last = tok
    except (tokenize.TokenError, SyntaxError) as err:
        print("HIT %s:%d: the %s compiles and cannot be tokenized (%s)" % (shown, start_line, what, err))
        return True
    if last is not None and last.type == tokenize.COMMENT and not text.rstrip(" \t").endswith("\n"):
        print("HIT %s:%d: the %s starting on line %d ends inside a Python comment, so an apostrophe in that comment"
              " closed its quote early and the rest of the program is read as shell" % (shown, line_of(b, end - 1), what, start_line))
    return True


def is_shell(rel, b):
    return rel.endswith((b".sh", b".bash", b".zsh")) or SHEBANG.match(b) is not None


files = programs = variables = skipped = 0
with open(listing, "rb") as f:
    paths = [p for p in f.read().split(b"\n") if p]
for rel in paths:
    shown = rel.decode("utf-8", "replace")
    try:
        with open(os.path.join(os.fsencode(root), rel), "rb") as f:
            b = f.read()
    except OSError as err:
        print("UNREAD %s: %s, so the programs in it were not judged" % (shown, err.strerror or err))
        continue
    if not is_shell(rel, b):
        continue
    files += 1
    if b"python" not in b and NAMED_PY.search(b) is None:
        continue
    try:
        lines = {n: (kind, bare.encode("utf-8", "surrogateescape"))
                 for n, _line, kind, bare, _ops in shell_code_lines.read_lines(b.decode("utf-8", "surrogateescape"))}
    except Exception as err:  # noqa: BLE001  a reading that failed is not one that found nothing
        print("UNPARSED %s: its code lines could not be read (%s: %s), so the programs in it were not judged"
              % (shown, type(err).__name__, err))
        continue
    for m in START.finditer(b):
        n = line_of(b, m.start())
        kind, bare = lines.get(n, ("code", b""))
        if kind == "code" and START.search(bare):
            programs += judge(b, shown, m.end(), "python3 -c program")
        elif b[m.end():m.end() + 1] == b"'":
            skipped += 1
            if starts:
                print("SKIPPED %s:%d" % (shown, n))
    for name in sorted(set(NAME_USE.findall(b)) | set(NAMED_PY.findall(b))):
        assign = re.compile(rb"(?m)^[ \t]*(?:(?:export|local|readonly|declare(?:[ \t]+-[A-Za-z]+)*)[ \t]+)?"
                            + re.escape(name) + rb"='")
        for m in assign.finditer(b):
            kind, bare = lines.get(line_of(b, m.start()), ("code", b""))
            if kind == "code" and name + b"=" in bare:
                variables += judge(b, shown, m.end() - 1, "python3 program in " + name.decode())
print("READ files=%d programs=%d variables=%d skipped=%d" % (files, programs, variables, skipped))
PY

LIB="$DIR/lib"
scan() { EMBEDDED_PY_LIB="$LIB" python3 -I -B "$TMPROOT/scan.py" "$@" 2>&1; }
# The scan's verdict on a run: clean only when it read to its last line, exited 0, and named no
# fault. Anything else, a crash included, is not clean (L98).
verdict() {  # $1 = exit status, $2 = output
  case "$2" in *"READ files="*) ;; *) echo "not clean: the scan never reached its last line"; return ;; esac
  [ "$1" -eq 0 ] || { echo "not clean: the scan exited $1"; return; }
  if grep -q -E '^(HIT|UNCLOSED|UNREAD|UNPARSED|NOREADER) ' <<< "$2"; then echo "not clean"; else echo "clean"; fi
}
# A fixture: printf the format into probe/<name>, @PY@ standing for python3. Apostrophes are written
# \047 and a backslash \134, so this file holds none of the programs it builds.
mkdir -p "$TMPROOT/probe"
fx() { printf "$2" | sed 's/@PY@/python3/g' > "$TMPROOT/probe/$1"; }
# ---------------------------------------------------------------------------
# Each shape an apostrophe takes inside a single quoted program is named at its line (L1, L147).
# The shapes are the ones found in the real hooks: comments, strings, docstrings, several blocks in
# one file, and a program held in a variable. Every fixture is read in one run of the scan, once.
# ---------------------------------------------------------------------------
fx comment.sh '#!/bin/bash\nout="$(@PY@ -c \047\nimport sys\n# the gate\047s own reader\nprint(1)\n\047)"\n'
fx string.sh '#!/bin/bash\n@PY@ -c \047import sys\nprint("it\047s here")\n\047\n'
fx docstring.sh '#!/bin/bash\n@PY@ -I -c \047\ndef f():\n    """Do not read what you didn\047t write."""\n    return 1\nprint(f())\n\047 "$x"\n'
fx later.sh '#!/bin/bash\na="$(@PY@ -c \047print(1)\047)"\nb="$(@PY@ -B -c \047\nimport sys\nprint(2)\n\047)"\nc="$(@PY@ -c \047\nimport os\n# the caller\047s folder\nprint(os.getcwd())\n\047)"\n'
fx endcomment.sh '#!/bin/bash\n@PY@ -c \047\nimport sys\n# the users\047 list\nprint(sys.argv)\n\047\n'
fx endstring.sh '#!/bin/bash\n@PY@ -c \047\nimport sys\nprint("the users\047 list")\n\047\n'
fx pair.sh '#!/bin/bash\n@PY@ -c \047import sys; print(\047\047)\047\n'
fx expansion.sh '#!/bin/bash\n@PY@ -c \047\n# it costs \047$5\047 a run\nprint(1)\n\047\n'
# Past the first fault the shell pairs every later quote the other way, so each variable has a file.
fx named.sh '#!/bin/bash\nREADER_PY=\047\nimport json\n# don\047t trust the payload\nprint(1)\n\047\n'
fx used.sh '#!/bin/bash\nlocal prog=\047import sys\nprint("it\047s")\047\n@PY@ -c "$prog"\n'
fx unclosed.sh '#!/bin/bash\n@PY@ -c \047print(1)\n'

# The fault as it arrived: a copy of payload-write-gate.sh with one apostrophe added in a comment of
# its first program, beside the copy as it stands.
GATE="$DIR/payload-write-gate.sh"
added=""
if [ -r "$GATE" ]; then
  cp "$GATE" "$TMPROOT/probe/gate-plain.sh"
  awk -v q="'" '{ print } !done && /python3 +-c +.$/ { print "# the gate" q "s own reader of the payload"; done = NR + 1 }
    END { if (done) print done > "/dev/stderr" }' "$GATE" > "$TMPROOT/probe/gate-added.sh" 2> "$TMPROOT/gate-added.line"
  added="$(cat "$TMPROOT/gate-added.line")"
fi

(cd "$TMPROOT" && ls probe/*.sh) > "$TMPROOT/probe.list"
probe_out="$(scan "$TMPROOT" "$TMPROOT/probe.list")"
# The lines the probe run names in one fixture, as "line line ...".
hits_in() {  # $1 = fixture name
  printf '%s\n' "$probe_out" | sed -n -E "s#^(HIT|UNCLOSED) probe/$1:([0-9]+):.*#\2#p" | tr '\n' ' '
}
expect_hits() {  # $1 = fixture, $2 = the lines wanted, $3 = what the fixture is
  local got; got="$(hits_in "$1")"
  [ "$got" = "$2" ] && check "$3 is named at its line" ok || check "$3 is named at its line" "named lines [$got], wanted [$2]: $(printf '%s\n' "$probe_out" | grep -F "probe/$1:")"
}
expect_hits comment.sh "4 " "an apostrophe inside a word of a comment"
expect_hits string.sh "3 " "an apostrophe inside a word of a string"
expect_hits docstring.sh "4 " "an apostrophe inside a docstring"
expect_hits later.sh "9 " "an apostrophe in the third block of a file with three"
expect_hits endcomment.sh "4 " "an apostrophe ending a word in a comment, which leaves the program ending in that comment"
expect_hits endstring.sh "4 " "an apostrophe ending a word in a string, which leaves the program not compiling"
expect_hits pair.sh "2 " "a pair of apostrophes, which the shell drops without a trace"
expect_hits expansion.sh "3 " "an apostrophe straight before an unquoted expansion"
expect_hits named.sh "4 " "an apostrophe in a program held in a variable named _PY"
expect_hits used.sh "3 " "an apostrophe in a program held in a variable handed to python3 with -c"
expect_hits unclosed.sh "2 " "a program whose quote never closes"

if [ ! -r "$GATE" ]; then
  check "payload-write-gate.sh is beside this suite to copy" "it is not readable at $GATE"
elif [ -z "$added" ]; then
  check "payload-write-gate.sh has a python3 program to add an apostrophe to" "no line of it ends in a single quoted python3 -c"
else
  case " $(hits_in gate-added.sh)" in
    *" $added "*) check "an apostrophe added to a comment of payload-write-gate.sh is named at line $added" ok ;;
    *) check "an apostrophe added to a comment of payload-write-gate.sh is named at line $added" "the scan named [$(hits_in gate-added.sh)]" ;;
  esac
  case " $(hits_in gate-plain.sh)" in
    *" $added "*) check "payload-write-gate.sh as it stands names no fault at line $added" "it does: $(hits_in gate-plain.sh)" ;;
    *) check "payload-write-gate.sh as it stands names no fault at line $added" ok ;;
  esac
fi

# The shapes that are right pass: an apostrophe written the deliberate ways, a quoted value spliced
# in, a program in double quotes, and Python in a heredoc, a shell comment or another program's
# fixture string.
fx clean.sh '#!/bin/bash\n@PY@ -c \047print(\047"\047"\047hi\047"\047"\047)\047\n@PY@ -c \047print(\047\134\047\047hi\047\134\047\047)\047\n@PY@ -c \047import sys; print("\047"$name"\047")\047\n@PY@ -c "print(\047it is\047)"\n# a python3 program with an apostrophe in it: it\047s fine here\n@PY@ - <<\047EOF\047\nprint("it\047s fine")\nEOF\nprintf \047%%s\\n\047 "@PY@ -c \047print(1)\047 and it\047s text"\n@PY@ -c \047\nimport sys\nprint(sys.argv)  # every argument\n\047 a b\n'
printf 'probe/clean.sh\n' > "$TMPROOT/clean.list"
clean_out="$(scan "$TMPROOT" "$TMPROOT/clean.list")"; clean_rc=$?
[ "$(verdict "$clean_rc" "$clean_out")" = clean ] \
  && check "the deliberate ways of writing an apostrophe, a spliced value, a double quoted program, a heredoc and text pass" ok \
  || check "the deliberate ways of writing an apostrophe, a spliced value, a double quoted program, a heredoc and text pass" "$clean_out"
case "$clean_out" in
  *"READ files=1 programs=4 variables=0 skipped=1"*) check "every program in the clean fixture was judged, and the one in a string skipped" ok ;;
  *) check "every program in the clean fixture was judged, and the one in a string skipped" "it said: $clean_out" ;;
esac


# ---------------------------------------------------------------------------
# What the scan cannot read fails it, never passes as nothing found.
# ---------------------------------------------------------------------------
fx locked.sh '#!/bin/bash\n@PY@ -c \047print(1)\047\n'
chmod 000 "$TMPROOT/probe/locked.sh"
printf 'probe/locked.sh\nprobe/gone.sh\n' > "$TMPROOT/unread.list"
unread_out="$(scan "$TMPROOT" "$TMPROOT/unread.list")"; unread_rc=$?
case "$unread_out" in
  *"UNREAD probe/gone.sh:"*) check "a listed file that is not there is reported as unread" ok ;;
  *) check "a listed file that is not there is reported as unread" "it said: $unread_out" ;;
esac
if [ -r "$TMPROOT/probe/locked.sh" ]; then
  echo "test-embedded-python-quotes: UNMEASURED: a file with no read permission is still readable here (running as root?), so the unreadable case was not measured."
else
  case "$unread_out" in
    *"UNREAD probe/locked.sh:"*) check "a file it has no permission to read is reported as unread" ok ;;
    *) check "a file it has no permission to read is reported as unread" "it said: $unread_out" ;;
  esac
fi
[ "$(verdict "$unread_rc" "$unread_out")" != clean ] \
  && check "a scan that could not read a file is not clean" ok \
  || check "a scan that could not read a file is not clean" "the verdict was clean: $unread_out"
chmod 600 "$TMPROOT/probe/locked.sh"

# A scan that crashed partway never reached its last line, and is not clean.
crash_out="$(scan "$TMPROOT" "$TMPROOT/no-such.list")"; crash_rc=$?
[ "$(verdict "$crash_rc" "$crash_out")" != clean ] \
  && check "a scan that crashed is not clean" ok \
  || check "a scan that crashed is not clean" "the verdict was clean: $crash_out"

# Without lib/shell-words.py there is no reading of which lines are code, and the scan refuses. The
# helpers go through lib/install-hook-libs.py, which follows imports, so shell-words.py, loaded by
# its path, stays out.
mkdir -p "$TMPROOT/nolib"
if python3 -I -B "$DIR/lib/install-hook-libs.py" "$DIR/lib" "$TMPROOT/nolib" python_c_programs.py shell_code_lines.py >/dev/null 2>&1 \
   && [ ! -e "$TMPROOT/nolib/shell-words.py" ]; then
  nolib_out="$(LIB="$TMPROOT/nolib" scan "$TMPROOT" "$TMPROOT/clean.list")"; nolib_rc=$?
  case "$nolib_out" in
    *NOREADER*) check "with lib/shell-words.py missing the scan says it cannot read which lines are code" ok ;;
    *) check "with lib/shell-words.py missing the scan says it cannot read which lines are code" "it said: $nolib_out" ;;
  esac
  [ "$(verdict "$nolib_rc" "$nolib_out")" != clean ] \
    && check "a scan with no reader of code lines is not clean" ok \
    || check "a scan with no reader of code lines is not clean" "the verdict was clean: $nolib_out"
else
  check "the helpers install without lib/shell-words.py" "lib/install-hook-libs.py did not install them, or brought shell-words.py with them"
fi

# ---------------------------------------------------------------------------
# The real tree: no program a shell file embeds in single quotes has an apostrophe ending it early.
# ---------------------------------------------------------------------------
bash "$DIR/lib/repo-files.sh" "$ROOT" > "$TMPROOT/files.list" 2>/dev/null
# A listing that came back empty read nothing, and the check below would pass over it (L98).
[ -s "$TMPROOT/files.list" ] \
  && check "the files to judge were listed" ok \
  || check "the files to judge were listed" "lib/repo-files.sh gave nothing for $ROOT, so nothing below was read"
tree="$(scan "$ROOT" "$TMPROOT/files.list" --starts)"; tree_rc=$?
faults="$(printf '%s\n' "$tree" | grep -E '^(HIT|UNCLOSED|UNREAD|UNPARSED|NOREADER) ')"
[ "$(verdict "$tree_rc" "$tree")" = clean ] \
  && check "no shell file in the repository has an apostrophe ending a single quoted python3 program early" ok \
  || check "no shell file in the repository has an apostrophe ending a single quoted python3 program early" "${faults:-the scan did not finish: $(printf '%s\n' "$tree" | tail -5)}"
# A scan that judged a handful of programs is reading the wrong tree (L98). On 2026-11-26 it judged
# 753 python3 -c programs and 6 variables in 696 shell files, and skipped 117 inside strings or
# heredoc bodies, all of them in suites.
nprog="$(printf '%s\n' "$tree" | sed -n 's/^READ files=[0-9]* programs=\([0-9]*\) .*/\1/p')"
[ "${nprog:-0}" -ge 500 ] \
  && check "the scan judged the repository's programs" ok \
  || check "the scan judged the repository's programs" "it judged ${nprog:-no} programs in $ROOT, where 753 were judged on 2026-11-26"
# The file the fault arrived in is among those judged, each of its programs (L400).
ngate="$(printf '%s\n' "$tree" | grep -c '^JUDGED payload/hooks/payload-write-gate.sh:')"
[ "$ngate" -ge 4 ] \
  && check "the programs in payload-write-gate.sh are judged" ok \
  || check "the programs in payload-write-gate.sh are judged" "only $ngate of them were, where 4 were on 2026-11-26"

# The header says this file holds no python3 call with -c as text, so it is held to that: a scan of
# inline programs that read its fixtures as programs would judge text written to be wrong.
self_calls="$(grep -n -E "python""3?( -[A-Za-z]+)* -[A-Za-z]*c +[\"'\\\\]""${EMBEDDED_PY_SELF:-$DIR/test-embedded-python-quotes.sh}" | cut -d: -f1 | tr '\n' ' ')"
[ -z "$self_calls" ] \
  && check "this suite's own file names no python3 call with -c, as its header says" ok \
  || check "this suite's own file names no python3 call with -c, as its header says" "lines [$self_calls] do; write the call as @PY@"

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
