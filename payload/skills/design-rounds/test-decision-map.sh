#!/usr/bin/env bash
# test-decision-map.sh: check-decision-map.py refuses a settled design whose decision map leaves a
# decision with no owner, and a plan that leaves a requirement with no issue (claude-config#1290).
# Every fixture is written here, into a throwaway folder, so no design file sits in the checkout.
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$HERE/check-decision-map.py"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
pass=0; fail=0
check() { if [ "$2" = ok ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1"; echo "$2" | sed 's/^/    /'; fi; }

# design <file> <map json>: a settled design file carrying that map, as the deliverable does.
design() {
  printf '<!doctype html>\n<html><head><title>Settled</title></head><body>\n<main>the screen</main>\n<script type="application/json" id="decision-map">\n%s\n</script>\n</body></html>\n' "$2" > "$1"
}
# The output is kept in a file too, and grep reads that file: a grep -q at the end of a pipe can stop
# reading early and fail the writer under pipefail (test-pipefail-shortcircuit.sh).
run() { out="$(python3 "$CHECK" "$@" 2>&1)"; rc=$?; printf '%s\n' "$out" > "$T/out.txt"; }
said() { grep -q -- "$1" "$T/out.txt"; }

MAPPED='{"decisions": [
  {"id": "D1", "decision": "The invoice list is one column", "requirement": "6.4"},
  {"id": "D2", "decision": "Red only where something is wrong", "requirement": "6.5"},
  {"id": "D3", "decision": "The heading reads Invoices", "noCode": "Copy already in the PRD, nothing to build"}
]}'
design "$T/mapped.html" "$MAPPED"
run "$T/mapped.html"
[ "$rc" -eq 0 ] && check "a map with every decision owned passes" ok || check "a map with every decision owned passes" "rc=$rc $out"

# 1. The fixture the issue names: one decision with neither a requirement nor a reason.
design "$T/unmapped.html" '{"decisions": [
  {"id": "D1", "decision": "The invoice list is one column", "requirement": "6.4"},
  {"id": "D2", "decision": "The empty state shows last month", "requirement": ""},
  {"id": "D3", "decision": "The heading reads Invoices", "noCode": "Copy only"}
]}'
run "$T/unmapped.html"
[ "$rc" -eq 1 ] && check "a decision with no owner is refused (exit 1)" ok || check "a decision with no owner is refused (exit 1)" "rc=$rc $out"
said '^UNMAPPED D2: The empty state shows last month$' && check "the refusal names the unmapped decision" ok \
  || check "the refusal names the unmapped decision" "$out"
[ "$(grep -c '^[A-Z-]* D[0-9]' "$T/out.txt")" = 1 ] && check "and only that one" ok || check "and only that one" "$out"

# 2. A reason that is empty is no reason, and a decision cannot be both owned and code free.
design "$T/empty-reason.html" '{"decisions": [{"id": "D1", "decision": "Dense rows", "noCode": "  "}]}'
run "$T/empty-reason.html"
[ "$rc" -eq 1 ] && check "an empty no code reason is refused" ok || check "an empty no code reason is refused" "rc=$rc $out"
design "$T/both.html" '{"decisions": [{"id": "D1", "decision": "Dense rows", "requirement": "6.1", "noCode": "none"}]}'
run "$T/both.html"
[ "$rc" -eq 1 ] && said '^AMBIGUOUS D1' && check "a decision both owned and code free is refused" ok \
  || check "a decision both owned and code free is refused" "rc=$rc $out"

# 3. Two decisions under one id would let one owner stand for both.
design "$T/dup.html" '{"decisions": [{"id": "D1", "decision": "A", "requirement": "6.1"}, {"id": "D1", "decision": "B", "requirement": "6.2"}]}'
run "$T/dup.html"
[ "$rc" -eq 1 ] && said '^DUPLICATE D1' && check "a repeated decision id is refused" ok || check "a repeated decision id is refused" "rc=$rc $out"

# A decision with no words cannot be checked against what was built, owner or not.
design "$T/unstated.html" '{"decisions": [{"id": "D1", "decision": " ", "requirement": "6.1"}]}'
run "$T/unstated.html"
[ "$rc" -eq 1 ] && said '^UNSTATED D1' && check "a decision with no text is refused" ok || check "a decision with no text is refused" "rc=$rc $out"

# An owner given as a number is said to be mistyped, not reported as missing (lessons review).
design "$T/numeric.html" '{"decisions": [{"id": "D1", "decision": "Dense rows", "requirement": 6.4}]}'
run "$T/numeric.html"
[ "$rc" -eq 1 ] && said '^MISTYPED D1: Dense rows (its requirement was read as the number 6.4; write it as text in quotes, exactly as the PRD numbers it)$' \
  && check "a requirement written as a number is named as mistyped" ok || check "a requirement written as a number is named as mistyped" "rc=$rc $out"
said '^UNMAPPED' && check "and is not reported as unmapped" "$out" || check "and is not reported as unmapped" ok

# 4. A map that cannot be read is exit 2, never a pass (L98, L11).
printf '<html><body>no map here</body></html>\n' > "$T/nomap.html"
run "$T/nomap.html"
[ "$rc" -eq 2 ] && check "a design with no decision map is unreadable (exit 2)" ok || check "a design with no decision map is unreadable (exit 2)" "rc=$rc $out"
design "$T/badjson.html" '{"decisions": [ nope ]}'
run "$T/badjson.html"
[ "$rc" -eq 2 ] && check "a map that is not JSON is unreadable" ok || check "a map that is not JSON is unreadable" "rc=$rc $out"
design "$T/empty.html" '{"decisions": []}'
run "$T/empty.html"
[ "$rc" -eq 2 ] && check "a map with no decisions is unreadable, not a pass" ok || check "a map with no decisions is unreadable, not a pass" "rc=$rc $out"
run "$T/missing.html"
[ "$rc" -eq 2 ] && check "a design file that is not there is unreadable" ok || check "a design file that is not there is unreadable" "rc=$rc $out"
{ cat "$T/mapped.html"; printf '<script type="application/json" id="decision-map">{"decisions": []}</script>\n'; } > "$T/twomaps.html"
run "$T/twomaps.html"
[ "$rc" -eq 2 ] && check "a design with two maps is unreadable" ok || check "a design with two maps is unreadable" "rc=$rc $out"

# 5. With a plan: every requirement the map names needs an issue naming it as Requirement <id>.
cat > "$T/plan-ok.json" <<'EOF'
{"title": "Invoices screen", "issues": [
  {"title": "Phase 1: the list", "body": "Builds Requirement 6.4."},
  {"title": "Phase 2: Requirement 6.5, colour", "body": "Red is reserved."}
]}
EOF
run "$T/mapped.html" "$T/plan-ok.json"
[ "$rc" -eq 0 ] && check "a plan naming every requirement passes" ok || check "a plan naming every requirement passes" "rc=$rc $out"
cat > "$T/plan-gap.json" <<'EOF'
{"title": "Invoices screen", "issues": [
  {"title": "Phase 1: the list", "body": "Builds Requirement 6.41 and requirements 6.5."}
]}
EOF
run "$T/mapped.html" "$T/plan-gap.json"
[ "$rc" -eq 1 ] && check "a requirement no issue names is refused" ok || check "a requirement no issue names is refused" "rc=$rc $out"
said '^NO-ISSUE Requirement 6.4 (D1)$' && check "the refusal names the requirement and the decisions it owns" ok \
  || check "the refusal names the requirement and the decisions it owns" "$out"
said 'NO-ISSUE Requirement 6.5' && check "a requirement named in another spelling is not counted as named" ok \
  || check "a requirement named in another spelling is not counted as named" "$out"
# The unmapped decision is refused before any issue is looked at, and both are reported together.
run "$T/unmapped.html" "$T/plan-ok.json"
[ "$rc" -eq 1 ] && said '^UNMAPPED D2' && check "an unmapped decision is refused with a plan too" ok \
  || check "an unmapped decision is refused with a plan too" "rc=$rc $out"
printf '{"title": "x", "issues": [ nope ' > "$T/plan-bad.json"
run "$T/mapped.html" "$T/plan-bad.json"
[ "$rc" -eq 2 ] && check "a plan that is not JSON is unreadable" ok || check "a plan that is not JSON is unreadable" "rc=$rc $out"

echo
echo "passed: $pass, failed: $fail"
# The runner parses this exact shape, so nothing else goes on this line.
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
