#!/usr/bin/env bash
# Tests for the negated-closing-keyword detector inside check-closing-keyword.sh.
#
# The bug it exists for (Overture #912, 2026-07-13): a PR body that said, in as many words,
# "It does not close #897" CLOSED #897 on merge. GitHub's linked-issue parser matches the
# keyword plus the reference and does no negation handling whatever, so the clearer the
# author is about NOT finishing an issue, the more likely they are to trip it.
#
# Extracts the real python3 detector out of the hook and feeds it synthetic PR bodies, so
# these exercise the actual code rather than a re-implementation of it.
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/check-closing-keyword.sh"

# The extracted detector goes in a directory of this RUN's own, never beside this file
# (claude-config#180). A fixed name in payload/hooks is one path shared by every run on the
# machine: two at once truncate and then delete each other's copy, and the second reads a half
# written file and reports that the detector found nothing. It also put a stray file inside the
# tree the sync mirrors whenever a run was killed between writing it and removing it.
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/claude-sync-work.closingkw.XXXXXXXX")" || WORKDIR=""
case "${WORKDIR%/}" in
  ''|/|"${HOME%/}") echo "$(basename "${BASH_SOURCE[0]}"): refusing to run: throwaway directory came back as '$WORKDIR'." >&2; exit 2 ;;
esac
trap 'rm -rf "$WORKDIR"' EXIT

awk '
  /^findings="\$\(printf/ { flag=1; next }
  flag && /2>\/dev\/null\)"$/ { flag=0; next }
  flag { print }
' "$HOOK" > "$WORKDIR/.closing-detector.tmp.py"
[ -s "$WORKDIR/.closing-detector.tmp.py" ] || { echo "FAIL: could not extract detector block"; exit 1; }

detect() {
  printf '%s' "$1" | python3 "$WORKDIR/.closing-detector.tmp.py"
}

pass=0
fail=0
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

echo
echo "passed: $pass   failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
