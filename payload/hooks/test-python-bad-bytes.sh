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
bad_byte_measured python "#1923 lb_read on a label list that is not UTF-8" || true
mkdir -p "$WORK/bin"
printf '#!/bin/sh\nprintf %s\n' "'[{\"name\":\"caf\\377\"}]'" > "$WORK/bin/gh"
chmod +x "$WORK/bin/gh"
OUT="$(PATH="$WORK/bin:$PATH" LC_ALL="$BAD_BYTE_LOCALE" bash -c '. "$1" && lb_read o/r "$2"; echo "rc=$?"' _ "$DIR/../skills/milestone/labels-lib.sh" "$WORK/lb.err" 2>&1)"
case "$OUT" in *"rc=1"*) ok ;; *) bad "lb_read should refuse a label list holding a byte that is not UTF-8, said: ${OUT:0:200}" ;; esac
case "$(cat "$WORK/lb.err" 2>/dev/null)" in *"not UTF-8"*) ok ;; *) bad "and say why, said: $(cat "$WORK/lb.err" 2>/dev/null)" ;; esac

# The scan, written out for each run. It reads every Python program in a tree; see its docstring.
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
  stdin       sys.stdin used for anything but its buffer (or isatty, fileno, close), input(), fileinput
"""
import ast, os, re, sys

MODULES_NOT_FILES = {"os", "tarfile", "gzip", "bz2", "lzma", "zipfile", "webbrowser", "shelve", "dbm",
                     "sqlite3", "urllib", "request", "wave", "aifc", "sunau", "Image", "pty", "socket"}
HEREDOC = re.compile(r"""<<-?[ \t]*(['"]?)([A-Za-z_][A-Za-z0-9_]*)\1""")
PYTHON = re.compile(r"""(^|[\s;&|("'`$])python3?(\s|$)""")
DASH_C = re.compile(r"""\bpython3?\b((?:[ \t]+-[A-Za-z]+)*?)[ \t]+-c[ \t]+(['"])""")
PY_VAR = re.compile(r"""^[ \t]*(?:export[ \t]+|local[ \t]+)?[A-Za-z_][A-Za-z0-9_]*_PY=(['"])""")
# A single quoted shell string goes on past these, each standing for one quote in the program.
SQ_IDIOMS = ("'\"'\"'", "'\\''")


def _quoted(lines, i, rest, q):
    """The text of a shell string opened on line i, whose remainder there is rest. Returns
    (text, index of the line it closes on)."""
    body, j, cur = [], i, ""
    while True:
        if q == "'":
            k = rest.find("'")
            while k >= 0 and rest.startswith(SQ_IDIOMS, k):
                idiom = next(s for s in SQ_IDIOMS if rest.startswith(s, k))
                cur += rest[:k] + "'"
                rest = rest[k + len(idiom):]
                k = rest.find("'")
        else:
            k = _dq_end(rest)
        if k >= 0:
            body.append(cur + rest[:k]); break
        body.append(cur + rest); cur = ""; j += 1
        if j >= len(lines):
            break
        rest = lines[j]
    src = "\n".join(body)
    if q == '"':
        src = src.replace('\\"', '"').replace("\\$", "$").replace("\\`", "`").replace("\\\\", "\\")
    return src, j


def units(path):
    """(first line number, source) for each Python program in the file: the whole of a .py file;
    in a shell script, each heredoc handed to python3 or named PY..., each python3 -c program, and
    each variable named ..._PY holding one."""
    text = open(path, "rb").read().decode("utf-8", "replace")
    if path.endswith(".py"):
        return [(1, text)]
    out, lines = [], text.split("\n")
    i = 0
    while i < len(lines):
        line = lines[i]
        if line.lstrip().startswith("#"):
            i += 1; continue
        m = HEREDOC.search(line)
        if m and (PYTHON.search(line[:m.start()]) or m.group(2).startswith("PY")):
            delim, body, j = m.group(2), [], i + 1
            while j < len(lines) and lines[j].strip() != delim:
                body.append(lines[j]); j += 1
            out.append((i + 2, "\n".join(body)))
            i = j + 1
            continue
        m = DASH_C.search(line) or PY_VAR.search(line)
        if m:
            q = m.groups()[-1]
            rest = line[m.end():]
            if rest.startswith("$"):
                i += 1; continue   # a program held in a variable, read where the variable is set
            src, j = _quoted(lines, i, rest, q)
            out.append((i + 1, src))
            i = j + 1
            continue
        i += 1
    return out


def _dq_end(s):
    k = 0
    while k < len(s):
        if s[k] == "\\":
            k += 2; continue
        if s[k] == '"':
            return k
        k += 1
    return -1


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
    if decodes_json and writes_stdout and not reconfigured:
        finds.append((None, "stdout"))
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
    main(sys.argv[1:])
SCAN

# ---------------------------------------------------------------------------
echo "every Python program in the hooks and the skills says how it handles text it cannot decode or encode"

python3 "$WORK/scan.py" "$DIR" > "$WORK/hooks.scan" 2>&1
units="$(sed -n 's/^UNITS //p' "$WORK/hooks.scan")"
[ "${units:-0}" -ge 100 ] && ok || bad "the scan read only ${units:-no} Python programs in $DIR, so it is reading the wrong tree or cannot find them"
unparsed="$(grep '^UNPARSED' "$WORK/hooks.scan")"
if [ -z "$unparsed" ]; then ok; else bad "the scan could not parse these, so it cannot vouch for them:
$unparsed"; fi
hits="$(grep -v -E '^(UNITS|UNPARSED) ' "$WORK/hooks.scan" | sed "s#^$DIR/##")"
if [ -z "$hits" ]; then ok; else bad "Python in the hooks raises on a byte that is not UTF-8 or a lone surrogate here. Give each open, subprocess and decode an errors= (\"replace\", or \"strict\" where refusing is the decision), and a program that decodes JSON and prints sys.stdout.reconfigure(errors=\"replace\") first:
$hits"; fi

# The skills, held to the same rules: they read gh's answers, transcripts and files the same way.
python3 "$WORK/scan.py" "$DIR/../skills" > "$WORK/skills.scan" 2>&1
sunits="$(sed -n 's/^UNITS //p' "$WORK/skills.scan")"
[ "${sunits:-0}" -ge 30 ] && ok || bad "the scan read only ${sunits:-no} Python programs under payload/skills"
shits="$(grep -v -E '^UNITS ' "$WORK/skills.scan" | sed "s#^$DIR/../##")"
if [ -z "$shits" ]; then ok; else bad "a script under payload/skills raises on a byte that is not UTF-8 or a lone surrogate, or reads stdin in text mode, which under C reads it as something else. Read sys.stdin.buffer, and give each open, subprocess and decode an errors= saying what happens to such a byte:
$shits"; fi

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
PROBE
python3 "$WORK/scan.py" "$WORK/probe/held.py" > "$WORK/probe.out"
for rule in "open: with open" "open: b = open" "subprocess: c =" "subprocess: d =" "decode: e =" "stdin: f =" "stdout:"; do
  grep -q -F "$rule" "$WORK/probe.out" && ok || bad "the scan does not fire on the shape '$rule' in a .py file; it said: $(tr '\n' '|' < "$WORK/probe.out")"
done
# A program decoding JSON through a decoder object, as the milestone list reader does.
printf '%s\n' 'import json, sys' 'v, _ = json.JSONDecoder().raw_decode(sys.stdin.buffer.read().decode("utf-8", "replace"))' 'print(v["t"])' > "$WORK/probe/decoder.py"
python3 "$WORK/scan.py" "$WORK/probe/decoder.py" > "$WORK/probe.out"
grep -q 'stdout:' "$WORK/probe.out" && ok || bad "the scan does not count a JSON decoder object as decoding JSON"
python3 "$WORK/scan.py" "$WORK/probe/fixed.py" > "$WORK/probe.out"
[ "$(grep -c -v '^UNITS ' "$WORK/probe.out")" = 0 ] && ok || bad "the scan fires on the forms it asks for: $(tr '\n' '|' < "$WORK/probe.out")"
python3 "$WORK/scan.py" "$WORK/probe/held.sh" > "$WORK/probe.out"
[ "$(sed -n 's/^UNITS //p' "$WORK/probe.out")" = 4 ] && ok || bad "the scan should find four programs in a shell script (a -c, a heredoc, a _PY variable, a -c quoting a quote), said: $(tr '\n' '|' < "$WORK/probe.out")"
for rule in "held.sh:2: stdin" "held.sh:2: stdout" "held.sh:5: open" "held.sh:10: subprocess" "held.sh:12: open"; do
  grep -q -F "$rule" "$WORK/probe.out" && ok || bad "the scan does not fire on '$rule' in a shell script; it said: $(tr '\n' '|' < "$WORK/probe.out")"
done

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
