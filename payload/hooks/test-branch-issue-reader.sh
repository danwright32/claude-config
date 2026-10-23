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

# BRANCH_READER_SCAN_ONLY=1 is this suite's own run of a copy of itself in a fixture tree (below):
# only the scan of that tree, so the copy needs neither node nor the reader beside it.
SCAN_ONLY="${BRANCH_READER_SCAN_ONLY:-}"

# The scan judges what this repository SHIPS, so it reads the files lib/repo-files.sh lists for the
# payload of the checkout this suite sits in, as every whole tree scan here does, never a walk of the
# folder around it. Installed in ~/.claude there is no such checkout, and that folder also holds
# marketplace plugins and other software's files: a walk of it read a vendored mermaid.min.js as
# three hand written readers (2026-10-23). There it says it cannot run, in the agreed shape, and
# run-all-tests.sh re-runs it from the checkout claude-sync names (claude-config#237). A repository
# above that is not this one (a home folder kept in git) is no checkout either: it must hold
# claude-sync and this very payload.
REPO="$(git -C "$PAYLOAD" rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "$REPO" ] || [ ! -f "$REPO/claude-sync" ] || [ ! -d "$REPO/payload" ] \
   || [ "$(cd "$REPO/payload" && pwd -P)" != "$(cd "$PAYLOAD" && pwd -P)" ]; then
  echo "test-branch-issue-reader: $PAYLOAD is not the payload of a claude-config checkout, so there is no list of the files it ships." >&2
  printf 'SUITE-NOT-RUN %s\n' "needs the repository to list the files it ships, and $PAYLOAD is not the payload of one"
  exit 2
fi

if [ -z "$SCAN_ONLY" ] && ! command -v node >/dev/null 2>&1; then
  printf 'SUITE-NOT-RUN %s\n' "node is not installed, and the reader runs under it"
  exit 2
fi

if [ -z "$SCAN_ONLY" ]; then
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
fi

# ---- the scan ----
SCAN="$TMPROOT/scan.py"
cat > "$SCAN" <<'PY'
import os
import re
import sys

# scan.py <root>, with the files to read on stdin, one per line relative to <root>: the list
# lib/repo-files.sh gives, never a walk, so nothing that merely sits in the folder is read.
root = sys.argv[1]
READER = "mods/mod-kit/hooks/branch.ts"
BRANCH = re.compile(r"branch|headrefname|head_ref", re.I)
# A pattern for a run of digits, in the spellings regular expressions, globs and shell use.
DIGITS = re.compile(r"\\d[+*{]|\[0-9\][+*{]|\[1-9\]\[0-9\]|\[\[:digit:\]\]|\[\^0-9\]")
CODE = (".py", ".sh", ".bash", ".js", ".mjs", ".cjs", ".ts", ".tsx")
COMMENT = re.compile(r"^\s*(#|//|\*|/\*)")
found = []
for rel in sorted(set(x for x in sys.stdin.read().split("\n") if x)):
    parts = rel.split("/")
    f = parts[-1]
    if any(d in ("tests", "node_modules", ".git") for d in parts[:-1]):
        continue
    if f.startswith("test-") or rel == READER:
        continue
    try:
        with open(os.path.join(root, rel), encoding="utf-8") as fh:
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
# The files to read, and the scan over them: one lister for the real tree and every planted one.
shipped_scan() {   # $1 = a folder inside a git repository
  local files
  files="$(bash "$DIR/lib/repo-files.sh" "$1")" || return 3
  [ -n "$files" ] || { echo "test-branch-issue-reader: lib/repo-files.sh listed nothing under $1, so nothing would be read." >&2; return 3; }
  printf '%s\n' "$files" | python3 -I "$SCAN" "$1"
}
out="$(shipped_scan "$PAYLOAD")"; rc=$?
check_eq "the scan ran over the files the payload ships" 0 "$rc"
if [ -n "$out" ]; then
  while IFS= read -r hit; do
    check "a hand written reader of a branch's issues at $hit: read them with \$.modkit.branch in a mod, or hooks/lib/branch-issues.mjs elsewhere" "found"
  done <<< "$out"
else
  check "no hand written reader of a branch's issues anywhere in the payload" ok
fi
check_eq "the scan read the reader's own folder" yes "$([ -f "$PAYLOAD/mods/mod-kit/hooks/branch.ts" ] && echo yes || echo no)"

if [ -z "$SCAN_ONLY" ]; then
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
git init -q "$PLANT" 2>/dev/null
out="$(shipped_scan "$PLANT")"
check_eq "every planted reader is caught, and only those" "hooks/lib/issue.sh:2
hooks/lib/issue.sh:3
hooks/lib/issue.sh:4
hooks/lib/queue.py:11
hooks/lib/queue.py:4
mods/x/hooks/branch.ts:1" "$out"

# ---- what the scan reads: what this repository ships, never what lives beside a copy of it ----
# claude-sync pull runs this suite from the INSTALLED copy in ~/.claude, where marketplace plugins
# and other software's files sit beside the hooks. Walking that folder read a vendored mermaid.min.js
# as three hand written readers (found 2026-10-23). A copy of this suite is run, scan only, in three
# trees that each hold such a foreign file, and in the checkout beside a shipped file holding the
# same line.
FOREIGN='plugins/marketplaces/m/plugins/p/assets/vendor/chart.min.js'
FOREIGN_LINE='var n=branch.match(/\d+/);'
seed_copy() {   # $1 = the folder standing for payload/ or ~/.claude
  mkdir -p "$1/hooks/lib" "$1/mods/mod-kit/hooks" "$1/$(dirname "$FOREIGN")"
  cp "$DIR/test-branch-issue-reader.sh" "$1/hooks/"
  cp "$DIR/lib/suite-deadline.sh" "$DIR/lib/repo-files.sh" "$1/hooks/lib/"
  printf '%s\n' 'export const issuesOfBranch = () => []' > "$1/mods/mod-kit/hooks/branch.ts"
  printf '%s\n' "$FOREIGN_LINE" > "$1/$FOREIGN"
}
scan_copy() { BRANCH_READER_SCAN_ONLY=1 bash "$1/hooks/test-branch-issue-reader.sh" 2>&1; }
names_foreign() { case "$1" in *chart.min.js*) echo yes ;; *) echo no ;; esac; }
said_not_run() { case "$1" in "SUITE-NOT-RUN "*|*$'\n'"SUITE-NOT-RUN "*) echo yes ;; *) echo no ;; esac; }

# An installed copy: no repository above it at all.
seed_copy "$TMPROOT/installed/.claude"
out="$(scan_copy "$TMPROOT/installed/.claude")"; rc=$?
check_eq "an installed copy does not read a foreign plugin's file as a reader" no "$(names_foreign "$out")"
check_eq "and says it cannot judge the shipped files there, for the pull to re run it from the checkout" "2 yes" \
  "$rc $(said_not_run "$out")"

# An installed copy inside somebody else's repository (a home folder kept in git): a repository,
# but not this one, so its files are not what this repository ships.
seed_copy "$TMPROOT/dotfiles/.claude"
git init -q "$TMPROOT/dotfiles" 2>/dev/null
out="$(scan_copy "$TMPROOT/dotfiles/.claude")"; rc=$?
check_eq "a copy inside another repository does not read its foreign file either" no "$(names_foreign "$out")"
check_eq "and says it cannot judge there" "2 yes" "$rc $(said_not_run "$out")"

# The checkout: a shipped file holding the same line is still caught, and a foreign folder the
# repository ignores is not read.
seed_copy "$TMPROOT/checkout/payload"
: > "$TMPROOT/checkout/claude-sync"
printf '%s\n' '/payload/plugins/' > "$TMPROOT/checkout/.gitignore"
printf '%s\n' "$FOREIGN_LINE" > "$TMPROOT/checkout/payload/hooks/lib/shipped.js"
git init -q "$TMPROOT/checkout" 2>/dev/null
out="$(scan_copy "$TMPROOT/checkout/payload")"; rc=$?
case "$out" in *"issues at hooks/lib/shipped.js:1:"*) caught=yes ;; *) caught=no ;; esac
check_eq "in the checkout the same line in a shipped file is still caught" "1 yes" "$rc $caught"
check_eq "and the folder the repository ignores is not read" no "$(names_foreign "$out")"
fi

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
