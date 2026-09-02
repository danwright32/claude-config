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
  { "number": 7, "title": "One store, one truth", "state": "open", "html_url": "https://github.com/acme/widgets/milestone/7" },
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
out="$(ensure acme/widgets "Search relevance" --create-approved --for-issues 2)"
check "create reports the milestone's real title" "MILESTONE-TITLE Search relevance" "$out"

# --- 3. a near duplicate stops and asks instead of creating a twin ---
out="$(ensure acme/widgets "Onboarding revamp v2" --create-approved --for-issues 2)"; rc=$?
check_eq "near duplicate exits 4" "4" "$rc"
check "near duplicate is named as such" "NEAR-DUPLICATE" "$out"
check "near duplicate names the candidate" "Onboarding revamp" "$out"
check_eq "near duplicate creates nothing even when approved" "0" "$(created_count)"

out="$(ensure acme/widgets "Onboarding" --create-approved --for-issues 2)"; rc=$?
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
out="$(ensure acme/widgets "Search relevance" --create-approved --for-issues 2)"; rc=$?
check_eq "approved create exits 0" "0" "$rc"
check "approved create reports the new milestone" "MILESTONE-CREATED 9 Search relevance" "$out"
check_eq "approved create makes exactly one write call" "1" "$(created_count)"

out="$(ensure acme/widgets "Search relevance" --create-approved --for-issues 2 --description "Better results" --due 2026-09-01T00:00:00Z)"
check "description is sent" "description=Better results" "$(cat "$TMP/calls.log")"
check "due date is sent" "due_on=2026-09-01T00:00:00Z" "$(cat "$TMP/calls.log")"

# --- 6. dry run writes nothing ---
out="$(DRY_RUN=1 ensure acme/widgets "Search relevance" --create-approved --for-issues 2)"; rc=$?
check_eq "dry run exits 0" "0" "$rc"
check "dry run says what it would do" "WOULD-CREATE-MILESTONE" "$out"
check_eq "dry run creates nothing" "0" "$(created_count)"

# --- 7. a closed milestone with the wanted title is a decision, not a silent reuse ---
out="$(ensure acme/widgets "Legacy cleanup" --create-approved --for-issues 2)"; rc=$?
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
out="$(GH_FAIL=1 ensure acme/widgets "Search relevance" --create-approved --for-issues 2)"; rc=$?
check_eq "api failure exits 6" "6" "$rc"
check "api failure explains itself" "could not read" "$(printf '%s' "$out" | tr 'A-Z' 'a-z')"
check_eq "api failure creates nothing" "0" "$(created_count)"

out="$(echo '[' >"$TMP/bad.json"; GH_FIXTURE="$TMP/bad.json" ensure acme/widgets "Search relevance" --create-approved --for-issues 2)"; rc=$?
check_eq "unreadable milestone list exits 6" "6" "$rc"
check_eq "unreadable list creates nothing" "0" "$(created_count)"

out="$(PATH="/usr/bin:/bin" bash "$SCRIPT" acme/widgets "Search relevance" --create-approved --for-issues 2 2>&1)"; rc=$?
check_eq "missing gh exits 6" "6" "$rc"
check "missing gh explains itself" "gh" "$out"

# --- 10. usage errors ---
out="$(ensure)"; rc=$?
check_eq "no args exits 2" "2" "$rc"
check "no args prints usage" "Usage:" "$out"

out="$(ensure acme/widgets "")"; rc=$?
check_eq "empty title exits 2" "2" "$rc"

# --- 11. a NEW milestone title names the feature, not a narrative sentence ---
# Why: on 2026-07-30 Dan found his milestone list full of titles like "Let Dan act
# where he is looking" and "One store, one truth". They read as essay headings, so
# the list could not be scanned. Nothing enforced a shape, so each session invented
# a theme. The rule now lives here, where every filing path already funnels.
#
# A milestone is the overarching FEATURE, and its issues are what has to be finished
# for that feature to ship. So the title is a short noun phrase naming the thing
# being built. The narrative belongs in the milestone description.
# ("One store, one truth" is deliberately absent: it exists in the fixture, so it
# is a reuse case, covered in 11b below.)
narrative=(
  "Let Dan act where he is looking"
  "A queue whose order and contents you can trust"
  "Trustworthy local verification: tests, guards, and the build"
  "Say it once, and only when Dan can act on it"
  "One paid contact answer, recorded and reused correctly"
)
for t in "${narrative[@]}"; do
  out="$(ensure acme/widgets "$t" --create-approved --for-issues 2)"; rc=$?
  check_eq "narrative title is refused: $t" "8" "$rc"
  check_eq "narrative title creates nothing: $t" "0" "$(created_count)"
done

# Each of the four rules gets a title that ONLY it catches. Without these, three of
# the rules could be deleted and this suite would stay green: every title above
# happens to trip the stop-word or length rule as well, which makes the other rules
# look tested when they are not.
#
#            title                                                      caught only by
isolating=(
  "Purge stale sources from every local build and cache"              # word count (9)
  "Docs, tests and guards"                                           # punctuation
  "Reconciliation instrumentation and provisioning telemetry pipeline"  # character count
  "Queue contents you trust"                                         # stop word
  "Dan cannot act here"                                              # stop word: his name
)
short_but_punctuated=(
  "Saved views, part one"
  "Saved views: phase one"
  "Queue windowing, part two"
  "Ship it."
)
for t in "${short_but_punctuated[@]}"; do
  out="$(ensure acme/widgets "$t" --create-approved --for-issues 2)"; rc=$?
  check_eq "punctuation is refused however short the title: $t" "8" "$rc"
  check "the refusal names the punctuation: $t" "reads as a sentence" "$out"
done

for t in "${isolating[@]}"; do
  out="$(ensure acme/widgets "$t" --create-approved --for-issues 2)"; rc=$?
  check_eq "each rule stands on its own: $t" "8" "$rc"
  check_eq "no creation on: $t" "0" "$(created_count)"
done

# The refusal has to teach the shape, not just say no, or the next attempt is
# another guess.
out="$(ensure acme/widgets "Say it once, and only when Dan can act on it" --create-approved --for-issues 2)"
check "the refusal is named" "TITLE-NOT-A-FEATURE" "$out"
check "the refusal points at the shared rule" "NAMING.md" "$out"
check "the refusal says the narrative belongs in the description" "description" "$(printf '%s' "$out" | tr 'A-Z' 'a-z')"
check "the refusal names the override" "ALLOW_ANY_MILESTONE_TITLE=1" "$out"

# Feature shaped titles pass. A milestone is the feature that ships when its issues
# are done, so these are the names of things being built.
features=(
  "Saved views"
  "Salesforce sync v2"
  "Bulk contact enrichment"
  "Canvas & editor"
  "Engine reliability"
  "Test coverage"
  "Queue windowing"
  "Organisation contact ledger"
  "Node test coloring in edit mode"
  "Bulk contact enrichment for scouted shows"
  "Organisation contact ledger for scouted show venues"
)
for t in "${features[@]}"; do
  out="$(ensure acme/widgets "$t" --create-approved --for-issues 2)"; rc=$?
  check_eq "feature title is accepted: $t" "0" "$rc"
done

# --- 11b. reuse is never blocked by the shape rule ---
# Dan kept his existing narrative milestones, so an issue still has to be able to
# attach to one. The shape rule guards CREATION only: applying it to a lookup would
# orphan every issue belonging to a milestone that already exists.
out="$(ensure acme/widgets "One store, one truth")"; rc=$?
check_eq "an existing narrative milestone is still reusable" "0" "$rc"
check "reuse of a narrative milestone reports it" "MILESTONE-EXISTS 7" "$out"
check "reuse reports the title for gh to match on" "MILESTONE-TITLE One store, one truth" "$out"
check_eq "reuse creates nothing" "0" "$(created_count)"

# Same lookup with approval to create: it matches, so it never reaches the shape
# check either.
out="$(ensure acme/widgets "One store, one truth" --create-approved --for-issues 2)"; rc=$?
check_eq "reuse with approval still exits 0" "0" "$rc"
check "reuse with approval still reuses" "MILESTONE-EXISTS 7" "$out"

# --- 11c. the shape rule is checked before anything is written ---
out="$(DRY_RUN=1 ensure acme/widgets "One paid contact answer, recorded and reused correctly" --create-approved --for-issues 2)"; rc=$?
check_eq "a dry run of a narrative title is still refused" "8" "$rc"
check_not "a refused dry run does not claim it would create" "WOULD-CREATE-MILESTONE" "$out"

# --- 11e. the catch-all milestone needs no approval ---
# Most issues are standalone bugs and chores that belong to no feature. They still
# need a milestone (the gate requires one), so there is one designated holding pen
# per repo. Creating it is not a decision anyone needs to make, so requiring
# approval every time would be pure friction, and the alternative is what happened
# before: a session invents a milestone to satisfy the gate.
out="$(ensure acme/widgets "Ungrouped")"; rc=$?
check_eq "the catch-all is created without approval" "0" "$rc"
check "the catch-all reports a real creation" "MILESTONE-CREATED" "$out"
check_eq "the catch-all makes exactly one write call" "1" "$(created_count)"
check "the catch-all says what it is for" "standalone" "$(printf '%s' "$out" | tr 'A-Z' 'a-z')"

out="$(ensure acme/widgets "ungrouped")"; rc=$?
check_eq "a case variant of the catch-all also needs no approval" "0" "$rc"

# The exemption is for that ONE title. Any other unmatched title still needs the
# user to approve it, or the approval rule is worthless.
out="$(ensure acme/widgets "Ungrouped work and other things")"; rc=$?
check_eq "a title merely containing the word still needs approval" "5" "$rc"
check_eq "it creates nothing" "0" "$(created_count)"

out="$(ensure acme/widgets "Saved views")"; rc=$?
check_eq "an ordinary feature title still needs approval" "5" "$rc"

# Creating a milestone is a PLANNING decision, so the refusal has to say where
# creation belongs and offer the two answers that are always available. Otherwise a
# session filing one ad hoc issue reads "needs approval" as "ask to create one",
# which is how a one-off bug ended up with a milestone of its own.
check "the refusal names the catch-all" "Ungrouped" "$out"
check "the refusal says creation belongs to a planning flow" "plan-council" "$out"
check "the refusal names the other planning flow" "plan-lite" "$out"
check "the refusal says not to create one for a one-off issue" "one-off" "$out"

# Once it exists it is reused like anything else, never twinned.
cat >"$TMP/withcatchall.json" <<'JSON'
[
  { "number": 3, "title": "Onboarding revamp", "state": "open", "html_url": "https://github.com/acme/widgets/milestone/3" },
  { "number": 12, "title": "Ungrouped", "state": "open", "html_url": "https://github.com/acme/widgets/milestone/12" }
]
JSON
out="$(GH_FIXTURE="$TMP/withcatchall.json" ensure acme/widgets "Ungrouped")"; rc=$?
check_eq "an existing catch-all is reused" "0" "$rc"
check "the existing catch-all is reported" "MILESTONE-EXISTS 12" "$out"
check_eq "reusing the catch-all creates nothing" "0" "$(created_count)"

# --- 11d. the documented override lets a genuine exception through ---
out="$(ALLOW_ANY_MILESTONE_TITLE=1 ensure acme/widgets "Say it once, and only when Dan can act on it" --create-approved --for-issues 2)"; rc=$?
check_eq "the override creates the milestone" "0" "$rc"
check "the override reports a real creation" "MILESTONE-CREATED" "$out"
check_eq "the override makes exactly one write call" "1" "$(created_count)"

# --- 12. a NEW milestone has to be for 2 or more issues ---
# The threshold used to live only in the instruction text, so nothing stopped a
# session opening a milestone for a single issue, which is a label with extra steps
# and is exactly what produced the six essay titled milestones. A rule that lives
# only in a prompt is a hope (L27), so the create path now refuses without a stated
# count. The count is STATED, not verified: the caller usually holds issues that do
# not exist yet, so no check here could confirm it. What it removes is creation by
# momentum, because passing --create-approved is no longer enough on its own.

out="$(ensure acme/widgets "Search relevance" --create-approved)"; rc=$?
check_eq "creating without a stated issue count is refused" "10" "$rc"
check "the refusal names the rule" "2 or more" "$out"
check "the refusal names the flag to use" "--for-issues" "$out"
check_eq "a refused create writes nothing" "0" "$(created_count)"

# ZERO is deliberately NOT refused. `milestone/SKILL.md` documents an empty "issues"
# array as the way to create a container before its issues exist, so the threshold
# refuses exactly ONE, which is the actual failure mode: a lone issue dressed up as a
# feature. The empty case is announced so it cannot happen silently.
out="$(ensure acme/widgets "Search relevance" --create-approved --for-issues 0)"; rc=$?
check_eq "creating an intentionally empty milestone still succeeds" "0" "$rc"
check "an empty milestone says so, so it cannot pass unnoticed" "EMPTY-MILESTONE" "$out"
check_eq "creating an empty milestone makes exactly one write call" "1" "$(created_count)"

out="$(ensure acme/widgets "Search relevance" --create-approved --for-issues 1)"; rc=$?
check_eq "creating for a single issue is refused" "10" "$rc"
check "the single issue refusal offers the catch-all instead" "Ungrouped" "$out"
check_eq "a single issue create writes nothing" "0" "$(created_count)"

out="$(ensure acme/widgets "Search relevance" --create-approved --for-issues 2)"; rc=$?
check_eq "creating for two issues succeeds" "0" "$rc"
check "creating for two issues reports a real creation" "MILESTONE-CREATED" "$out"
check_eq "creating for two issues makes exactly one write call" "1" "$(created_count)"

# A count that is not a number must be a usage error, never quietly read as 0 or as
# good enough: a caller passing an empty variable would otherwise be refused with a
# message about the threshold, which points at the wrong thing (L11).
for bad_count in "two" "" "-1" "2.5"; do
  out="$(ensure acme/widgets "Search relevance" --create-approved --for-issues "$bad_count")"; rc=$?
  check_eq "--for-issues '$bad_count' is a usage error" "2" "$rc"
  check_eq "--for-issues '$bad_count' writes nothing" "0" "$(created_count)"
done

# --- 12a. the exemptions, which have to stay exempt ---
# The holding pen is not a feature, so the threshold does not apply to it. If it did,
# the pen could not be created and every standalone issue would have nowhere to go,
# which is the deadlock an exemption written too narrowly produces (L362).
out="$(ensure acme/widgets "Ungrouped")"; rc=$?
check_eq "the catch-all is still created with no stated count" "0" "$rc"
check "the catch-all still reports itself as the exempt holding pen" "CATCH-ALL-MILESTONE" "$out"
check_eq "the catch-all still makes exactly one write call" "1" "$(created_count)"

# Reusing an existing milestone is not creating one, so it needs no count. This is
# the commonest path by far and must not have acquired a new requirement.
out="$(ensure acme/widgets "Onboarding revamp")"; rc=$?
check_eq "reusing an open milestone needs no stated count" "0" "$rc"
check "reusing an open milestone still reports the reuse" "MILESTONE-EXISTS" "$out"
check_eq "reusing an open milestone writes nothing" "0" "$(created_count)"

# --- 12b. the visible override, for a genuine exception ---
out="$(ALLOW_SINGLE_ISSUE_MILESTONE=1 ensure acme/widgets "Search relevance" --create-approved --for-issues 1)"; rc=$?
check_eq "the override allows a single issue milestone" "0" "$rc"
check "the override says it was overridden, so it cannot pass unnoticed" "OVERRIDDEN" "$out"
check_eq "the override makes exactly one write call" "1" "$(created_count)"

# The override must not also waive the count being WELL FORMED, or one override
# quietly waives two rules (each rule keeps its own override).
out="$(ALLOW_SINGLE_ISSUE_MILESTONE=1 ensure acme/widgets "Search relevance" --create-approved --for-issues nonsense)"; rc=$?
check_eq "the override does not waive a malformed count" "2" "$rc"

# --- 12c. the threshold is checked BEFORE the title shape ---
# Both can be wrong at once. Whichever is reported, nothing may be created, because a
# refusal that still writes is worse than either message being the wrong one.
out="$(ensure acme/widgets "Say it once, and only when Dan can act on it" --create-approved --for-issues 1)"; rc=$?
check_eq "a create wrong in two ways still writes nothing" "0" "$(created_count)"
if [[ "$rc" -eq 10 || "$rc" -eq 8 ]]; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  echo "FAIL: a create that is both single issue and badly titled should be refused (got rc=$rc)"
fi

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
