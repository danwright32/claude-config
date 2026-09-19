#!/usr/bin/env bash
# Tests for ensure-priority-labels.sh.
#
# A fake gh on PATH stands in for GitHub, so these tests cannot reach the network
# or touch a real repository. The fake records every call, which lets the tests
# assert that nothing was created on the paths where creating is forbidden, and
# that a second run creates nothing at all.
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$DIR/ensure-priority-labels.sh"
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
# `gh label list` answers from a fixture the test controls; `gh label create`
# records the call and succeeds, or fails in the ways GitHub really fails.
mkdir -p "$TMP/bin"
cat >"$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_CALLS"
if [ "${2:-}" = "list" ]; then
  if [ -n "${GH_LIST_FAIL:-}" ]; then
    echo "gh: simulated API failure" >&2
    exit 1
  fi
  cat "$GH_FIXTURE"
  exit 0
fi
if [ "${2:-}" = "create" ]; then
  if [ -n "${GH_CREATE_EXISTS:-}" ]; then
    echo 'HTTP 422: Validation Failed (label already exists)' >&2
    exit 1
  fi
  if [ -n "${GH_CREATE_FAIL:-}" ]; then
    echo "gh: permission denied" >&2
    exit 1
  fi
  exit 0
fi
exit 0
STUB
chmod +x "$TMP/bin/gh"

echo '[]' >"$TMP/none.json"
cat >"$TMP/all.json" <<'JSON'
[{"name":"priority-p0"},{"name":"priority-p1"},{"name":"priority-p2"},
 {"name":"priority-p3"},{"name":"priority-p4"},{"name":"bug"}]
JSON
cat >"$TMP/partial.json" <<'JSON'
[{"name":"priority-p1"},{"name":"PRIORITY-P2"},{"name":"bug"},{"name":"frontend"}]
JSON
cat >"$TMP/withsev.json" <<'JSON'
[{"name":"priority-p1"},{"name":"sev-low"},{"name":"sev-medium"},
 {"name":"severity:high"},{"name":"bug"}]
JSON

export GH_FIXTURE="$TMP/none.json"

# ensure <args...> : runs the script with the fake gh, fresh call log each time
ensure() {
  export GH_CALLS="$TMP/calls.log"
  : >"$GH_CALLS"
  PATH="$TMP/bin:$PATH" bash "$SCRIPT" "$@" 2>&1
}
created_count() { grep -c 'label create' "$TMP/calls.log" 2>/dev/null; }

# --- 1. an empty repo gets all five levels ---
out="$(ensure acme/widgets)"; rc=$?
check_eq "empty repo exits 0" "0" "$rc"
check_eq "empty repo creates exactly five labels" "5" "$(created_count)"
for lvl in 0 1 2 3 4; do
  check "level p$lvl is created" "PRIORITY-LABEL-CREATED priority-p$lvl" "$out"
done
check "reports it finished" "PRIORITY-LABELS-READY acme/widgets" "$out"

# Each label carries its meaning, so the scale is readable on GitHub itself and
# not only in the config. A colour ramp makes the level legible at a glance.
calls="$(cat "$TMP/calls.log")"
lc_calls="$(printf '%s' "$calls" | tr 'A-Z' 'a-z')"
check "p0 says what it means" "broken now" "$lc_calls"
check "p1 says what it means" "do next" "$lc_calls"
check "p2 says what it means" "normal" "$lc_calls"
check "p3 says what it means" "nice to have" "$lc_calls"
check "p4 says what it means" "someday" "$lc_calls"
check "labels are coloured" "--color" "$calls"
check "the repo is passed through" "--repo acme/widgets" "$calls"

# --- 2. assume it runs twice: a second run creates nothing ---
export GH_FIXTURE="$TMP/all.json"
out="$(ensure acme/widgets)"; rc=$?
check_eq "second run exits 0" "0" "$rc"
check_eq "second run creates nothing" "0" "$(created_count)"
check "second run reports the labels already exist" "PRIORITY-LABEL-EXISTS priority-p0" "$out"
check "second run still reports ready" "PRIORITY-LABELS-READY" "$out"

# --- 3. a partly labelled repo gets only what is missing ---
export GH_FIXTURE="$TMP/partial.json"
out="$(ensure acme/widgets)"; rc=$?
check_eq "partial repo exits 0" "0" "$rc"
check_eq "partial repo creates only the three missing" "3" "$(created_count)"
check "existing p1 is left alone" "PRIORITY-LABEL-EXISTS priority-p1" "$out"
# GitHub label names are case insensitive for uniqueness, so creating priority-p2
# next to PRIORITY-P2 would fail. Matching has to ignore case.
check "an existing label in another case counts as present" "PRIORITY-LABEL-EXISTS priority-p2" "$out"
check_not "the existing p2 is not recreated" "PRIORITY-LABEL-CREATED priority-p2" "$out"
check "the missing p0 is created" "PRIORITY-LABEL-CREATED priority-p0" "$out"

# --- 4. the rival severity scales are reported, never silently deleted ---
# Priority replaces them, but deleting a label strips it from every issue that
# carries it, so that is Dan's call and not this script's.
export GH_FIXTURE="$TMP/withsev.json"
out="$(ensure acme/widgets)"; rc=$?
check_eq "a repo with severity labels still exits 0" "0" "$rc"
check "the rival labels are named" "SEVERITY-LABELS-FOUND" "$out"
check "sev-low is listed" "sev-low" "$out"
check "severity:high is listed" "severity:high" "$out"
check "it says why they matter" "priority" "$(printf '%s' "$out" | tr 'A-Z' 'a-z')"
check_not "it does not delete anything" "label delete" "$(cat "$TMP/calls.log")"

export GH_FIXTURE="$TMP/all.json"
out="$(ensure acme/widgets)"
check_not "a clean repo gets no severity warning" "SEVERITY-LABELS-FOUND" "$out"

# --- 5. dry run writes nothing ---
export GH_FIXTURE="$TMP/none.json"
out="$(DRY_RUN=1 ensure acme/widgets)"; rc=$?
check_eq "dry run exits 0" "0" "$rc"
check "dry run says what it would do" "WOULD-CREATE-LABEL priority-p0" "$out"
check_eq "dry run creates nothing" "0" "$(created_count)"

# --- 6. failure paths fail loud and never create blind ---
# Reading the label list is what tells the script which labels are missing. If that
# read fails, creating anyway would fire five doomed calls and report success.
out="$(GH_LIST_FAIL=1 ensure acme/widgets)"; rc=$?
check_eq "an unreadable label list exits 6" "6" "$rc"
check "the read failure explains itself" "could not read" "$(printf '%s' "$out" | tr 'A-Z' 'a-z')"
check_eq "the read failure creates nothing" "0" "$(created_count)"
check_not "the read failure does not claim to be ready" "PRIORITY-LABELS-READY" "$out"

out="$(echo '[' >"$TMP/bad.json"; GH_FIXTURE="$TMP/bad.json" ensure acme/widgets)"; rc=$?
check_eq "an unparseable label list exits 6" "6" "$rc"
check_eq "an unparseable list creates nothing" "0" "$(created_count)"

# A create that genuinely fails must be reported as a failure, not swallowed.
out="$(GH_CREATE_FAIL=1 ensure acme/widgets)"; rc=$?
check_eq "a failed create exits 7" "7" "$rc"
check "the failed create is named" "LABEL-FAILED" "$out"
check_not "a failed run does not claim to be ready" "PRIORITY-LABELS-READY" "$out"

# But a create that fails BECAUSE the label already exists is the idempotent path,
# not an error: two runs racing each other must both end up fine.
out="$(GH_CREATE_EXISTS=1 ensure acme/widgets)"; rc=$?
check_eq "an already-exists create still exits 0" "0" "$rc"
check "the race is reported as existing, not failed" "PRIORITY-LABEL-EXISTS" "$out"
check_not "the race is not reported as a failure" "LABEL-FAILED" "$out"
check "the race still reports ready" "PRIORITY-LABELS-READY" "$out"

out="$(PATH="/usr/bin:/bin" bash "$SCRIPT" acme/widgets 2>&1)"; rc=$?
check_eq "missing gh exits 6" "6" "$rc"
check "missing gh explains itself" "gh" "$out"

# --- 7. usage errors ---
out="$(ensure)"; rc=$?
check_eq "no args exits 2" "2" "$rc"
check "no args prints usage" "Usage:" "$out"

out="$(ensure "not-a-repo")"; rc=$?
check_eq "a repo with no owner exits 2" "2" "$rc"

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
