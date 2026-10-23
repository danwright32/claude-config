#!/usr/bin/env bash
# A whole tree scan: a send touching these paths runs this suite (claude-config#809).
# send-gate: scans hooks/ skills/ mods/ commands/ agents/
# The one reader of the issues a branch names (claude-config#1475).
#
# Which issues a branch's name names is read in one place, issuesOfBranch in mod-kit's
# hooks/branch.ts: mods reach it through $.modkit.branch, and hooks and libraries outside the mods
# through hooks/lib/branch-issues.mjs, which runs it under node. Two readers had drifted apart.
# mod-kit's was fixed for an agent worktree's random id in #1306 and for a plan's step in #1475,
# while sleep-queue.py kept its own: it read every run of digits, so connections-pr10-form-2338
# kept #10 out of the night and worktree-agent-ad4e7831d26de84f8 kept #7831, #26 and #84 out, and
# it read fix/1119-1124-... as a date, so a branch on both issues kept neither out.
#
# This suite holds the door the libraries use to the reader's answers, and fails on the next reader
# written by hand anywhere in the payload: a line naming a branch beside a pattern for a run of
# digits, or a python function whose name or docstring speaks of a branch and holds one. Each
# shape the hand written readers had is planted below and must be caught (L1, L613).
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PAYLOAD="$(cd "$DIR/.." && pwd)"
CLI="$DIR/lib/branch-issues.mjs"

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }
check_eq() { if [[ "$2" == "$3" ]]; then check "$1" ok; else check "$1" "expected '$2', got '$3'"; fi; }

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/branch-issue-reader.XXXXXXXX")" || TMPROOT=""
case "${TMPROOT%/}" in
  ''|/|"${HOME%/}") echo "test-branch-issue-reader: refusing to run: throwaway directory came back as '$TMPROOT'." >&2; exit 2 ;;
esac
trap 'rm -rf "$TMPROOT"' EXIT

if ! command -v node >/dev/null 2>&1; then
  printf 'SUITE-NOT-RUN %s\n' "node is not installed, and the reader runs under it"
  exit 2
fi

# ---- the door: names in, one per line; a JSON object of each name's issues out ----
read_names() { printf '%s\n' "$@" | node --experimental-strip-types --no-warnings "$CLI"; }
out="$(read_names connections-pr10-form-2338 connections-pr-10-form-2338 fix/1119-1124-sleep-claims-and-git-judging worktree-agent-ad4e7831d26de84f8 guard-costs/2026-09-03 i2968-dismissed-followup-render)"; rc=$?
check_eq "the reader runs" 0 "$rc"
check_eq "each name read as mod-kit reads it" '{"connections-pr10-form-2338":[2338],"connections-pr-10-form-2338":[2338],"fix/1119-1124-sleep-claims-and-git-judging":[1119,1124],"worktree-agent-ad4e7831d26de84f8":[],"guard-costs/2026-09-03":[],"i2968-dismissed-followup-render":[2968]}' "$out"
out="$(printf '' | node --experimental-strip-types --no-warnings "$CLI")"; rc=$?
check_eq "no names read as none" "0 {}" "$rc $out"
# Where mod-kit is not beside it, the reader fails loud rather than reading every name as none.
mkdir -p "$TMPROOT/lonely/hooks/lib"
cp "$CLI" "$TMPROOT/lonely/hooks/lib/branch-issues.mjs"
out="$(printf 'fix-1475\n' | node --experimental-strip-types --no-warnings "$TMPROOT/lonely/hooks/lib/branch-issues.mjs" 2>&1)"; rc=$?
check_eq "a reader with no mod-kit beside it fails" yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
case "$out" in '{'*|*$'\n{'*) answered=yes ;; *) answered=no ;; esac
check_eq "and prints no answer" no "$answered"

# ---- the scan ----
SCAN="$TMPROOT/scan.py"
cat > "$SCAN" <<'PY'
import os
import re
import sys

root = sys.argv[1]
READER = "mods/mod-kit/hooks/branch.ts"
BRANCH = re.compile(r"branch|headrefname|head_ref", re.I)
# A pattern for a run of digits, in the spellings regular expressions, globs and shell use.
DIGITS = re.compile(r"\\d[+*{]|\[0-9\][+*{]|\[1-9\]\[0-9\]|\[\[:digit:\]\]|\[\^0-9\]")
CODE = (".py", ".sh", ".bash", ".js", ".mjs", ".cjs", ".ts", ".tsx")
COMMENT = re.compile(r"^\s*(#|//|\*|/\*)")
found = []
for dp, dns, fns in os.walk(root):
    dns[:] = sorted(d for d in dns if d not in ("tests", "node_modules", ".git"))
    for f in sorted(fns):
        p = os.path.join(dp, f)
        rel = os.path.relpath(p, root)
        if f.startswith("test-") or rel == READER:
            continue
        try:
            with open(p, encoding="utf-8") as fh:
                text = fh.read()
        except (UnicodeDecodeError, OSError):
            continue
        if not (f.endswith(CODE) or text.startswith("#!")):
            continue
        for i, line in enumerate(text.split("\n"), 1):
            if not COMMENT.match(line) and BRANCH.search(line) and DIGITS.search(line):
                found.append("%s:%d" % (rel, i))
        if f.endswith(".py"):
            # A function whose name or docstring speaks of a branch and whose code holds a digit run.
            for m in re.finditer(r"^([ \t]*)def (\w+)[^\n]*\n((?:\1[ \t]+[^\n]*\n|[ \t]*\n)*)", text, re.M):
                body = m.group(3)
                doc = re.match(r'\s*("""|\'\'\')(.*?)\1', body, re.S)
                said = m.group(2) + " " + (doc.group(2) if doc else "")
                code = "\n".join(x for x in body.split("\n") if not COMMENT.match(x))
                if BRANCH.search(said) and DIGITS.search(code):
                    found.append("%s:%d" % (rel, text[:m.start()].count("\n") + 1))
for x in found:
    print(x)
PY
out="$(python3 -I "$SCAN" "$PAYLOAD")"; rc=$?
check_eq "the scan ran over the payload" 0 "$rc"
if [ -n "$out" ]; then
  while IFS= read -r hit; do
    check "a hand written reader of a branch's issues at $hit: read them with \$.modkit.branch in a mod, or hooks/lib/branch-issues.mjs elsewhere" "found"
  done <<< "$out"
else
  check "no hand written reader of a branch's issues anywhere in the payload" ok
fi
check_eq "the scan read the reader's own folder" yes "$([ -f "$PAYLOAD/mods/mod-kit/hooks/branch.ts" ] && echo yes || echo no)"

# Positive controls: each shape a hand written reader has had, planted in a tree of its own.
PLANT="$TMPROOT/plant"
mkdir -p "$PLANT/hooks/lib" "$PLANT/mods/x/hooks"
# sleep-queue.py's own, before #1475: a function the docstring ties to a branch name.
cat > "$PLANT/hooks/lib/queue.py" <<'PY'
import re


def digits(text):
    """The issue numbers a branch name can mean: every run of digits."""
    t = text or ""
    return set(re.findall(r"\d+", t))


def claim(branch):
    return re.match(r"^sleep/([1-9][0-9]*)$", branch)


def request_refs(request):
    """The issues a request names: each #N."""
    return set(re.findall(r"#(\d+)", request))
PY
# mod-kit's own, before #1306.
printf '%s\n' 'export const issuesOfBranch = (branch: string): number[] => [...branch.matchAll(/(?:^|[^0-9])(\d{2,6})(?=$|[^0-9])/g)].map(m => Number(m[1]))' > "$PLANT/mods/x/hooks/branch.ts"
# The shell's spellings.
cat > "$PLANT/hooks/lib/issue.sh" <<'SH'
#!/usr/bin/env bash
n="$(grep -oE '[0-9]+' <<< "$branch")"
[[ "$branch" =~ ([0-9]{2,6}) ]] && n="${BASH_REMATCH[1]}"
m="${head_branch//[^0-9]/}"
# a comment naming a branch and [0-9]+ is prose, not a reader
SH
out="$(python3 -I "$SCAN" "$PLANT")"
check_eq "every planted reader is caught, and only those" "hooks/lib/issue.sh:2
hooks/lib/issue.sh:3
hooks/lib/issue.sh:4
hooks/lib/queue.py:11
hooks/lib/queue.py:4
mods/x/hooks/branch.ts:1" "$out"

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
