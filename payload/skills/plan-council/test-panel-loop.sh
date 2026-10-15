#!/usr/bin/env bash
# Tests for plan-council's check loop (claude-config#1208), by RUNNING panel.workflow.js with every
# agent stood in (panel-loop.harness.cjs), not by grepping its text. Every run since 2026-09-21 ended
# with problems open, because each round sampled afresh and nothing asked whether a given finding
# was fixed. The loop now keeps the findings by id, closes one only on a verifier's verdict about it,
# has the fix edit items rather than rewrite the plan, and re-checks only what an edit could change.
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WF="${PANEL_WORKFLOW:-$DIR/panel.workflow.js}"
H="$DIR/panel-loop.harness.cjs"
pass=0; fail=0
if ! command -v node >/dev/null 2>&1; then
  echo "FAIL: node is missing, so the loop could not be run"
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
fi

# expect <scenario> <description> <python expression over r (result), calls, logs>
expect() {
  local scen="$1" what="$2" expr="$3" out
  out="$(node "$H" "$WF" "$scen" 2>&1)"
  if python3 -c '
import json, sys
d = json.loads(sys.argv[1]); r, calls, logs = d["result"], d["calls"], d["logs"]
labels = [c["label"] for c in calls]
prompt = lambda lab: next((c["prompt"] for c in calls if c["label"] == lab), "")
sys.exit(0 if eval(sys.argv[2]) else 1)
' "$out" "$expr" 2>/dev/null; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1)); echo "FAIL: [$scen] $what"; echo "  expr: $expr"; echo "  out: ${out:0:600}"
  fi
}

# Converges as soon as every blocking finding is verified fixed, after one round.
expect converges "a blocking finding verified fixed ends the run clean" "r['checks']['stoppedAt'] == 'clean' and r['checks']['converged'] is True"
expect converges "after exactly one fix round" "r['checks']['rounds'] == 1 and 'fix:2' not in labels"
expect converges "the fix's edit is in the returned plan" "'The real route reads the Phase 1 table.' in r['plan']['plan']"
expect converges "the verifier is asked about the finding by its id" "'F1' in prompt('verify:1')"
expect converges "the plan's size is reported per round" "len(r['checks']['sizes']) == 2"

# Never confirmed: stops at the ceiling of 3 rounds, with the finding named as open.
expect ceiling "a finding never verified fixed stops the run at the ceiling" "r['checks']['stoppedAt'] == 'ceiling' and r['checks']['converged'] is False"
expect ceiling "after 3 rounds and no more" "r['checks']['rounds'] == 3 and 'fix:4' not in labels"
expect ceiling "with the open finding listed" "[f['id'] for f in r['checks']['open']] == ['F1']"

# Advisory findings never hold the loop, and are handed to Dan.
expect advisory "an advisory finding alone runs no fix round" "not any(l.startswith('fix:') for l in labels)"
expect advisory "and is listed for Dan" "[f['lessonId'] for f in r['checks']['advisory']] == ['L36']"
expect advisory "and the run is clean" "r['checks']['stoppedAt'] == 'clean'"

# A verifier that answers for no finding leaves it open; nothing is assumed fixed.
expect verifier-omits "a finding the verifier skipped stays open to the ceiling" "r['checks']['stoppedAt'] == 'ceiling' and [f['id'] for f in r['checks']['open']] == ['F1']"
expect verifier-omits "and the skipped verdict is logged" "any('did not answer for F1' in l for l in logs)"

# Only an edited item and items naming it are checked again; an untouched one is byte identical.
expect references "the item naming the edited one is re-checked" "'## Phase 2 api' in prompt('recheck:1').split('ITEMS TO CHECK')[-1]"
expect references "an item naming nothing edited is not" "'## Phase 3 ui' not in prompt('recheck:1').split('ITEMS TO CHECK')[-1]"
expect references "unedited items are byte identical in the returned plan" "r['plan']['plan'].endswith('## Phase 2 api\nThe route reads the Phase 1 table.\n\n## Phase 3 ui\nShow the count.\n')"

# A finding the whole plan pass raises reopens the loop, and its fix gets a whole plan pass too.
expect consistency-reopens "a finding from the whole plan pass runs another fix round" "'fix:2' in labels"
expect consistency-reopens "and that fix is followed by another whole plan pass" "'consistency:2' in labels and r['checks']['stoppedAt'] == 'clean'"

# A declined finding is Dan's: the run is settled with dissent, never clean, and it is not re-raised.
expect declined "a declined finding ends the run settled with dissent" "r['checks']['stoppedAt'] == 'settled-with-dissent' and r['checks']['converged'] is False"
expect declined "with the decline and its reason returned" "[(d['id'], d['reason']) for d in r['checks']['declined']] == [('F1', 'the table is empty by construction')]"
expect declined "and the finding is not handed to the verifier as open" "not any(l.startswith('verify:') and 'F1' in c['prompt'] for l, c in zip(labels, calls))"

# overruledDissent from the debate survives the fix rounds (it used to be re-emitted, and lost).
expect converges "the debate's overruled dissent survives a fix round" "r['plan']['overruledDissent'] == ['kept from the debate']"

# A check that never ran is never a clean run.
expect dead-check "a dead reality-check leaves the run unverified, never clean" "r['checks']['converged'] is False and r['checks']['stoppedAt'] != 'clean' and any('reality' in u for u in r['checks']['unverified'])"
expect unaudited "an audit that skipped an index file leaves the run unaudited, never clean" "r['checks']['converged'] is False and any('lessons' in u for u in r['checks']['unverified'])"

# Revise mode runs the same loop.
expect revise "revise mode converges through the same loop" "r['mode'] == 'revise' and r['checks']['stoppedAt'] == 'clean' and r['checks']['rounds'] == 1"
expect revise "with the fix in the revised plan" "'The real route reads the Phase 1 table.' in r['revised']['plan']"

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
