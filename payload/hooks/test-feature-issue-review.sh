#!/usr/bin/env bash
# Tests for feature-issue-review.sh.
#
# The hook's whole payload is one hand-written JSON heredoc holding a 7,000
# character instruction. Two things can break it silently: an unescaped quote makes
# the JSON unparseable, so Claude Code drops the hook and the review just stops
# happening with nothing in the transcript to say so; and an edit can quietly drop a
# rule the prompt is the only carrier of. Both are invisible without this test.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/feature-issue-review.sh"

pass=0
fail=0
check() { # check <description> <condition-result>
  if [[ "$2" == "ok" ]]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL: $1 ($2)"
  fi
}

# --- the payload has to be valid JSON, or the hook silently does nothing ---
result="$(python3 - "$HOOK" <<'PY'
import json, re, sys

src = open(sys.argv[1]).read()
m = re.search(r"cat <<'JSON'\n(.*?)\nJSON", src, re.S)
if not m:
    print("no JSON heredoc found")
    sys.exit(0)
try:
    payload = json.loads(m.group(1))
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
check "the hook payload is valid JSON with a block decision and a reason" "$result"

# --- the rules the prompt is the only carrier of ---
# Each of these exists because it was got wrong in practice. A silent drop would
# bring the original problem straight back, so they are asserted individually.
reason="$(python3 - "$HOOK" <<'PY'
import json, re, sys
src = open(sys.argv[1]).read()
m = re.search(r"cat <<'JSON'\n(.*?)\nJSON", src, re.S)
try:
    print(json.loads(m.group(1)).get("reason", ""))
except Exception:
    print("")
PY
)"

needs=(
  "MILESTONE AND PRIORITY"          # both axes required on every issue
  "priority-p0"                     # the scale is spelled out, not assumed
  "priority-p2"
  "priority-p4"
  "[p2, Queue windowing]"           # the level and milestone are SHOWN in the picker
  "Ungrouped"                       # the catch-all is offered
  "NEVER create a new milestone"    # ad hoc filing does not open milestones
  "plan-council"                    # where creating one actually belongs
  "ensure-priority-labels.sh"       # how to make the labels exist
  "severity:*"                      # the retired scale is named as retired
  "NAMING.md"                       # points at the shared rule
  "AskUserQuestion"                 # the picker, not prose
  "claude-suggested"                # the forbidden attribution label
  "EVERY area label that genuinely applies"  # labels are many per issue, not one
  "STARTING POINT, not a closed set"         # the vocabulary is guidance, not a cage
  "gh label list"                            # read the repo's own labels first
  "data-integrity"                           # the area vocabulary is actually listed
)
for want in "${needs[@]}"; do
  if [[ "$reason" == *"$want"* ]]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL: the prompt should still carry '$want'"
  fi
done

# --- the prompt must obey the writing rule it enforces ---
# It tells Claude never to use dashes as punctuation, and it used 17 em dashes doing
# so. That also trips the pre-push style hook the moment this line is edited.
if [[ "$reason" != *"—"* && "$reason" != *"–"* ]]; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  echo "FAIL: the prompt contains an em or en dash, which the style rule forbids"
fi

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
[[ "$fail" -eq 0 ]]
