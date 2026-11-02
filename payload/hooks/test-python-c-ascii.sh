#!/usr/bin/env bash
# A whole tree scan: a send touching these paths runs this suite (claude-config#809).
# send-gate: scans hooks/ skills/ mods/ commands/ agents/
# Every inline python3 -c program in the repository is written in ASCII alone (claude-config#2066).
#
# THE FAULT. python3 takes a -c program from argv, and argv is decoded by the locale. On Linux under
# LC_ALL=C with PYTHONUTF8=0 and PYTHONCOERCECLOCALE=0 it is decoded as ASCII with surrogateescape,
# so any byte outside ASCII in the program becomes a lone surrogate, the program fails to compile,
# and the call prints nothing. The Mac always decodes argv as UTF-8, so every such program passes
# there. CI runs Ubuntu, and that is how #2056 turned red: ps_parse_payload held a literal U+FFFD.
# A program read from a file or a heredoc on stdin is decoded as UTF-8 source on every machine, so
# only -c is at risk.
#
# THE FIX is always the same: write the character as an escape (é, ’), so the program
# holds only ASCII and means the same under any locale. There is no skip list.
#
# THE SCAN reads every file the repository ships (lib/repo-files.sh), once each, as bytes (L297). For
# each python3 -c it reads the next shell word the way the shell would join it: single quoted runs,
# double quoted runs, a backslash escape, and the \"...\" a program takes when it sits inside an outer
# double quoted string, until an unquoted space or operator. Any byte above 0x7f in that word is a
# finding. test-python-bad-bytes.sh has its own reader of -c programs, which decodes each file and
# takes one program per line in the hooks' .sh files; this one reads raw bytes, takes every program on
# a line, and reads every file, tests, tools and claude-sync included.
#
# A finding never names the character, so this file holds no byte outside ASCII: the fixtures below
# make theirs with printf octal escapes.
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
ROOT="${PYTHON_C_ASCII_ROOT:-$(bash "$DIR/lib/checkout-root.sh" "$DIR/.." 2>/dev/null || true)}"

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }

if [ -z "$ROOT" ] || [ ! -d "$ROOT" ]; then
  echo "test-python-c-ascii: $DIR/.. is not the payload of a claude-config checkout, so there were no files of this repository to read." >&2
  printf 'SUITE-NOT-RUN %s\n' "needs the repository to read its files, and $DIR/.. is not the payload of a claude-config checkout"
  exit 2
fi
if ! command -v python3 >/dev/null 2>&1; then
  printf 'SUITE-NOT-RUN %s\n' "the scan is a python3 program, and python3 is not on PATH"
  exit 2
fi

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/python-c-ascii.XXXXXXXX")" || TMPROOT=""
case "${TMPROOT%/}" in
  ''|/|"${HOME%/}") echo "test-python-c-ascii: refusing to run: throwaway directory came back as '$TMPROOT'." >&2; exit 2 ;;
esac
trap 'rm -rf "$TMPROOT"' EXIT

# The scan is a file python3 reads, never a -c program, so it compiles under any locale itself.
# scan.py <root> <list file> [--starts]: for each path in the list, relative to root, prints
#   HIT <path>:<line>: ...   for each program holding a byte outside ASCII, at that byte's line
#   START <path>:<line>      with --starts, for every program it read, at the line it starts on
#   UNCLOSED <path>:<line>   for a program whose quote never closes, which it cannot vouch for
# and last, always, READ files=<n> programs=<n>.
cat > "$TMPROOT/scan.py" <<'PY'
import os, re, sys

root, listing = sys.argv[1], sys.argv[2]
starts = "--starts" in sys.argv[3:]
# python3 (or python), any flags, then -c (alone or ending a cluster such as -Ic), then a space.
START = re.compile(rb"(?<![A-Za-z0-9_./-])python3?(?:[ \t]+-[A-Za-z]+)*?[ \t]+-[A-Za-z]*c[ \t]+")
ENDS = b" \t\n;|&()<>"


def word(b, i):
    """The shell word starting at i, as the bytes between its quotes, or None when a quote never
    closes. Returns (bytes or None, the index just past it)."""
    out, n = bytearray(), len(b)
    while i < n:
        c = b[i:i + 1]
        if c == b"'":
            j = b.find(b"'", i + 1)
            if j < 0:
                return None, i
            out += b[i + 1:j]
            i = j + 1
        elif b.startswith(b'\\"', i):
            j = b.find(b'\\"', i + 2)
            if j < 0:
                return None, i
            out += b[i + 2:j]
            i = j + 2
        elif c == b'"':
            j = i + 1
            while j < n and b[j:j + 1] != b'"':
                j += 2 if b[j:j + 1] == b"\\" else 1
            if j >= n:
                return None, i
            out += b[i + 1:j]
            i = j + 1
        elif c == b"\\":
            out += b[i + 1:i + 2]
            i += 2
        elif c in ENDS:
            break
        else:
            out += c
            i += 1
    return bytes(out), i


files = programs = 0
with open(listing, "rb") as f:
    paths = [p for p in f.read().split(b"\n") if p]
for rel in paths:
    shown = rel.decode("utf-8", "replace")
    try:
        with open(os.path.join(os.fsencode(root), rel), "rb") as f:
            b = f.read()
    except OSError:
        continue
    files += 1
    if b"python" not in b or b"\0" in b:
        continue
    for m in START.finditer(b):
        line = b.count(b"\n", 0, m.start()) + 1
        prog, end = word(b, m.end())
        if prog is None:
            print("UNCLOSED %s:%d" % (shown, line))
            continue
        programs += 1
        if starts:
            print("START %s:%d" % (shown, line))
        # The first byte above 0x7f is found in the file itself, between the program's start and its
        # end, so the line named is the one to edit.
        for k in range(m.end(), end):
            if b[k] > 0x7f:
                print("HIT %s:%d: the python3 -c program starting on line %d holds a byte outside ASCII"
                      " (0x%02x); write the character as an escape" % (shown, b.count(b"\n", 0, k) + 1, line, b[k]))
                break
print("READ files=%d programs=%d" % (files, programs))
PY

scan() { python3 -I -B "$TMPROOT/scan.py" "$@" 2>&1; }

# ---------------------------------------------------------------------------
# The scan has to see a program holding the byte in every shape one takes, and pass the byte where it
# is not part of a program, before the tree is asked (L1).
# ---------------------------------------------------------------------------
mkdir -p "$TMPROOT/probe"
EM='\342\200\224'; CURLY='\342\200\231'; ACUTE='\303\251'
{
  printf '#!/usr/bin/env bash\n'
  printf "python3 -c 'print(\"a${EM}b\")'\n"                               # 2: single quoted
  printf "out=\"\$(python3 -c '\nimport sys\nprint(\"Dan${CURLY}s\")\n')\"\n" # 3 to 6: over lines, byte on 5
  printf "python3 -I -B -c \"print('${ACUTE}')\"\n"                        # 7: flags, double quoted
  printf "bash -c \"python3 -c \\\\\"print('${ACUTE}')\\\\\"\"\n"          # 8: inside an outer string
  printf "python3 -c 'print('\\\\''${EM}'\\\\'')'\n"                       # 9: past a quoted quote
  printf "a=\"\$(python3 -c 'print(1)')\"; b=\"\$(python3 -Ic 'print(\"${EM}\")')\"\n" # 10: second on a line
  printf "python3 -c 'import sys; print(sys.argv[1])' \"Dan${CURLY}s folder\"\n"       # 11: an argument
  printf "# a python3 -c program is written in ASCII, unlike Dan${CURLY}s folder\n"    # 12: prose
  printf "python3 -c 'print(\"\\\\u00e9\")'\n"                             # 13: the escape, the fix
  printf "python3 - <<'EOF'\nprint(\"${EM}\")\nEOF\n"                      # 14 to 16: stdin is UTF-8
  printf "python3x -c 'print(\"${EM}\")'\n"                                # 17: another program
} > "$TMPROOT/probe/probe.sh"
printf 'probe/probe.sh\n' > "$TMPROOT/probe.list"
probe="$(scan "$TMPROOT" "$TMPROOT/probe.list")"
hit_lines="$(printf '%s\n' "$probe" | sed -n 's/^HIT probe\/probe.sh:\([0-9]*\):.*/\1/p' | tr '\n' ' ')"
[ "$hit_lines" = "2 5 7 8 9 10 " ] \
  && check "the scan finds the byte in each shape a program takes, and not in an argument, prose, an escape, a heredoc or another program" ok \
  || check "the scan finds the byte in each shape a program takes, and not in an argument, prose, an escape, a heredoc or another program" "it found lines [$hit_lines], wanted [2 5 7 8 9 10 ]: $probe"
case "$probe" in
  *"READ files=1 programs=10"*) check "the scan reads every program in the probe, the clean ones too" ok ;;
  *) check "the scan reads every program in the probe, the clean ones too" "it said: $probe" ;;
esac
# Ten: the prose on line 12 is read as a program named "program", which holds no such byte.
# A quote that never closes is a program it cannot vouch for, said as such, never passed.
printf "python3 -c 'print(1)\n" > "$TMPROOT/probe/open.sh"
printf 'probe/open.sh\n' > "$TMPROOT/open.list"
open_out="$(scan "$TMPROOT" "$TMPROOT/open.list")"
case "$open_out" in
  *"UNCLOSED probe/open.sh:1"*) check "a program whose quote never closes is reported, not passed" ok ;;
  *) check "a program whose quote never closes is reported, not passed" "it said: $open_out" ;;
esac

# And the hazard itself on this machine, so the rule rests on a measurement (L82). The program only
# assigns, so what is measured is whether it compiles, not whether stdout can write the character.
# Linux fails here; the Mac decodes argv as UTF-8 and passes, which is why the scan, not a run, has
# to hold the rule.
prog="$(printf "x = \"a${EM}b\"")"
hazard="$(LC_ALL=C PYTHONUTF8=0 PYTHONCOERCECLOCALE=0 python3 -c "$prog" 2>&1)"; hazard_rc=$?
if [ "$hazard_rc" -eq 0 ]; then
  echo "test-python-c-ascii: on this machine, a python3 -c program holding a byte outside ASCII compiles under LC_ALL=C. On Linux it does not."
else
  echo "test-python-c-ascii: on this machine, a python3 -c program holding a byte outside ASCII fails to compile under LC_ALL=C (exit $hazard_rc), which is the fault this guards: $(printf '%s' "$hazard" | tail -1)"
fi

# ---------------------------------------------------------------------------
# The real tree: no program anywhere holds a byte outside ASCII.
# ---------------------------------------------------------------------------
bash "$DIR/lib/repo-files.sh" "$ROOT" > "$TMPROOT/files.list" 2>/dev/null
# A listing that came back empty read nothing, and the check below would pass over it (L98).
[ -s "$TMPROOT/files.list" ] \
  && check "the files to judge were listed" ok \
  || check "the files to judge were listed" "lib/repo-files.sh gave nothing for $ROOT, so nothing below was read"
tree="$(scan "$ROOT" "$TMPROOT/files.list" --starts)"
hits="$(printf '%s\n' "$tree" | grep -E '^(HIT|UNCLOSED) ')"
[ -z "$hits" ] \
  && check "no python3 -c program in the repository holds a byte outside ASCII" ok \
  || check "no python3 -c program in the repository holds a byte outside ASCII" "these do, and fail to compile on Linux under the C locale:
$hits"
# A scan that read a handful of programs is reading the wrong tree (L98). 658 were read on 2026-11-02.
nprog="$(printf '%s\n' "$tree" | sed -n 's/^READ files=[0-9]* programs=\([0-9]*\)$/\1/p')"
[ "${nprog:-0}" -ge 400 ] \
  && check "the scan read the repository's programs" ok \
  || check "the scan read the repository's programs" "it read ${nprog:-no} python3 -c programs in $ROOT, where 658 were read on 2026-11-02"

# The four payload readers in lib/push-scope.sh, which #2056 fixed, are among the programs read, so
# this scan is the check on them (it replaced the one in test-payload-separator.sh). Each program's
# start line is matched to the function it sits in.
printf '%s\n' "$tree" | sed -n 's/^START payload\/hooks\/lib\/push-scope.sh:\([0-9]*\)$/\1/p' > "$TMPROOT/ps.starts"
in_fn="$(awk 'FILENAME == ARGV[1] { want[$1] = 1; next }
  /^[A-Za-z_][A-Za-z0-9_]*\(\)/ { fn = $1; sub(/\(\).*/, "", fn) }
  (FNR in want) { print fn }' "$TMPROOT/ps.starts" "$ROOT/payload/hooks/lib/push-scope.sh" | sort -u | tr '\n' ' ')"
for reader in ps_clean_payload ps_parse_payload ps_payload_text ps_payload_unread; do
  case " $in_fn" in
    *" $reader "*) check "#2056 the program in $reader is one the scan reads" ok ;;
    *) check "#2056 the program in $reader is one the scan reads" "the scan read programs in push-scope.sh only inside: [$in_fn]" ;;
  esac
done

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
