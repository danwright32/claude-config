#!/usr/bin/env bash
# Python in the hooks reads what it is given and prints what it read (claude-config#1923).
#
# #1900 made every python3 read of stdin in payload/hooks survive a byte that is not UTF-8. Three
# ways python still raised on bad text, and each was the same fault one step along:
#
#   1. a file or transcript opened in text mode with strict errors: subagent-digest.py read a whole
#      subagent transcript as unreadable for one such byte, so the harvest filed the agent as
#      saying nothing;
#   2. a subprocess run with text=True: git output holding one raised in the reader;
#   3. print() of a field holding a lone surrogate, which json.loads makes of an escape such as
#      \ud800: scratchpad-subagent-gate.sh raised while printing its refusal, and let the write
#      through as a gate that did not run.
#
# And under payload/skills, five scripts still read stdin in text mode.
#
# Each is shown on a real reader, then a scan over every Python program in the hooks (each .py file,
# and each python3 heredoc, -c program or ..._PY variable in a shell script) fails on the next one:
# every text mode open, subprocess and decode names how it handles what it cannot decode, every
# program that decodes JSON and writes to stdout sets stdout's errors first, and nothing in the hooks
# or the skills reads stdin as text. errors="replace" stands in U+FFFD for only the undecodable
# bytes, so every ASCII word a hook matches survives and its decision is the one the raw bytes would
# get; errors="strict" is the named decision to refuse, made where a reader rewrites what it read or
# decides on a value that must be exact.
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/lib/test_bad_byte_locale.sh" || {
  echo "FAIL: $(basename "$0"): lib/test_bad_byte_locale.sh is missing, so its cases with a byte that is not UTF-8 have no locale to run under."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
BAD_BYTE_LOCALE="$(bad_byte_locale)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/pbb.XXXXXXXX")" || exit 1
case "${WORK%/}" in ''|/|"${HOME%/}") echo "refusing to run: throwaway directory came back as '$WORK'" >&2; exit 2 ;; esac
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
ok(){ pass=$((pass + 1)); }
bad(){ fail=$((fail + 1)); echo "FAIL: $1"; }

# ---------------------------------------------------------------------------
echo "a refusal holding a lone surrogate is still a refusal"

# The path a subagent names comes from the model, and json.loads reads \ud800 in it as a lone
# surrogate, which print() could not encode: the gate raised and let the write through.
sp_run(){ # sp_run <file name> -> OUT and RC
  printf '{"tool_name":"Write","agent_id":"a1b2","tool_input":{"file_path":"/tmp/claude-501/proj/sess/scratchpad/%s","content":"x"}}' "$1" > "$WORK/sp.json"
  OUT="$(LC_ALL="$BAD_BYTE_LOCALE" bash "$DIR/scratchpad-subagent-gate.sh" < "$WORK/sp.json" 2>&1)"; RC=$?
}
sp_run 'notes.md'
if [ "$RC" -eq 2 ]; then ok; else bad "control: a subagent's Write into the scratchpad root should be refused, exited $RC: ${OUT:0:200}"; fi
sp_run 'n\ud800tes.md'
if [ "$RC" -eq 2 ]; then ok; else bad "a Write into the scratchpad root whose name holds a lone surrogate should be refused, exited $RC: ${OUT:0:200}"; fi
case "$OUT" in *REFUSED*) ok ;; *) bad "and the refusal should be the gate's own, said: ${OUT:0:200}" ;; esac

# ---------------------------------------------------------------------------
echo "a transcript holding a byte that is not UTF-8, or a lone surrogate, is still digested"

transcript(){ # transcript <file> <line>...
  local f="$1"; shift
  : > "$f"
  for l in "$@"; do printf '%s\n' "$l" >> "$f"; done
}
said(){ printf '{"type":"assistant","message":{"content":[{"type":"text","text":"%s"}]}}' "$1"; }
transcript "$WORK/byte.jsonl" '{"type":"user","message":{"content":"the task"}}' "$(said "$(printf 'caf\377 early note')")" "$(said 'the closing finding')"
OUT="$(LC_ALL="$BAD_BYTE_LOCALE" python3 "$DIR/subagent-digest.py" "$WORK/byte.jsonl" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ]; then ok; else bad "a transcript holding a byte that is not UTF-8 should digest (exit 0), exited $RC: ${OUT:0:200}"; fi
case "$OUT" in *"the closing finding"*"early note"*|*"early note"*"the closing finding"*) ok ;; *) bad "and the digest should carry both lines, said: ${OUT:0:200}" ;; esac
transcript "$WORK/surrogate.jsonl" '{"type":"user","message":{"content":"the task"}}' "$(said 'a lone \ud800 one')" "$(said 'the closing finding')"
OUT="$(LC_ALL="$BAD_BYTE_LOCALE" python3 "$DIR/subagent-digest.py" "$WORK/surrogate.jsonl" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ]; then ok; else bad "a transcript holding a lone surrogate should digest (exit 0), not read as an agent that said nothing, exited $RC: ${OUT:0:200}"; fi
case "$OUT" in *"the closing finding"*) ok ;; *) bad "and the digest should carry what the agent said, said: ${OUT:0:200}" ;; esac

# ---------------------------------------------------------------------------
echo "git output holding a byte that is not UTF-8 is read, not raised on"

git -C "$WORK" init -q repo && printf 'caf\377 line\nsecond\n' > "$WORK/repo/f.txt" \
  && git -C "$WORK/repo" add f.txt && git -C "$WORK/repo" -c user.name=t -c user.email=t@t commit -q -m one \
  || bad "could not build the git fixture"
OUT="$(LC_ALL="$BAD_BYTE_LOCALE" python3 - "$DIR/lib/review-answered.py" "$WORK/repo" <<'PY' 2>&1
import importlib.util, sys
spec = importlib.util.spec_from_file_location("review_answered", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
out = m.git(sys.argv[2], "show", "HEAD:f.txt").stdout
print("lines=%d replaced=%s" % (len(out.splitlines()), "�" in out))
PY
)"; RC=$?
if [ "$RC" -eq 0 ] && [ "$OUT" = "lines=2 replaced=True" ]; then ok; else bad "review-answered.py's git() should read a blob holding a byte that is not UTF-8, exited $RC: ${OUT:0:300}"; fi

# ---------------------------------------------------------------------------
echo "a skill reading a response that is not UTF-8 refuses it by name"

# lb_read lists a repository's labels before any is created. A byte that is not UTF-8 raised under a
# UTF-8 locale and was reported as an unexpected response, and under C was read as something else.
# The other cases here raise under any locale; this one's before differs by locale, so it is measured.
bad_byte_measured python-stdin "#1923 lb_read on a label list that is not UTF-8" || true
mkdir -p "$WORK/bin"
printf '#!/bin/sh\nprintf %s\n' "'[{\"name\":\"caf\\377\"}]'" > "$WORK/bin/gh"
chmod +x "$WORK/bin/gh"
OUT="$(PATH="$WORK/bin:$PATH" LC_ALL="$BAD_BYTE_LOCALE" bash -c '. "$1" && lb_read o/r "$2"; echo "rc=$?"' _ "$DIR/../skills/milestone/labels-lib.sh" "$WORK/lb.err" 2>&1)"
case "$OUT" in *"rc=1"*) ok ;; *) bad "lb_read should refuse a label list holding a byte that is not UTF-8, said: ${OUT:0:200}" ;; esac
case "$(cat "$WORK/lb.err" 2>/dev/null)" in *"not UTF-8"*) ok ;; *) bad "and say why, said: $(cat "$WORK/lb.err" 2>/dev/null)" ;; esac

# The scan, written out for each run. It reads every Python program in a tree; see its docstring.
# Its python3 -c programs come from lib/python_c_programs.py, which it finds through this.
export PYTHON_C_PROGRAMS_LIB="$DIR/lib"
cat > "$WORK/scan.py" <<'SCAN'
"""Find Python that raises on a byte that is not UTF-8, or on a lone surrogate, in every Python
program under the trees named: each .py file, and each python3 heredoc or -c program in a .sh file.

Prints one line per finding, `<file>:<line>: <rule>: <source line>`, and `UNPARSED <file>:<line>` for
a program it could not parse, which the caller counts as a failure: a program the scan cannot read
is one it cannot vouch for.

Rules:
  open        a text mode open, TextIOWrapper, read_text or write_text with no errors= argument
  subprocess  a call with text=True, universal_newlines=True or encoding= and no errors= argument
  decode      a .decode() naming no error handler, positional or errors=
  stdout      a program that decodes JSON and writes to stdout without sys.stdout.reconfigure(errors=)
  encode      in a program that decodes JSON, a .encode() naming no error handler, positional or errors=
  stdin       sys.stdin used for anything but its buffer (or isatty, fileno, close), input(), fileinput
"""
import ast, os, re, sys

MODULES_NOT_FILES = {"os", "tarfile", "gzip", "bz2", "lzma", "zipfile", "webbrowser", "shelve", "dbm",
                     "sqlite3", "urllib", "request", "wave", "aifc", "sunau", "Image", "pty", "socket"}
PYTHON = re.compile(r"""(^|[\s;&|("'`$])python3?(\s|$)""")
PY_VAR = re.compile(rb"""^[ \t]*(?:export[ \t]+|local[ \t]+)?[A-Za-z_][A-Za-z0-9_]*_PY=(['"])""")
# The python3 -c programs come from the one reader the ASCII scan uses too (lib/python_c_programs.py),
# which takes every program on a line; this scan once took only the first (#2066). Where a heredoc's
# body begins and ends comes from lib/shell_code_lines.py, which reads the end marker through
# lib/shell-words.py as bash does (#2080): read with a pattern of its own, <<'P'Y ended at P and
# <<END-OF at END, and only the first heredoc on a line was read.
sys.dont_write_bytecode = True
sys.path.insert(0, os.environ["PYTHON_C_PROGRAMS_LIB"])
import python_c_programs
import shell_code_lines


def units(path):
    """(first line number, source or None) for each Python program in the file: the whole of a .py
    file; in a shell script, each heredoc handed to python3 or named PY..., each python3 -c program,
    and each variable named ..._PY holding one. None is a shell string whose quote never closes."""
    raw = open(path, "rb").read()
    if path.endswith(".py"):
        return [(1, raw.decode("utf-8", "replace"))]
    out, inside = [], set()
    for line, start, end, prog in python_c_programs.programs(raw):
        if prog is not None and prog.startswith(b"$"):
            continue   # a program held in a variable, read where the variable is set
        out.append((line, None if prog is None else prog.decode("utf-8", "replace")))
        # The lines a program runs on past its first are its own, never a heredoc or a variable.
        inside.update(range(line, raw.count(b"\n", 0, end) + 1))
    shell_units(raw, 0, inside, out)
    return out


def shell_units(raw, base, inside, out):
    """Add the programs in shell text raw, whose first line is line base + 1 of its file, to out.
    A heredoc handed to python3 or named PY... is a program; any other heredoc is read again as
    shell, since a stand in a script writes can run python3 itself. False once a shell quote never
    closes, after which nothing more in the file is read."""
    # surrogateescape, so a line taken from the text encodes back to exactly the bytes it came from.
    text = raw.decode("utf-8", "surrogateescape")
    blines = raw.split(b"\n")
    offsets, k = [], 0
    for bl in blines:
        offsets.append(k)
        k += len(bl) + 1
    walked = list(shell_code_lines.read_lines(text))
    i = 0
    while i < len(walked):
        n, line, kind, _, ops = walked[i]
        i += 1
        if base + n - 1 in inside or kind in ("heredoc", "end") or line.lstrip().startswith("#"):
            continue
        python_op = False
        at = shell_code_lines.heredoc_openers(line)
        for strip, marker, _ in ops:
            pos = next((o for o in at if o[1] == marker), None)
            if pos is not None:
                at = at[at.index(pos) + 1:]
            python = bool(PYTHON.search(line[:pos[0]] if pos is not None else line)) or marker.startswith("PY")
            python_op = python_op or python
            first, body = i + 1, []
            while i < len(walked) and walked[i][2] == "heredoc":
                body.append(walked[i][1]); i += 1
            if i < len(walked) and walked[i][2] == "end":
                i += 1
            sub = "\n".join(body).encode("utf-8", "surrogateescape")
            if python:
                out.append((base + first, sub.decode("utf-8", "replace")))
            elif body and not shell_units(sub, base + first - 1, inside, out):
                return False
        if python_op:
            continue
        m = PY_VAR.search(blines[n - 1])
        if m:
            src, end = python_c_programs.word(raw, offsets[n - 1] + m.end() - 1)
            if src is None:
                out.append((base + n, None))
                return False
            if not src.startswith(b"$"):   # a variable naming a file or another variable
                out.append((base + n, src.decode("utf-8", "replace")))
            if not ops:
                last = raw.count(b"\n", 0, end) + 1   # the line after the word, 0 based
                while i < len(walked) and walked[i][0] - 1 < last:
                    i += 1
    return True


def kw(call, name):
    return any(k.arg == name for k in call.keywords)


def kwval(call, name):
    for k in call.keywords:
        if k.arg == name:
            return k.value
    return None


def is_true(node):
    return isinstance(node, ast.Constant) and node.value is True


def dotted(node):
    parts = []
    while isinstance(node, ast.Attribute):
        parts.append(node.attr); node = node.value
    if isinstance(node, ast.Name):
        parts.append(node.id)
    return ".".join(reversed(parts))


def text_mode(call, mode_index):
    mode = kwval(call, "mode")
    if mode is None and len(call.args) > mode_index:
        mode = call.args[mode_index]
    if mode is None:
        return True
    if isinstance(mode, ast.Constant) and isinstance(mode.value, str):
        return "b" not in mode.value
    return True  # a mode the scan cannot read is judged as text, so it must say how it decodes


STDIN_OK = ("buffer", "isatty", "fileno", "close")


def judge(tree):
    finds = []
    decodes_json = writes_stdout = reconfigured = False
    encodes = []
    # sys.stdin read as text: any use but its buffer, and the builtins that read it as text.
    fine = {id(n.value) for n in ast.walk(tree) if isinstance(n, ast.Attribute) and n.attr in STDIN_OK and dotted(n.value) == "sys.stdin"}
    for node in ast.walk(tree):
        if isinstance(node, ast.Attribute) and dotted(node) == "sys.stdin" and id(node) not in fine:
            finds.append((node.lineno, "stdin"))
        if not isinstance(node, ast.Call):
            continue
        if dotted(node.func) in ("input", "fileinput.input"):
            finds.append((node.lineno, "stdin"))
        f, name = node.func, dotted(node.func)
        # Any way of decoding JSON makes a lone surrogate of an escape: the decoder object too.
        if name in ("json.load", "json.loads", "json.JSONDecoder") or (isinstance(f, ast.Attribute) and f.attr == "raw_decode"):
            decodes_json = True
        if name == "sys.stdout.reconfigure" and kw(node, "errors"):
            reconfigured = True
        if name == "sys.stdout.write" or (name == "json.dump" and len(node.args) > 1 and dotted(node.args[1]) == "sys.stdout"):
            writes_stdout = True
        if name == "print":
            target = kwval(node, "file")
            if target is None or dotted(target) == "sys.stdout":
                writes_stdout = True
        if not kw(node, "errors"):
            if name in ("open", "io.open", "codecs.open") and text_mode(node, 1):
                finds.append((node.lineno, "open"))
            elif name == "os.fdopen" and text_mode(node, 1):
                finds.append((node.lineno, "open"))
            elif name.endswith("TextIOWrapper"):
                finds.append((node.lineno, "open"))
            elif isinstance(f, ast.Attribute) and f.attr in ("read_text", "write_text"):
                finds.append((node.lineno, "open"))
            elif isinstance(f, ast.Attribute) and f.attr == "open" and name.split(".")[0] not in MODULES_NOT_FILES \
                    and name not in ("io.open", "codecs.open") and text_mode(node, 0):
                finds.append((node.lineno, "open"))
            elif is_true(kwval(node, "text")) or is_true(kwval(node, "universal_newlines")) or kw(node, "encoding"):
                finds.append((node.lineno, "subprocess"))
            elif isinstance(f, ast.Attribute) and f.attr == "decode" and len(node.args) < 2:
                finds.append((node.lineno, "decode"))
            elif isinstance(f, ast.Attribute) and f.attr == "encode" and len(node.args) < 2:
                encodes.append((node.lineno, "encode"))
    if decodes_json and writes_stdout and not reconfigured:
        finds.append((None, "stdout"))
    # The way back (claude-config#1944): a program that decodes JSON holds a lone surrogate wherever the
    # text carried a lone \ud800 escape, and a .encode() naming no handler raises on it, mostly while
    # hashing a key. A program decoding no JSON gets one only from a surrogateescape it chose itself.
    if decodes_json:
        finds.extend(encodes)
    return finds


def walk(args):
    """Each argument a file, or a tree walked for its .py and .sh files. Tests are left out (test-*,
    test_*, *_tests.py, and tests/ and fixtures/ folders): they make bad text on purpose."""
    for a in args:
        if not os.path.isdir(a):
            yield a; continue
        for d, subs, names in os.walk(a):
            subs[:] = sorted(s for s in subs if s not in ("fixtures", "tests", "__pycache__", "node_modules"))
            for n in sorted(names):
                if n.endswith((".py", ".sh")) and not n.startswith(("test-", "test_")) and not n.endswith("_tests.py"):
                    yield os.path.join(d, n)


def main(argv):
    if shell_code_lines.READER_ERROR is not None:
        print("scan.py: lib/shell-words.py could not be loaded (%s), so where a heredoc ends cannot be read"
              % shell_code_lines.READER_ERROR, file=sys.stderr)
        return 2
    if argv and argv[0] == "--list":
        for path in walk(argv[1:]):
            print(path)
        return
    rules = None
    if argv and argv[0].startswith("--rules="):
        rules = set(argv[0].split("=", 1)[1].split(","))
        argv = argv[1:]
    n = 0
    for path in walk(argv):
        try:
            us = units(path)
        except OSError as e:
            print("UNPARSED %s:0: %s" % (path, e)); continue
        for first, src in us:
            n += 1
            if src is None:
                print("UNPARSED %s:%d: a shell quote that never closes" % (path, first)); continue
            try:
                tree = ast.parse(src)
            except SyntaxError as e:
                print("UNPARSED %s:%d: %s" % (path, first + (e.lineno or 1) - 1, e.msg)); continue
            lines = src.split("\n")
            for ln, rule in judge(tree):
                if rules is not None and rule not in rules:
                    continue
                if ln is None:
                    print("%s:%d: stdout: a program that decodes JSON writes to stdout without sys.stdout.reconfigure(errors=...)" % (path, first))
                else:
                    print("%s:%d: %s: %s" % (path, first + ln - 1, rule, lines[ln - 1].strip()[:160]))
    print("UNITS %d" % n)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
SCAN

# ---------------------------------------------------------------------------
echo "every Python program in the hooks and the skills says how it handles text it cannot decode or encode"

python3 "$WORK/scan.py" "$DIR" > "$WORK/hooks.scan" 2>&1
rc=$?
[ "$rc" = 0 ] && ok || bad "the scan of $DIR exited $rc: $(grep -v -E '^(UNITS|UNPARSED) |^/' "$WORK/hooks.scan" | head -5 | tr '\n' '|')"
units="$(sed -n 's/^UNITS //p' "$WORK/hooks.scan")"
[ "${units:-0}" -ge 100 ] && ok || bad "the scan read only ${units:-no} Python programs in $DIR, so it is reading the wrong tree or cannot find them"
unparsed="$(grep '^UNPARSED' "$WORK/hooks.scan")"
if [ -z "$unparsed" ]; then ok; else bad "the scan could not parse these, so it cannot vouch for them:
$unparsed"; fi
hits="$(grep -v -E '^(UNITS|UNPARSED) ' "$WORK/hooks.scan" | sed "s#^$DIR/##")"
if [ -z "$hits" ]; then ok; else bad "Python in the hooks raises on a byte that is not UTF-8 or a lone surrogate here. Give each open, subprocess, decode and (in a program that decodes JSON) encode an errors= (\"replace\", \"strict\" where refusing is the decision, or \"surrogatepass\" for a hash key), and a program that decodes JSON and prints sys.stdout.reconfigure(errors=\"replace\") first:
$hits"; fi

# The skills, held to the same rules: they read gh's answers, transcripts and files the same way.
# Only what the sync carries: lib/unmanaged-skills.sh is the one list of what it leaves alone (#2001).
. "$DIR/lib/unmanaged-skills.sh" && declare -F carried_skill_paths >/dev/null || {
  echo "FAIL: $(basename "$0"): lib/unmanaged-skills.sh is missing or holds no carried_skill_paths, so the skills scan cannot tell a skill the sync carries from one it leaves alone."
  printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$((fail + 1))"
  exit 1
}
skill_scan(){ # skill_scan <skills dir> -> the scan's report on each program there the sync carries
  local progs=() p listed
  # Read into a variable first, never through process substitution, whose child bash 3.2 never waits
  # for and whose exit can cut short what this suite prints next (L1035, #1989).
  listed="$(python3 "$WORK/scan.py" --list "$1" | carried_skill_paths "$1")"
  while IFS= read -r p; do [ -n "$p" ] && progs+=("$p"); done <<LISTED
$listed
LISTED
  python3 "$WORK/scan.py" ${progs[@]+"${progs[@]}"}
}
skill_scan "$DIR/../skills" > "$WORK/skills.scan" 2>&1
rc=$?
[ "$rc" = 0 ] && ok || bad "the scan of payload/skills exited $rc: $(grep -v -E '^(UNITS|UNPARSED) |^/' "$WORK/skills.scan" | head -5 | tr '\n' '|')"
sunits="$(sed -n 's/^UNITS //p' "$WORK/skills.scan")"
[ "${sunits:-0}" -ge 30 ] && ok || bad "the scan read only ${sunits:-no} Python programs under payload/skills"
shits="$(grep -v -E '^UNITS ' "$WORK/skills.scan" | sed "s#^$DIR/../##")"
if [ -z "$shits" ]; then ok; else bad "a script under payload/skills raises on a byte that is not UTF-8 or a lone surrogate, or reads stdin in text mode, which under C reads it as something else. Read sys.stdin.buffer, and give each open, subprocess and decode an errors= saying what happens to such a byte:
$shits"; fi

# Run from the installed copy, the skills folder also holds what the sync never carries: the Claude
# app's downloads under skills/synced and Claude Code's skills/.trash (claude-config#2001). A script
# there is nobody's to fix, so the scan leaves out exactly what lib/unmanaged-skills.sh says the sync
# leaves out, and still reads the same script in a real skill, including one inside a folder of the
# real skill that merely happens to be called synced.
for d in synced/acct/skill-a/scripts .trash/stamp/skill-a/scripts real-skill/scripts real-skill/synced real-skill/.trash/old; do
  mkdir -p "$WORK/skills/$d"
  printf '%s\n' 'import sys' 'print(open(sys.argv[1]).read())' > "$WORK/skills/$d/stylometry.py"
done
skill_scan "$WORK/skills" > "$WORK/fixture.scan" 2>&1
got="$(grep -v '^UNITS ' "$WORK/fixture.scan" | sed -e "s#^$WORK/skills/##" -e 's#:.*##' | sort -u | tr '\n' ' ')"
[ "$got" = "real-skill/scripts/stylometry.py real-skill/synced/stylometry.py " ] && ok \
  || bad "#2001 the scan should report the real skill's scripts and nothing under skills/synced or any .trash, reported: $got"
[ "$(sed -n 's/^UNITS //p' "$WORK/fixture.scan")" = 2 ] && ok \
  || bad "#2001 the scan should read exactly the real skill's two programs, said: $(tr '\n' '|' < "$WORK/fixture.scan")"

# The scan is seen to fire on each shape the hooks held, in each place a program can sit, and to stay
# quiet on the forms it asks for.
mkdir -p "$WORK/probe"
cat > "$WORK/probe/held.py" <<'PROBE'
import json, subprocess, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    a = fh.read()
b = open(sys.argv[1]).read()
c = subprocess.run(["git", "status"], capture_output=True, text=True).stdout
d = subprocess.run(["git", "status"], capture_output=True, universal_newlines=True).stdout
e = open(sys.argv[1], "rb").read().decode("utf-8")
f = json.loads(sys.stdin.read())
print(f["x"])
g = f["x"].encode("utf-8")
PROBE
cat > "$WORK/probe/fixed.py" <<'PROBE'
import json, subprocess, sys
with open(sys.argv[1], encoding="utf-8", errors="replace") as fh:
    a = fh.read()
b = open(sys.argv[1], "rb").read()
c = subprocess.run(["git", "status"], capture_output=True, text=True, errors="replace").stdout
e = open(sys.argv[1], "rb").read().decode("utf-8", "strict")
f = json.loads(sys.stdin.buffer.read().decode("utf-8", "replace"))
sys.stdout.reconfigure(errors="replace")
print(f["x"])
g = f["x"].encode("utf-8", "surrogatepass")
h = f["x"].encode(errors="replace")
PROBE
cat > "$WORK/probe/held.sh" <<'PROBE'
#!/bin/bash
x="$(python3 -c 'import json, sys; print(json.load(sys.stdin)["a"])')"
y="$(python3 - "$f" <<'PY'
import sys
print(open(sys.argv[1]).read())
PY
)"
HELD_PY='
import subprocess
r = subprocess.run(["git", "log"], capture_output=True, text=True)
'
z="$(python3 -c 'import sys; d = open(sys.argv[1]).read(); print(d.split("'"'"'")[0])' "$f")"
a="$(python3 -c 'print(1)')"; b="$(python3 -c 'import sys; print(open(sys.argv[1]).read())' "$f")"
PROBE
python3 "$WORK/scan.py" "$WORK/probe/held.py" > "$WORK/probe.out"
for rule in "open: with open" "open: b = open" "subprocess: c =" "subprocess: d =" "decode: e =" "stdin: f =" "stdout:" "encode: g ="; do
  grep -q -F "$rule" "$WORK/probe.out" && ok || bad "the scan does not fire on the shape '$rule' in a .py file; it said: $(tr '\n' '|' < "$WORK/probe.out")"
done
# A bare .encode() in a program that decodes no JSON holds no lone surrogate it did not choose, so it
# is not this rule's (claude-config#1944).
printf '%s\n' 'import hashlib, sys' 'k = hashlib.sha1(sys.argv[1].encode("utf-8")).hexdigest()' > "$WORK/probe/nojson.py"
python3 "$WORK/scan.py" "$WORK/probe/nojson.py" > "$WORK/probe.out"
[ "$(grep -c -v '^UNITS ' "$WORK/probe.out")" = 0 ] && ok || bad "the encode rule fires on a program that decodes no JSON: $(tr '\n' '|' < "$WORK/probe.out")"
# A program decoding JSON through a decoder object, as the milestone list reader does.
printf '%s\n' 'import json, sys' 'v, _ = json.JSONDecoder().raw_decode(sys.stdin.buffer.read().decode("utf-8", "replace"))' 'print(v["t"])' > "$WORK/probe/decoder.py"
python3 "$WORK/scan.py" "$WORK/probe/decoder.py" > "$WORK/probe.out"
grep -q 'stdout:' "$WORK/probe.out" && ok || bad "the scan does not count a JSON decoder object as decoding JSON"
python3 "$WORK/scan.py" "$WORK/probe/fixed.py" > "$WORK/probe.out"
[ "$(grep -c -v '^UNITS ' "$WORK/probe.out")" = 0 ] && ok || bad "the scan fires on the forms it asks for: $(tr '\n' '|' < "$WORK/probe.out")"
python3 "$WORK/scan.py" "$WORK/probe/held.sh" > "$WORK/probe.out"
[ "$(sed -n 's/^UNITS //p' "$WORK/probe.out")" = 6 ] && ok || bad "the scan should find six programs in a shell script (a -c, a heredoc, a _PY variable, a -c quoting a quote, and two -c on one line), said: $(tr '\n' '|' < "$WORK/probe.out")"
# The second -c on line 13 is judged too: the scan once took only the first program on a line (#2066).
for rule in "held.sh:2: stdin" "held.sh:2: stdout" "held.sh:5: open" "held.sh:10: subprocess" "held.sh:12: open" "held.sh:13: open"; do
  grep -q -F "$rule" "$WORK/probe.out" && ok || bad "the scan does not fire on '$rule' in a shell script; it said: $(tr '\n' '|' < "$WORK/probe.out")"
done
# A quote that never closes is a program the scan cannot vouch for, so it says so rather than judging
# whatever runs to the end of the file, for a -c and for a _PY variable alike.
printf "x=\"\$(python3 -c 'print(1)\n" > "$WORK/probe/open-c.sh"
printf "OPEN_PY='\nprint(1)\n" > "$WORK/probe/open-var.sh"
python3 "$WORK/scan.py" "$WORK/probe/open-c.sh" "$WORK/probe/open-var.sh" > "$WORK/probe.out"
for want in "UNPARSED $WORK/probe/open-c.sh:1: a shell quote that never closes" "UNPARSED $WORK/probe/open-var.sh:1: a shell quote that never closes"; do
  grep -q -F "$want" "$WORK/probe.out" && ok || bad "the scan should report [$want]; it said: $(tr '\n' '|' < "$WORK/probe.out")"
done

# Where a heredoc's body ends is read as bash reads it, by lib/shell-words.py through
# lib/shell_code_lines.py (claude-config#2080). Read with a pattern of its own, <<'P'Y ended at P and
# <<END-OF at END, so the body never closed and ran on into the shell after it, reported unparsed;
# and only the first heredoc on a line was read, so a python3 heredoc after another went unjudged.
mkdir -p "$WORK/marker"
printf '%s\n' '#!/bin/bash' "python3 - \"\$f\" <<'P'Y" 'import sys' 'print(open(sys.argv[1]).read())' 'PY' 'echo done' > "$WORK/marker/split.sh"
printf '%s\n' '#!/bin/bash' 'python3 - "$f" <<END-OF' 'import sys' 'print(open(sys.argv[1]).read())' 'END-OF' "python3 - <<'PY'" 'print(1)' 'PY' 'echo done' > "$WORK/marker/hyphen.sh"
printf '%s\n' '#!/bin/bash' "cat <<A; python3 - \"\$f\" <<'PY'" 'text' 'A' 'import sys' 'print(open(sys.argv[1]).read())' 'PY' > "$WORK/marker/two.sh"
# A heredoc that is not Python is still read for the programs it holds: a stand in a script writes
# can run python3 itself, and a variable named _PY inside one is a program too.
printf '%s\n' '#!/bin/bash' "cat > \"\$WORK/x.sh\" <<'SH'" "python3 - \"\$f\" <<'PY'" 'import sys' 'print(open(sys.argv[1]).read())' 'PY' "X_PY='" 'import subprocess' 'r = subprocess.run(["ls"], capture_output=True, text=True)' "'" 'SH' > "$WORK/marker/nested.sh"
python3 "$WORK/scan.py" "$WORK/marker/split.sh" "$WORK/marker/hyphen.sh" "$WORK/marker/two.sh" "$WORK/marker/nested.sh" > "$WORK/marker.out" 2>&1
for want in "split.sh:4: open" "hyphen.sh:4: open" "two.sh:6: open" "nested.sh:5: open" "nested.sh:9: subprocess" "UNITS 6"; do
  grep -q -F "$want" "$WORK/marker.out" && ok || bad "#2080 the scan should report [$want], reading each heredoc's end as bash does; it said: $(tr '\n' '|' < "$WORK/marker.out")"
done
grep -q '^UNPARSED' "$WORK/marker.out" && bad "#2080 the scan read a heredoc past its end: $(grep '^UNPARSED' "$WORK/marker.out" | tr '\n' '|')" || ok
# With lib/shell-words.py missing there is no reading of where a heredoc ends, so the scan refuses by
# name rather than guessing; and the tree scans above fail on its exit, not only on what it printed.
mkdir -p "$WORK/nolib"
cp "$DIR/lib/python_c_programs.py" "$DIR/lib/shell_code_lines.py" "$WORK/nolib/"
PYTHON_C_PROGRAMS_LIB="$WORK/nolib" python3 "$WORK/scan.py" "$WORK/marker/split.sh" > "$WORK/nolib.out" 2>&1
rc=$?
[ "$rc" = 2 ] && ok || bad "#2080 with shell-words.py missing the scan should exit 2, exited $rc: $(tr '\n' '|' < "$WORK/nolib.out")"
grep -q 'shell-words.py' "$WORK/nolib.out" && ok || bad "#2080 and name shell-words.py, said: $(tr '\n' '|' < "$WORK/nolib.out")"

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
