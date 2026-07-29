#!/usr/bin/env bash
# Tests for ensure-milestone.sh.
#
# A fake gh on PATH stands in for GitHub, so these tests cannot reach the network
# or touch a real repository. The fake records every call, which lets the tests
# assert that nothing was created on the paths where creating is forbidden.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$DIR/ensure-milestone.sh"
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
check_not() { # check_not <description> <forbidden-substring> <actual>
  if [[ "$3" != *"$2"* ]]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL: $1 (output should not contain '$2')"
    echo "  actual: $3"
  fi
}

# --- the fake gh ---
mkdir -p "$TMP/bin"
cat >"$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
# Records the call, then answers from fixtures the test controls.
printf '%s\n' "$*" >>"$GH_CALLS"
if [ -n "${GH_FAIL:-}" ]; then
  echo "gh: simulated API failure" >&2
  exit 1
fi
for a in "$@"; do
  if [ "$a" = "-f" ] || [ "$a" = "--method" ]; then
    cat "$GH_CREATED"
    exit 0
  fi
done
cat "$GH_FIXTURE"
exit 0
STUB
chmod +x "$TMP/bin/gh"

cat >"$TMP/milestones.json" <<'JSON'
[
  { "number": 3, "title": "Onboarding revamp", "state": "open",   "html_url": "https://github.com/acme/widgets/milestone/3" },
  { "number": 4, "title": "Payments hardening", "state": "open",   "html_url": "https://github.com/acme/widgets/milestone/4" },
  { "number": 1, "title": "Legacy cleanup",     "state": "closed", "html_url": "https://github.com/acme/widgets/milestone/1" }
]
JSON

cat >"$TMP/created.json" <<'JSON'
{ "number": 9, "title": "Search relevance", "state": "open", "html_url": "https://github.com/acme/widgets/milestone/9" }
JSON

export GH_FIXTURE="$TMP/milestones.json"
export GH_CREATED="$TMP/created.json"

# ensure <args...> : runs the script with the fake gh, fresh call log each time
ensure() {
  export GH_CALLS="$TMP/calls.log"
  : >"$GH_CALLS"
  PATH="$TMP/bin:$PATH" bash "$SCRIPT" "$@" 2>&1
}
# grep -c already prints 0 when it matches nothing, so no fallback (a fallback
# here printed "0\n0" and made every no-create assertion fail).
created_count() { grep -c -- ' -f ' "$TMP/calls.log" 2>/dev/null; }

# --- 1. an exact open title is reused, never recreated ---
out="$(ensure acme/widgets "Onboarding revamp")"; rc=$?
check_eq "exact match exits 0" "0" "$rc"
check "exact match reports reuse" "MILESTONE-EXISTS 3 Onboarding revamp" "$out"
check_eq "exact match creates nothing" "0" "$(created_count)"

# --- 2. a case or punctuation variant is the same milestone, so reuse it ---
out="$(ensure acme/widgets "onboarding revamp")"; rc=$?
check_eq "lowercase variant exits 0" "0" "$rc"
check "lowercase variant reuses number 3" "MILESTONE-EXISTS 3" "$out"
check_eq "lowercase variant creates nothing" "0" "$(created_count)"

out="$(ensure acme/widgets "Onboarding Revamp!")"; rc=$?
check_eq "punctuation variant exits 0" "0" "$rc"
check "punctuation variant reuses number 3" "MILESTONE-EXISTS 3" "$out"

# gh issue create matches a milestone BY NAME, so callers need the milestone's own
# exact title, not the variant that was asked for, or the issue create fails.
out="$(ensure acme/widgets "onboarding revamp")"
check "reuse reports the milestone's real title" "MILESTONE-TITLE Onboarding revamp" "$out"
out="$(ensure acme/widgets "Search relevance" --create-approved)"
check "create reports the milestone's real title" "MILESTONE-TITLE Search relevance" "$out"

# --- 3. a near duplicate stops and asks instead of creating a twin ---
out="$(ensure acme/widgets "Onboarding revamp v2" --create-approved)"; rc=$?
check_eq "near duplicate exits 4" "4" "$rc"
check "near duplicate is named as such" "NEAR-DUPLICATE" "$out"
check "near duplicate names the candidate" "Onboarding revamp" "$out"
check_eq "near duplicate creates nothing even when approved" "0" "$(created_count)"

out="$(ensure acme/widgets "Onboarding" --create-approved)"; rc=$?
check_eq "substring of an existing title exits 4" "4" "$rc"
check "substring case is a near duplicate" "NEAR-DUPLICATE" "$out"

# --- 4. an unrelated title needs approval before it can be created ---
out="$(ensure acme/widgets "Search relevance")"; rc=$?
check_eq "no match without approval exits 5" "5" "$rc"
check "no match is named as such" "NO-MATCH" "$out"
check "no match lists the open milestones to choose from" "Onboarding revamp" "$out"
check "no match lists the other open milestone" "Payments hardening" "$out"
check_not "no match does not list closed milestones as options" "Legacy cleanup" "$out"
check_eq "no match creates nothing" "0" "$(created_count)"

# --- 5. with approval, an unrelated title is created ---
out="$(ensure acme/widgets "Search relevance" --create-approved)"; rc=$?
check_eq "approved create exits 0" "0" "$rc"
check "approved create reports the new milestone" "MILESTONE-CREATED 9 Search relevance" "$out"
check_eq "approved create makes exactly one write call" "1" "$(created_count)"

out="$(ensure acme/widgets "Search relevance" --create-approved --description "Better results" --due 2026-09-01T00:00:00Z)"
check "description is sent" "description=Better results" "$(cat "$TMP/calls.log")"
check "due date is sent" "due_on=2026-09-01T00:00:00Z" "$(cat "$TMP/calls.log")"

# --- 6. dry run writes nothing ---
out="$(DRY_RUN=1 ensure acme/widgets "Search relevance" --create-approved)"; rc=$?
check_eq "dry run exits 0" "0" "$rc"
check "dry run says what it would do" "WOULD-CREATE-MILESTONE" "$out"
check_eq "dry run creates nothing" "0" "$(created_count)"

# --- 7. a closed milestone with the wanted title is a decision, not a silent reuse ---
out="$(ensure acme/widgets "Legacy cleanup" --create-approved)"; rc=$?
check_eq "closed exact match exits 3" "3" "$rc"
check "closed match is named as such" "CLOSED-MATCH" "$out"
check_eq "closed match creates nothing" "0" "$(created_count)"

# --- 8. the whole list is read, not just the first page ---
ensure acme/widgets "Onboarding revamp" >/dev/null
check "milestones are fetched with pagination" "--paginate" "$(cat "$TMP/calls.log")"
check "milestones are fetched in both states" "state=all" "$(cat "$TMP/calls.log")"

# --- 8b. a warning on stderr must not corrupt the JSON on stdout ---
cat >"$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_CALLS"
echo "gh: a deprecation warning" >&2
if [ -n "${GH_FAIL:-}" ]; then exit 1; fi
for a in "$@"; do
  if [ "$a" = "-f" ] || [ "$a" = "--method" ]; then cat "$GH_CREATED"; exit 0; fi
done
cat "$GH_FIXTURE"
exit 0
STUB
chmod +x "$TMP/bin/gh"
out="$(ensure acme/widgets "Onboarding revamp")"; rc=$?
check_eq "a stderr warning does not break resolution" "0" "$rc"
check "warning case still reuses the milestone" "MILESTONE-EXISTS 3" "$out"

# restore the quiet stub for the remaining cases
cat >"$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_CALLS"
if [ -n "${GH_FAIL:-}" ]; then
  echo "gh: simulated API failure" >&2
  exit 1
fi
for a in "$@"; do
  if [ "$a" = "-f" ] || [ "$a" = "--method" ]; then cat "$GH_CREATED"; exit 0; fi
done
cat "$GH_FIXTURE"
exit 0
STUB
chmod +x "$TMP/bin/gh"

# --- 9. failure paths fail loud and never create ---
out="$(GH_FAIL=1 ensure acme/widgets "Search relevance" --create-approved)"; rc=$?
check_eq "api failure exits 6" "6" "$rc"
check "api failure explains itself" "could not read" "$(printf '%s' "$out" | tr 'A-Z' 'a-z')"
check_eq "api failure creates nothing" "0" "$(created_count)"

out="$(echo '[' >"$TMP/bad.json"; GH_FIXTURE="$TMP/bad.json" ensure acme/widgets "Search relevance" --create-approved)"; rc=$?
check_eq "unreadable milestone list exits 6" "6" "$rc"
check_eq "unreadable list creates nothing" "0" "$(created_count)"

out="$(PATH="/usr/bin:/bin" bash "$SCRIPT" acme/widgets "Search relevance" --create-approved 2>&1)"; rc=$?
check_eq "missing gh exits 6" "6" "$rc"
check "missing gh explains itself" "gh" "$out"

# --- 10. usage errors ---
out="$(ensure)"; rc=$?
check_eq "no args exits 2" "2" "$rc"
check "no args prints usage" "Usage:" "$out"

out="$(ensure acme/widgets "")"; rc=$?
check_eq "empty title exits 2" "2" "$rc"

echo
echo "passed: $pass, failed: $fail"
[[ "$fail" -eq 0 ]]
