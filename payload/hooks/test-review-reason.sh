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

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

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
# And SEVERAL are all carried. The review passes the held back count and a seen ledger it could not
# keep (#1019 follow-up) as two --extra lines, and one replacing the other would lose the held back
# report while the hook files those records away as reported.
reason="$(reason_of "$("$HELPER" --instruction "$INSTRUCTION" --label "X" --extra "FIRST EXTRA held back count" --extra "SECOND EXTRA could not keep 1 seen ledger" 2>/dev/null)")"
[[ "$reason" == *"FIRST EXTRA held back count"* && "$reason" == *"SECOND EXTRA could not keep 1 seen ledger"* ]] \
  && check "two extra lines are both carried in the reason" ok \
  || check "two extra lines are both carried in the reason" "[$reason]"

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

# ---------------------------------------------------------------------------
# 10. READ ONCE PER SESSION. Each fire used to send Claude back to cat the whole
#     instruction, and that text was then re-read by every later request: the reads
#     of the two instruction files were 0.93% of every token read in Slate
#     sessions, Oct 1 to 15 2026. Given --transcript, the helper sends the full
#     "read it now" pointer only when this session has not read the file since its
#     last compaction (or the file changed after that read), and otherwise a short
#     pointer at the copy already in context. Every way of failing to tell falls
#     toward the full pointer, because a review run from a copy that is not there is
#     the worse failure.
# ---------------------------------------------------------------------------
T="$WORK/transcript.jsonl"
tool_line() { # tool_line <timestamp> <tool name> <input json>
  python3 -c '
import json, sys
print(json.dumps({"type": "assistant", "timestamp": sys.argv[1],
  "message": {"role": "assistant", "content": [{"type": "tool_use", "id": "t", "name": sys.argv[2], "input": json.loads(sys.argv[3])}]}},
  ensure_ascii=False))  # as Claude Code writes its transcript: characters, not escapes
' "$1" "$2" "$3"
}
read_line() { tool_line "$1" Read "$(python3 -c 'import json,sys; print(json.dumps({"file_path": sys.argv[1]}))' "$INSTRUCTION")"; }
cat_line() { tool_line "$1" Bash "$(python3 -c 'import json,sys; print(json.dumps({"command": "cat " + sys.argv[1] + "; echo done"}))' "$INSTRUCTION")"; }
boundary_line='{"type":"system","subtype":"compact_boundary","content":"Conversation compacted","timestamp":"2099-01-02T00:00:00.000Z"}'
user_line='{"type":"user","message":{"role":"user","content":"do the thing"}}'
FUTURE="2099-01-01T00:00:00.000Z"   # after the fixture's mtime, so the read is of the current file
PAST="2000-01-01T00:00:00.000Z"     # before it, so the file has changed since that read

reason_with() { reason_of "$("$HELPER" --instruction "$INSTRUCTION" --label "SESSION REFLECTION" --transcript "$T" 2>/dev/null)"; }
is_full() { [[ "$1" == *"Read $INSTRUCTION now"* ]]; }
is_repeat() { [[ "$1" == *"Follow $INSTRUCTION again"* && "$1" != *"Read $INSTRUCTION now"* ]]; }

printf '%s\n' "$user_line" > "$T"
r="$(reason_with)"
is_full "$r" && check "no read in the transcript: the full pointer" ok \
  || check "no read in the transcript: the full pointer" "[$r]"

{ printf '%s\n' "$user_line"; read_line "$FUTURE"; } > "$T"
r="$(reason_with)"
is_repeat "$r" && check "a Read of the file this session: the short repeat pointer" ok \
  || check "a Read of the file this session: the short repeat pointer" "[$r]"
[[ "$r" == *"$INSTRUCTION"* ]] && check "the repeat pointer still names the file" ok \
  || check "the repeat pointer still names the file" "[$r]"
[ "$(( ${#r} - ${#INSTRUCTION} ))" -le 130 ] && check "the repeat pointer is short (<= 130 characters besides the path)" ok \
  || check "the repeat pointer is short (<= 130 characters besides the path)" "it is ${#r} with a ${#INSTRUCTION} character path"

{ printf '%s\n' "$user_line"; cat_line "$FUTURE"; } > "$T"
r="$(reason_with)"
is_repeat "$r" && check "a cat of the file in a Bash call counts as a read" ok \
  || check "a cat of the file in a Bash call counts as a read" "[$r]"

{ printf '%s\n' "$user_line"; read_line "$FUTURE"; printf '%s\n' "$boundary_line"; } > "$T"
r="$(reason_with)"
is_full "$r" && check "a read before a compaction does not count: the full pointer again" ok \
  || check "a read before a compaction does not count: the full pointer again" "[$r]"

{ printf '%s\n' "$user_line"; read_line "$FUTURE"; printf '%s\n' "$boundary_line"; cat_line "$FUTURE"; } > "$T"
r="$(reason_with)"
is_repeat "$r" && check "a read after the compaction counts again" ok \
  || check "a read after the compaction counts again" "[$r]"

# Naming the file is not reading it: a listing, a count, an existence test or an edit leaves the
# text out of context, so each of those still gets the full pointer.
for cmd in "ls -l PATH" "grep -c rule PATH" "test -f PATH && echo yes" "git diff -- PATH"; do
  { printf '%s\n' "$user_line"; tool_line "$FUTURE" Bash "$(python3 -c 'import json,sys; print(json.dumps({"command": sys.argv[1].replace("PATH", sys.argv[2])}))' "$cmd" "$INSTRUCTION")"; } > "$T"
  r="$(reason_with)"
  is_full "$r" && check "a Bash call that only names the file ($cmd) is not a read" ok \
    || check "a Bash call that only names the file ($cmd) is not a read" "[$r]"
done
{ printf '%s\n' "$user_line"; tool_line "$FUTURE" Edit "$(python3 -c 'import json,sys; print(json.dumps({"file_path": sys.argv[1], "old_string": "a", "new_string": "b"}))' "$INSTRUCTION")"; } > "$T"
r="$(reason_with)"
is_full "$r" && check "an Edit of the file is not a read of it" ok || check "an Edit of the file is not a read of it" "[$r]"
# A PARTIAL read is not a read of the instruction (lessons review of #1228): the short pointer says
# "you read it earlier", and after a Read of a slice or a head of the file most of it never was.
# Only a whole file Read (no offset, no limit) or a whole file print counts.
read_with() { # read_with <extra Read input as JSON>: a Read of the instruction carrying those keys
  tool_line "$FUTURE" Read "$(python3 -c 'import json,sys; d={"file_path": sys.argv[1]}; d.update(json.loads(sys.argv[2])); print(json.dumps(d))' "$INSTRUCTION" "$1")"
}
for extra in '{"offset": 40}' '{"limit": 20}' '{"offset": 1, "limit": 2000}'; do
  { printf '%s\n' "$user_line"; read_with "$extra"; } > "$T"
  r="$(reason_with)"
  is_full "$r" && check "a Read with $extra is a partial read, not a read" ok \
    || check "a Read with $extra is a partial read, not a read" "[$r]"
done
{ printf '%s\n' "$user_line"; read_with '{"offset": null, "limit": null}'; } > "$T"
r="$(reason_with)"
is_repeat "$r" && check "a Read whose offset and limit are null is a whole file read" ok \
  || check "a Read whose offset and limit are null is a whole file read" "[$r]"
# FIRST is spelled as a placeholder and swapped for the command name when the line is built, so this
# file holds no literal pipeline into it for the short circuit scan to count (it is a fixture string).
for cmd in "cat PATH | FIRST -n 5" "cat PATH | grep -n rule" "cat > PATH <<EOF" "cat >> PATH" "head -n 40 PATH" "head PATH" "tail -n 20 PATH" "sed -n 1,5p PATH" "sed -n 1,400p PATH | cat" "sed 5q PATH" "awk 'NR<10' PATH" "bat -r 1:20 PATH"; do
  { printf '%s\n' "$user_line"; tool_line "$FUTURE" Bash "$(python3 -c 'import json,sys; print(json.dumps({"command": sys.argv[1].replace("PATH", sys.argv[2]).replace("FIRST", "he" + "ad")}))' "$cmd" "$INSTRUCTION")"; } > "$T"
  r="$(reason_with)"
  is_full "$r" && check "a partial print ($cmd) is not a read" ok \
    || check "a partial print ($cmd) is not a read" "[$r]"
done
for cmd in "cat PATH" "cat -n PATH" "sed -n p PATH" "sed '' PATH" "awk 1 PATH" "awk '{print}' PATH" "bat PATH" "cat PATH; echo ======; cat /tmp/other.txt" "cat PATH | cat" "cat PATH 2>&1"; do
  { printf '%s\n' "$user_line"; tool_line "$FUTURE" Bash "$(python3 -c 'import json,sys; print(json.dumps({"command": sys.argv[1].replace("PATH", sys.argv[2])}))' "$cmd" "$INSTRUCTION")"; } > "$T"
  r="$(reason_with)"
  is_repeat "$r" && check "a whole file print ($cmd) counts as a read" ok \
    || check "a whole file print ($cmd) counts as a read" "[$r]"
done

{ printf '%s\n' "$user_line"; read_line "$PAST"; } > "$T"
r="$(reason_with)"
is_full "$r" && check "a file changed since it was read: the full pointer" ok \
  || check "a file changed since it was read: the full pointer" "[$r]"

{ printf '%s\n' "$user_line"; tool_line "$FUTURE" Read "$(python3 -c 'import json,sys; print(json.dumps({"file_path": sys.argv[1] + ".bak"}))' "$INSTRUCTION")"; } > "$T"
r="$(reason_with)"
is_full "$r" && check "a read of a different file whose name starts the same does not count" ok \
  || check "a read of a different file whose name starts the same does not count" "[$r]"

{ printf '%s\n' "$user_line"; tool_line "not a time" Read "$(python3 -c 'import json,sys; print(json.dumps({"file_path": sys.argv[1]}))' "$INSTRUCTION")"; } > "$T"
r="$(reason_with)"
is_full "$r" && check "a read with an unreadable timestamp falls toward the full pointer" ok \
  || check "a read with an unreadable timestamp falls toward the full pointer" "[$r]"

# A path holding a character outside ASCII, like the curly apostrophe in Dan’s project folders, is
# written into the transcript as the character itself and must still be recognised as a read.
ODD_DIR="$WORK/Dan’s config"; mkdir -p "$ODD_DIR"; ODD="$ODD_DIR/issue-review.md"; cp "$INSTRUCTION" "$ODD"
{ printf '%s\n' "$user_line"; tool_line "$FUTURE" Read "$(python3 -c 'import json,sys; print(json.dumps({"file_path": sys.argv[1]}, ensure_ascii=False))' "$ODD")"; } > "$T"
r="$(reason_of "$("$HELPER" --instruction "$ODD" --label "SESSION REFLECTION" --transcript "$T" 2>/dev/null)")"
[[ "$r" == *"Follow $ODD again"* ]] && check "a read of a path with a non ASCII character counts" ok \
  || check "a read of a path with a non ASCII character counts" "[$r]"

r="$(reason_of "$("$HELPER" --instruction "$INSTRUCTION" --label "SESSION REFLECTION" --transcript "$WORK/no-such-transcript.jsonl" 2>/dev/null)")"
is_full "$r" && check "an unreadable transcript falls toward the full pointer" ok \
  || check "an unreadable transcript falls toward the full pointer" "[$r]"

r="$(reason_of "$("$HELPER" --instruction "$INSTRUCTION" --label "SESSION REFLECTION" 2>/dev/null)")"
is_full "$r" && check "no transcript given: the full pointer" ok \
  || check "no transcript given: the full pointer" "[$r]"
[ "$(( ${#r} - ${#INSTRUCTION} ))" -le 110 ] && check "the full pointer itself is short (<= 110 characters besides the path)" ok \
  || check "the full pointer itself is short (<= 110 characters besides the path)" "it is ${#r} with a ${#INSTRUCTION} character path"

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
