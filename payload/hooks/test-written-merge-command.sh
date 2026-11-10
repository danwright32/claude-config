#!/usr/bin/env bash
# A whole tree scan: a send touching these paths runs this suite (claude-config#809).
# send-gate: scans CLAUDE.md skills/ commands/ agents/ hooks/lib/merge-when-ready.sh
# Every merge command the rules write out can be run as written (claude-config#2563).
#
# On 2026-11-09 the command in the orchestrate skill and the global CLAUDE.md was refused twice when
# followed word for word: merge-when-ready.sh exits 64 when it is not run from a checkout of the
# repository, and again when no merge method is passed and the repository allows more than one. So
# each written command must name a method and say, in its own list item or paragraph, that it runs
# from a checkout; and each flag it passes must be one the helper's own usage line offers, so the
# next change to the helper's arguments fails here instead of in a session.
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PAYLOAD="$(cd "$DIR/.." && pwd)"
HELPER="$DIR/lib/merge-when-ready.sh"

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }

if [ ! -f "$HELPER" ]; then
  echo "FAIL: test-written-merge-command: lib/merge-when-ready.sh is missing beside this suite"
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
fi

# Judges the markdown files named on stdin (paths under $1) against the helper's usage line, read
# from the helper itself. Prints one line per written command, "ok <file>:<line>" or
# "bad <file>:<line>: <what is wrong>", and "none" when it found no command at all.
judge() { # judge <payload folder> <helper>
  python3 -I -c '
import re, sys
root, helper = sys.argv[1], sys.argv[2]
usage = ""
for line in open(helper, encoding="utf-8", errors="replace"):
    m = re.search(r"usage: \$SELF ([^\"]*)\"", line)
    if m:
        usage = m.group(1)
        break
if not usage:
    print("bad %s: no usage line was found in the helper" % helper)
    sys.exit(0)
offered = set(re.findall(r"--[a-z][a-z-]*", usage))
methods = {"--squash", "--merge", "--rebase"}
CMD = re.compile(r"`bash ~/\.claude/hooks/lib/merge-when-ready\.sh ([^`]*)`")
ITEM = re.compile(r"^\s*(?:\d+\.|[-*])\s")
found = 0
for rel in sys.stdin.read().split("\n"):
    rel = rel.strip()
    if not rel:
        continue
    lines = open(root + "/" + rel, encoding="utf-8", errors="replace").read().split("\n")
    # Each list item or paragraph, as the line it starts on and its text joined.
    blocks, start, buf = [], 0, []
    for i, line in enumerate(lines):
        if not line.strip() or ITEM.match(line):
            if buf:
                blocks.append((start, " ".join(buf)))
            buf, start = ([line.strip()], i) if line.strip() else ([], i + 1)
        else:
            if not buf:
                start = i
            buf.append(line.strip())
    if buf:
        blocks.append((start, " ".join(buf)))
    for start, text in blocks:
        for m in CMD.finditer(text):
            found += 1
            where = "%s:%d" % (rel, start + 1)
            flags = set(f.split("=")[0] for f in re.findall(r"--[a-z][a-z=-]*", m.group(1)))
            wrong = []
            unknown = sorted(flags - offered)
            if unknown:
                wrong.append("passes %s, which the usage line (%s) does not offer" % (", ".join(unknown), usage))
            if not flags & methods:
                wrong.append("names no merge method (--squash, --merge or --rebase)")
            if "checkout" not in text:
                wrong.append("does not say it runs from a checkout of the repository")
            print(("bad %s: %s" % (where, "; ".join(wrong))) if wrong else "ok " + where)
if not found:
    print("none")
' "$1" "$2"
}

# The judge itself, on planted documents, so a pass below is one it could have failed (L1).
T="$(mktemp -d "${TMPDIR:-/tmp}/written-merge.XXXXXXXX")" || T=""
case "${T%/}" in ''|/|"${HOME%/}") echo "test-written-merge-command: refusing to run: throwaway directory came back as '$T'." >&2; exit 2 ;; esac
trap 'rm -rf "$T"' EXIT
B='`bash ~/.claude/hooks/lib/merge-when-ready.sh'
{
  printf '1. From a checkout of the repository, merge with %s <n> --repo <o>/<r> --squash --delete-branch`.\n' "$B"
  printf '2. Merge with %s <n> --repo <o>/<r> --delete-branch`, from a checkout.\n' "$B"
  printf '3. Merge with %s <n> --squash --delete-branch`.\n' "$B"
  printf '4. From a checkout, %s <n> --squash --admin`.\n' "$B"
  printf '5. Something unrelated about a checkout.\n\nA paragraph, run from a checkout of the\nrepository: %s <n> --rebase\n--log=<file>`.\n' "$B"
} > "$T/doc.md"
out="$(printf 'doc.md\n' | judge "$T" "$HELPER")"
case "$out" in *"ok doc.md:1"*) check "a command naming a method, from a checkout, passes" ok ;; *) check "a command naming a method, from a checkout, passes" "$out" ;; esac
case "$out" in *"bad doc.md:2: names no merge method"*) check "a command naming no method fails" ok ;; *) check "a command naming no method fails" "$out" ;; esac
case "$out" in *"bad doc.md:3: does not say it runs from a checkout"*) check "a command whose item never says checkout fails, though the next item does" ok ;; *) check "a command whose item never says checkout fails, though the next item does" "$out" ;; esac
case "$out" in *"bad doc.md:4: passes --admin, which the usage line"*) check "a flag the usage line does not offer fails" ok ;; *) check "a flag the usage line does not offer fails" "$out" ;; esac
printf 'Nothing here.\n' > "$T/empty.md"
out="$(printf 'empty.md\n' | judge "$T" "$HELPER")"
[ "$out" = "none" ] && check "a document with no command is reported as none, not as passing" ok || check "a document with no command is reported as none, not as passing" "$out"

# The rules as shipped.
DOCS="$(cd "$PAYLOAD" && grep -rl --include='*.md' 'hooks/lib/merge-when-ready.sh ' . 2>/dev/null | grep -v '/LESSONS' | sed 's#^\./##')"
out="$(printf '%s\n' "$DOCS" | judge "$PAYLOAD" "$HELPER")"
case "$out" in
  none|'') check "the rules write out at least one merge command (this suite reads them)" "found none under $PAYLOAD" ;;
  *) check "the rules write out at least one merge command (this suite reads them)" ok ;;
esac
for f in CLAUDE.md skills/orchestrate/SKILL.md skills/next-issue/SKILL.md; do
  case "$out" in *" $f:"*) check "$f's merge command is judged" ok ;; *) check "$f's merge command is judged" "not among: $out" ;; esac
done
bad="$(printf '%s\n' "$out" | grep '^bad ' || true)"
[ -z "$bad" ] && check "every merge command the rules write out names a method, a checkout, and only flags the helper offers" ok \
  || check "every merge command the rules write out names a method, a checkout, and only flags the helper offers" "$bad"

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
