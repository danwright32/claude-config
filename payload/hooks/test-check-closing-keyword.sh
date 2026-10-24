#!/usr/bin/env bash
# Tests for lib/closing-keyword.py, the one reading of a closing keyword GitHub honours against the
# sentence it sits in. Two hooks ask it: check-closing-keyword.sh about the text of a pull request
# or commit being written, and check-closing-merge.sh about a pull request's body as GitHub holds it
# at merge time (claude-config#1550).
#
# The bug it exists for (Overture #912, 2026-07-13): a PR body that said, in as many words,
# "It does not close #897" CLOSED #897 on merge. GitHub's linked-issue parser matches the
# keyword plus the reference and does no negation handling whatever, so the clearer the
# author is about NOT finishing an issue, the more likely they are to trip it (L1018).
#
# Drives the real detector file, so these exercise the actual code rather than a re-implementation
# of it (L52). The detector lived inline in check-closing-keyword.sh until #1550 gave it a second
# reader; this suite extracted it from the hook with awk until then.
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# CLOSING_KEYWORD_LIB points this at a mutated copy, to see each case fail against a detector
# without the rule it covers (L1).
LIB="${CLOSING_KEYWORD_LIB:-$DIR/lib/closing-keyword.py}"

pass=0
fail=0

# A detector that is not there finds nothing, and nothing is what a clean body looks like (L98).
if [ ! -f "$LIB" ]; then
  echo "FAIL: $LIB is missing, so every case below would read as clean"
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
fi

detect() {
  printf '%s' "$1" | python3 "$LIB" text
}

want_flag() {
  local desc="$1" body="$2" out
  out="$(detect "$body")"
  if [ -n "$out" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: expected a finding: $desc"; fi
}
want_clean() {
  local desc="$1" body="$2" out
  out="$(detect "$body")"
  if [ -z "$out" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: expected no finding: $desc -> got: $out"; fi
}

# --- The exact sentence that caused this ---
want_flag "the real one" "This does not close #897, which stays open for the per-page work."

# --- Every way a person naturally negates it ---
want_flag "does not fix"        "It does not fix #12 yet."
want_flag "doesn't close"       "This doesn't close #5."
want_flag "will not resolve"    "This will not resolve #77."
want_flag "won't close"         "It won't close #77."
want_flag "never closes"        "This never closes #3."
want_flag "cannot fix"          "A one line change cannot fix #44."
want_flag "not enough to close" "This is not enough to close #9 on its own."
want_flag "no longer fixes"     "That branch no longer fixes #22."
want_flag "capitalized"         "This Does Not Close #897."
want_flag "past tense"          "This did not fix #100."
want_flag "full url"            "This does not close https://github.com/danwright32/overture/issues/897"
want_flag "cross repo"          "This does not close danwright32/overture#897."
want_flag "colon form"          "This does not close: #897."

# --- Conditional, relative and partial sentences (claude-config#1550). Each is a sentence measured
#     on a real merged pull request whose merge closed an issue its body meant to leave open. ---
want_flag "conditional (slate#2603)"     "Fixing the parser too, which would also have closed #2584, is left for later."
want_flag "conditional, could"           "A bigger change could fix #12."
want_flag "relative, which (overture#4038)" "Follows #4036, which closed #3769."
want_flag "partial (overture#2271)"      "Partially closes #2265 (the deterministic half; the fixture case remains)."
want_flag "partial, helps"               "This helps fix #12."

# --- The body contradicting itself about one issue (claude-config#1550) ---
# claude-config#970: "Part of #953" at the top and "The next PR ... closes #953" further down.
want_flag "part of, then a close of the same issue" \
  "Part of #953

Nothing reads these files yet. The next PR points the check at them and closes #953."
# overture#3944: a close at the top and "#3566 should stay open" in the residual.
want_flag "a close, then the same issue stays open" \
  "Closes #3566.

The residual, stated plainly. #3566 should stay open for that half."
want_flag "a close, then the same issue remains open" "Fixes #40. #40 remains open for the docs."

# --- A genuine close must still sail through, or the guard is useless ---
want_clean "a real close"           "Closes #897."
want_clean "a real fix"             "Fixes #12 and adds a test."
want_clean "resolves"               "Resolves #5."
want_clean "the safe phrasing"      "Part of #897, which stays open."
want_clean "stays open"             "#897 stays open: this is only the ratchet."
want_clean "negation, no issue ref" "This does not fix the underlying ratchet at all."
want_clean "issue ref, no keyword"  "See #897 for the analysis."
want_clean "prose about closing"    "The queue closes the lead out when Dan sends a closing note."
want_clean "empty"                  ""

# --- The contradiction is about ONE issue, never a neighbour (measured on overture#828, #979, #1077,
#     #3618, each a real close the first draft of the rule would have refused) ---
want_clean "part of one issue, closes another"   "Part of #951. Closes #953."
want_clean "another issue stays open"            "Closes #771; #800 stays open for the Sources list."
want_clean "not part of the closed issue"        "Closes #981. Seeding real titles is a follow-up, not part of #981."
want_clean "a decision the issue left open"      "Closes #3078. The decision #3078 left open is answered here."
want_clean "which, in an earlier sentence"       "The guard, which was slow, is gone. Closes #12."
want_clean "would, in an earlier sentence"       "A rewrite would be cleaner. Fixes #12."

# --- The negation has to GOVERN the keyword, or half the honest PRs in the world are blocked ---

# A previous SENTENCE negation is ordinary English, and must sail through. This is the case
# that matters most for keeping the hook trusted: a PR that says what it does NOT do, then
# genuinely closes something, is exactly what a careful author writes.
want_clean "negation in the previous sentence" \
  "This does not attempt the per-page contract. Closes #910."

# The discriminating case: the negation is only a WORD or two back, but it belongs to the
# previous sentence, so it governs nothing here. A plain distance window (however tight) blocks
# this, and it is a sentence a careful author writes constantly.
want_clean "negation ending the previous sentence" \
  "The ratchet was not simple. Closes #910."

want_clean "far-away negation" \
  "This does not attempt the per-page contract, the reject tolerance, or any of the other three problems the issue raises, and it is deliberately narrow. Closes #910."

# But inside ONE sentence, a negation a few words back still governs the keyword.
want_flag "negation with a clause between it and the keyword" \
  "This does not, in the end, close #897."

# =================================================================================================
# The merge time reading (claude-config#1550): a pull request as GitHub holds it, judged only about
# the issues GitHub itself lists as closing (closingIssuesReferences). A negated keyword before an
# issue GitHub does NOT list closes nothing, so it is not this reading's business.
# =================================================================================================

# pr_json <body> <closing refs as owner/name#N, space separated>
pr_json() {
  python3 -c '
import json, sys
refs = []
for r in sys.argv[2].split():
    slug, n = r.split("#")
    owner, name = slug.split("/")
    refs.append({"number": int(n), "repository": {"name": name, "owner": {"login": owner}}})
print(json.dumps({"number": 7, "url": "https://github.com/acme/widget/pull/7", "body": sys.argv[1], "closingIssuesReferences": refs}))
' "$1" "$2"
}
judge() {  # $1 = body, $2 = closing refs ; sets judge_out and judge_rc, in this shell
  local json
  json="$(pr_json "$1" "$2")"
  judge_out="$(printf '%s' "$json" | python3 "$LIB" pr acme/widget)"; judge_rc=$?
}
pr_flag() {  # $1 = description, $2 = body, $3 = closing refs, $4 = a needle the finding must carry
  local out
  judge "$2" "$3"; out="$judge_out"
  if [ "$judge_rc" -ne 0 ]; then fail=$((fail+1)); echo "FAIL: $1: the detector exited $judge_rc"; return; fi
  case "$out" in
    *"$4"*) pass=$((pass+1)) ;;
    *) fail=$((fail+1)); echo "FAIL: expected a finding carrying [$4]: $1 -> got: $out" ;;
  esac
}
pr_clean() {  # $1 = description, $2 = body, $3 = closing refs
  local out
  judge "$2" "$3"; out="$judge_out"
  if [ "$judge_rc" -ne 0 ]; then fail=$((fail+1)); echo "FAIL: $1: the detector exited $judge_rc"; return; fi
  if [ -z "$out" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: expected no finding: $1 -> got: $out"; fi
}

pr_flag  "a negated close of a closing issue is named by number" \
  "Part of #4358. This does not close #4358." "acme/widget#4358" "#4358"
pr_flag  "and says what kind of sentence it sits in" \
  "This does not close #4358." "acme/widget#4358" "negated"
pr_flag  "a which clause is named as describing another change" \
  "Follows #4036, which closed #3769." "acme/widget#3769" "which"
pr_flag  "a conditional sentence is named" \
  "That fix would also have closed #2584." "acme/widget#2584" "conditional"
pr_flag  "a partial sentence is named" \
  "Partially closes #2265." "acme/widget#2265" "partial"
pr_flag  "part of, with GitHub listing the issue as closing" \
  "Part of #953. The next PR closes #953." "acme/widget#953" "Part of #953"
# GitHub lists an issue linked by hand in the sidebar too, with no keyword in the body at all: the
# body saying it stays open is still contradicted by the merge.
pr_flag  "a hand linked issue the body says stays open" \
  "Adds the reader. #9 stays open for the writer." "acme/widget#9" "stays open"
pr_flag  "a hand linked issue the body calls part of" \
  "Part of #9." "acme/widget#9" "Part of #9"
pr_flag  "a cross repository reference GitHub lists" \
  "This does not close acme/other#5." "acme/other#5" "acme/other#5"
pr_flag  "an issue url GitHub lists" \
  "This does not close https://github.com/acme/widget/issues/12." "acme/widget#12" "#12"

pr_clean "a negated keyword before an issue GitHub does not list closes nothing" \
  "This does not close #4358." ""
pr_clean "a real close beside a negated mention of another issue" \
  "Closes #12. This does not close #13." "acme/widget#12"
pr_clean "a bare #N is this repository's issue, never another's with the same number" \
  "This does not close #5." "acme/other#5"
pr_clean "a clean close of a listed issue" "Closes #12." "acme/widget#12"
pr_clean "no body at all" "" "acme/widget#12"

# A pull request with a null body, as gh prints one with no description.
out="$(printf '%s' '{"number":7,"url":"https://github.com/acme/widget/pull/7","body":null,"closingIssuesReferences":[{"number":3,"repository":{"name":"widget","owner":{"login":"acme"}}}]}' | python3 "$LIB" pr acme/widget)"; rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: a null body: exit $rc, said: $out"; fi

# An answer it cannot read is never a clean one (L98): it exits non zero, and the gate refuses on it.
printf 'not json' | python3 "$LIB" pr acme/widget >/dev/null 2>&1; rc=$?
if [ "$rc" -ne 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: an unreadable pull request read as clean (exit 0)"; fi
printf '%s' '{"number":7,"body":"x"}' | python3 "$LIB" pr acme/widget >/dev/null 2>&1; rc=$?
if [ "$rc" -ne 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: an answer with no closingIssuesReferences read as clean (exit 0)"; fi

echo
echo "passed: $pass   failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
