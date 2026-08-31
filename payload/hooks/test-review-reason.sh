#!/usr/bin/env bash
# Tests for lib/review-reason.py, which builds the JSON payload both Stop hooks emit.
#
# Why this exists at all. A Stop hook delivers its instruction through `reason`, and
# `reason` is printed to Dan verbatim. Both hooks used to carry their whole
# instruction there, about 7,000 characters each, and the issue review appended the
# spooled subagent findings on top of that (measured 2026-08-31: one review carried
# a 45 line preamble plus a findings list capped at 8,000 characters). All of it was
# addressed to Claude and all of it landed on Dan's screen.
#
# So the instruction moved to a file and the reason became a pointer. The property
# that has to hold, and the reason this suite is not just a JSON parse check, is
# that the reason STAYS short no matter how much is pending. A pointer that grows
# with its target is the same defect wearing a different shape, so the budget is
# asserted against a deliberately enormous findings file rather than a tidy one.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$DIR/lib/review-reason.py"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/claude-review-reason.XXXXXX")" || exit 2
case "${WORK%/}" in
  ''|/|"${HOME%/}") echo "refusing to run: throwaway directory came back as '$WORK'." >&2; exit 2 ;;
esac
# Normalised, because $TMPDIR on macOS ends in a slash and mktemp hands back a
# path holding a double one. Every hook below resolves its own directory through
# `cd ... && pwd`, which collapses it, so an un-normalised fixture path compares
# unequal to the identical directory and the relocation test fails on punctuation.
WORK="$(cd "$WORK" && pwd)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
check() { # check <description> <ok|why-not>
  if [[ "$2" == "ok" ]]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL: $1 ($2)"
  fi
}

# The reason, extracted the way Claude Code would: parse the JSON, take the field.
# Reading it with grep would pass on a payload that does not parse, which is the
# failure that silently stops the hook working.
reason_of() { # reason_of <payload json>
  printf '%s' "$1" | python3 -c '
import json, sys
try:
    p = json.loads(sys.stdin.read())
except Exception as exc:
    print("PAYLOAD DOES NOT PARSE: %s" % exc)
    sys.exit(0)
if p.get("decision") != "block":
    print("DECISION IS NOT BLOCK: %r" % p.get("decision"))
    sys.exit(0)
print(p.get("reason") or "")
'
}

INSTRUCTION="$WORK/issue-review.md"
cat > "$INSTRUCTION" <<'MD'
# Issue review
Do the review. This body is deliberately long so that a helper that inlined the
instruction instead of pointing at it would blow the size budget below.
MD
# Pad the instruction to something the size of the real one, so "the reason is
# short" cannot pass by the instruction happening to be tiny.
python3 -c "
import sys
with open(sys.argv[1], 'a') as fh:
    fh.write('filler. ' * 900)
" "$INSTRUCTION"

# ---------------------------------------------------------------------------
# 1. The pointer payload, with nothing pending.
# ---------------------------------------------------------------------------
out="$("$HELPER" --instruction "$INSTRUCTION" --label "END OF TURN ISSUE REVIEW" 2>/dev/null)"
rc=$?
[ "$rc" -eq 0 ] && check "a plain pointer payload exits 0" ok || check "a plain pointer payload exits 0" "exit $rc"

reason="$(reason_of "$out")"
[[ "$reason" != *"DOES NOT PARSE"* && "$reason" != *"NOT BLOCK"* ]] \
  && check "the payload is valid JSON carrying a block decision" ok \
  || check "the payload is valid JSON carrying a block decision" "$reason"

[[ "$reason" == *"$INSTRUCTION"* ]] \
  && check "the reason names the instruction file" ok \
  || check "the reason names the instruction file" "it does not: [$reason]"

[[ "$reason" == *"END OF TURN ISSUE REVIEW"* ]] \
  && check "the reason carries the label it was given" ok \
  || check "the reason carries the label it was given" "it does not: [$reason]"

# The instruction's own text must NOT be inlined. Checked against a distinctive
# string from the file rather than against its length, so a helper that inlined
# only the first paragraph is still caught.
[[ "$reason" != *"This body is deliberately long"* ]] \
  && check "the instruction body is pointed at, not inlined" ok \
  || check "the instruction body is pointed at, not inlined" "the reason contains the instruction text"

# ---------------------------------------------------------------------------
# 2. THE BUDGET. This is the whole point of the change.
#
# An enormous findings file, because the failure being guarded against is a
# reason that grows with what is pending. 60,000 characters is larger than any
# real spool has rendered to (the largest measured was 50,030 on 2026-08-29).
# ---------------------------------------------------------------------------
BUDGET=1200
FINDINGS="$WORK/findings.txt"
{
  printf 'FINDING (general-purpose, 2026-08-21T16:21:20Z): the parser is duplicated four times\n'
  printf 'FINDING (general-purpose, 2026-08-21T16:21:21Z): the retry fires on any failure\n'
  python3 -c "
for i in range(700):
    print('FINDING (general-purpose, 2026-08-21T16:21:%02dZ): %s' % (i % 60, 'padding ' * 10))
"
  printf 'HARVEST FAILED (subagent, last 2026-08-21T16:22:00Z, 3 times): the named agent transcript does not exist. Nothing was read from those agents, so this is not the same as them finding nothing.\n'
} > "$FINDINGS"

size="$(wc -c < "$FINDINGS" | tr -d ' ')"
[ "$size" -gt 50000 ] \
  && check "the oversized findings fixture really is oversized" ok \
  || check "the oversized findings fixture really is oversized" "it is only $size characters, so the budget below proves nothing"

out="$("$HELPER" --instruction "$INSTRUCTION" --label "END OF TURN ISSUE REVIEW" --findings "$FINDINGS" 2>/dev/null)"
reason="$(reason_of "$out")"
len="${#reason}"

[ "$len" -le "$BUDGET" ] \
  && check "the reason stays under the budget with a 50,000 character spool pending" ok \
  || check "the reason stays under the budget with a 50,000 character spool pending" "it is $len characters, budget is $BUDGET"

[[ "$reason" == *"$FINDINGS"* ]] \
  && check "the reason names the findings file" ok \
  || check "the reason names the findings file" "it does not: [$reason]"

[[ "$reason" != *"padding padding"* ]] \
  && check "the findings themselves are pointed at, not inlined" ok \
  || check "the findings themselves are pointed at, not inlined" "the reason contains the findings text"

# The COUNTS have to be right, because they are what Dan actually reads. A wrong
# count is worse than no count: it is a claim about how much is waiting.
[[ "$reason" == *"702 finding"* ]] \
  && check "the reason counts the findings" ok \
  || check "the reason counts the findings" "it does not say 702: [$reason]"

[[ "$reason" == *"1 harvest failure"* ]] \
  && check "the reason counts the harvest failures separately" ok \
  || check "the reason counts the harvest failures separately" "it does not say 1 harvest failure: [$reason]"

# ---------------------------------------------------------------------------
# 3. A findings file with no failures must not claim there are failures, and one
#    with no findings must not claim there are findings. Both directions, because
#    a hardcoded sentence naming both would pass a test of either alone.
# ---------------------------------------------------------------------------
ONLYFAIL="$WORK/onlyfail.txt"
printf 'HARVEST FAILED (subagent, last 2026-08-21T16:22:00Z): the named agent transcript does not exist.\n' > "$ONLYFAIL"
reason="$(reason_of "$("$HELPER" --instruction "$INSTRUCTION" --label "X" --findings "$ONLYFAIL" 2>/dev/null)")"
[[ "$reason" == *"1 harvest failure"* && "$reason" != *"1 finding"* ]] \
  && check "a spool holding only failures is not reported as holding findings" ok \
  || check "a spool holding only failures is not reported as holding findings" "[$reason]"

# ---------------------------------------------------------------------------
# 4. A line the renderer produced that this helper does not recognise must be
#    COUNTED, never dropped. Silently ignoring it would understate what is
#    waiting, and the understatement would look exactly like a quiet spool.
# ---------------------------------------------------------------------------
ODD="$WORK/odd.txt"
{
  printf 'FINDING (a, b): one real finding\n'
  printf 'UNREADABLE SPOOL RECORDS: 4 line(s) in the spool are not valid records and were skipped.\n'
} > "$ODD"
reason="$(reason_of "$("$HELPER" --instruction "$INSTRUCTION" --label "X" --findings "$ODD" 2>/dev/null)")"
[[ "$reason" == *"1 finding"* && "$reason" == *"1 other line"* ]] \
  && check "a line the helper does not recognise is counted, not dropped" ok \
  || check "a line the helper does not recognise is counted, not dropped" "[$reason]"

# ---------------------------------------------------------------------------
# 5. Extra lines. The periodic count of held-back harvest failures rides in the
#    REASON and never in the findings file, because the hook files those records
#    away and restarts their week on the strength of having reported them. If the
#    only copy were in a file nobody opened, that report would be lost and the
#    next one silenced for a week.
# ---------------------------------------------------------------------------
reason="$(reason_of "$("$HELPER" --instruction "$INSTRUCTION" --label "X" --extra "HELD BACK: 235 harvest failures with no remedy since 2026-08-24." 2>/dev/null)")"
[[ "$reason" == *"HELD BACK: 235 harvest failures with no remedy since 2026-08-24."* ]] \
  && check "an extra line is carried in the reason itself" ok \
  || check "an extra line is carried in the reason itself" "[$reason]"

# ---------------------------------------------------------------------------
# 6. A missing instruction file is LOUD. A half applied sync on the other Mac is
#    the case this covers: the hook is there and the instruction is not. Staying
#    silent would look identical to a turn with nothing to review, and emitting
#    the normal pointer would send Claude to a file that is not there.
# ---------------------------------------------------------------------------
out="$("$HELPER" --instruction "$WORK/not-there.md" --label "END OF TURN ISSUE REVIEW" 2>/dev/null)"
reason="$(reason_of "$out")"
[[ "$reason" == *"$WORK/not-there.md"* ]] \
  && check "a missing instruction file is named in the reason" ok \
  || check "a missing instruction file is named in the reason" "[$reason]"

[[ "$reason" == *"missing"* ]] \
  && check "a missing instruction file says so plainly" ok \
  || check "a missing instruction file says so plainly" "[$reason]"

[[ "$reason" == *"claude-sync pull"* ]] \
  && check "a missing instruction file names the remedy" ok \
  || check "a missing instruction file names the remedy" "[$reason]"

# It must not read as an ordinary review, or Claude would carry on inventing one.
[[ "$reason" != *"follow it exactly"* ]] \
  && check "a missing instruction file does not also issue the normal pointer" ok \
  || check "a missing instruction file does not also issue the normal pointer" "[$reason]"

# ---------------------------------------------------------------------------
# 7. Paths are JSON escaped. Dan's real project paths carry spaces, and a path
#    holding a quote or a backslash would otherwise produce a payload that does
#    not parse, which Claude Code drops with nothing in the transcript to say so.
# ---------------------------------------------------------------------------
ODDDIR="$WORK/a \"quoted\" dir"
mkdir -p "$ODDDIR"
cp "$INSTRUCTION" "$ODDDIR/i.md"
out="$("$HELPER" --instruction "$ODDDIR/i.md" --label "X" 2>/dev/null)"
reason="$(reason_of "$out")"
[[ "$reason" == *'a "quoted" dir'* ]] \
  && check "a path holding quotes survives into a payload that still parses" ok \
  || check "a path holding quotes survives into a payload that still parses" "[$reason]"

# ---------------------------------------------------------------------------
# 8. The force fail seam, so the hooks' fallback is tested rather than assumed.
#    Nothing on stdout, because a caller that printed a partial payload would
#    hand Claude Code unparseable JSON.
# ---------------------------------------------------------------------------
out="$(CLAUDE_REVIEW_REASON_FORCE_FAIL=1 "$HELPER" --instruction "$INSTRUCTION" --label "X" 2>/dev/null)"
rc=$?
[ "$rc" -ne 0 ] \
  && check "the force fail seam exits non-zero" ok \
  || check "the force fail seam exits non-zero" "it exited 0"
[ -z "$out" ] \
  && check "the force fail seam prints nothing on stdout" ok \
  || check "the force fail seam prints nothing on stdout" "it printed: [$out]"

# ---------------------------------------------------------------------------
# 9. The reason obeys the writing rule the instructions themselves enforce.
# ---------------------------------------------------------------------------
# The two characters are BUILT rather than written, because a file holding one
# literally is exactly what the pre push style hook blocks, and it cannot tell a
# line banning the character from a line using it.
emdash="$(printf '\xe2\x80\x94')"
endash="$(printf '\xe2\x80\x93')"
reason="$(reason_of "$("$HELPER" --instruction "$INSTRUCTION" --label "X" --findings "$FINDINGS" 2>/dev/null)")"
if [[ "$reason" != *"$emdash"* && "$reason" != *"$endash"* ]]; then
  check "the reason carries no em or en dash" ok
else
  check "the reason carries no em or en dash" "it does"
fi

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
