#!/usr/bin/env bash
# Tests for create-milestone.sh — run in DRY_RUN mode so no GitHub calls are made.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$DIR/create-milestone.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
check() { # check <description> <expected-substring> <actual>
  if [[ "$3" == *"$2"* ]]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL: $1"
    echo "  expected to contain: $2"
    echo "  actual: $3"
  fi
}
check_eq() { # check_eq <description> <expected> <actual>
  if [[ "$3" == "$2" ]]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL: $1 (expected '$2', got '$3')"
  fi
}

cat >"$TMP/plan.json" <<'JSON'
{
  "title": "Onboarding revamp",
  "description": "Rework first-run experience.\n\nFrom /plan-council.",
  "issues": [
    { "title": "Phase 1: empty states", "body": "Design empty states." },
    { "title": "Phase 2: tour", "body": "Build the product tour." },
    { "title": "Phase 3: telemetry", "body": "Instrument funnel." }
  ]
}
JSON

# --- happy path (dry run) ---
out="$(DRY_RUN=1 bash "$SCRIPT" "acme/widgets" "$TMP/plan.json" 2>&1)"

check "creates milestone with title" "WOULD-CREATE-MILESTONE repo=acme/widgets title=Onboarding revamp" "$out"

n_issues="$(printf '%s\n' "$out" | grep -c '^WOULD-CREATE-ISSUE')"
check_eq "creates one issue per phase" "3" "$n_issues"

check "issue carries the milestone title" "milestone=Onboarding revamp title=Phase 1: empty states" "$out"
check "last phase present" "title=Phase 3: telemetry" "$out"

# --- missing args ---
out_noargs="$(bash "$SCRIPT" 2>&1)"; rc=$?
check_eq "missing args exits non-zero" "1" "$rc"
check "missing args prints usage" "Usage:" "$out_noargs"

# --- missing title in json ---
echo '{ "issues": [] }' >"$TMP/notitle.json"
out_notitle="$(DRY_RUN=1 bash "$SCRIPT" "acme/widgets" "$TMP/notitle.json" 2>&1)"; rc=$?
check_eq "missing title exits non-zero" "1" "$rc"
check "missing title explains why" "title" "$out_notitle"

# --- zero issues is allowed (milestone only) ---
echo '{ "title": "Just a milestone", "issues": [] }' >"$TMP/noissues.json"
out_noissues="$(DRY_RUN=1 bash "$SCRIPT" "acme/widgets" "$TMP/noissues.json" 2>&1)"; rc=$?
check_eq "zero issues still succeeds" "0" "$rc"
check "milestone created even with no issues" "WOULD-CREATE-MILESTONE repo=acme/widgets title=Just a milestone" "$out_noissues"
n0="$(printf '%s\n' "$out_noissues" | grep -c '^WOULD-CREATE-ISSUE' || true)"
check_eq "no issue lines when issues empty" "0" "$n0"

echo
echo "passed: $pass, failed: $fail"
[[ "$fail" -eq 0 ]]
