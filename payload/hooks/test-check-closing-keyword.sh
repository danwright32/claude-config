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

# THE LOOKUP, injected (claude-config#2464): every number a closing keyword sits in front of is
# looked up to tell a pull request from an issue, and this suite never asks GitHub. The stub reads
# a table of "owner/name#N kind state" lines (kind: issue, pr, fail or junk); a number it does not
# list is an open issue. Every number it is asked about is logged, so a case can see what was looked up.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/closing-keyword-lookup.XXXXXXXX")"
trap 'rm -rf "$WORK"' EXIT
LOOKUP_TABLE="$WORK/table"; LOOKUP_LOG="$WORK/log"
: > "$LOOKUP_TABLE"; : > "$LOOKUP_LOG"
cat > "$WORK/lookup.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s#%s\n' "$1" "$2" >> "$LOOKUP_LOG"
kind=issue; state=open
line="$(grep -i -- "^$1#$2 " "$LOOKUP_TABLE" | head -1)"
[ -n "$line" ] && read -r _ kind state <<< "$line"
case "$kind" in
  fail) echo "HTTP 404: Not Found (https://api.github.com/repos/$1/issues/$2)" >&2; exit 1 ;;
  pr) printf '{"number":%s,"state":"%s","pull_request":{"url":"x"}}' "$2" "$state" ;;
  junk) printf 'not json' ;;
  *) printf '{"number":%s,"state":"%s"}' "$2" "$state" ;;
esac
STUB
chmod +x "$WORK/lookup.sh"
export LOOKUP_TABLE LOOKUP_LOG CLOSING_KEYWORD_LOOKUP="$WORK/lookup.sh"

# Text as written in acme/widget, so a bare #N is acme/widget's.
detect() {
  printf '%s' "$1" | python3 "$LIB" text acme/widget
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

# =================================================================================================
# EVERY keyword and number pair is looked up (claude-config#2464). On 2026-11-08 the description of
# claude-config#2456 said, in passing, "including the p0 fix #2451 and batch #2438". #2451 was an
# open pull request, GitHub read "fix #2451" as a closing keyword, and merging #2456 closed it
# unmerged. GitHub does not list a pull request in closingIssuesReferences, so no rule judging only
# listed issues could ever see it.
# =================================================================================================
printf '%s\n' "acme/widget#2451 pr open" "acme/widget#2438 pr open" "acme/widget#60 pr closed" \
  "acme/widget#61 issue closed" "acme/widget#404 fail" "acme/widget#405 junk" > "$LOOKUP_TABLE"

want_finding() {  # $1 = description, $2 = body, $3 = a needle the finding must carry
  local out; out="$(detect "$2")"
  case "$out" in
    *"$3"*) pass=$((pass+1)) ;;
    *) fail=$((fail+1)); echo "FAIL: expected a finding carrying [$3]: $1 -> got: $out" ;;
  esac
}

want_finding "the #2456 sentence: a closing word in passing before a pull request" \
  "6 were cancelled at forty minutes with nothing failing, including the p0 fix #2451 and batch #2438, which" \
  "pull request"
want_finding "and the refusal shows the phrase to reword" \
  "6 were cancelled at forty minutes with nothing failing, including the p0 fix #2451 and batch #2438, which" \
  "including the p0 fix #2451"
want_finding "a pull request on a Closes line of its own is still a pull request" "Closes #2451" "pull request"
want_finding "a pull request named by its full reference" "Fixes acme/widget#2451." "pull request"
want_finding "a closing word in the middle of a sentence before an open issue" \
  "This is the follow up fix #12 asked for." "not at the start of a line or sentence"
want_finding "a lookup that fails refuses, with the reason" "Closes #404." "HTTP 404"
want_finding "a lookup that fails names the reference it could not look up" "Closes #404." "acme/widget#404"
want_finding "an answer that is not GitHub's issue shape refuses" "Closes #405." "could not look up"
want_finding "a later pair on a line is judged by its own place, not the first pair's" \
  "Closes #12, and the p0 fix #2451 is unrelated." "pull request"

want_clean "a Closes line of its own before an open issue" "Closes #12"
want_clean "two pairs chained on one Closes line" "Closes #12, closes #13"
want_clean "a Closes line in a list" "- Closes #12"
want_clean "a Closes line in a numbered list" "1. Fixes #12"
want_clean "a Closes line among other lines" "Summary of the change.

Closes #12
"
want_clean "a closing word starting its own sentence" "Adds the reader. Fixes #12 too."
want_clean "a closing word right after the opening quote of a message" 'commit -m "Closes #12"'
want_clean "a closing word in passing before a CLOSED pull request closes nothing" "the earlier fix #60 landed"
want_clean "a closing word in passing before a closed issue closes nothing" "the earlier fix #61 landed"
want_clean "no pair, nothing looked up" "See #2451 for the p0."

# A number already refused for its sentence is not also looked up: nothing the lookup says can clear it.
: > "$LOOKUP_LOG"
detect "This does not close #897." >/dev/null
if [ ! -s "$LOOKUP_LOG" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: a number already refused was looked up: $(cat "$LOOKUP_LOG")"; fi

# With no repository known, a bare #N cannot be looked up, and that refuses rather than passes.
out="$(printf 'Closes #12' | python3 "$LIB" text)"
case "$out" in
  *"which repository"*) pass=$((pass+1)) ;;
  *) fail=$((fail+1)); echo "FAIL: a bare #N with no repository known should refuse, said: $out" ;;
esac
: > "$LOOKUP_TABLE"

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

# Pull requests at merge time (claude-config#2464): GitHub lists none in closingIssuesReferences, so
# an empty list is not a body with nothing to judge.
printf '%s\n' "acme/widget#2451 pr open" "acme/widget#404 fail" > "$LOOKUP_TABLE"
pr_flag  "the #2456 body: a closing word before a pull request, with nothing listed" \
  "including the p0 fix #2451 and batch #2438" "" "pull request"
pr_flag  "a listed issue whose closing word sits mid sentence closes what the body never declared" \
  "This is the follow up fix #12 asked for." "acme/widget#12" "not at the start of a line or sentence"
pr_flag  "a lookup that fails at merge refuses" "Closes #404." "" "HTTP 404"
pr_clean "an unlisted issue is one GitHub will not close, whatever its sentence" \
  "the follow up fix #13 asked for" ""
: > "$LOOKUP_LOG"
judge "Closes #12." "acme/widget#12"
if [ ! -s "$LOOKUP_LOG" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: an issue GitHub lists was looked up again: $(cat "$LOOKUP_LOG")"; fi
: > "$LOOKUP_TABLE"

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
