#!/usr/bin/env bash
# Tests for feature-issue-review.sh and the instruction it now points at.
#
# The 8,000 character instruction used to live inside this hook as a JSON heredoc.
# It moved to review/issue-review.md (claude-config#243) because a Stop hook's
# `reason` is printed to Dan verbatim, so everything addressed to Claude was landing
# on his screen. The rules did not change; where they live did.
#
# What has to be checked did not change either. The instruction is the ONLY carrier
# of a set of rules that were each got wrong in practice, and a silent drop brings
# the original problem straight back, so each is asserted individually. The JSON
# parse check moved with them: the hook still holds one hand written JSON payload,
# the fallback it emits when the pointer cannot be built, and an unescaped quote
# there makes Claude Code drop the hook with nothing in the transcript to say so.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/feature-issue-review.sh"
INSTRUCTION="$DIR/review/issue-review.md"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/claude-issue-review.XXXXXX")" || exit 2
case "${WORK%/}" in
  ''|/|"${HOME%/}") echo "refusing to run: throwaway directory came back as '$WORK'." >&2; exit 2 ;;
esac
WORK="$(cd "$WORK" && pwd)"
trap 'rm -rf "$WORK"' EXIT

# Pinned to a throwaway spool, so this suite is structurally unable to write into
# the real one (L2). A sibling suite did exactly that 120 times before it was noticed.
export CLAUDE_ISSUE_SPOOL_DIR="$WORK/spool"
mkdir -p "$CLAUDE_ISSUE_SPOOL_DIR"

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

# --- the instruction file has to exist, or the review points at nothing ---
[ -f "$INSTRUCTION" ] \
  && check "the instruction file exists" ok \
  || check "the instruction file exists" "nothing at $INSTRUCTION"

instruction="$(cat "$INSTRUCTION" 2>/dev/null)"

# --- the rules the instruction is the only carrier of ---
# Each of these exists because it was got wrong in practice.
needs=(
  "MILESTONE AND PRIORITY"          # both axes required on every issue
  "priority-p0"                     # the scale is spelled out, not assumed
  "priority-p2"
  "priority-p4"
  "[p2, tech-debt, NEW Backlog grouping, moves #241 #242]"  # a new milestone is SHOWN as new, with what it moves
  "Ungrouped"                       # the catch-all is still offered
  "milestone-candidates.sh"         # the backlog is READ before a milestone is chosen
  "SIBLING-COUNT"                   # and the sibling count is what the 2 or more rule counts
  "2 OR MORE issues would go into it at once"  # the bar for opening a new milestone
  "--create-approved"               # which only happens after Dan selects it
  "gh issue edit"                   # and the siblings actually get moved
  "plan-council"                    # planning a feature still belongs there
  "ensure-priority-labels.sh"       # how to make the labels exist
  "severity:*"                      # the retired scale is named as retired
  "NAMING.md"                       # points at the shared rule
  "AskUserQuestion"                 # the picker, not prose
  "claude-suggested"                # the forbidden attribution label
  "EVERY area label that genuinely applies"  # labels are many per issue, not one
  "STARTING POINT, not a closed set"         # the vocabulary is guidance, not a cage
  "gh label list"                            # read the repo's own labels first
  "data-integrity"                           # the area vocabulary is actually listed
  "ISSUE REVIEW"                             # the banner it has to open with
  "SECOND PASS"                              # the reflection folds in here
)
# --- and the wording it must NOT carry any more ---------------------------
# The rule that ad hoc filing may never open a milestone was REVERSED on 2026-09-02,
# after Dan opened his list and found Ungrouped holding 98 issues in this repo, 157
# in bidspoke and 102 in new-agent-onboarding, with obvious clusters inside them. The
# assertion that used to guard the old rule is deleted rather than adjusted: its whole
# content was the decision being reversed, so keeping it in any form would leave a
# test defending the behaviour that was removed (L252).
#
# These two are the wording that CAUSED the pile-up. The ban itself, and the sentence
# that primed every idea toward the holding pen before it had even been looked at.
forbidden=(
  "NEVER create a new milestone"
  "Most of these ideas are standalone fixes"
  "there is no third option"
)
for gone in "${forbidden[@]}"; do
  if [[ "$instruction" != *"$gone"* ]]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL: the instruction should no longer carry '$gone'"
  fi
done

for want in "${needs[@]}"; do
  if [[ "$instruction" == *"$want"* ]]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL: the instruction should still carry '$want'"
  fi
done

# --- the instruction must obey the writing rule it enforces ---
# It tells Claude never to use dashes as punctuation, and it once used 17 em dashes
# doing so. A rule contradicted by the prose around it loses to the demonstration
# (L270). The characters are BUILT rather than written, because a file holding one
# literally is what the pre push style hook blocks, and it cannot tell a line banning
# the character from a line using it.
emdash="$(printf '\xe2\x80\x94')"
endash="$(printf '\xe2\x80\x93')"
if [[ "$instruction" != *"$emdash"* && "$instruction" != *"$endash"* ]]; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  echo "FAIL: the instruction contains an em or en dash, which the style rule forbids"
fi

# --- the hook's fallback payload has to be valid JSON ---
# It is the one hand written JSON left in the hook. An unescaped quote there is
# invisible: Claude Code drops the hook and the review simply stops happening.
result="$(python3 - "$HOOK" <<'PY'
import json, re, sys

src = open(sys.argv[1]).read()
blocks = re.findall(r"cat <<'JSON'\n(.*?)\nJSON", src, re.S)
if not blocks:
    print("no JSON heredoc found, so the fallback payload is missing")
    sys.exit(0)
for block in blocks:
    try:
        payload = json.loads(block)
    except Exception as exc:
        print("JSON does not parse: %s" % exc)
        sys.exit(0)
    if payload.get("decision") != "block":
        print("decision should be 'block', got %r" % payload.get("decision"))
        sys.exit(0)
    if not (payload.get("reason") or "").strip():
        print("reason is empty")
        sys.exit(0)
print("ok")
PY
)"
check "the hook's fallback payload is valid JSON with a block decision and a reason" "$result"

# ---------------------------------------------------------------------------
# The spool wiring: what the review does with findings that are waiting.
# ---------------------------------------------------------------------------
TRANSCRIPT="$WORK/transcript.jsonl"
{
  printf '%s\n' '{"type":"user","message":{"role":"user","content":"do the thing"}}'
  printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Edit","id":"t1","input":{}}]}}'
  printf '%s\n' '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}'
} > "$TRANSCRIPT"

run_review() { # run_review <project dir>
  printf '{"transcript_path":"%s","stop_hook_active":false}' "$TRANSCRIPT" | \
    CLAUDE_PROJECT_DIR="$1" bash "$HOOK"
}
reason_of() {
  printf '%s' "$1" | python3 -c '
import json, sys
raw = sys.stdin.read()
if not raw.strip():
    print("NO PAYLOAD AT ALL")
    sys.exit(0)
try:
    print(json.loads(raw).get("reason") or "")
except Exception as exc:
    print("PAYLOAD DOES NOT PARSE: %s" % exc)
'
}

# An EMPTY spool must not produce a findings pointer. A reason that always names a
# file leaves Claude opening a stale one, and a stale findings file reads exactly
# like findings that are still waiting.
EMPTY_PROJ="$(mktemp -d "$WORK/empty.XXXXXX")"
reason="$(reason_of "$(run_review "$EMPTY_PROJ")")"
[[ "$reason" != *"SUBAGENT FINDINGS"* ]] \
  && check "an empty spool produces no findings pointer" ok \
  || check "an empty spool produces no findings pointer" "[$reason]"

# A spool holding a finding must produce a pointer at a file that HOLDS that
# finding. Checked by reading the file the reason names, not by trusting that one
# was written: a pointer at an empty or missing file is the failure worth catching.
FIND_PROJ="$(mktemp -d "$WORK/withfindings.XXXXXX")"
MARKER="the widget cache is never invalidated on rename"
bash "$DIR/lib/issue-spool.sh" note "$FIND_PROJ" "$MARKER" "test-suite" "$TRANSCRIPT" >/dev/null 2>&1
reason="$(reason_of "$(run_review "$FIND_PROJ")")"

[[ "$reason" == *"SUBAGENT FINDINGS"* ]] \
  && check "a pending finding produces a findings pointer" ok \
  || check "a pending finding produces a findings pointer" "[$reason]"

[[ "$reason" == *"1 finding"* ]] \
  && check "the pointer counts the one pending finding" ok \
  || check "the pointer counts the one pending finding" "[$reason]"

named="$(printf '%s' "$reason" | python3 -c '
import re, sys
m = re.search(r"waiting in (\S+?)\. They", sys.stdin.read())
print(m.group(1) if m else "")
')"
[ -s "$named" ] \
  && check "the findings file the pointer names exists and is not empty" ok \
  || check "the findings file the pointer names exists and is not empty" "nothing at [$named]"

grep -qF "$MARKER" "$named" 2>/dev/null \
  && check "the findings file holds the finding that was spooled" ok \
  || check "the findings file holds the finding that was spooled" "[$named] does not contain it"

# The finding must SURVIVE the review. Reading does not consume the spool: a review
# that is read and then interrupted has to leave the finding for the next one, and
# only `clear` (after the picker is answered) files it away.
bash "$DIR/lib/issue-spool.sh" has-findings "$FIND_PROJ" "$TRANSCRIPT" >/dev/null 2>&1 \
  && check "the finding is still pending after the review carried it" ok \
  || check "the finding is still pending after the review carried it" "the spool no longer holds it"

# --- the hook stays quiet when nothing happened ---
# It fires on Stop, so a chat-only turn must not trigger a review. An absent
# transcript is the cheapest stand-in for "nothing to review".
out="$(printf '{"transcript_path":"/nonexistent/path.jsonl"}' | bash "$HOOK" 2>/dev/null)"
if [[ -z "$out" ]]; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  echo "FAIL: a missing transcript should produce no output, got: $out"
fi

# --- the hook is syntactically valid shell ---
if bash -n "$HOOK" 2>/dev/null; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  echo "FAIL: the hook is not valid bash"
fi

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
