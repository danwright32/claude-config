#!/usr/bin/env bash
# Tests for feature-issue-review.sh and the instruction it now points at.
#
# The 8,000 character instruction used to live inside this hook as a JSON heredoc.
# It moved to review/issue-review.md (claude-config#243) because a Stop hook's
# `reason` is printed to Dan verbatim, so everything addressed to Claude was landing
# on his screen. The rules did not change; where they live did.
#
# What has to be checked did not change either. The instruction is the ONLY carrier
# of a set of rules that were each got wrong in practice, and a silent drop brings
# the original problem straight back, so each is asserted individually. The JSON
# parse check moved with them: the hook still holds one hand written JSON payload,
# the fallback it emits when the pointer cannot be built, and an unescaped quote
# there makes Claude Code drop the hook with nothing in the transcript to say so.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/feature-issue-review.sh"
INSTRUCTION="$DIR/review/issue-review.md"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/claude-issue-review.XXXXXX")" || exit 2
case "${WORK%/}" in
  ''|/|"${HOME%/}") echo "refusing to run: throwaway directory came back as '$WORK'." >&2; exit 2 ;;
esac
WORK="$(cd "$WORK" && pwd)"
trap 'rm -rf "$WORK"' EXIT

# Pinned to a throwaway spool, so this suite is structurally unable to write into
# the real one (L2). A sibling suite did exactly that 120 times before it was noticed.
export CLAUDE_ISSUE_SPOOL_DIR="$WORK/spool"
mkdir -p "$CLAUDE_ISSUE_SPOOL_DIR"

pass=0
fail=0
check() { # check <description> <ok|why-not>
  if [[ "$2" == "ok" ]]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL: $1 ($2)"
  fi
}

# --- the instruction file has to exist, or the review points at nothing ---
[ -f "$INSTRUCTION" ] \
  && check "the instruction file exists" ok \
  || check "the instruction file exists" "nothing at $INSTRUCTION"

instruction="$(cat "$INSTRUCTION" 2>/dev/null)"

# --- the rules the instruction is the only carrier of ---
# Each of these exists because it was got wrong in practice.
needs=(
  "MILESTONE AND PRIORITY"          # both axes required on every issue
  "priority-p0"                     # the scale is spelled out, not assumed
  "priority-p2"
  "priority-p4"
  "[p2, tech-debt, NEW Backlog grouping, moves #241 #242]"  # a new milestone is SHOWN as new, with what it moves
  "Ungrouped"                       # the catch-all is still offered
  "milestone-candidates.sh"         # the backlog is READ before a milestone is chosen
  "READ THE TITLES"                 # the score ranks the shortlist, the reader decides (#265)
  "DUPLICATE-RISK"                  # an idea that already exists is not filed again
  "CHECK THOSE BEFORE FILING"       # which only works if the lines are actually read
  "2 OR MORE issues would go into it at once"  # the bar for opening a new milestone
  "--create-approved"               # which only happens after Dan selects it
  "--for-issues <n>"                # and the cluster size is stated, because the script now enforces it
  "gh issue edit"                   # and the siblings actually get moved
  "plan-council"                    # planning a feature still belongs there
  "ensure-priority-labels.sh"       # how to make the labels exist
  "severity:*"                      # the retired scale is named as retired
  "NAMING.md"                       # points at the shared rule
  "AskUserQuestion"                 # the picker, not prose
  "claude-suggested"                # the forbidden attribution label
  "EVERY area label that genuinely applies"  # labels are many per issue, not one
  "STARTING POINT, not a closed set"         # the vocabulary is guidance, not a cage
  "gh label list"                            # read the repo's own labels first
  "data-integrity"                           # the area vocabulary is actually listed
  "ISSUE REVIEW"                             # the banner it has to open with
  "SECOND PASS"                              # the reflection folds in here
  "TO FILE THESE"                            # the clear command the render wrote (#287)
  "Run that line, verbatim"                  # and it is run as it stands, not reconstructed
  "do NOT drop any of its arguments"         # its last one is the stamp of what was read (#381)
  "THESE cannot be filed from this review"   # a render with no stamp has nothing to run (#381)
  "harvested after the review was rendered"  # and a clear that left late arrivals needs nothing (#381)
)
# --- and the wording it must NOT carry any more ---------------------------
# The rule that ad hoc filing may never open a milestone was REVERSED on 2026-09-02,
# after Dan opened his list and found Ungrouped holding 98 issues in this repo, 157
# in bidspoke and 102 in new-agent-onboarding, with obvious clusters inside them. The
# assertion that used to guard the old rule is deleted rather than adjusted: its whole
# content was the decision being reversed, so keeping it in any form would leave a
# test defending the behaviour that was removed (L252).
#
# These two are the wording that CAUSED the pile-up. The ban itself, and the sentence
# that primed every idea toward the holding pen before it had even been looked at.
#
# The third is the clear command as a FIXED line (claude-config#287). It passed no session
# transcript, so it keyed on the git common dir while the render that produced the findings keyed
# on the transcript's directory, and the two agreed only when those roots coincided. The render now
# writes the command it means, so any fixed form here is a second derivation of the same key and
# the exact failure over again (L70, L285). Matched on the whole invocation rather than on the
# words, so the prose explaining why it is gone does not answer for it (L135).
forbidden=(
  "NEVER create a new milestone"
  "Most of these ideas are standalone fixes"
  "there is no third option"
  "issue-spool.sh clear \"\$PWD\""
)
for gone in "${forbidden[@]}"; do
  if [[ "$instruction" != *"$gone"* ]]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL: the instruction should no longer carry '$gone'"
  fi
done

for want in "${needs[@]}"; do
  if [[ "$instruction" == *"$want"* ]]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL: the instruction should still carry '$want'"
  fi
done

# --- the instruction must obey the writing rule it enforces ---
# It tells Claude never to use dashes as punctuation, and it once used 17 em dashes
# doing so. A rule contradicted by the prose around it loses to the demonstration
# (L270). The characters are BUILT rather than written, because a file holding one
# literally is what the pre push style hook blocks, and it cannot tell a line banning
# the character from a line using it.
emdash="$(printf '\xe2\x80\x94')"
endash="$(printf '\xe2\x80\x93')"
if [[ "$instruction" != *"$emdash"* && "$instruction" != *"$endash"* ]]; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  echo "FAIL: the instruction contains an em or en dash, which the style rule forbids"
fi

# --- the hook's fallback payload has to be valid JSON ---
# It is the one hand written JSON left in the hook. An unescaped quote there is
# invisible: Claude Code drops the hook and the review simply stops happening.
result="$(python3 - "$HOOK" <<'PY'
import json, re, sys

src = open(sys.argv[1]).read()
blocks = re.findall(r"cat <<'JSON'\n(.*?)\nJSON", src, re.S)
if not blocks:
    print("no JSON heredoc found, so the fallback payload is missing")
    sys.exit(0)
for block in blocks:
    try:
        payload = json.loads(block)
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
check "the hook's fallback payload is valid JSON with a block decision and a reason" "$result"

# ---------------------------------------------------------------------------
# The spool wiring: what the review does with findings that are waiting.
# ---------------------------------------------------------------------------
TRANSCRIPT="$WORK/transcript.jsonl"
{
  printf '%s\n' '{"type":"user","message":{"role":"user","content":"do the thing"}}'
  printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Edit","id":"t1","input":{}}]}}'
  printf '%s\n' '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}'
} > "$TRANSCRIPT"

run_review() { # run_review <project dir>
  printf '{"transcript_path":"%s","stop_hook_active":false}' "$TRANSCRIPT" | \
    CLAUDE_PROJECT_DIR="$1" bash "$HOOK"
}
reason_of() {
  printf '%s' "$1" | python3 -c '
import json, sys
raw = sys.stdin.read()
if not raw.strip():
    print("NO PAYLOAD AT ALL")
    sys.exit(0)
try:
    print(json.loads(raw).get("reason") or "")
except Exception as exc:
    print("PAYLOAD DOES NOT PARSE: %s" % exc)
'
}

# An EMPTY spool must not produce a findings pointer. A reason that always names a
# file leaves Claude opening a stale one, and a stale findings file reads exactly
# like findings that are still waiting.
EMPTY_PROJ="$(mktemp -d "$WORK/empty.XXXXXX")"
reason="$(reason_of "$(run_review "$EMPTY_PROJ")")"
[[ "$reason" != *"SUBAGENT FINDINGS"* ]] \
  && check "an empty spool produces no findings pointer" ok \
  || check "an empty spool produces no findings pointer" "[$reason]"

# A spool holding a finding must produce a pointer at a file that HOLDS that
# finding. Checked by reading the file the reason names, not by trusting that one
# was written: a pointer at an empty or missing file is the failure worth catching.
FIND_PROJ="$(mktemp -d "$WORK/withfindings.XXXXXX")"
MARKER="the widget cache is never invalidated on rename"
bash "$DIR/lib/issue-spool.sh" note "$FIND_PROJ" "$MARKER" "test-suite" "$TRANSCRIPT" >/dev/null 2>&1
reason="$(reason_of "$(run_review "$FIND_PROJ")")"

[[ "$reason" == *"SUBAGENT FINDINGS"* ]] \
  && check "a pending finding produces a findings pointer" ok \
  || check "a pending finding produces a findings pointer" "[$reason]"

[[ "$reason" == *"1 finding"* ]] \
  && check "the pointer counts the one pending finding" ok \
  || check "the pointer counts the one pending finding" "[$reason]"

named="$(printf '%s' "$reason" | python3 -c '
import re, sys
m = re.search(r"waiting in (\S+?)\. They", sys.stdin.read())
print(m.group(1) if m else "")
')"
[ -s "$named" ] \
  && check "the findings file the pointer names exists and is not empty" ok \
  || check "the findings file the pointer names exists and is not empty" "nothing at [$named]"

grep -qF "$MARKER" "$named" 2>/dev/null \
  && check "the findings file holds the finding that was spooled" ok \
  || check "the findings file holds the finding that was spooled" "[$named] does not contain it"

# The finding must SURVIVE the review. Reading does not consume the spool: a review
# that is read and then interrupted has to leave the finding for the next one, and
# only `clear` (after the picker is answered) files it away.
bash "$DIR/lib/issue-spool.sh" has-findings "$FIND_PROJ" "$TRANSCRIPT" >/dev/null 2>&1 \
  && check "the finding is still pending after the review carried it" ok \
  || check "the finding is still pending after the review carried it" "the spool no longer holds it"

# ---------------------------------------------------------------------------
# A finding an open issue already covers arrives WITH the issue number (claude-config#256).
# ---------------------------------------------------------------------------
# On 2026-09-01 eight read only agents audited every open issue in one repo. The harvest spooled
# their observations, another session's review offered them as fresh findings, and four were filed:
# each a twin of the issue the agent had been READING, closed as a duplicate within the hour. The
# harvest cannot know a problem is already tracked; the review can look.
MATCH_PROJ="$(mktemp -d "$WORK/matching.XXXXXX")"
mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
# Answers the one question the matcher asks, and records that it was asked.
printf '%s\n' "$*" >> "$GH_CALLS"
cat "$GH_ISSUES"
STUB
chmod +x "$WORK/bin/gh"
export GH_CALLS="$WORK/gh-calls.log"; : > "$GH_CALLS"
export GH_ISSUES="$WORK/issues.json"
cat > "$GH_ISSUES" <<'JSON'
[{"number": 412, "title": "The widget cache is never invalidated in widget/cache.py",
  "body": "widget/cache.py keeps a stale entry after a rename."},
 {"number": 998, "title": "Something else entirely",
  "body": "About other/thing.py and nothing to do with the above."}]
JSON
bash "$DIR/lib/issue-spool.sh" note "$MATCH_PROJ" \
  "widget/cache.py keeps a stale cache entry when a widget is renamed" "test-suite" "$TRANSCRIPT" >/dev/null 2>&1
reason="$(PATH="$WORK/bin:$PATH" reason_of "$(PATH="$WORK/bin:$PATH" run_review "$MATCH_PROJ")")"
named="$(printf '%s' "$reason" | python3 -c '
import re, sys
m = re.search(r"waiting in (\S+?)\. They", sys.stdin.read())
print(m.group(1) if m else "")
')"
# The stub really was asked, or everything below is satisfied by a matcher that never ran (L100).
grep -q "issue list" "$GH_CALLS" 2>/dev/null \
  && check "#256 the review asks for the open issues" ok \
  || check "#256 the review asks for the open issues" "gh was never called: $(cat "$GH_CALLS" 2>/dev/null)"
grep -q "already #412" "$named" 2>/dev/null \
  && check "#256 a finding an open issue already covers carries that issue's number" ok \
  || check "#256 a finding an open issue already covers carries that issue's number" "file=$(awk 'NR <= 3' "$named" 2>/dev/null)"
grep -q "already #998" "$named" 2>/dev/null \
  && check "#256 and an unrelated open issue is not attached to it" "it named #998 as well" \
  || check "#256 and an unrelated open issue is not attached to it" ok

# A finding naming a file NO open issue mentions gets nothing, or the annotation says nothing and
# would talk somebody out of filing a real finding (L159).
NOMATCH_PROJ="$(mktemp -d "$WORK/nomatch.XXXXXX")"
bash "$DIR/lib/issue-spool.sh" note "$NOMATCH_PROJ" \
  "unrelated/module.py drops its error on the floor" "test-suite" "$TRANSCRIPT" >/dev/null 2>&1
reason_nm="$(PATH="$WORK/bin:$PATH" reason_of "$(PATH="$WORK/bin:$PATH" run_review "$NOMATCH_PROJ")")"
named_nm="$(printf '%s' "$reason_nm" | python3 -c '
import re, sys
m = re.search(r"waiting in (\S+?)\. They", sys.stdin.read())
print(m.group(1) if m else "")
')"
# Asked of the LINE, not of the file. Every note here shares one transcript, so they share one
# spool key and one pending list: a file-wide grep is answered by the annotated finding above and
# says nothing about this one (L135, and it did exactly that).
_nm_line="$(grep 'unrelated/module.py' "$named_nm" 2>/dev/null || true)"
case "$_nm_line" in
  "") check "#256 a finding no open issue covers is left alone" "the finding is not in the file at all" ;;
  *"already #"*) check "#256 a finding no open issue covers is left alone" "it was annotated: $_nm_line" ;;
  *) check "#256 a finding no open issue covers is left alone" ok ;;
esac

# And it FAILS OPEN. This is a convenience on a review, and losing it must never cost the review.
FAILOPEN_PROJ="$(mktemp -d "$WORK/failopen.XXXXXX")"
cat > "$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "gh: not logged in" >&2
exit 1
STUB
chmod +x "$WORK/bin/gh"
FAILMARK="widget/cache.py still drops the rename"
bash "$DIR/lib/issue-spool.sh" note "$FAILOPEN_PROJ" "$FAILMARK" "test-suite" "$TRANSCRIPT" >/dev/null 2>&1
reason_fo="$(PATH="$WORK/bin:$PATH" reason_of "$(PATH="$WORK/bin:$PATH" run_review "$FAILOPEN_PROJ")")"
named_fo="$(printf '%s' "$reason_fo" | python3 -c '
import re, sys
m = re.search(r"waiting in (\S+?)\. They", sys.stdin.read())
print(m.group(1) if m else "")
')"
grep -qF "$FAILMARK" "$named_fo" 2>/dev/null \
  && check "#256 a gh that refuses leaves the findings going out unannotated" ok \
  || check "#256 a gh that refuses leaves the findings going out unannotated" "file=[$named_fo] $(awk 'NR <= 2' "$named_fo" 2>/dev/null)"
# And SAYS it could not look. Failing open is right; failing open in silence makes an unannotated
# list indistinguishable from a list with no duplicates in it (L10, L11).
grep -q "OPEN ISSUES NOT READ" "$named_fo" 2>/dev/null \
  && check "#256 and says the open issues could not be read" ok \
  || check "#256 and says the open issues could not be read" "file=[$named_fo]"
# The control: a run that COULD read them says nothing of the kind.
grep -q "OPEN ISSUES NOT READ" "$named" 2>/dev/null \
  && check "#256 and a run that read them says nothing about it" "it claimed it could not read them" \
  || check "#256 and a run that read them says nothing about it" ok

# The matcher on its own, by name. Driving it only through the review would leave its own refusals
# untested, and the coverage ratchet is right that a file no suite names is a file nobody checks.
MATCHER="$DIR/lib/match-open-issues.py"
matcher_out() { # matcher_out <findings text>   -> the annotated text
  printf '%s\n' "$1" | PATH="$WORK/bin:$PATH" python3 "$MATCHER" "$WORK" 2>/dev/null
}
cat > "$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
cat "$GH_ISSUES"
STUB
chmod +x "$WORK/bin/gh"
mo="$(matcher_out 'FINDING (a, b): widget/cache.py keeps a stale entry after a rename')"
case "$mo" in
  *"already #412"*) check "#256 the matcher on its own attaches the issue that names the same file" ok ;;
  *) check "#256 the matcher on its own attaches the issue that names the same file" "out=$mo" ;;
esac
# A finding naming NO file is left alone whatever words it shares. Title words alone produced false
# siblings twice in the milestone helper, always claiming a cluster that was not there (#265).
mo_nofile="$(matcher_out 'FINDING (a, b): the widget cache is never invalidated on rename')"
case "$mo_nofile" in
  *"already #"*) check "#256 a finding naming no file is never matched on words alone" "out=$mo_nofile" ;;
  *) check "#256 a finding naming no file is never matched on words alone" ok ;;
esac
# A shared file and no shared word is two findings that mention one file, not one subject.
mo_pathonly="$(matcher_out 'FINDING (a, b): widget/cache.py should log its eviction reason')"
case "$mo_pathonly" in
  *"already #412"*) check "#256 a shared path with no shared subject word is not a match" "out=$mo_pathonly" ;;
  *) check "#256 a shared path with no shared subject word is not a match" ok ;;
esac
# The PROJECT DIRECTORY IS NOT ALWAYS THE CHECKOUT (claude-config#344). In PET the workspace root
# is one level above the repo, so `gh issue list` run there refused with "not a git repository" and
# the matcher fell back to its honest OPEN ISSUES NOT READ line. Failing open was right, but the
# effect was that the duplicate check had never once run in that project: every review there judged
# duplicates with no sight of the backlog, which is the condition #265 was written about, and the
# notice reads as a footnote rather than as "this whole review was blind".
#
# This gh REFUSES outside a checkout, the way the real one does, so a matcher that did not resolve
# the repo cannot pass. It gets its own bin directory rather than overwriting the stub above, which
# the cases before this one still depend on.
mkdir -p "$WORK/bin-pet"
cat > "$WORK/bin-pet/gh" <<'STUB'
#!/usr/bin/env bash
if [ ! -e .git ]; then
  echo "fatal: not a git repository (or any of the parent directories): .git" >&2
  exit 1
fi
cat "$GH_ISSUES"
STUB
chmod +x "$WORK/bin-pet/gh"
PET_ROOT="$(mktemp -d "$WORK/pet.XXXXXX")"
mkdir -p "$PET_ROOT/pet/.git"
mo_pet="$(printf '%s\n' 'FINDING (a, b): widget/cache.py keeps a stale entry after a rename' \
  | PATH="$WORK/bin-pet:$PATH" python3 "$MATCHER" "$PET_ROOT" 2>/dev/null)"
case "$mo_pet" in
  *"already #412"*) check "#344 a project whose checkout is one level down is still matched" ok ;;
  *) check "#344 a project whose checkout is one level down is still matched" "out=$mo_pet" ;;
esac
case "$mo_pet" in
  *"OPEN ISSUES NOT READ"*) check "#344 and it does not report itself blind" "out=$mo_pet" ;;
  *) check "#344 and it does not report itself blind" ok ;;
esac
# TWO checkouts under one project directory: it must not pick one (claude-config#346). Reading
# another repository's open issues would put THAT repository's issue numbers beside these findings,
# and a wrong "already #N" is the one outcome this whole matcher is built to avoid, because it
# would talk somebody out of filing a real finding.
AMBIG_ROOT="$(mktemp -d "$WORK/ambig.XXXXXX")"
mkdir -p "$AMBIG_ROOT/alpha/.git" "$AMBIG_ROOT/beta/.git"
mo_ambig="$(printf '%s\n' 'FINDING (a, b): widget/cache.py keeps a stale entry after a rename' \
  | PATH="$WORK/bin-pet:$PATH" python3 "$MATCHER" "$AMBIG_ROOT" 2>/dev/null)"
case "$mo_ambig" in
  *"already #"*) check "#346 a project directory holding two checkouts is never matched" "out=$mo_ambig" ;;
  *) check "#346 a project directory holding two checkouts is never matched" ok ;;
esac
# And it says WHY, naming the ambiguity rather than reporting gh's complaint about a directory
# that is not a repository, which is true and is a different fault with a different remedy (L11).
case "$mo_ambig" in
  *"more than one checkout"*) check "#346 and says which fault stopped it looking" ok ;;
  *) check "#346 and says which fault stopped it looking" "out=$mo_ambig" ;;
esac
# The same two children under a project that IS a checkout, as a git WORKTREE, where `.git` is a
# file (claude-config#402). The helper's rule is that the directory itself wins whatever its children
# look like, and it tests for `.git` with `-e`. The matcher re-checked with a DIRECTORY test, so a
# worktree read as no checkout at all and was refused as ambiguous, the two halves of one rule
# disagreeing about the case agents work in by default (L263).
WTP_ROOT="$(mktemp -d "$WORK/worktree.XXXXXX")"
mkdir -p "$WTP_ROOT/alpha/.git" "$WTP_ROOT/beta/.git"
printf 'gitdir: /somewhere/else/.git/worktrees/x\n' > "$WTP_ROOT/.git"
mo_wtp="$(printf '%s\n' 'FINDING (a, b): widget/cache.py keeps a stale entry after a rename' \
  | PATH="$WORK/bin-pet:$PATH" python3 "$MATCHER" "$WTP_ROOT" 2>/dev/null)"
case "$mo_wtp" in
  *"already #412"*) check "#402 a project that is itself a worktree is matched, not refused as ambiguous" ok ;;
  *) check "#402 a project that is itself a worktree is matched, not refused as ambiguous" "out=$mo_wtp" ;;
esac

# The control. Resolving must find a checkout, never invent one: a directory with no repo anywhere
# still fails open and still SAYS so, or the case above would be satisfied by a matcher that had
# simply stopped reporting when it could not look (L11, L159).
BARE_ROOT="$(mktemp -d "$WORK/bare.XXXXXX")"
mo_bare="$(printf '%s\n' 'FINDING (a, b): widget/cache.py keeps a stale entry after a rename' \
  | PATH="$WORK/bin-pet:$PATH" python3 "$MATCHER" "$BARE_ROOT" 2>/dev/null)"
case "$mo_bare" in
  *"OPEN ISSUES NOT READ"*) check "#344 a directory with no checkout anywhere still says it could not look" ok ;;
  *) check "#344 a directory with no checkout anywhere still says it could not look" "out=$mo_bare" ;;
esac

# Text with no findings in it comes back untouched, so the matcher can never eat a report.
mo_plain="$(matcher_out 'HARVEST FAILED: one agent could not be read')"
case "$mo_plain" in
  *"HARVEST FAILED: one agent could not be read"*) check "#256 text holding no finding is passed through" ok ;;
  *) check "#256 text holding no finding is passed through" "out=$mo_plain" ;;
esac

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
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
